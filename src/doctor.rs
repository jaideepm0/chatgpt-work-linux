use std::{collections::BTreeMap, env, fs, path::Path, time::Duration};

use serde::Serialize;

use crate::{
    config::{Config, RuntimeEngine},
    engine::{chromium_candidates, find_chromium},
    paths::AppPaths,
};

#[derive(Debug, Serialize)]
pub struct DoctorReport {
    pub healthy: bool,
    pub application_version: String,
    pub operating_system: String,
    pub architecture: String,
    pub session_type: Option<String>,
    pub desktop: Option<String>,
    pub gtk_version: Option<String>,
    pub webkitgtk_version: Option<String>,
    pub chromium_candidates: Vec<String>,
    pub portal_available: bool,
    pub screenshot_portal_available: bool,
    pub global_shortcuts_portal_available: bool,
    pub profile: String,
    pub configured_engine: RuntimeEngine,
    pub paths: AppPaths,
    pub path_checks: BTreeMap<String, String>,
    pub warnings: Vec<String>,
}

impl DoctorReport {
    pub fn collect(profile: &str, paths: AppPaths, config: &Config) -> Self {
        let webkitgtk_version = Some(webkit_runtime_version());
        let gtk_version = Some(format!(
            "{}.{}.{}",
            gtk::major_version(),
            gtk::minor_version(),
            gtk::micro_version()
        ));
        let mut chromium_paths = chromium_candidates();
        if let Some(configured) = find_chromium(&config.chromium)
            && !chromium_paths.contains(&configured)
        {
            chromium_paths.insert(0, configured);
        }
        let chromium_candidates: Vec<String> = chromium_paths
            .into_iter()
            .map(|path| path.display().to_string())
            .collect();
        let (screenshot_portal_available, global_shortcuts_portal_available) =
            desktop_portal_capabilities();
        let portal_available = screenshot_portal_available || global_shortcuts_portal_available;

        let mut warnings = Vec::new();
        if webkitgtk_version.is_none() {
            warnings
                .push("webkit2gtk-4.1 is unavailable; use the Chromium or browser engine".into());
        }
        if !screenshot_portal_available {
            warnings.push("Screenshot portal is unavailable; native capture is disabled".into());
        }
        if config.shortcuts.enabled && !global_shortcuts_portal_available {
            warnings.push(
                "Global Shortcuts portal is unavailable; the desktop shortcut is disabled".into(),
            );
        }
        if config.validate().is_err() {
            warnings.push("configuration validation failed; defaults will be used".into());
        }

        let engine_available = match config.general.engine {
            RuntimeEngine::Auto => webkitgtk_version.is_some(),
            RuntimeEngine::Webkit => webkitgtk_version.is_some(),
            RuntimeEngine::Chromium => !chromium_candidates.is_empty(),
            RuntimeEngine::Browser => true,
        };

        let path_checks = [
            ("config", &paths.config_file),
            ("data", &paths.data_dir),
            ("cache", &paths.cache_dir),
            ("state", &paths.state_dir),
            ("downloads", &paths.downloads_dir),
        ]
        .into_iter()
        .map(|(name, path)| (name.to_owned(), describe_path(path)))
        .collect();

        Self {
            healthy: engine_available,
            application_version: crate::VERSION.to_owned(),
            operating_system: os_pretty_name(),
            architecture: env::consts::ARCH.to_owned(),
            session_type: env::var("XDG_SESSION_TYPE").ok(),
            desktop: env::var("XDG_CURRENT_DESKTOP").ok(),
            gtk_version,
            webkitgtk_version,
            chromium_candidates,
            portal_available,
            screenshot_portal_available,
            global_shortcuts_portal_available,
            profile: profile.to_owned(),
            configured_engine: config.general.engine,
            paths,
            path_checks,
            warnings,
        }
    }

    pub fn render_text(&self) -> String {
        let warnings = if self.warnings.is_empty() {
            "none".to_owned()
        } else {
            self.warnings.join("; ")
        };
        format!(
            "chatgpt-work-linux {}\nstatus: {}\nos: {} ({})\nsession: {} / {}\nGTK: {}\nWebKitGTK: {}\nChromium: {}\nportal: {}\nprofile: {}\nengine: {:?}\nconfig: {}\ndata: {}\ncache: {}\nwarnings: {}",
            self.application_version,
            if self.healthy { "healthy" } else { "degraded" },
            self.operating_system,
            self.architecture,
            self.session_type.as_deref().unwrap_or("unknown"),
            self.desktop.as_deref().unwrap_or("unknown"),
            self.gtk_version.as_deref().unwrap_or("not found"),
            self.webkitgtk_version.as_deref().unwrap_or("not found"),
            if self.chromium_candidates.is_empty() {
                "not found".to_owned()
            } else {
                self.chromium_candidates.join(", ")
            },
            if self.portal_available {
                "available"
            } else {
                "not found"
            },
            self.profile,
            self.configured_engine,
            self.paths.config_file.display(),
            self.paths.data_dir.display(),
            self.paths.cache_dir.display(),
            warnings,
        )
    }
}

fn webkit_runtime_version() -> String {
    // SAFETY: these WebKitGTK functions are pure version queries, accept no
    // pointers, and are available in every supported WebKitGTK 4.1 release.
    unsafe {
        format!(
            "{}.{}.{}",
            webkit2gtk::ffi::webkit_get_major_version(),
            webkit2gtk::ffi::webkit_get_minor_version(),
            webkit2gtk::ffi::webkit_get_micro_version()
        )
    }
}

fn desktop_portal_capabilities() -> (bool, bool) {
    if env::var_os("DBUS_SESSION_BUS_ADDRESS").is_none() {
        return (false, false);
    }
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    else {
        return (false, false);
    };
    runtime
        .block_on(tokio::time::timeout(Duration::from_millis(1500), async {
            let screenshot = ashpd::desktop::screenshot::ScreenshotProxy::new().await;
            let shortcuts = ashpd::desktop::global_shortcuts::GlobalShortcuts::new().await;
            (screenshot, shortcuts)
        }))
        .map(|(screenshot, shortcuts)| (screenshot.is_ok(), shortcuts.is_ok()))
        .unwrap_or((false, false))
}

fn os_pretty_name() -> String {
    fs::read_to_string("/etc/os-release")
        .ok()
        .and_then(|contents| {
            contents.lines().find_map(|line| {
                line.strip_prefix("PRETTY_NAME=")
                    .map(|value| value.trim_matches('"').to_owned())
            })
        })
        .unwrap_or_else(|| env::consts::OS.to_owned())
}

fn describe_path(path: &Path) -> String {
    match fs::metadata(path) {
        Ok(metadata) if metadata.is_dir() => "directory exists".to_owned(),
        Ok(metadata) if metadata.is_file() => "file exists".to_owned(),
        Ok(_) => "exists with unexpected type".to_owned(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => "not created yet".to_owned(),
        Err(error) => format!("unavailable: {error}"),
    }
}
