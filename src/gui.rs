use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    io::Read,
    os::{fd::AsRawFd, unix::net::UnixStream},
    path::{Path, PathBuf},
    rc::{Rc, Weak},
    time::{Duration, Instant},
};

use clap::Parser;
use gio::prelude::*;
use glib::translate::{FromGlib, ToGlibPtr};
use glib::{ControlFlow, object::Cast};
use gtk::prelude::*;
use webkit2gtk::{
    CacheModel, CookieManagerExt, CookiePersistentStorage, DeviceInfoPermissionRequest, Download,
    DownloadExt, GeolocationPermissionRequest, HardwareAccelerationPolicy, LoadEvent,
    MediaCaptureState, MemoryPressureSettings, NavigationPolicyDecision,
    NavigationPolicyDecisionExt, NotificationPermissionRequest, PermissionRequest,
    PermissionRequestExt, PolicyDecisionExt, PolicyDecisionType, Settings, SettingsExt,
    URIRequestExt, UserMediaPermissionRequest, UserMediaPermissionRequestExt, WebContext,
    WebContextExt, WebProcessTerminationReason, WebView, WebViewExt,
    WebsiteDataAccessPermissionRequest, WebsiteDataAccessPermissionRequestExt, WebsiteDataManager,
    WebsiteDataManagerExt,
};

