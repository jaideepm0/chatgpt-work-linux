use std::{
    io::Write,
    os::unix::net::UnixStream,
    thread::{self, JoinHandle},
};

use ashpd::desktop::{
    CreateSessionOptions,
    global_shortcuts::{BindShortcutsOptions, GlobalShortcuts, NewShortcut},
};
use futures_util::StreamExt;

pub const TOGGLE_SHORTCUT_ID: &str = "toggle-chatgpt-work-linux";

pub fn start_global_shortcut(
    preferred_trigger: String,
    mut events: UnixStream,
) -> std::io::Result<JoinHandle<()>> {
    thread::Builder::new()
        .name("chatgpt-work-linux-shortcut".to_owned())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(error) => {
                    tracing::warn!(%error, "could not start global-shortcut runtime");
                    return;
                }
            };

            if let Err(error) = runtime.block_on(run_shortcut(preferred_trigger, &mut events)) {
                tracing::warn!(%error, "global shortcut unavailable");
            }
        })
}

async fn run_shortcut(preferred_trigger: String, events: &mut UnixStream) -> anyhow::Result<()> {
    let portal = GlobalShortcuts::new().await?;
    let session = portal
        .create_session(CreateSessionOptions::default())
        .await?;
    let session_handle = serde_json::to_value(&session)?
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("portal returned an invalid shortcut session handle"))?
        .to_owned();
    let shortcut = NewShortcut::new(TOGGLE_SHORTCUT_ID, "Show or hide chatgpt-work-linux")
        .preferred_trigger(Some(preferred_trigger.as_str()));
    let request = portal
        .bind_shortcuts(&session, &[shortcut], None, BindShortcutsOptions::default())
        .await?;
    let response = request.response()?;
    if !response
        .shortcuts()
        .iter()
        .any(|shortcut| shortcut.id() == TOGGLE_SHORTCUT_ID)
    {
        anyhow::bail!("the desktop did not bind the requested shortcut");
    }

    tracing::info!(
        trigger = %response.shortcuts()[0].trigger_description(),
        "global shortcut registered"
    );

    let mut activated = portal.receive_activated().await?;
    while let Some(event) = activated.next().await {
        if event.session_handle().as_str() == session_handle
            && event.shortcut_id() == TOGGLE_SHORTCUT_ID
            && events.write_all(&[1]).is_err()
        {
            break;
        }
    }
    Ok(())
}
