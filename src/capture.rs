use std::{
    io::Write,
    os::unix::net::UnixStream,
    thread::{self, JoinHandle},
};

use ashpd::desktop::screenshot::Screenshot;

const MAX_RESULT_URI_BYTES: usize = 4096;

pub fn request_interactive_screenshot(mut result: UnixStream) -> std::io::Result<JoinHandle<()>> {
    thread::Builder::new()
        .name("chatgpt-work-linux-screenshot".to_owned())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(error) => {
                    tracing::warn!(%error, "could not start screenshot portal runtime");
                    return;
                }
            };
            let uri = runtime.block_on(async {
                Screenshot::request()
                    .interactive(true)
                    .modal(true)
                    .send()
                    .await?
                    .response()
                    .map(|response| response.uri().as_str().to_owned())
            });
            match uri {
                Ok(uri) => {
                    let bytes = uri.as_bytes();
                    if bytes.len() > MAX_RESULT_URI_BYTES {
                        tracing::warn!(bytes = bytes.len(), "screenshot result URI was too large");
                    } else if result
                        .write_all(&(bytes.len() as u32).to_be_bytes())
                        .and_then(|_| result.write_all(bytes))
                        .is_err()
                    {
                        tracing::warn!("screenshot result receiver closed early");
                    }
                }
                Err(error) => tracing::warn!(%error, "screenshot request was cancelled or failed"),
            }
        })
}