use crate::{
    APP_NAME, DEFAULT_START_URL,
    capture::request_interactive_screenshot,
    cli::Cli,
    config::{Config, PerformancePreset, PermissionPolicy, RuntimeEngine},
    engine::{ChromiumLaunchOptions, launch_chromium, launch_system_browser},
    paths::{AppPaths, ProfileLock},
    policy::{
        NavigationDisposition, PermissionKind, is_allowed_website_data_pair, is_authentication_url,
        is_chatgpt_service_url, is_google_auth_url, is_trusted_origin, navigation_disposition,
        redact_url_for_log, sanitize_download_filename,
    },
    shortcut::start_global_shortcut,
    state::RuntimeState,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WindowRole {
    Main,
    Companion,
    Auth,
}

#[derive(Clone)]
struct WindowRecord {
    role: WindowRole,
    window: gtk::ApplicationWindow,
    webview: WebView,
    info_bar: gtk::InfoBar,
    info_label: gtk::Label,
    safe_mode: bool,
}

struct GuiState {
    application: gtk::Application,
    config: Config,
    paths: AppPaths,
    context: WebContext,
    windows: RefCell<Vec<WindowRecord>>,
    shortcut_started: Cell<bool>,
    screenshot_in_flight: Rc<Cell<bool>>,
    runtime_state: RefCell<RuntimeState>,
    private: bool,
    profile: String,
    _profile_lock: ProfileLock,
}

pub fn run(
    initial_cli: &Cli,
    config: Config,
    paths: AppPaths,
    config_warning: Option<String>,
) -> anyhow::Result<i32> {
    let mut application_id = paths.application_id(&initial_cli.profile);
    if initial_cli.private {
        application_id.push_str(".private");
    }

    let mut flags = gio::ApplicationFlags::HANDLES_COMMAND_LINE;
    if std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_none() {
        flags |= gio::ApplicationFlags::NON_UNIQUE;
    }
    let application = gtk::Application::builder()
        .application_id(&application_id)
        .flags(flags)
        .build();
    let state: Rc<RefCell<Option<Rc<GuiState>>>> = Rc::new(RefCell::new(None));
    let config = Rc::new(config);
    let paths = Rc::new(paths);
    let warning = Rc::new(config_warning);

    application.connect_command_line({
        let state = Rc::clone(&state);
        let config = Rc::clone(&config);
        let paths = Rc::clone(&paths);
        let warning = Rc::clone(&warning);
        move |application, command_line| {
            let cli = match Cli::try_parse_from(command_line.arguments()) {
                Ok(cli) if cli.is_gui_command() => cli,
                Ok(_) => {
                    eprintln!("non-GUI commands cannot be forwarded to a running GUI instance");
                    return 2;
                }
                Err(error) => {
                    eprintln!("{error}");
                    return 2;
                }
            };

            // Drop the immutable RefCell borrow before initialization stores the
            // newly-created state. Keeping the temporary borrow alive across the
            // `else` branch would panic on the first launch.
            let existing = state.borrow().as_ref().cloned();
            let current = if let Some(current) = existing {
                current
            } else {
                match GuiState::new(
                    application,
                    (*config).clone(),
                    (*paths).clone(),
                    cli.private,
                    cli.profile.clone(),
                ) {
                    Ok(created) => {
                        *state.borrow_mut() = Some(Rc::clone(&created));
                        created
                    }
                    Err(error) => {
                        eprintln!("failed to initialize chatgpt-work-linux: {error:#}");
                        return 1;
                    }
                }
            };

            current.handle_command(&cli);
            if let Some(warning) = warning.as_ref() {
                current.show_warning(warning);
            }
            0
        }
    });

    Ok(application.run().value())
}

impl GuiState {
    fn new(
        application: &gtk::Application,
        config: Config,
        paths: AppPaths,
        private: bool,
        profile: String,
    ) -> anyhow::Result<Rc<Self>> {
        paths.ensure_private_directories()?;
        let profile_lock = paths.acquire_profile_lock()?;

        if (config.performance.reduce_motion
            || config.effective_preset() == PerformancePreset::Efficient)
            && let Some(settings) = gtk::Settings::default()
        {
            settings.set_gtk_enable_animations(false);
        }

        let data_manager = if private {
            WebsiteDataManager::new_ephemeral()
        } else {
            let webkit_data = paths.webkit_data_dir();
            let webkit_cache = paths.webkit_cache_dir();
            crate::paths::ensure_private_directory(&webkit_data)?;
            crate::paths::ensure_private_directory(&webkit_cache)?;
            WebsiteDataManager::builder()
                .base_data_directory(webkit_data.to_string_lossy())
                .base_cache_directory(webkit_cache.to_string_lossy())
                .build()
        };
        data_manager.set_persistent_credential_storage_enabled(!private);

        let context = if let Some(limit_mib) = config.effective_web_process_memory_limit_mib() {
            let mut pressure = MemoryPressureSettings::new();
            pressure.set_memory_limit(limit_mib);
            WebsiteDataManager::set_memory_pressure_settings(&mut pressure);
            tracing::info!(limit_mib, "enabled efficient WebKit memory-pressure policy");
            WebContext::builder()
                .website_data_manager(&data_manager)
                .memory_pressure_settings(&pressure)
                .build()
        } else {
            WebContext::with_website_data_manager(&data_manager)
        };
        context.set_cache_model(if config.effective_page_cache() {
            CacheModel::WebBrowser
        } else {
            CacheModel::DocumentViewer
        });
        if !private && let Some(cookie_manager) = context.cookie_manager() {
            cookie_manager.set_persistent_storage(
                &paths.cookies_file().to_string_lossy(),
                CookiePersistentStorage::Sqlite,
            );
        }

        let (runtime_state, state_warning) = RuntimeState::load(&paths.runtime_state_file());
        if let Some(warning) = state_warning {
            tracing::warn!(%warning, "runtime state was not loaded");
        }
        let state = Rc::new(Self {
            application: application.clone(),
            config,
            paths,
            context,
            windows: RefCell::new(Vec::new()),
            shortcut_started: Cell::new(false),
            screenshot_in_flight: Rc::new(Cell::new(false)),
            runtime_state: RefCell::new(runtime_state),
            private,
            profile,
            _profile_lock: profile_lock,
        });
        state.configure_downloads();
        state.start_shortcut_if_enabled();
        state.install_actions();
        Ok(state)
    }

    fn handle_command(self: &Rc<Self>, cli: &Cli) {
        if cli.toggle {
            self.toggle_primary_window();
            return;
        }

        let requested_url = cli.url.as_deref().unwrap_or(&self.config.general.start_url);
        match navigation_disposition(requested_url) {
            NavigationDisposition::Internal if is_trusted_top_level(requested_url) => {}
            NavigationDisposition::Internal => {
                tracing::warn!(uri = %redact_url_for_log(requested_url), "refused non-service launch URL inside the embedded view");
                if self.primary_window().is_none() {
                    self.create_window(
                        DEFAULT_START_URL,
                        window_role(cli.companion),
                        cli.safe_mode,
                        None,
                        None,
                    );
                }
                self.show_warning(
                    "The requested address is not a ChatGPT service page and was not opened inside the application.",
                );
                return;
            }
            NavigationDisposition::External => {
                if let Err(error) = launch_system_browser(requested_url) {
                    tracing::warn!(%error, uri = %redact_url_for_log(requested_url), "could not open external URL");
                }
                if self.primary_window().is_none() {
                    self.create_window(
                        DEFAULT_START_URL,
                        window_role(cli.companion),
                        cli.safe_mode,
                        None,
                        None,
                    );
                }
                return;
            }
            NavigationDisposition::Blocked => {
                tracing::warn!(uri = %redact_url_for_log(requested_url), "blocked unsafe launch URL");
                if self.primary_window().is_none() {
                    self.create_window(
                        DEFAULT_START_URL,
                        window_role(cli.companion),
                        cli.safe_mode,
                        None,
                        None,
                    );
                }
                self.show_warning("The requested URL was blocked by the navigation policy.");
                return;
            }
        }

        if cli.companion {
            let companion = self
                .windows
                .borrow()
                .iter()
                .find(|record| record.role == WindowRole::Companion)
                .cloned();
            if let Some(companion) = companion {
                companion.window.show_all();
                companion.window.present();
            } else {
                self.create_window(
                    requested_url,
                    WindowRole::Companion,
                    cli.safe_mode,
                    None,
                    None,
                );
            }
            return;
        }
        if cli.new_window || self.primary_window().is_none() {
            self.create_window(requested_url, WindowRole::Main, cli.safe_mode, None, None);
            return;
        }

        let primary = self.primary_window();
        if let Some(primary) = primary {
            if cli.safe_mode && !primary.safe_mode {
                primary.window.close();
                self.create_window(requested_url, WindowRole::Main, true, None, None);
                return;
            }
            if primary.webview.uri().as_deref() != Some(requested_url) {
                primary.webview.load_uri(requested_url);
            }
            primary.window.show_all();
            primary.window.present();
        }
    }

    fn primary_window(&self) -> Option<WindowRecord> {
        let windows = self.windows.borrow();
        windows
            .iter()
            .find(|record| record.role == WindowRole::Main)
            .or_else(|| {
                windows
                    .iter()
                    .find(|record| record.role == WindowRole::Companion)
            })
            .cloned()
    }

    fn create_window(
        self: &Rc<Self>,
        url: &str,
        role: WindowRole,
        safe_mode: bool,
        related: Option<&WebView>,
        parent: Option<&gtk::ApplicationWindow>,
    ) -> WebView {
        let settings = build_settings(&self.config, safe_mode);
        let webview = if let Some(related) = related {
            let webview = WebView::with_related_view(related);
            webview.set_settings(&settings);
            webview
        } else {
            WebView::builder()
                .web_context(&self.context)
                .settings(&settings)
                .build()
        };

        let runtime_state = self.runtime_state.borrow().clone();
        let default_width = if role == WindowRole::Main {
            runtime_state
                .window_width
                .unwrap_or(self.config.general.width)
        } else {
            480
        };
        let default_height = if role == WindowRole::Main {
            runtime_state
                .window_height
                .unwrap_or(self.config.general.height)
        } else {
            720
        };
        let window = gtk::ApplicationWindow::builder()
            .application(&self.application)
            .title(APP_NAME)
            .default_width(default_width)
            .default_height(default_height)
            .build();
        window.set_icon_name(Some("chatgpt-work-linux"));
        if role == WindowRole::Companion {
            apply_companion_layout(&window);
        }
        if role == WindowRole::Auth
            && let Some(parent) = parent
        {
            window.set_transient_for(Some(parent));
            window.set_modal(false);
        }
        if role == WindowRole::Main && runtime_state.window_maximized {
            window.maximize();
        }

        let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
        if role != WindowRole::Auth {
            content.pack_start(&build_menu_bar(), false, false, 0);
        }
        let progress = gtk::ProgressBar::new();
        progress.set_show_text(false);
        progress.set_no_show_all(true);
        progress.set_visible(false);
        content.pack_start(&progress, false, false, 0);
        let info_bar = gtk::InfoBar::new();
        info_bar.set_message_type(gtk::MessageType::Warning);
        info_bar.set_show_close_button(true);
        let info_label = gtk::Label::new(None);
        info_label.set_line_wrap(true);
        info_label.set_xalign(0.0);
        info_bar
            .content_area()
            .pack_start(&info_label, true, true, 0);
        info_bar.hide();
        content.pack_start(&info_bar, false, false, 0);

        let capture_revealer = gtk::Revealer::new();
        let capture_bar = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        capture_bar.set_border_width(6);
        let capture_label = gtk::Label::new(Some("Media capture is active"));
        capture_label.set_xalign(0.0);
        let stop_capture = gtk::Button::with_label("Stop capture");
        capture_bar.pack_start(&capture_label, true, true, 0);
        capture_bar.pack_end(&stop_capture, false, false, 0);
        capture_revealer.add(&capture_bar);
        capture_revealer.set_reveal_child(false);
        content.pack_start(&capture_revealer, false, false, 0);
        content.pack_start(&webview, true, true, 0);
        window.add(&content);

        let record = WindowRecord {
            role,
            window: window.clone(),
            webview: webview.clone(),
            info_bar: info_bar.clone(),
            info_label,
            safe_mode,
        };
        self.windows.borrow_mut().push(record);
        self.configure_webview(&window, &webview, &info_bar, &progress, safe_mode);

        let capture_view = webview.clone();
        stop_capture.connect_clicked(move |_| {
            capture_view.set_camera_capture_state(MediaCaptureState::None);
            capture_view.set_microphone_capture_state(MediaCaptureState::None);
            capture_view.set_display_capture_state(MediaCaptureState::None);
        });
        for connect in [0_u8, 1, 2] {
            let indicator = capture_revealer.clone();
            let label = capture_label.clone();
            match connect {
                0 => webview.connect_camera_capture_state_notify(move |view| {
                    update_capture_indicator(view, &indicator, &label)
                }),
                1 => webview.connect_microphone_capture_state_notify(move |view| {
                    update_capture_indicator(view, &indicator, &label)
                }),
                _ => webview.connect_display_capture_state_notify(move |view| {
                    update_capture_indicator(view, &indicator, &label)
                }),
            };
        }

        let weak_state = Rc::downgrade(self);
        window.connect_destroy(move |destroyed| {
            if let Some(state) = weak_state.upgrade() {
                let removed_role = state
                    .windows
                    .borrow()
                    .iter()
                    .find(|record| record.window == *destroyed)
                    .map(|record| record.role);
                if removed_role == Some(WindowRole::Main) && !state.private {
                    state.save_window_state(destroyed);
                }
                state
                    .windows
                    .borrow_mut()
                    .retain(|record| record.window != *destroyed);
            }
        });

        if self.config.general.close_to_background && role != WindowRole::Auth {
            window.connect_delete_event(|window, _| {
                window.hide();
                glib::Propagation::Stop
            });
        }

        window.show_all();
        capture_revealer.set_reveal_child(false);
        info_bar.hide();
        if role == WindowRole::Auth {
            window.hide();
            let popup_window = window.clone();
            webview.connect_ready_to_show(move |_| {
                popup_window.show_all();
                popup_window.present();
            });
            let close_window = window.clone();
            webview.connect_close(move |_| close_window.close());
        }
        if related.is_none() {
            webview.load_uri(url);
        }
        if role != WindowRole::Auth {
            window.present();
        }
        webview
    }

    fn configure_webview(
        self: &Rc<Self>,
        window: &gtk::ApplicationWindow,
        webview: &WebView,
        info_bar: &gtk::InfoBar,
        progress: &gtk::ProgressBar,
        safe_mode: bool,
    ) {
        let navigation_info = info_bar.clone();
        let navigation_parent = window.clone();
        let weak_state = Rc::downgrade(self);
        webview.connect_decide_policy(move |_, decision, decision_type| {
            if !matches!(
                decision_type,
                PolicyDecisionType::NavigationAction | PolicyDecisionType::NewWindowAction
            ) {
                return false;
            }
            let Some(navigation) = decision.downcast_ref::<NavigationPolicyDecision>() else {
                decision.ignore();
                return true;
            };
            let Some(action) = navigation.navigation_action() else {
                decision.ignore();
                return true;
            };
            let user_gesture = action.is_user_gesture();
            let Some(uri) = action.request().and_then(|request| request.uri()) else {
                decision.ignore();
                return true;
            };

            if is_google_auth_url(&uri) {
                decision.ignore();
                if let Some(state) = weak_state.upgrade() {
                    state.offer_chromium_auth_handoff(&navigation_parent);
                }
                return true;
            }

            match navigation_disposition(&uri) {
                NavigationDisposition::Internal
                    if uri == "about:blank" || is_trusted_top_level(&uri) =>
                {
                    false
                }
                NavigationDisposition::Internal | NavigationDisposition::External => {
                    decision.ignore();
                    if user_gesture {
                        if let Err(error) = launch_system_browser(&uri) {
                            tracing::warn!(%error, uri = %redact_url_for_log(&uri), "could not open external navigation");
                        }
                    } else {
                        tracing::warn!(uri = %redact_url_for_log(&uri), "blocked page-initiated external navigation");
                        show_info_bar(
                            &navigation_info,
                            "Blocked a page-initiated request to open an external application or website.",
                        );
                    }
                    true
                }
                NavigationDisposition::Blocked => {
                    tracing::warn!(uri = %redact_url_for_log(&uri), "blocked unsafe navigation");
                    decision.ignore();
                    true
                }
            }
        });

        let weak_state = Rc::downgrade(self);
        let popup_parent = window.clone();
        webview.connect_create(move |related, action| {
            let uri = action.request().and_then(|request| request.uri());
            let user_gesture = action.is_user_gesture();
            let state = weak_state.upgrade()?;
            if uri.as_deref().is_some_and(is_google_auth_url) {
                state.offer_chromium_auth_handoff(&popup_parent);
                return None;
            }
            match uri.as_deref().map(navigation_disposition) {
                Some(NavigationDisposition::Internal)
                    if uri
                        .as_deref()
                        .is_some_and(|uri| uri == "about:blank" || is_trusted_top_level(uri)) =>
                {
                    Some(
                        state
                            .create_window(
                                "about:blank",
                                WindowRole::Auth,
                                safe_mode,
                                Some(related),
                                Some(&popup_parent),
                            )
                            .upcast(),
                    )
                }
                None => Some(
                    state
                        .create_window(
                            "about:blank",
                            WindowRole::Auth,
                            safe_mode,
                            Some(related),
                            Some(&popup_parent),
                        )
                        .upcast(),
                ),
                Some(NavigationDisposition::Internal) => None,
                Some(NavigationDisposition::External) => {
                    if user_gesture
                        && let Some(uri) = uri
                        && let Err(error) = launch_system_browser(&uri)
                    {
                        tracing::warn!(%error, uri = %redact_url_for_log(&uri), "could not open popup externally");
                    }
                    None
                }
                Some(NavigationDisposition::Blocked) => None,
            }
        });

        let permission_config = self.config.privacy.clone();
        webview.connect_permission_request(move |view, request| {
            handle_permission(view, request, &permission_config)
        });

        let application = self.application.clone();
        webview.connect_show_notification(move |_, web_notification| {
            let _ = web_notification;
            let notification = gio::Notification::new("ChatGPT Work notification");
            notification.set_body(Some("Open chatgpt-work-linux to view it."));
            notification.set_default_action("app.focus");
            notification.set_icon(&gio::ThemedIcon::new("chatgpt-work-linux"));
            application.send_notification(None, &notification);
            true
        });

        let title_window = window.clone();
        webview.connect_title_notify(move |view| {
            let title = view.title().filter(|title| !title.is_empty());
            title_window.set_title(&format!(
                "{} — {APP_NAME}",
                title.as_deref().unwrap_or("ChatGPT Work")
            ));
        });

        let progress_bar = progress.clone();
        webview.connect_estimated_load_progress_notify(move |view| {
            let value = view.estimated_load_progress();
            progress_bar.set_fraction(value);
            progress_bar.set_visible(value > 0.0 && value < 1.0);
        });

        let info = info_bar.clone();
        webview.connect_is_web_process_responsive_notify(move |view| {
            if !view.is_web_process_responsive() {
                show_info_bar(&info, "The web page is not responding. Reload it or use the Chromium compatibility engine.");
            }
        });

        let crash_times: Rc<RefCell<VecDeque<Instant>>> = Rc::new(RefCell::new(VecDeque::new()));
        let crash_info = info_bar.clone();
        webview.connect_web_process_terminated(move |view, reason| {
            match reason {
                WebProcessTerminationReason::ExceededMemoryLimit => {
                    tracing::warn!(?reason, "WebKit web process exceeded its memory limit");
                    show_info_bar(
                        &crash_info,
                        "The web process ran out of memory. Automatic reload is paused to avoid a loop; relaunch with --safe-mode or use the Chromium engine.",
                    );
                    return;
                }
                WebProcessTerminationReason::TerminatedByApi => {
                    tracing::warn!(?reason, "WebKit web process was terminated by an API request");
                    show_info_bar(
                        &crash_info,
                        "The web process was stopped. Reload when you are ready.",
                    );
                    return;
                }
                WebProcessTerminationReason::Crashed => {}
                _ => {
                    tracing::warn!(?reason, "WebKit web process stopped for an unknown reason");
                    show_info_bar(
                        &crash_info,
                        "The web process stopped unexpectedly. Reload it or relaunch with --safe-mode.",
                    );
                    return;
                }
            }
            let now = Instant::now();
            let mut crashes = crash_times.borrow_mut();
            while crashes.front().is_some_and(|time| now.duration_since(*time) > Duration::from_secs(60)) {
                crashes.pop_front();
            }
            crashes.push_back(now);
            let attempt = crashes.len();
            tracing::warn!(?reason, attempt, "WebKit web process terminated");
            if attempt <= 3 {
                show_info_bar(&crash_info, "The web process stopped. chatgpt-work-linux is recovering it with bounded backoff.");
                let view = view.clone();
                glib::timeout_add_local_once(Duration::from_millis(500 * (1 << (attempt - 1))), move || {
                    view.reload();
                });
            } else {
                show_info_bar(&crash_info, "The web process stopped repeatedly. Relaunch with --safe-mode or --engine chromium.");
            }
        });

        let load_failed = Rc::new(Cell::new(false));
        let load_error_visible = Rc::new(Cell::new(false));
        let load_info = info_bar.clone();
        let changed_failed = Rc::clone(&load_failed);
        let changed_error_visible = Rc::clone(&load_error_visible);
        webview.connect_load_changed(move |_, event| {
            if event == LoadEvent::Started {
                changed_failed.set(false);
            } else if event == LoadEvent::Finished
                && !changed_failed.get()
                && changed_error_visible.replace(false)
            {
                load_info.hide();
            }
        });

        let failure_info = info_bar.clone();
        let failure_state = Rc::clone(&load_failed);
        let failure_error_visible = Rc::clone(&load_error_visible);
        webview.connect_load_failed(move |_, event, failing_uri, error| {
            if event == LoadEvent::Committed || error.matches(gio::IOErrorEnum::Cancelled) {
                return false;
            }
            failure_state.set(true);
            failure_error_visible.set(true);
            tracing::warn!(uri = %redact_url_for_log(failing_uri), %error, "page load failed");
            show_info_bar(
                &failure_info,
                "Could not load ChatGPT Work. Check the network, proxy, and TLS inspection settings, then reload.",
            );
            false
        });
    }

    fn install_actions(self: &Rc<Self>) {
        add_state_action(&self.application, self, "focus", |state| {
            if let Some(primary) = state.primary_window() {
                primary.window.show_all();
                primary.window.present();
            }
        });
        add_state_action(&self.application, self, "new-window", |state| {
            state.create_window(
                &state.config.general.start_url,
                WindowRole::Main,
                state.current_safe_mode(),
                None,
                None,
            );
        });
        add_state_action(&self.application, self, "companion", |state| {
            state.create_window(
                &state.config.general.start_url,
                WindowRole::Companion,
                state.current_safe_mode(),
                None,
                None,
            );
        });
        add_state_action(&self.application, self, "back", |state| {
            if let Some(primary) = state.primary_window()
                && primary.webview.can_go_back()
            {
                primary.webview.go_back();
            }
        });
        add_state_action(&self.application, self, "forward", |state| {
            if let Some(primary) = state.primary_window()
                && primary.webview.can_go_forward()
            {
                primary.webview.go_forward();
            }
        });
        add_state_action(&self.application, self, "reload", |state| {
            if let Some(primary) = state.primary_window() {
                if primary.webview.is_loading() {
                    primary.webview.stop_loading();
                } else {
                    primary.webview.reload();
                }
            }
        });
        add_state_action(&self.application, self, "home", |state| {
            if let Some(primary) = state.primary_window() {
                primary.webview.load_uri(&state.config.general.start_url);
            }
        });
        add_state_action(&self.application, self, "open-external", |state| {
            if let Some(uri) = state
                .primary_window()
                .and_then(|primary| primary.webview.uri())
                && let Err(error) = launch_system_browser(&uri)
            {
                tracing::warn!(%error, uri = %redact_url_for_log(&uri), "could not open current page externally");
                state.show_warning("Could not open the current page in the system browser.");
            }
        });
        add_state_action(&self.application, self, "screenshot", |state| {
            state.begin_screenshot();
        });
        add_state_action(&self.application, self, "use-chromium", |state| {
            if let Some(primary) = state.primary_window() {
                state.offer_chromium_handoff(&primary.window, false);
            }
        });
        add_state_action(&self.application, self, "settings", |state| {
            state.show_settings_dialog();
        });
        add_state_action(&self.application, self, "diagnostics", |state| {
            state.show_diagnostics_dialog();
        });
        add_state_action(&self.application, self, "about", |state| {
            state.show_about_dialog();
        });
        add_state_action(&self.application, self, "quit", |state| {
            if let Some(primary) = state.primary_window() {
                state.save_window_state(&primary.window);
            }
            state.application.quit();
        });

        for (action, accelerators) in [
            ("app.new-window", &["<Primary>n"][..]),
            ("app.companion", &["<Primary><Shift>n"][..]),
            ("app.back", &["<Alt>Left"][..]),
            ("app.forward", &["<Alt>Right"][..]),
            ("app.reload", &["<Primary>r"][..]),
            ("app.home", &["<Alt>Home"][..]),
            ("app.screenshot", &["<Primary><Shift>s"][..]),
            ("app.settings", &["<Primary>comma"][..]),
            ("app.quit", &["<Primary>q"][..]),
        ] {
            self.application.set_accels_for_action(action, accelerators);
        }
    }

    fn current_safe_mode(&self) -> bool {
        self.primary_window().is_some_and(|window| window.safe_mode)
    }

    fn begin_screenshot(self: &Rc<Self>) {
        if self.screenshot_in_flight.replace(true) {
            self.show_warning("A screenshot request is already in progress.");
            return;
        }
        let Some(primary) = self.primary_window() else {
            self.screenshot_in_flight.set(false);
            return;
        };
        request_screenshot(&primary.info_bar, Rc::clone(&self.screenshot_in_flight));
    }

    fn save_window_state(&self, window: &gtk::ApplicationWindow) {
        if self.private {
            return;
        }
        let (width, height) = window.size();
        let mut state = self.runtime_state.borrow().clone();
        if !window.is_maximized() && (320..=7680).contains(&width) && (320..=4320).contains(&height)
        {
            state.window_width = Some(width);
            state.window_height = Some(height);
        }
        state.window_maximized = window.is_maximized();
        if let Err(error) = state.save(&self.paths.runtime_state_file()) {
            tracing::warn!(%error, "could not save window state");
        } else {
            *self.runtime_state.borrow_mut() = state;
        }
    }

    fn offer_chromium_auth_handoff(self: &Rc<Self>, parent: &gtk::ApplicationWindow) {
        self.offer_chromium_handoff(parent, true);
    }

    fn offer_chromium_handoff(self: &Rc<Self>, parent: &gtk::ApplicationWindow, oauth: bool) {
        if self.private {
            let dialog = gtk::MessageDialog::new(
                Some(parent),
                gtk::DialogFlags::MODAL,
                gtk::MessageType::Info,
                gtk::ButtonsType::Close,
                "Open a private Chromium session from the launcher",
            );
            dialog.set_secondary_text(Some(
                "To keep the temporary browser profile alive without retaining a hidden WebKit engine, close this window and run chatgpt-work-linux --engine chromium --private.",
            ));
            dialog.run();
            dialog.close();
            return;
        }
        let dialog = gtk::MessageDialog::new(
            Some(parent),
            gtk::DialogFlags::MODAL,
            gtk::MessageType::Question,
            gtk::ButtonsType::None,
            if oauth {
                "Continue sign-in with the Chromium compatibility engine?"
            } else {
                "Restart this profile with the Chromium compatibility engine?"
            },
        );
        dialog.set_secondary_text(Some(if oauth {
            "Google does not support sign-in inside embedded browser views. chatgpt-work-linux can reopen this isolated profile in your installed Chromium browser, where Google sign-in is supported. Cookies are never copied between engines."
        } else {
            "This uses an isolated browser profile and retains Chromium's sandbox, TLS checks, and web security. The choice will be remembered for Auto mode."
        }));
        dialog.add_button("Cancel", gtk::ResponseType::Cancel);
        dialog.add_button("Continue", gtk::ResponseType::Accept);
        let accepted = dialog.run() == gtk::ResponseType::Accept;
        dialog.close();
        if !accepted {
            return;
        }

        if !self.private {
            let mut runtime_state = self.runtime_state.borrow().clone();
            runtime_state.preferred_engine = Some(RuntimeEngine::Chromium);
            if let Err(error) = runtime_state.save(&self.paths.runtime_state_file()) {
                tracing::warn!(%error, "could not remember Chromium compatibility choice");
                self.show_warning(
                    "Could not save the compatibility-engine choice; sign-in was not moved.",
                );
                return;
            }
            *self.runtime_state.borrow_mut() = runtime_state;
        }

        let process = launch_chromium(
            &self.config.chromium,
            &self.paths,
            &self.config.general.start_url,
            ChromiumLaunchOptions {
                private: self.private,
                x11: std::env::var("GDK_BACKEND").is_ok_and(|backend| backend == "x11"),
                ..ChromiumLaunchOptions::default()
            },
        );
        match process {
            Ok(process) => drop(process),
            Err(error) => {
                tracing::warn!(%error, "could not start Chromium compatibility engine");
                self.show_warning("No compatible Chromium browser could be started. Configure chromium.executable or use email sign-in.");
                return;
            }
        }
        // A persistent Chromium profile is owned by Chromium itself. Exit the
        // WebKit controller now so a compatibility handoff never runs two full
        // rendering engines at once. Child::drop does not terminate the browser.
        self.application.quit();
    }

    fn show_diagnostics_dialog(&self) {
        let report =
            crate::doctor::DoctorReport::collect(&self.profile, self.paths.clone(), &self.config);
        show_text_dialog(
            self.primary_window().as_ref().map(|record| &record.window),
            "chatgpt-work-linux diagnostics",
            &report.render_text(),
        );
    }

    fn show_about_dialog(&self) {
        let dialog = gtk::AboutDialog::new();
        dialog.set_transient_for(self.primary_window().as_ref().map(|record| &record.window));
        dialog.set_modal(true);
        dialog.set_program_name("chatgpt-work-linux");
        dialog.set_version(Some(crate::VERSION));
        dialog.set_comments(Some(
            "Unofficial independent community client for the ChatGPT Work experience on Linux. Not affiliated with or endorsed by OpenAI.",
        ));
        dialog.set_license_type(gtk::License::MitX11);
        dialog.set_logo_icon_name(Some("chatgpt-work-linux"));
        dialog.run();
        dialog.close();
    }

    fn show_settings_dialog(self: &Rc<Self>) {
        show_settings_dialog(self);
    }

    fn configure_downloads(self: &Rc<Self>) {
        let paths = self.paths.clone();
        let application = self.application.clone();
        self.context.connect_download_started(move |_, download| {
            configure_download(download, &paths.downloads_dir, &application);
        });
    }

    fn start_shortcut_if_enabled(self: &Rc<Self>) {
        if !self.config.shortcuts.enabled
            || std::env::var_os("CHATGPT_WORK_LINUX_DISABLE_SHORTCUT").is_some()
            || self.shortcut_started.replace(true)
        {
            return;
        }
        let Ok((sender, mut receiver)) = UnixStream::pair() else {
            tracing::warn!("could not create global-shortcut event socket");
            return;
        };
        if receiver.set_nonblocking(true).is_err() {
            tracing::warn!("could not configure global-shortcut event socket");
            return;
        }

        let weak_state: Weak<Self> = Rc::downgrade(self);
        glib::source::unix_fd_add_local(
            receiver.as_raw_fd(),
            glib::IOCondition::IN | glib::IOCondition::HUP,
            move |_, condition| {
                if condition.contains(glib::IOCondition::HUP) {
                    return ControlFlow::Break;
                }
                let mut buffer = [0_u8; 32];
                if let Ok(read) = receiver.read(&mut buffer)
                    && read > 0
                    && let Some(state) = weak_state.upgrade()
                {
                    for _ in 0..read {
                        state.toggle_primary_window();
                    }
                }
                ControlFlow::Continue
            },
        );
        if let Err(error) =
            start_global_shortcut(self.config.shortcuts.preferred_trigger.clone(), sender)
        {
            self.shortcut_started.set(false);
            tracing::warn!(%error, "could not create global-shortcut thread");
        }
    }

    fn toggle_primary_window(self: &Rc<Self>) {
        let primary = self.primary_window();
        if let Some(primary) = primary {
            if primary.window.is_visible() && primary.window.is_active() {
                primary.window.hide();
            } else {
                primary.window.show_all();
                primary.window.present();
            }
        } else {
            self.create_window(
                &self.config.general.start_url,
                WindowRole::Companion,
                false,
                None,
                None,
            );
        }
    }

    fn show_warning(&self, message: &str) {
        if let Some(record) = self.primary_window() {
            record.info_label.set_text(message);
            record.info_bar.show_all();
        }
    }
}

fn add_state_action<F>(
    application: &gtk::Application,
    state: &Rc<GuiState>,
    name: &str,
    callback: F,
) where
    F: Fn(&Rc<GuiState>) + 'static,
{
    let action = gio::SimpleAction::new(name, None);
    let weak_state = Rc::downgrade(state);
    action.connect_activate(move |_, _| {
        if let Some(state) = weak_state.upgrade() {
            callback(&state);
        }
    });
    application.add_action(&action);
}

fn window_role(companion: bool) -> WindowRole {
    if companion {
        WindowRole::Companion
    } else {
        WindowRole::Main
    }
}

fn is_trusted_top_level(uri: &str) -> bool {
    is_chatgpt_service_url(uri) || is_authentication_url(uri)
}

fn update_capture_indicator(view: &WebView, revealer: &gtk::Revealer, label: &gtk::Label) {
    let mut active = Vec::new();
    if view.camera_capture_state() != MediaCaptureState::None {
        active.push("camera");
    }
    if view.microphone_capture_state() != MediaCaptureState::None {
        active.push("microphone");
    }
    if view.display_capture_state() != MediaCaptureState::None {
        active.push("screen sharing");
    }
    if active.is_empty() {
        revealer.set_reveal_child(false);
    } else {
        label.set_text(&format!("Active capture: {}", active.join(", ")));
        revealer.set_reveal_child(true);
    }
}

fn show_text_dialog(parent: Option<&gtk::ApplicationWindow>, title: &str, contents: &str) {
    let dialog = gtk::Dialog::new();
    dialog.set_title(title);
    dialog.set_modal(true);
    dialog.set_default_size(700, 460);
    dialog.set_transient_for(parent);
    dialog.add_button("Close", gtk::ResponseType::Close);
    let scroller = gtk::ScrolledWindow::new(gtk::Adjustment::NONE, gtk::Adjustment::NONE);
    scroller.set_policy(gtk::PolicyType::Automatic, gtk::PolicyType::Automatic);
    let text = gtk::TextView::new();
    text.set_editable(false);
    text.set_cursor_visible(false);
    text.set_monospace(true);
    text.set_wrap_mode(gtk::WrapMode::WordChar);
    if let Some(buffer) = text.buffer() {
        buffer.set_text(contents);
    }
    scroller.add(&text);
    dialog.content_area().pack_start(&scroller, true, true, 0);
    dialog.show_all();
    dialog.run();
    dialog.close();
}

fn show_settings_dialog(state: &Rc<GuiState>) {
    let dialog = gtk::Dialog::new();
    dialog.set_title("chatgpt-work-linux Settings");
    dialog.set_modal(true);
    dialog.set_default_size(560, 620);
    dialog.set_transient_for(state.primary_window().as_ref().map(|record| &record.window));
    dialog.add_button("Cancel", gtk::ResponseType::Cancel);
    dialog.add_button("Save", gtk::ResponseType::Accept);

    let scroller = gtk::ScrolledWindow::new(gtk::Adjustment::NONE, gtk::Adjustment::NONE);
    scroller.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
    let grid = gtk::Grid::new();
    grid.set_border_width(16);
    grid.set_row_spacing(10);
    grid.set_column_spacing(18);

    let engine = gtk::ComboBoxText::new();
    for (id, label) in [
        ("auto", "Auto (remember compatibility choice)"),
        ("webkit", "Native WebKitGTK"),
        ("chromium", "Chromium compatibility"),
        ("browser", "System browser"),
    ] {
        engine.append(Some(id), label);
    }
    engine.set_active_id(Some(engine_id(state.config.general.engine)));
    attach_setting(&grid, 0, "Rendering engine", &engine);

    let performance = gtk::ComboBoxText::new();
    for (id, label) in [
        ("auto", "Auto"),
        ("efficient", "Efficient (older hardware)"),
        ("balanced", "Balanced"),
        ("quality", "Quality"),
    ] {
        performance.append(Some(id), label);
    }
    performance.set_active_id(Some(performance_id(state.config.performance.preset)));
    attach_setting(&grid, 1, "Performance", &performance);

    let reduce_motion = gtk::Switch::new();
    reduce_motion.set_active(state.config.performance.reduce_motion);
    attach_setting(&grid, 2, "Reduce motion", &reduce_motion);
    let page_cache = gtk::Switch::new();
    page_cache.set_active(state.config.performance.page_cache);
    attach_setting(&grid, 3, "Page cache", &page_cache);

    let microphone = permission_combo(state.config.privacy.microphone);
    attach_setting(&grid, 4, "Microphone", &microphone);
    let camera = permission_combo(state.config.privacy.camera);
    attach_setting(&grid, 5, "Camera", &camera);
    let display_capture = permission_combo(state.config.privacy.display_capture);
    attach_setting(&grid, 6, "Screen sharing", &display_capture);
    let geolocation = permission_combo(state.config.privacy.geolocation);
    attach_setting(&grid, 7, "Location", &geolocation);
    let notifications = permission_combo(state.config.privacy.notifications);
    attach_setting(&grid, 8, "Notifications", &notifications);
    let website_data = permission_combo(state.config.privacy.website_data);
    attach_setting(&grid, 9, "Cross-site sign-in storage", &website_data);

    let shortcut_enabled = gtk::Switch::new();
    shortcut_enabled.set_active(state.config.shortcuts.enabled);
    attach_setting(&grid, 10, "Global shortcut", &shortcut_enabled);
    let shortcut = gtk::Entry::new();
    shortcut.set_text(&state.config.shortcuts.preferred_trigger);
    shortcut.set_max_length(128);
    attach_setting(&grid, 11, "Shortcut trigger", &shortcut);
    let close_to_background = gtk::Switch::new();
    close_to_background.set_active(state.config.general.close_to_background);
    attach_setting(&grid, 12, "Close to background", &close_to_background);

    let note = gtk::Label::new(Some(
        "Settings are stored locally with mode 0600. Engine and rendering changes apply on the next launch. Google sign-in requires Chromium compatibility mode because Google blocks embedded user-agents.",
    ));
    note.set_line_wrap(true);
    note.set_xalign(0.0);
    grid.attach(&note, 0, 13, 2, 1);

    scroller.add(&grid);
    dialog.content_area().pack_start(&scroller, true, true, 0);
    dialog.show_all();
    let response = dialog.run();
    if response == gtk::ResponseType::Accept {
        let mut updated = state.config.clone();
        updated.general.engine = parse_engine(engine.active_id().as_deref());
        updated.performance.preset = parse_performance(performance.active_id().as_deref());
        updated.performance.reduce_motion = reduce_motion.is_active();
        updated.performance.page_cache = page_cache.is_active();
        updated.privacy.microphone = parse_permission(microphone.active_id().as_deref());
        updated.privacy.camera = parse_permission(camera.active_id().as_deref());
        updated.privacy.display_capture = parse_permission(display_capture.active_id().as_deref());
        updated.privacy.geolocation = parse_permission(geolocation.active_id().as_deref());
        updated.privacy.notifications = parse_permission(notifications.active_id().as_deref());
        updated.privacy.website_data = parse_permission(website_data.active_id().as_deref());
        updated.shortcuts.enabled = shortcut_enabled.is_active();
        updated.shortcuts.preferred_trigger = shortcut.text().to_string();
        updated.general.close_to_background = close_to_background.is_active();
        match updated.save_atomic(&state.paths.config_file) {
            Ok(()) => state.show_warning(
                "Settings saved. Restart the app to apply engine and rendering changes.",
            ),
            Err(error) => {
                tracing::warn!(%error, "could not save settings");
                state.show_warning(&format!("Could not save settings: {error}"));
            }
        }
    }
    dialog.close();
}

fn attach_setting<W: IsA<gtk::Widget>>(grid: &gtk::Grid, row: i32, label: &str, widget: &W) {
    let label = gtk::Label::new(Some(label));
    label.set_xalign(0.0);
    grid.attach(&label, 0, row, 1, 1);
    grid.attach(widget, 1, row, 1, 1);
}

fn permission_combo(policy: PermissionPolicy) -> gtk::ComboBoxText {
    let combo = gtk::ComboBoxText::new();
    combo.append(Some("ask"), "Ask each time");
    combo.append(Some("allow"), "Allow");
    combo.append(Some("deny"), "Deny");
    combo.set_active_id(Some(permission_id(policy)));
    combo
}

fn permission_id(policy: PermissionPolicy) -> &'static str {
    match policy {
        PermissionPolicy::Allow => "allow",
        PermissionPolicy::Ask => "ask",
        PermissionPolicy::Deny => "deny",
    }
}

