use std::{
    env, fmt,
    fs::{self, OpenOptions},
    path::{Component, Path, PathBuf},
};

use serde::Serialize;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct AppPaths {
    pub config_file: PathBuf,
    pub data_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub state_dir: PathBuf,
    pub downloads_dir: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InvalidProfileName;

pub struct ProfileLock {
    _file: fs::File,
}

impl fmt::Display for InvalidProfileName {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(
            "profile must be 1-32 ASCII letters, digits, underscores, or hyphens and start with a letter or digit",
        )
    }
}

impl std::error::Error for InvalidProfileName {}

pub fn validate_profile_name(profile: &str) -> Result<(), InvalidProfileName> {
    let mut chars = profile.chars();
    let Some(first) = chars.next() else {
        return Err(InvalidProfileName);
    };

    if profile.len() > 32
        || !first.is_ascii_alphanumeric()
        || !chars.all(|character| {
            character.is_ascii_alphanumeric() || character == '_' || character == '-'
        })
    {
        return Err(InvalidProfileName);
    }

    Ok(())
}

impl AppPaths {
    pub fn discover(profile: &str) -> anyhow::Result<Self> {
        validate_profile_name(profile)?;

        let home = home_dir()?;
        let config_home = env_path("XDG_CONFIG_HOME").unwrap_or_else(|| home.join(".config"));
        let data_home =
            env_path("XDG_DATA_HOME").unwrap_or_else(|| home.join(".local").join("share"));
        let cache_home = env_path("XDG_CACHE_HOME").unwrap_or_else(|| home.join(".cache"));
        let state_home =
            env_path("XDG_STATE_HOME").unwrap_or_else(|| home.join(".local").join("state"));

        let profile_tail = Path::new("chatgpt-work-linux")
            .join("profiles")
            .join(profile);

        Ok(Self {
            config_file: config_home.join("chatgpt-work-linux").join("config.toml"),
            data_dir: data_home.join(&profile_tail),
            cache_dir: cache_home.join(&profile_tail),
            state_dir: state_home.join(&profile_tail),
            downloads_dir: discover_downloads_dir(&home),
        })
    }

    pub fn application_id(&self, profile: &str) -> String {
        if profile == "default" {
            return crate::APP_ID_BASE.to_owned();
        }
        let encoded_profile = profile
            .as_bytes()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        format!("{}.profile_{}", crate::APP_ID_BASE, encoded_profile)
    }

    pub fn ensure_private_directories(&self) -> anyhow::Result<()> {
        ensure_private_directory(&self.data_dir)?;
        ensure_private_directory(&self.cache_dir)?;
        ensure_private_directory(&self.state_dir)?;
        if let Some(config_dir) = self.config_file.parent() {
            ensure_private_directory(config_dir)?;
        }
        Ok(())
    }

    pub fn cookies_file(&self) -> PathBuf {
        self.data_dir.join("cookies.sqlite")
    }

    pub fn webkit_data_dir(&self) -> PathBuf {
        self.data_dir.join("webkit")
    }

    pub fn webkit_cache_dir(&self) -> PathBuf {
        self.cache_dir.join("webkit")
    }

    pub fn runtime_state_file(&self) -> PathBuf {
        self.state_dir.join("state.toml")
    }

    pub fn profile_lock_file(&self) -> PathBuf {
        self.state_dir.join("instance.lock")
    }

    pub fn acquire_profile_lock(&self) -> anyhow::Result<ProfileLock> {
        ensure_private_directory(&self.state_dir)?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = options.open(self.profile_lock_file())?;
        file.try_lock().map_err(|error| {
            anyhow::anyhow!(
                "profile data is already in use by another chatgpt-work-linux process: {error}"
            )
        })?;
        Ok(ProfileLock { _file: file })
    }
}

pub fn ensure_private_directory(path: &Path) -> anyhow::Result<()> {
    fs::create_dir_all(path)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }

    Ok(())
}

fn env_path(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
}

fn home_dir() -> anyhow::Result<PathBuf> {
    let home = env::var_os("HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| anyhow::anyhow!("HOME is unset; cannot resolve XDG paths"))?;
    if !home.is_absolute() {
        anyhow::bail!("HOME must be an absolute path");
    }
    Ok(home)
}

fn discover_downloads_dir(home: &Path) -> PathBuf {
    let Some(config_home) = env_path("XDG_CONFIG_HOME").or_else(|| Some(home.join(".config")))
    else {
        return home.join("Downloads");
    };
    let user_dirs = config_home.join("user-dirs.dirs");
    let Ok(contents) = fs::read_to_string(user_dirs) else {
        return home.join("Downloads");
    };

    contents
        .lines()
        .find_map(|line| {
            let value = line
                .strip_prefix("XDG_DOWNLOAD_DIR=")?
                .trim()
                .trim_matches('"');
            if value.is_empty() {
                return None;
            }
            parse_downloads_value(value, home)
        })
        .unwrap_or_else(|| home.join("Downloads"))
}

fn parse_downloads_value(value: &str, home: &Path) -> Option<PathBuf> {
    if value == "$HOME" {
        return Some(home.to_owned());
    }
    if let Some(relative) = value.strip_prefix("$HOME/") {
        let relative = Path::new(relative);
        if relative
            .components()
            .all(|component| matches!(component, Component::Normal(_)))
        {
            return Some(home.join(relative));
        }
        return None;
    }
    let absolute = PathBuf::from(value);
    absolute.is_absolute().then_some(absolute)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_validation_is_strict() {
        for valid in ["default", "work-2", "A", "team_alpha"] {
            assert!(validate_profile_name(valid).is_ok(), "{valid}");
        }
        for invalid in ["", "-bad", "../bad", "has space", "slash/name", "🦀"] {
            assert!(validate_profile_name(invalid).is_err(), "{invalid}");
        }
        assert!(validate_profile_name(&"a".repeat(33)).is_err());
    }

    #[test]
    fn profile_application_ids_are_injective() {
        let paths = AppPaths::discover("default").unwrap();
        assert_ne!(
            paths.application_id("foo-bar"),
            paths.application_id("foo_bar")
        );
        assert_eq!(
            paths.application_id("A"),
            "io.github.chatgpt_work_linux.profile_41"
        );
        assert_eq!(
            paths.application_id("default"),
            "io.github.chatgpt_work_linux"
        );
    }

    #[test]
    fn downloads_values_must_be_absolute_and_cannot_traverse() {
        let home = Path::new("/home/tester");
        assert_eq!(
            parse_downloads_value("$HOME/Downloads", home),
            Some(PathBuf::from("/home/tester/Downloads"))
        );
        assert_eq!(
            parse_downloads_value("/srv/downloads", home),
            Some(PathBuf::from("/srv/downloads"))
        );
        assert_eq!(parse_downloads_value(".", home), None);
        assert_eq!(parse_downloads_value("$HOME/../escape", home), None);
        assert_eq!(parse_downloads_value("prefix-$HOME/Downloads", home), None);
    }
}
