pub mod capture;
pub mod cli;
pub mod config;
pub mod doctor;
pub mod engine;
pub mod gui;
pub mod paths;
pub mod policy;
pub mod shortcut;
pub mod state;

pub const APP_ID_BASE: &str = "io.github.chatgpt_work_linux";
pub const APP_NAME: &str = "chatgpt-work-linux — Unofficial";
pub const DEFAULT_START_URL: &str = "https://chatgpt.com/";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn is_flatpak_sandbox() -> bool {
    std::env::var_os("FLATPAK_ID").is_some() || std::path::Path::new("/.flatpak-info").is_file()
}