fn parse_permission(value: Option<&str>) -> PermissionPolicy {
    match value {
        Some("allow") => PermissionPolicy::Allow,
        Some("deny") => PermissionPolicy::Deny,
        _ => PermissionPolicy::Ask,
    }
}

fn engine_id(engine: RuntimeEngine) -> &'static str {
    match engine {
        RuntimeEngine::Auto => "auto",
        RuntimeEngine::Webkit => "webkit",
        RuntimeEngine::Chromium => "chromium",
        RuntimeEngine::Browser => "browser",
    }
}

fn parse_engine(value: Option<&str>) -> RuntimeEngine {
    match value {
        Some("webkit") => RuntimeEngine::Webkit,
        Some("chromium") => RuntimeEngine::Chromium,
        Some("browser") => RuntimeEngine::Browser,
        _ => RuntimeEngine::Auto,
    }
}

fn performance_id(preset: PerformancePreset) -> &'static str {
    match preset {
        PerformancePreset::Auto => "auto",
        PerformancePreset::Efficient => "efficient",
        PerformancePreset::Balanced => "balanced",
        PerformancePreset::Quality => "quality",
    }
}

fn parse_performance(value: Option<&str>) -> PerformancePreset {
    match value {
        Some("efficient") => PerformancePreset::Efficient,
        Some("quality") => PerformancePreset::Quality,
        Some("balanced") => PerformancePreset::Balanced,
        _ => PerformancePreset::Auto,
    }
}

