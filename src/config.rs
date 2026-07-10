use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
};

use clap::ValueEnum;
use serde::{Deserialize, Serialize};

use crate::DEFAULT_START_URL;

#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize, ValueEnum, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum RuntimeEngine {
    #[default]
    Auto,
    Webkit,
    Chromium,
    Browser,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum PerformancePreset {
    Auto,
    Efficient,
    #[default]
    Balanced,
    Quality,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum PermissionPolicy {
    Allow,
    #[default]
    Ask,
    Deny,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub general: GeneralConfig,
    pub performance: PerformanceConfig,
    pub privacy: PrivacyConfig,
    pub shortcuts: ShortcutConfig,
    pub chromium: ChromiumConfig,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct GeneralConfig {
    pub start_url: String,
    pub engine: RuntimeEngine,
    pub width: i32,
    pub height: i32,
    pub close_to_background: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct PerformanceConfig {
    pub preset: PerformancePreset,
    pub reduce_motion: bool,
    pub page_cache: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct PrivacyConfig {
    pub microphone: PermissionPolicy,
    pub camera: PermissionPolicy,
    pub display_capture: PermissionPolicy,
    pub geolocation: PermissionPolicy,
    pub notifications: PermissionPolicy,
    pub website_data: PermissionPolicy,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct ShortcutConfig {
    pub enabled: bool,
    pub preferred_trigger: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct ChromiumConfig {
    pub executable: Option<String>,
    pub extra_args: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct LoadedConfig {
    pub config: Config,
    pub warning: Option<String>,
}

impl Default for GeneralConfig {
    fn default() -> Self {
        Self {
            start_url: DEFAULT_START_URL.to_owned(),
            engine: RuntimeEngine::Auto,
            width: 1180,
            height: 820,
            close_to_background: false,
        }
    }
}

impl Default for PerformanceConfig {
    fn default() -> Self {
        Self {
            preset: PerformancePreset::Auto,
            reduce_motion: false,
            page_cache: true,
        }
    }
}

impl Default for PrivacyConfig {
    fn default() -> Self {
        Self {
            microphone: PermissionPolicy::Ask,
            camera: PermissionPolicy::Ask,
            display_capture: PermissionPolicy::Ask,
            geolocation: PermissionPolicy::Deny,
            notifications: PermissionPolicy::Ask,
            website_data: PermissionPolicy::Ask,
        }
    }
}

impl Default for ShortcutConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            preferred_trigger: "CTRL+ALT+space".to_owned(),
        }
    }
}

impl Config {
    pub fn load(path: &Path) -> LoadedConfig {
        if fs::metadata(path).is_ok_and(|metadata| metadata.len() > 1024 * 1024) {
            return LoadedConfig {
                config: Self::default(),
                warning: Some(format!(
                    "ignored oversized config {} (limit: 1 MiB)",
                    path.display()
                )),
            };
        }
        let contents = match fs::read_to_string(path) {
            Ok(contents) => contents,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return LoadedConfig {
                    config: Self::default(),
                    warning: None,
                };
            }
            Err(error) => {
                return LoadedConfig {
                    config: Self::default(),
                    warning: Some(format!("could not read {}: {error}", path.display())),
                };
            }
        };

        match toml::from_str::<Self>(&contents) {
            Ok(config) => LoadedConfig {
                config,
                warning: None,
            },
            Err(error) => LoadedConfig {
                config: Self::default(),
                warning: Some(format!(
                    "ignored invalid config {}: {error}",
                    path.display()
                )),
            },
        }
    }

    pub fn effective_preset(&self) -> PerformancePreset {
        match self.performance.preset {
            PerformancePreset::Auto => {
                if total_memory_mib().is_some_and(|memory| memory < 4_096) {
                    PerformancePreset::Efficient
                } else {
                    PerformancePreset::Balanced
                }
            }
            preset => preset,
        }
    }

    pub fn effective_page_cache(&self) -> bool {
        self.performance.page_cache && self.effective_preset() != PerformancePreset::Efficient
    }

    pub fn effective_web_process_memory_limit_mib(&self) -> Option<u32> {
        web_process_memory_limit_mib(total_memory_mib(), self.effective_preset())
    }

    pub fn validate(&self) -> Result<(), String> {
        let start_url = url::Url::parse(&self.general.start_url)
            .map_err(|error| format!("general.start_url is invalid: {error}"))?;
        if start_url.scheme() != "https" {
            return Err("general.start_url must use HTTPS".to_owned());
        }
        if !crate::policy::is_chatgpt_service_url(&self.general.start_url) {
            return Err("general.start_url must use the ChatGPT service origin".to_owned());
        }
        if !(320..=7680).contains(&self.general.width)
            || !(320..=4320).contains(&self.general.height)
        {
            return Err("general window size is outside the supported range".to_owned());
        }
        if self.shortcuts.preferred_trigger.len() > 128 {
            return Err("shortcuts.preferred_trigger is too long".to_owned());
        }
        if self.general.close_to_background && !self.shortcuts.enabled {
            return Err(
                "general.close_to_background requires shortcuts.enabled so the hidden app remains reachable"
                    .to_owned(),
            );
        }
        for argument in &self.chromium.extra_args {
            if !is_allowed_chromium_argument(argument) {
                return Err(format!(
                    "chromium.extra_args contains unsupported argument {argument:?}; only display and locale overrides are accepted"
                ));
            }
        }
        Ok(())
    }

    pub fn save_atomic(&self, path: &Path) -> anyhow::Result<()> {
        self.validate().map_err(anyhow::Error::msg)?;
        let parent = path
            .parent()
            .ok_or_else(|| anyhow::anyhow!("configuration path has no parent directory"))?;
        crate::paths::ensure_private_directory(parent)?;
        let payload = toml::to_string_pretty(self)?;
        atomic_private_write(path, payload.as_bytes())
    }
}

pub fn resolve_engine(
    configured: RuntimeEngine,
    command_line: Option<RuntimeEngine>,
    remembered: Option<RuntimeEngine>,
) -> RuntimeEngine {
    let requested = command_line.unwrap_or(configured);
    match requested {
        RuntimeEngine::Auto => remembered
            .filter(|engine| *engine != RuntimeEngine::Auto)
            .unwrap_or(RuntimeEngine::Webkit),
        engine => engine,
    }
}

static TEMP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub(crate) fn atomic_private_write(path: &Path, payload: &[u8]) -> anyhow::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("target path has no parent directory"))?;
    let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let filename = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("state");
    let temporary = parent.join(format!(".{filename}.tmp-{}-{sequence}", std::process::id()));

    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let result = (|| -> anyhow::Result<()> {
        let mut file = options.open(&temporary)?;
        file.write_all(payload)?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        fs::File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn is_allowed_chromium_argument(argument: &str) -> bool {
    if matches!(
        argument,
        "--disable-smooth-scrolling" | "--enable-wayland-ime"
    ) {
        return true;
    }

    if let Some(value) = argument.strip_prefix("--ozone-platform=") {
        return matches!(value, "auto" | "wayland" | "x11");
    }

    if let Some(value) = argument.strip_prefix("--force-device-scale-factor=") {
        return value
            .parse::<f32>()
            .is_ok_and(|scale| scale.is_finite() && (0.5..=4.0).contains(&scale));
    }

    if let Some(value) = argument.strip_prefix("--lang=") {
        return !value.is_empty()
            && value.len() <= 35
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'));
    }

    false
}

fn total_memory_mib() -> Option<u64> {
    let host = fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|meminfo| parse_meminfo_mib(&meminfo));
    let cgroup = cgroup_v2_memory_limit_mib().or_else(cgroup_v1_memory_limit_mib);
    match (host, cgroup) {
        (Some(host), Some(cgroup)) => Some(host.min(cgroup)),
        (host, cgroup) => host.or(cgroup),
    }
}

fn web_process_memory_limit_mib(
    available_memory_mib: Option<u64>,
    preset: PerformancePreset,
) -> Option<u32> {
    if preset != PerformancePreset::Efficient {
        return None;
    }
    let available = available_memory_mib.unwrap_or(2_048);
    Some((available / 2).clamp(512, 1_024) as u32)
}

fn parse_meminfo_mib(meminfo: &str) -> Option<u64> {
    let kib = meminfo
        .lines()
        .find_map(|line| line.strip_prefix("MemTotal:"))?
        .split_whitespace()
        .next()?
        .parse::<u64>()
        .ok()?;
    Some(kib / 1024)
}

fn cgroup_v2_memory_limit_mib() -> Option<u64> {
    let relative = fs::read_to_string("/proc/self/cgroup")
        .ok()
        .and_then(|contents| {
            contents
                .lines()
                .find_map(|line| line.strip_prefix("0::").map(std::path::PathBuf::from))
        });
    let root = Path::new("/sys/fs/cgroup");
    let current = relative
        .map(|path| root.join(path.strip_prefix("/").unwrap_or(&path)))
        .unwrap_or_else(|| root.to_owned());
    current
        .ancestors()
        .take_while(|path| path.starts_with(root))
        .filter_map(|path| read_limit_mib(&path.join("memory.max")))
        .min()
}

fn cgroup_v1_memory_limit_mib() -> Option<u64> {
    read_limit_mib(Path::new("/sys/fs/cgroup/memory/memory.limit_in_bytes"))
}

fn read_limit_mib(path: &Path) -> Option<u64> {
    let value = fs::read_to_string(path).ok()?;
    let bytes = value.trim().parse::<u64>().ok()?;
    (bytes > 0 && bytes < (1_u64 << 60)).then_some(bytes / (1024 * 1024))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_safe_and_valid() {
        let config = Config::default();
        assert!(config.validate().is_ok());
        assert_eq!(config.privacy.geolocation, PermissionPolicy::Deny);
        assert_eq!(config.general.engine, RuntimeEngine::Auto);
    }

    #[test]
    fn unknown_keys_are_rejected() {
        let result = toml::from_str::<Config>("mystery = true");
        assert!(result.is_err());
    }

    #[test]
    fn insecure_start_url_is_rejected() {
        let mut config = Config::default();
        config.general.start_url = "http://chatgpt.com".to_owned();
        assert!(config.validate().is_err());

        config.general.start_url = "https://attacker.example/".to_owned();
        assert!(config.validate().is_err());
    }

    #[test]
    fn chromium_arguments_use_a_strict_allowlist() {
        let mut config = Config::default();
        config.chromium.extra_args = vec![
            "--ozone-platform=wayland".to_owned(),
            "--force-device-scale-factor=1.25".to_owned(),
            "--lang=en-US".to_owned(),
        ];
        assert!(config.validate().is_ok());

        for dangerous in [
            "--no-sandbox",
            "--disable-web-security",
            "--ignore-certificate-errors",
            "--remote-debugging-port=9222",
            "--user-data-dir=/tmp/shared",
        ] {
            config.chromium.extra_args = vec![dangerous.to_owned()];
            assert!(config.validate().is_err(), "{dangerous}");
        }
    }

    #[test]
    fn atomic_save_round_trips_with_private_permissions() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        let config = Config::default();
        config.save_atomic(&path).unwrap();
        assert_eq!(Config::load(&path).config.general.width, 1180);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn auto_engine_uses_remembered_compatibility_choice() {
        assert_eq!(
            resolve_engine(RuntimeEngine::Auto, None, Some(RuntimeEngine::Chromium)),
            RuntimeEngine::Chromium
        );
        assert_eq!(
            resolve_engine(RuntimeEngine::Webkit, Some(RuntimeEngine::Auto), None),
            RuntimeEngine::Webkit
        );
        assert_eq!(
            resolve_engine(
                RuntimeEngine::Auto,
                Some(RuntimeEngine::Browser),
                Some(RuntimeEngine::Chromium)
            ),
            RuntimeEngine::Browser
        );
    }

    #[test]
    fn memory_and_efficient_cache_policy_are_bounded() {
        assert_eq!(parse_meminfo_mib("MemTotal:       786432 kB\n"), Some(768));
        let mut config = Config::default();
        config.performance.preset = PerformancePreset::Efficient;
        config.performance.page_cache = true;
        assert!(!config.effective_page_cache());
        assert_eq!(
            web_process_memory_limit_mib(Some(768), PerformancePreset::Efficient),
            Some(512)
        );
        assert_eq!(
            web_process_memory_limit_mib(Some(32_768), PerformancePreset::Efficient),
            Some(1_024)
        );
        assert_eq!(
            web_process_memory_limit_mib(Some(768), PerformancePreset::Balanced),
            None
        );
    }
}
