use std::{
    env,
    ffi::OsString,
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Stdio},
};

use anyhow::Context;

use crate::{config::ChromiumConfig, paths::AppPaths};

#[derive(Debug, Clone, Copy, Default)]
pub struct ChromiumLaunchOptions {
    pub safe_mode: bool,
    pub private: bool,
    pub x11: bool,
    pub companion: bool,
    pub new_window: bool,
}

pub struct ChromiumProcess {
    child: Child,
    _private_profile: Option<tempfile::TempDir>,
}

impl ChromiumProcess {
    pub fn try_wait(&mut self) -> std::io::Result<Option<ExitStatus>> {
        self.child.try_wait()
    }

    pub fn wait(&mut self) -> std::io::Result<ExitStatus> {
        self.child.wait()
    }
}

const CHROMIUM_CANDIDATES: &[&str] = &[
    "chromium",
    "chromium-browser",
    "google-chrome-stable",
    "google-chrome",
    "brave-browser",
    "microsoft-edge-stable",
];

pub fn find_chromium(config: &ChromiumConfig) -> Option<PathBuf> {
    if let Some(executable) = config.executable.as_deref() {
        let candidate = PathBuf::from(executable);
        return is_executable(&candidate).then_some(candidate);
    }
    CHROMIUM_CANDIDATES
        .iter()
        .find_map(|candidate| find_in_path(candidate))
}

pub fn launch_chromium(
    config: &ChromiumConfig,
    paths: &AppPaths,
    url: &str,
    options: ChromiumLaunchOptions,
) -> anyhow::Result<ChromiumProcess> {
    let executable = find_chromium(config).ok_or_else(|| {
        anyhow::anyhow!(
            "no compatible Chromium browser found; configure chromium.executable or use --engine browser"
        )
    })?;

    let private_profile = if options.private {
        Some(
            tempfile::Builder::new()
                .prefix("chatgpt-work-linux-")
                .tempdir()?,
        )
    } else {
        None
    };
    let profile_dir = private_profile
        .as_ref()
        .map(|directory| directory.path().to_owned())
        .unwrap_or_else(|| paths.data_dir.join("chromium"));
    crate::paths::ensure_private_directory(&profile_dir)?;

    let mut command = Command::new(&executable);
    command
        .arg(format!("--app={url}"))
        .arg(format!("--user-data-dir={}", profile_dir.display()))
        .arg("--no-first-run")
        .arg("--no-default-browser-check")
        .arg("--class=io.github.chatgpt_work_linux")
        .args(&config.extra_args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    if options.safe_mode {
        command.arg("--disable-gpu");
    }
    if options.private {
        command.arg("--incognito");
    }
    if options.x11 {
        command.arg("--ozone-platform=x11");
    }
    if options.companion {
        command.arg("--window-size=480,720");
    }
    if options.new_window {
        command.arg("--new-window");
    }

    let child = command
        .spawn()
        .with_context(|| format!("failed to launch {}", executable.display()))?;
    Ok(ChromiumProcess {
        child,
        _private_profile: private_profile,
    })
}

pub fn launch_system_browser(url: &str) -> anyhow::Result<()> {
    gio::AppInfo::launch_default_for_uri(url, gio::AppLaunchContext::NONE)
        .map_err(|error| anyhow::anyhow!("failed to open system browser: {error}"))
}

pub fn chromium_candidates() -> Vec<PathBuf> {
    CHROMIUM_CANDIDATES
        .iter()
        .filter_map(|candidate| find_in_path(candidate))
        .collect()
}

fn find_in_path(binary: &str) -> Option<PathBuf> {
    if binary.contains('/') {
        let path = PathBuf::from(binary);
        return path.is_file().then_some(path);
    }
    let path = env::var_os("PATH")?;
    env::split_paths(&path)
        .map(|directory| directory.join(binary))
        .find(|candidate| is_executable(candidate))
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    path.metadata()
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}

pub fn sanitized_environment_path() -> OsString {
    env::var_os("PATH").unwrap_or_else(|| OsString::from("/usr/local/bin:/usr/bin:/bin"))
}
