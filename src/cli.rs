use std::path::PathBuf;

use clap::{Parser, Subcommand};

use crate::{config::RuntimeEngine, paths::validate_profile_name};

#[derive(Debug, Clone, Parser)]
#[command(
    name = "chatgpt-work-linux",
    version,
    about = "Lightweight Linux desktop workspace for the ChatGPT Work web surface",
    disable_help_subcommand = true
)]
pub struct Cli {
    /// Isolated browser profile name.
    #[arg(long, global = true, default_value = "default", value_parser = validate_profile)]
    pub profile: String,

    /// Override the configured browser engine.
    #[arg(long, global = true, value_enum)]
    pub engine: Option<RuntimeEngine>,

    /// Disable GPU/WebGL and optional visual effects for recovery.
    #[arg(long, global = true)]
    pub safe_mode: bool,

    /// Use an ephemeral WebKit session that is deleted on exit.
    #[arg(long, global = true)]
    pub private: bool,

    /// Prefer X11 for this launch (must be supplied to the first instance).
    #[arg(long, global = true)]
    pub x11: bool,

    /// Open the compact, always-on-top companion layout.
    #[arg(long)]
    pub companion: bool,

    /// Toggle the existing window, or launch it if it is not running.
    #[arg(long)]
    pub toggle: bool,

    /// Open another window in the current profile.
    #[arg(long)]
    pub new_window: bool,

    /// Trusted ChatGPT/OpenAI URL to open. Other URLs open in the system browser.
    #[arg(value_name = "URL")]
    pub url: Option<String>,

    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Debug, Clone, Subcommand)]
pub enum Command {
    /// Print a host/runtime diagnostic report without starting the GUI.
    Doctor {
        #[arg(long)]
        json: bool,
    },

    /// Print XDG paths used by the selected profile.
    Paths {
        #[arg(long)]
        json: bool,
    },

    /// Print the effective configuration with secrets redacted.
    PrintConfig {
        #[arg(long)]
        json: bool,
    },

    /// Remove only disposable browser caches; login data is preserved.
    ClearCache {
        /// Required for non-interactive deletion.
        #[arg(long)]
        yes: bool,
    },

    /// Inspect a locally downloaded official DMG without executing it.
    InspectUpstream {
        #[arg(default_value = "ChatGPT-work.dmg")]
        dmg: PathBuf,
    },
}

fn validate_profile(value: &str) -> Result<String, String> {
    validate_profile_name(value)
        .map(|_| value.to_owned())
        .map_err(|error| error.to_string())
}

impl Cli {
    pub fn is_gui_command(&self) -> bool {
        self.command.is_none()
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser;

    use super::*;

    #[test]
    fn parses_gui_options() {
        let cli = Cli::try_parse_from([
            "chatgpt-work-linux",
            "--profile",
            "work_2",
            "--safe-mode",
            "--companion",
            "https://chatgpt.com/",
        ])
        .unwrap();

        assert_eq!(cli.profile, "work_2");
        assert!(cli.safe_mode);
        assert!(cli.companion);
        assert!(cli.is_gui_command());
    }

    #[test]
    fn rejects_unsafe_profile_name() {
        let result = Cli::try_parse_from(["chatgpt-work-linux", "--profile", "../escape"]);
        assert!(result.is_err());
    }
}