fn build_settings(config: &Config, safe_mode: bool) -> Settings {
    let settings = Settings::new();
    let preset = config.effective_preset();
    settings.set_enable_javascript(true);
    settings.set_enable_page_cache(config.effective_page_cache());
    settings.set_enable_smooth_scrolling(!safe_mode && preset != PerformancePreset::Efficient);
    settings.set_enable_webgl(!safe_mode && preset != PerformancePreset::Efficient);
    settings.set_enable_webrtc(true);
    settings.set_enable_media(true);
    settings.set_media_playback_requires_user_gesture(true);
    settings.set_javascript_can_access_clipboard(false);
    settings.set_javascript_can_open_windows_automatically(false);
    settings.set_allow_file_access_from_file_urls(false);
    settings.set_allow_universal_access_from_file_urls(false);
    settings.set_enable_developer_extras(false);
    settings.set_hardware_acceleration_policy(if safe_mode {
        HardwareAccelerationPolicy::Never
    } else {
        match preset {
            PerformancePreset::Quality => HardwareAccelerationPolicy::Always,
            _ => HardwareAccelerationPolicy::OnDemand,
        }
    });
    settings
}

fn build_menu_bar() -> gtk::MenuBar {
    let root = gio::Menu::new();
    let file = gio::Menu::new();
    file.append(Some("New Window"), Some("app.new-window"));
    file.append(Some("Companion Window"), Some("app.companion"));
    file.append(Some("Settings"), Some("app.settings"));
    file.append(Some("Quit"), Some("app.quit"));
    root.append_submenu(Some("File"), &file);

    let view = gio::Menu::new();
    view.append(Some("Back"), Some("app.back"));
    view.append(Some("Forward"), Some("app.forward"));
    view.append(Some("Reload"), Some("app.reload"));
    view.append(Some("Home"), Some("app.home"));
    root.append_submenu(Some("View"), &view);

    let tools = gio::Menu::new();
    tools.append(Some("Take Screenshot"), Some("app.screenshot"));
    tools.append(
        Some("Open Current Page in Browser"),
        Some("app.open-external"),
    );
    tools.append(
        Some("Use Chromium Compatibility Mode"),
        Some("app.use-chromium"),
    );
    root.append_submenu(Some("Tools"), &tools);

    let help = gio::Menu::new();
    help.append(Some("Diagnostics"), Some("app.diagnostics"));
    help.append(Some("About"), Some("app.about"));
    root.append_submenu(Some("Help"), &help);
    gtk::MenuBar::from_model(&root)
}

