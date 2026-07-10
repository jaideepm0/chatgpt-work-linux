use std::{fs, path::Path};

use serde::{Deserialize, Serialize};

use crate::config::{RuntimeEngine, atomic_private_write};

const MAX_STATE_BYTES: u64 = 256 * 1024;

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct RuntimeState {
    pub preferred_engine: Option<RuntimeEngine>,
    pub window_width: Option<i32>,
    pub window_height: Option<i32>,
    pub window_maximized: bool,
}

impl RuntimeState {
    pub fn load(path: &Path) -> (Self, Option<String>) {
        if fs::metadata(path).is_ok_and(|metadata| metadata.len() > MAX_STATE_BYTES) {
            return (
                Self::default(),
                Some(format!(
                    "ignored oversized runtime state {}",
                    path.display()
                )),
            );
        }
        let contents = match fs::read_to_string(path) {
            Ok(contents) => contents,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return (Self::default(), None);
            }
            Err(error) => {
                return (
                    Self::default(),
                    Some(format!(
                        "could not read runtime state {}: {error}",
                        path.display()
                    )),
                );
            }
        };
        match toml::from_str(&contents) {
            Ok(state) => (state, None),
            Err(error) => (
                Self::default(),
                Some(format!(
                    "ignored invalid runtime state {}: {error}",
                    path.display()
                )),
            ),
        }
    }

    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        if self.preferred_engine == Some(RuntimeEngine::Auto) {
            anyhow::bail!("auto is not a concrete preferred engine");
        }
        if self
            .window_width
            .is_some_and(|width| !(320..=7680).contains(&width))
            || self
                .window_height
                .is_some_and(|height| !(320..=4320).contains(&height))
        {
            anyhow::bail!("saved window size is outside the supported range");
        }
        let parent = path
            .parent()
            .ok_or_else(|| anyhow::anyhow!("runtime state path has no parent directory"))?;
        crate::paths::ensure_private_directory(parent)?;
        atomic_private_write(path, toml::to_string_pretty(self)?.as_bytes())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_state_round_trips() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("state.toml");
        let state = RuntimeState {
            preferred_engine: Some(RuntimeEngine::Chromium),
            window_width: Some(900),
            window_height: Some(700),
            window_maximized: true,
        };
        state.save(&path).unwrap();
        let (loaded, warning) = RuntimeState::load(&path);
        assert!(warning.is_none());
        assert_eq!(loaded.preferred_engine, Some(RuntimeEngine::Chromium));
        assert_eq!(loaded.window_width, Some(900));
        assert!(loaded.window_maximized);
    }

    #[test]
    fn auto_cannot_be_persisted_as_a_concrete_engine() {
        let directory = tempfile::tempdir().unwrap();
        let state = RuntimeState {
            preferred_engine: Some(RuntimeEngine::Auto),
            ..RuntimeState::default()
        };
        assert!(state.save(&directory.path().join("state.toml")).is_err());
    }
}
