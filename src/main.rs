use std::{env, fs, path::PathBuf, process::Command as ProcessCommand};

use anyhow::Context;
use chatgpt_work_linux::{
    cli::{Cli, Command},
    config::{Config, RuntimeEngine, resolve_engine},
    doctor::DoctorReport,
    engine::{ChromiumLaunchOptions, launch_chromium, launch_system_browser},
    paths::AppPaths,
    policy::{NavigationDisposition, is_chatgpt_service_url, navigation_disposition},
    state::RuntimeState,
};
use clap::Parser;
use tracing_subscriber::EnvFilter;

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("chatgpt_work_linux=info,warn")),
        )
        .with_target(false)
        .compact()
        .init();

    if let Err(error) = run() {
        eprintln!("chatgpt-work-linux: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    let cli = Cli::parse();
    if cli.x11 {
        // SAFETY: this happens on the initial single-threaded path, before GTK or any worker starts.
        unsafe { env::set_var("GDK_BACKEND", "x11") };
    }

    let paths = AppPaths::discover(&cli.profile)?;
    let loaded = Config::load(&paths.config_file);
    let mut config = loaded.config;
    let mut warnings = loaded.warning.into_iter().collect::<Vec<_>>();
    if let Err(error) = config.validate() {
        tracing::warn!(%error, "using default configuration after validation failure");
        warnings.push(format!("invalid configuration was ignored: {error}"));
        config = Config::default();
    }
    let (runtime_state, state_warning) = RuntimeState::load(&paths.runtime_state_file());
    warnings.extend(state_warning);

    if let Some(command) = &cli.command {
        return handle_command(command, &cli, &paths, &config);
    }

    let engine = resolve_engine(
        config.general.engine,
        cli.engine,
        runtime_state.preferred_engine,
    );
    validate_engine_options(engine, &cli)?;
    let url = cli.url.as_deref().unwrap_or(&config.general.start_url);
    match engine {
        RuntimeEngine::Auto => unreachable!("auto engine must be resolved before dispatch"),
        RuntimeEngine::Webkit => {
            let code = chatgpt_work_linux::gui::run(
                &cli,
                config,
                paths,
                (!warnings.is_empty()).then(|| warnings.join("\n")),
            )?;
            if code != 0 {
                anyhow::bail!("GUI exited with status {code}");
            }
        }
        RuntimeEngine::Chromium => match navigation_disposition(url) {
            NavigationDisposition::Internal if is_chatgpt_service_url(url) => {
                let _profile_lock = paths.acquire_profile_lock()?;
                let mut process = launch_chromium(
                    &config.chromium,
                    &paths,
                    url,
                    ChromiumLaunchOptions {
                        safe_mode: cli.safe_mode,
                        private: cli.private,
                        x11: cli.x11,
                        companion: cli.companion,
                        new_window: cli.new_window,
                    },
                )?;
                let status = process
                    .wait()
                    .context("failed while waiting for Chromium")?;
                if !status.success() {
                    anyhow::bail!("Chromium compatibility engine exited with {status}");
                }
            }
            NavigationDisposition::Internal | NavigationDisposition::External => {
                launch_system_browser(url)?
            }
            NavigationDisposition::Blocked => {
                anyhow::bail!("refusing to launch a URL blocked by the navigation policy")
            }
        },
        RuntimeEngine::Browser => {
            if navigation_disposition(url) == NavigationDisposition::Blocked {
                anyhow::bail!("refusing to launch a URL blocked by the navigation policy");
            }
            launch_system_browser(url)?;
        }
    }
    Ok(())
}

fn validate_engine_options(engine: RuntimeEngine, cli: &Cli) -> anyhow::Result<()> {
    match engine {
        RuntimeEngine::Auto => anyhow::bail!("auto engine was not resolved"),
        RuntimeEngine::Webkit => Ok(()),
        RuntimeEngine::Chromium if cli.toggle => {
            anyhow::bail!("--toggle is only available with the native WebKit engine")
        }
        RuntimeEngine::Chromium => Ok(()),
        RuntimeEngine::Browser
            if cli.toggle
                || cli.companion
                || cli.new_window
                || cli.private
                || cli.safe_mode
                || cli.x11 =>
        {
            anyhow::bail!(
                "window, private-session, and rendering options are unavailable with --engine browser"
            )
        }
        RuntimeEngine::Browser => Ok(()),
    }
}

fn handle_command(
    command: &Command,
    cli: &Cli,
    paths: &AppPaths,
    config: &Config,
) -> anyhow::Result<()> {
    match command {
        Command::Doctor { json } => {
            let report = DoctorReport::collect(&cli.profile, paths.clone(), config);
            if *json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                println!("{}", report.render_text());
            }
            if !report.healthy {
                anyhow::bail!("no configured rendering engine is available");
            }
        }
        Command::Paths { json } => {
            if *json {
                println!("{}", serde_json::to_string_pretty(paths)?);
            } else {
                println!("config={}", paths.config_file.display());
                println!("data={}", paths.data_dir.display());
                println!("cache={}", paths.cache_dir.display());
                println!("state={}", paths.state_dir.display());
                println!("downloads={}", paths.downloads_dir.display());
            }
        }
        Command::PrintConfig { json } => {
            if *json {
                println!("{}", serde_json::to_string_pretty(config)?);
            } else {
                println!("{}", toml::to_string_pretty(config)?);
            }
        }
        Command::ClearCache { yes } => {
            if !yes {
                anyhow::bail!("refusing to remove cache without --yes");
            }
            let _profile_lock = paths.acquire_profile_lock()?;
            match fs::remove_dir_all(&paths.cache_dir) {
                Ok(()) => println!("removed {}", paths.cache_dir.display()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    println!("cache did not exist: {}", paths.cache_dir.display());
                }
                Err(error) => return Err(error).context("failed to remove browser cache"),
            }
        }
        Command::InspectUpstream { dmg } => run_upstream_inspector(dmg)?,
    }
    Ok(())
}

fn run_upstream_inspector(dmg: &std::path::Path) -> anyhow::Result<()> {
    let inspector = locate_inspector().ok_or_else(|| {
        anyhow::anyhow!(
            "upstream inspector was not installed; run scripts/inspect-upstream.py from a source checkout"
        )
    })?;
    let status = ProcessCommand::new("python3")
        .arg(&inspector)
        .arg("--dmg")
        .arg(dmg)
        .status()
        .with_context(|| format!("failed to run {}", inspector.display()))?;
    if !status.success() {
        anyhow::bail!("upstream inspector failed with {status}");
    }
    Ok(())
}

fn locate_inspector() -> Option<PathBuf> {
    if let Some(path) = env::var_os("CHATGPT_WORK_LINUX_UPSTREAM_INSPECTOR").map(PathBuf::from)
        && path.is_file()
    {
        return Some(path);
    }
    let installed = env::current_exe()
        .ok()?
        .parent()?
        .join("../lib/chatgpt-work-linux/inspect-upstream.py");
    if installed.is_file() {
        return Some(installed);
    }
    if cfg!(debug_assertions) {
        let source_path = env::current_dir()
            .ok()?
            .join("scripts")
            .join("inspect-upstream.py");
        if source_path.is_file() {
            return Some(source_path);
        }
    }
    None
}