fn request_screenshot(info_bar: &gtk::InfoBar, in_flight: Rc<Cell<bool>>) {
    show_info_bar(
        info_bar,
        "Choose a screen, window, or area. The screenshot will be copied to the clipboard.",
    );
    let Ok((sender, mut receiver)) = UnixStream::pair() else {
        in_flight.set(false);
        show_info_bar(info_bar, "Could not start the screenshot portal.");
        return;
    };
    if receiver.set_nonblocking(true).is_err() {
        in_flight.set(false);
        show_info_bar(info_bar, "Could not configure the screenshot portal.");
        return;
    }

    let result_info = info_bar.clone();
    let result_active = Rc::clone(&in_flight);
    let mut frame = Vec::with_capacity(512);
    glib::source::unix_fd_add_local(
        receiver.as_raw_fd(),
        glib::IOCondition::IN | glib::IOCondition::HUP,
        move |_, condition| {
            let mut chunk = [0_u8; 1024];
            loop {
                match receiver.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(read) => {
                        if frame.len() + read > 4100 {
                            result_active.set(false);
                            show_info_bar(
                                &result_info,
                                "The screenshot portal returned an oversized result.",
                            );
                            return ControlFlow::Break;
                        }
                        frame.extend_from_slice(&chunk[..read]);
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                    Err(error) => {
                        result_active.set(false);
                        tracing::warn!(%error, "could not read screenshot portal result");
                        show_info_bar(
                            &result_info,
                            "The screenshot portal returned an unreadable result.",
                        );
                        return ControlFlow::Break;
                    }
                }
            }

            if frame.len() >= 4 {
                let length = u32::from_be_bytes(frame[..4].try_into().unwrap()) as usize;
                if length > 4096 {
                    result_active.set(false);
                    show_info_bar(
                        &result_info,
                        "The screenshot portal returned an oversized result.",
                    );
                    return ControlFlow::Break;
                }
                if frame.len() >= length + 4 {
                    result_active.set(false);
                    let uri = std::str::from_utf8(&frame[4..length + 4]).ok();
                    if uri.is_some_and(copy_screenshot_to_clipboard) {
                        show_info_bar(
                            &result_info,
                            "Screenshot copied. Focus the message box and paste it with Ctrl+V.",
                        );
                    } else {
                        show_info_bar(
                            &result_info,
                            "The screenshot portal returned an unreadable image.",
                        );
                    }
                    return ControlFlow::Break;
                }
            }

            if condition.contains(glib::IOCondition::HUP) {
                result_active.set(false);
                if frame.is_empty() {
                    show_info_bar(&result_info, "Screenshot cancelled.");
                } else {
                    show_info_bar(
                        &result_info,
                        "The screenshot portal returned an incomplete result.",
                    );
                }
                ControlFlow::Break
            } else {
                ControlFlow::Continue
            }
        },
    );
    if let Err(error) = request_interactive_screenshot(sender) {
        in_flight.set(false);
        tracing::warn!(%error, "could not create screenshot portal thread");
        show_info_bar(info_bar, "Could not start the screenshot portal.");
    }
}

fn copy_screenshot_to_clipboard(uri: &str) -> bool {
    let Some(path) = url::Url::parse(uri).ok().and_then(|url| {
        (url.scheme() == "file")
            .then(|| url.to_file_path().ok())
            .flatten()
    }) else {
        return false;
    };
    let Ok(metadata) = std::fs::metadata(&path) else {
        return false;
    };
    if !metadata.is_file() || metadata.len() > 64 * 1024 * 1024 {
        return false;
    }
    let Some((_, width, height)) = gdk_pixbuf::Pixbuf::file_info(&path) else {
        return false;
    };
    let pixels = i64::from(width).checked_mul(i64::from(height));
    if width <= 0 || height <= 0 || pixels.is_none_or(|pixels| pixels > 32_000_000) {
        return false;
    }
    let Ok(pixbuf) = gdk_pixbuf::Pixbuf::from_file(path) else {
        return false;
    };
    gtk::Clipboard::get(&gdk::SELECTION_CLIPBOARD).set_image(&pixbuf);
    true
}

fn apply_companion_layout(window: &gtk::ApplicationWindow) {
    window.resize(480, 720);
    window.set_keep_above(true);
}

fn handle_permission(
    view: &WebView,
    request: &PermissionRequest,
    config: &crate::config::PrivacyConfig,
) -> bool {
    if !is_trusted_origin(view.uri().as_deref()) {
        request.deny();
        tracing::warn!(
            uri = %view.uri().as_deref().map(redact_url_for_log).unwrap_or_else(|| "<none>".to_owned()),
            "denied permission for untrusted origin"
        );
        return true;
    }

    let mut detail = None;
    let (kind, policy) = if let Some(media) = request.downcast_ref::<UserMediaPermissionRequest>() {
        if user_media_is_for_display_device(media) {
            (PermissionKind::DisplayCapture, config.display_capture)
        } else {
            match (media.is_for_audio_device(), media.is_for_video_device()) {
                (true, true) => (
                    PermissionKind::CameraAndMicrophone,
                    combine_policies(config.microphone, config.camera),
                ),
                (true, false) => (PermissionKind::Microphone, config.microphone),
                (false, true) => (PermissionKind::Camera, config.camera),
                (false, false) => (PermissionKind::Unknown, PermissionPolicy::Deny),
            }
        }
    } else if request.is::<DeviceInfoPermissionRequest>() {
        (
            PermissionKind::DeviceInfo,
            combine_policies(config.microphone, config.camera),
        )
    } else if let Some(website_data) = request.downcast_ref::<WebsiteDataAccessPermissionRequest>()
    {
        let current = website_data.current_domain().unwrap_or_default();
        let requesting = website_data.requesting_domain().unwrap_or_default();
        if !is_allowed_website_data_pair(&current, &requesting) {
            request.deny();
            tracing::warn!(
                current_domain = %current,
                requesting_domain = %requesting,
                "denied cross-site website data request"
            );
            return true;
        }
        detail = Some(format!(
            "This allows {requesting} to use sign-in data while the current ChatGPT page is on {current}."
        ));
        (PermissionKind::WebsiteData, config.website_data)
    } else if request.is::<GeolocationPermissionRequest>() {
        (PermissionKind::Geolocation, config.geolocation)
    } else if request.is::<NotificationPermissionRequest>() {
        (PermissionKind::Notifications, config.notifications)
    } else {
        (PermissionKind::Unknown, PermissionPolicy::Deny)
    };

    let allow = match policy {
        PermissionPolicy::Allow => true,
        PermissionPolicy::Deny => false,
        PermissionPolicy::Ask => ask_permission(view, kind, detail.as_deref()),
    };
    if allow {
        request.allow();
    } else {
        request.deny();
    }
    tracing::info!(%kind, allow, "handled web permission request");
    true
}

fn user_media_is_for_display_device(request: &UserMediaPermissionRequest) -> bool {
    // SAFETY: request is a live WebKitUserMediaPermissionRequest and this pure
    // query is available since WebKitGTK 2.34 (the application requires 2.40).
    unsafe {
        bool::from_glib(
            webkit2gtk::ffi::webkit_user_media_permission_is_for_display_device(
                request.to_glib_none().0,
            ),
        )
    }
}

fn combine_policies(left: PermissionPolicy, right: PermissionPolicy) -> PermissionPolicy {
    match (left, right) {
        (PermissionPolicy::Deny, _) | (_, PermissionPolicy::Deny) => PermissionPolicy::Deny,
        (PermissionPolicy::Allow, PermissionPolicy::Allow) => PermissionPolicy::Allow,
        _ => PermissionPolicy::Ask,
    }
}

fn ask_permission(view: &WebView, kind: PermissionKind, detail: Option<&str>) -> bool {
    let parent = view
        .toplevel()
        .and_then(|widget| widget.downcast::<gtk::Window>().ok());
    let origin = view
        .uri()
        .and_then(|uri| url::Url::parse(&uri).ok())
        .map(|url| url.origin().ascii_serialization())
        .unwrap_or_else(|| "this site".to_owned());
    let prompt = format!("Allow {origin} to use {kind}?");
    let dialog = gtk::MessageDialog::new(
        parent.as_ref(),
        gtk::DialogFlags::MODAL,
        gtk::MessageType::Question,
        gtk::ButtonsType::None,
        &prompt,
    );
    let secondary = detail.map_or_else(
        || {
            "chatgpt-work-linux does not receive this data. The permission goes directly to the loaded web service for this session."
                .to_owned()
        },
        |detail| {
            format!(
                "{detail}\n\nchatgpt-work-linux does not receive this data. The permission goes directly to the loaded web service for this session."
            )
        },
    );
    dialog.set_secondary_text(Some(&secondary));
    dialog.add_button("Deny", gtk::ResponseType::Cancel);
    dialog.add_button("Allow once", gtk::ResponseType::Accept);
    let response = dialog.run();
    dialog.close();
    response == gtk::ResponseType::Accept
}

fn configure_download(download: &Download, downloads_dir: &Path, application: &gtk::Application) {
    let directory = downloads_dir.to_owned();
    download.connect_decide_destination(move |download, suggested| {
        if let Err(error) = std::fs::create_dir_all(&directory) {
            tracing::warn!(%error, path = %directory.display(), "could not create downloads directory");
            return false;
        }
        let filename = sanitize_download_filename(suggested);
        let destination = unique_destination(&directory, &filename);
        let Ok(uri) = url::Url::from_file_path(&destination) else {
            return false;
        };
        download.set_allow_overwrite(false);
        download.set_destination(uri.as_str());
        true
    });

    let failed = Rc::new(Cell::new(false));
    let success_app = application.clone();
    let finished_failed = Rc::clone(&failed);
    download.connect_finished(move |download| {
        if finished_failed.get() {
            return;
        }
        let notification = gio::Notification::new("Download complete");
        if let Some(filename) = download
            .destination()
            .and_then(|destination| url::Url::parse(&destination).ok())
            .and_then(|url| url.to_file_path().ok())
            .and_then(|path| {
                path.file_name()
                    .map(|name| name.to_string_lossy().into_owned())
            })
        {
            notification.set_body(Some(&filename));
        }
        notification.set_default_action("app.focus");
        notification.set_icon(&gio::ThemedIcon::new("chatgpt-work-linux"));
        success_app.send_notification(None, &notification);
    });

    let failure_app = application.clone();
    let failure_state = Rc::clone(&failed);
    download.connect_failed(move |_, error| {
        failure_state.set(true);
        tracing::warn!(%error, "download failed");
        let notification = gio::Notification::new("Download failed");
        notification.set_body(Some("Open chatgpt-work-linux for details."));
        notification.set_default_action("app.focus");
        notification.set_icon(&gio::ThemedIcon::new("chatgpt-work-linux"));
        failure_app.send_notification(None, &notification);
    });
}

fn unique_destination(directory: &Path, filename: &str) -> PathBuf {
    let initial = directory.join(filename);
    if !initial.exists() {
        return initial;
    }

    let path = Path::new(filename);
    let stem = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("download");
    let extension = path.extension().and_then(|value| value.to_str());
    for counter in 1..10_000 {
        let candidate_name = if let Some(extension) = extension {
            format!("{stem} ({counter}).{extension}")
        } else {
            format!("{stem} ({counter})")
        };
        let candidate = directory.join(candidate_name);
        if !candidate.exists() {
            return candidate;
        }
    }
    directory.join(format!("download-{}", std::process::id()))
}

fn show_info_bar(info_bar: &gtk::InfoBar, message: &str) {
    if let Some(content) = info_bar
        .content_area()
        .children()
        .into_iter()
        .find_map(|widget| widget.downcast::<gtk::Label>().ok())
    {
        content.set_text(message);
    }
    info_bar.show_all();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn permission_policy_combination_is_least_privilege() {
        assert_eq!(
            combine_policies(PermissionPolicy::Allow, PermissionPolicy::Deny),
            PermissionPolicy::Deny
        );
        assert_eq!(
            combine_policies(PermissionPolicy::Allow, PermissionPolicy::Ask),
            PermissionPolicy::Ask
        );
        assert_eq!(
            combine_policies(PermissionPolicy::Allow, PermissionPolicy::Allow),
            PermissionPolicy::Allow
        );
    }

    #[test]
    fn collision_names_keep_extensions() {
        let directory = tempfile::tempdir().unwrap();
        std::fs::write(directory.path().join("report.pdf"), b"old").unwrap();
        assert_eq!(
            unique_destination(directory.path(), "report.pdf")
                .file_name()
                .unwrap(),
            "report (1).pdf"
        );
    }
}
