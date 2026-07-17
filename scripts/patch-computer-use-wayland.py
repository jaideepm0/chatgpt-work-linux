#!/usr/bin/env python3
"""Harden the disposable Computer Use adapter for portal-only Wayland input."""

from __future__ import annotations

import argparse
import os
from pathlib import Path


ORIGINAL = """        let mut args = vec![\"key\".to_string()];
        args.extend(key_events);
        let result = run_ydotool(&args).await.map(|output| vec![output]);
"""

BROKEN_PATCHED = """        let mut pressed_keycodes = key_events
            .iter()
            .filter_map(|event| event.strip_suffix(\":1\"))
            .filter_map(|keycode| keycode.parse::<i32>().ok())
            .collect::<Vec<_>>();
        let keycode = pressed_keycodes
            .pop()
            .expect(\"validated key sequence must contain a pressed key\");
        let result = match self.ensure_portal_keyboard_session().await {
            Ok(Some(session)) => {
                match press_keycode_chord(&session, &pressed_keycodes, keycode).await {
                    Ok(()) => Ok(vec![
                        \"Action sent through the Wayland remote desktop portal.\".to_string(),
                    ]),
                    Err(error) => {
                        self.clear_portal_keyboard_session();
                        Err(error)
                    }
                }
            }
            Ok(None) => {
                let mut args = vec![\"key\".to_string()];
                args.extend(key_events);
                run_ydotool(&args).await.map(|output| vec![output])
            }
            Err(error) => Err(error),
        };
"""

PORTAL_PRESS_KEY = """        let mut pressed_keycodes = key_events
            .iter()
            .filter_map(|event| event.strip_suffix(\":1\"))
            .filter_map(|keycode| keycode.parse::<i32>().ok())
            .collect::<Vec<_>>();
        let keycode = pressed_keycodes
            .pop()
            .expect(\"validated key sequence must contain a pressed key\");
        match self.ensure_portal_keyboard_session().await {
            Ok(Some(session)) => {
                match press_keycode_chord(&session, &pressed_keycodes, keycode).await {
                    Ok(()) => {
                        let notes = self.input_landing_notes(focus.as_ref(), false).await;
                        return Json(with_notes(
                            successful_action_with_focus(
                                \"press_key\",
                                \"Action sent through the Wayland remote desktop portal.\",
                                received,
                                focus,
                            ),
                            notes,
                        ));
                    }
                    Err(error) => {
                        self.clear_portal_keyboard_session();
                        return Json(action_result_with_focus(
                            \"press_key\",
                            Err(format!(\"{error:#}\")),
                            received,
                            focus,
                        ));
                    }
                }
            }
            Ok(None) => {}
            Err(error) => {
                return Json(action_result_with_focus(
                    \"press_key\",
                    Err(format!(\"{error:#}\")),
                    received,
                    focus,
                ));
            }
        }
        let mut args = vec![\"key\".to_string()];
        args.extend(key_events);
        let result = run_ydotool(&args).await.map(|output| vec![output]);
"""

PATCHED = """        let mut pressed_keycodes = key_events
            .iter()
            .filter_map(|event| event.strip_suffix(\":1\"))
            .filter_map(|keycode| keycode.parse::<i32>().ok())
            .collect::<Vec<_>>();
        let keycode = pressed_keycodes
            .pop()
            .expect(\"validated key sequence must contain a pressed key\");
        match self.ensure_portal_keyboard_session().await {
            Ok(Some(session)) => {
                let focus = match self.focus_target_for_input(&params.window_target()).await {
                    Ok(focus) => focus,
                    Err(message) => {
                        return Json(ActionOutput {
                            ok: false,
                            implemented: true,
                            action: \"press_key\".to_string(),
                            message,
                            received,
                        });
                    }
                };
                match press_keycode_chord(&session, &pressed_keycodes, keycode).await {
                    Ok(()) => {
                        let notes = self.input_landing_notes(focus.as_ref(), false).await;
                        return Json(with_notes(
                            successful_action_with_focus(
                                \"press_key\",
                                \"Action sent through the Wayland remote desktop portal.\",
                                received,
                                focus,
                            ),
                            notes,
                        ));
                    }
                    Err(error) => {
                        self.clear_portal_keyboard_session();
                        return Json(action_result_with_focus(
                            \"press_key\",
                            Err(format!(\"{error:#}\")),
                            received,
                            focus,
                        ));
                    }
                }
            }
            Ok(None) => {}
            Err(error) => {
                return Json(action_result_with_focus(
                    \"press_key\",
                    Err(format!(\"{error:#}\")),
                    received,
                    focus,
                ));
            }
        }
        let mut args = vec![\"key\".to_string()];
        args.extend(key_events);
        let result = run_ydotool(&args).await.map(|output| vec![output]);
"""

ORIGINAL_ABS_POINTER_GUARD = """        if env_flag_enabled_any(&[
            \"CU_DISABLE_ABS_POINTER\",
            \"CODEX_COMPUTER_USE_DISABLE_ABS_POINTER\",
        ]) {
            return false;
        }
"""
PATCHED_ABS_POINTER_GUARD = """        if self.is_wayland_session()
            || env_flag_enabled_any(&[
                \"CU_DISABLE_ABS_POINTER\",
                \"CODEX_COMPUTER_USE_DISABLE_ABS_POINTER\",
            ])
        {
            return false;
        }
"""

ORIGINAL_POINTER_PREFERENCE = """    fn should_prefer_portal_pointer_backend(&self) -> bool {
        if env_flag_enabled_any(&[
            \"COMPUTER_USE_LINUX_FORCE_YDOTOOL_POINTER\",
            \"CODEX_COMPUTER_USE_FORCE_YDOTOOL_POINTER\",
        ]) {
            return false;
        }
        if env_flag_enabled_any(&[
            \"COMPUTER_USE_LINUX_FORCE_PORTAL_POINTER\",
            \"CODEX_COMPUTER_USE_FORCE_PORTAL_POINTER\",
        ]) {
            return self.is_wayland_session();
        }
        should_prefer_portal_backend_by_default(
            self.is_wayland_session(),
            ydotool_backend_available(),
        )
    }
"""
PATCHED_POINTER_PREFERENCE = """    fn should_prefer_portal_pointer_backend(&self) -> bool {
        self.is_wayland_session()
    }
"""

ORIGINAL_KEYBOARD_PREFERENCE = """    fn should_prefer_portal_keyboard_backend(&self) -> bool {
        if env_flag_enabled_any(&[
            \"COMPUTER_USE_LINUX_FORCE_YDOTOOL_KEYBOARD\",
            \"CODEX_COMPUTER_USE_FORCE_YDOTOOL_KEYBOARD\",
        ]) {
            return false;
        }
        if env_flag_enabled_any(&[
            \"COMPUTER_USE_LINUX_FORCE_PORTAL_KEYBOARD\",
            \"CODEX_COMPUTER_USE_FORCE_PORTAL_KEYBOARD\",
        ]) {
            return self.is_wayland_session() && !self.is_kde_wayland_session();
        }
        !self.is_kde_wayland_session()
            && should_prefer_portal_backend_by_default(
                self.is_wayland_session(),
                ydotool_backend_available(),
            )
    }
"""
PATCHED_KEYBOARD_PREFERENCE = """    fn should_prefer_portal_keyboard_backend(&self) -> bool {
        self.is_wayland_session()
    }
"""

ORIGINAL_KEYBOARD_SESSION_GUARD = """        if env_flag_enabled_any(&[
            \"COMPUTER_USE_LINUX_FORCE_YDOTOOL_KEYBOARD\",
            \"CODEX_COMPUTER_USE_FORCE_YDOTOOL_KEYBOARD\",
        ]) || !self.is_wayland_session()
        {
            return Ok(None);
        }
"""
PATCHED_KEYBOARD_SESSION_GUARD = """        if !self.is_wayland_session() {
            return Ok(None);
        }
"""

ORIGINAL_KDE_TARGET_CONDITION = """        if self.should_prefer_kde_clipboard_text_backend() {
"""
PATCHED_KDE_TARGET_CONDITION = """        if self.should_prefer_kde_clipboard_text_backend() && !params.window_target().has_target() {
"""

ORIGINAL_PORTAL_TYPE_TEXT = """                    Ok(Some(session)) => match type_text_with_keysyms(&session, &keysyms).await {
                        Ok(()) => {
                            let notes = self.input_landing_notes(focus.as_ref(), true).await;
                            return Json(with_notes(
                                successful_action_with_focus(
                                    \"type_text\",
                                    \"Action sent through the remote desktop portal.\",
                                    received,
                                    focus,
                                ),
                                notes,
                            ));
                        }
                        Err(error) => {
                            self.clear_portal_keyboard_session();
                            return Json(action_result_with_focus(
                                \"type_text\",
                                Err(format!(\"{error:#}\")),
                                received,
                                focus,
                            ));
                        }
                    },
"""
PATCHED_PORTAL_TYPE_TEXT = """                    Ok(Some(session)) => {
                        let focus = match self.focus_target_for_input(&params.window_target()).await
                        {
                            Ok(focus) => focus,
                            Err(message) => {
                                return Json(ActionOutput {
                                    ok: false,
                                    implemented: true,
                                    action: \"type_text\".to_string(),
                                    message,
                                    received,
                                });
                            }
                        };
                        match type_text_with_keysyms(&session, &keysyms).await {
                            Ok(()) => {
                                let notes = self.input_landing_notes(focus.as_ref(), true).await;
                                return Json(with_notes(
                                    successful_action_with_focus(
                                        \"type_text\",
                                        \"Action sent through the remote desktop portal.\",
                                        received,
                                        focus,
                                    ),
                                    notes,
                                ));
                            }
                            Err(error) => {
                                self.clear_portal_keyboard_session();
                                return Json(action_result_with_focus(
                                    \"type_text\",
                                    Err(format!(\"{error:#}\")),
                                    received,
                                    focus,
                                ));
                            }
                        }
                    }
"""

ORIGINAL_YDOTOOL_COMMAND = """async fn run_ydotool(args: &[String]) -> std::result::Result<Output, String> {
    ydotool::ensure_supported()?;
    let mut command = TokioCommand::new(\"ydotool\");
"""
PATCHED_YDOTOOL_COMMAND = """async fn run_ydotool(args: &[String]) -> std::result::Result<Output, String> {
    if env::var(\"XDG_SESSION_TYPE\")
        .ok()
        .is_some_and(|value| value.eq_ignore_ascii_case(\"wayland\"))
        || env::var_os(\"WAYLAND_DISPLAY\").is_some()
    {
        return Err(\"ydotool is disabled on Wayland; a consented XDG Remote Desktop portal session is required\".to_string());
    }
    ydotool::ensure_supported()?;
    let mut command = TokioCommand::new(\"ydotool\");
"""

ORIGINAL_YDOTOOL_TYPE = """async fn run_ydotool_type_text(text: &str) -> std::result::Result<Output, String> {
    ydotool::ensure_supported()?;
    let mut command = TokioCommand::new(\"ydotool\");
"""
PATCHED_YDOTOOL_TYPE = """async fn run_ydotool_type_text(text: &str) -> std::result::Result<Output, String> {
    if env::var(\"XDG_SESSION_TYPE\")
        .ok()
        .is_some_and(|value| value.eq_ignore_ascii_case(\"wayland\"))
        || env::var_os(\"WAYLAND_DISPLAY\").is_some()
    {
        return Err(\"ydotool is disabled on Wayland; a consented XDG Remote Desktop portal session is required\".to_string());
    }
    ydotool::ensure_supported()?;
    let mut command = TokioCommand::new(\"ydotool\");
"""

ORIGINAL_UNUSED_YDOTOOL_HELPERS = """fn ydotool_backend_available() -> bool {
    ydotool_backend_available_from(
        ydotool_socket_connectable(),
        ydotool::ensure_supported().is_ok(),
    )
}

fn ydotool_socket_connectable() -> bool {
    if let Some(socket) = explicit_ydotool_socket() {
        return ydotool_socket_connects(&PathBuf::from(socket));
    }
    connectable_ydotool_socket_from(fallback_ydotool_socket_candidates()).is_some()
}

fn ydotool_backend_available_from(socket_available: bool, cli_supported: bool) -> bool {
    socket_available && cli_supported
}

fn should_prefer_portal_backend_by_default(is_wayland: bool, ydotool_available: bool) -> bool {
    is_wayland && !ydotool_available
}
"""
PATCHED_UNUSED_YDOTOOL_HELPERS = """// Wayland selects the consented portal directly, without probing legacy ydotool.
"""

ORIGINAL_UNUSED_YDOTOOL_TEST = """    #[test]
    fn legacy_ydotool_socket_does_not_suppress_portal_fallback() {
        let legacy_ydotool_available = ydotool_backend_available_from(true, false);
        let current_ydotool_available = ydotool_backend_available_from(true, true);

        assert!(should_prefer_portal_backend_by_default(
            true,
            legacy_ydotool_available
        ));
        assert!(!should_prefer_portal_backend_by_default(
            true,
            current_ydotool_available
        ));
        assert!(!should_prefer_portal_backend_by_default(
            false,
            legacy_ydotool_available
        ));
    }
"""
PATCHED_UNUSED_YDOTOOL_TEST = """    // Portal preference no longer depends on ambient ydotool socket state.
"""


TRANSFORMS = (
    ("press_key portal and focus revalidation", (ORIGINAL, BROKEN_PATCHED, PORTAL_PRESS_KEY), PATCHED),
    ("disable uinput pointer on Wayland", (ORIGINAL_ABS_POINTER_GUARD,), PATCHED_ABS_POINTER_GUARD),
    ("prefer portal pointer on Wayland", (ORIGINAL_POINTER_PREFERENCE,), PATCHED_POINTER_PREFERENCE),
    ("prefer portal keyboard on Wayland", (ORIGINAL_KEYBOARD_PREFERENCE,), PATCHED_KEYBOARD_PREFERENCE),
    ("ignore ydotool override on Wayland", (ORIGINAL_KEYBOARD_SESSION_GUARD,), PATCHED_KEYBOARD_SESSION_GUARD),
    ("avoid target clipboard focus race", (ORIGINAL_KDE_TARGET_CONDITION,), PATCHED_KDE_TARGET_CONDITION),
    ("type_text portal focus revalidation", (ORIGINAL_PORTAL_TYPE_TEXT,), PATCHED_PORTAL_TYPE_TEXT),
    ("block ydotool actions on Wayland", (ORIGINAL_YDOTOOL_COMMAND,), PATCHED_YDOTOOL_COMMAND),
    ("block ydotool text on Wayland", (ORIGINAL_YDOTOOL_TYPE,), PATCHED_YDOTOOL_TYPE),
    (
        "remove obsolete ydotool availability probes",
        (ORIGINAL_UNUSED_YDOTOOL_HELPERS,),
        PATCHED_UNUSED_YDOTOOL_HELPERS,
    ),
    (
        "remove obsolete ydotool portal preference test",
        (ORIGINAL_UNUSED_YDOTOOL_TEST,),
        PATCHED_UNUSED_YDOTOOL_TEST,
    ),
)


def apply_transform(source: str, name: str, originals: tuple[str, ...], patched: str) -> tuple[str, bool]:
    patched_count = source.count(patched)
    original_counts = [source.count(original) for original in originals]
    if patched_count == 1:
        without_patched = source.replace(patched, "", 1)
        if all(without_patched.count(original) == 0 for original in originals):
            return source, False
    if patched_count == 0:
        candidates = [
            original for original, count in zip(originals, original_counts, strict=True) if count == 1
        ]
        if candidates:
            original = max(candidates, key=len)
            without_original = source.replace(original, "", 1)
            if all(without_original.count(item) == 0 for item in originals):
                return source.replace(original, patched, 1), True
    raise SystemExit(
        f"patch-computer-use-wayland: {name}: expected exactly one original or patched block; "
        f"found originals={original_counts}, patched={patched_count}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("server", type=Path)
    args = parser.parse_args()

    try:
        source = args.server.read_text(encoding="utf-8")
    except OSError as error:
        raise SystemExit(f"patch-computer-use-wayland: cannot read source: {error}") from error

    changed = []
    for name, originals, patched in TRANSFORMS:
        source, did_change = apply_transform(source, name, originals, patched)
        if did_change:
            changed.append(name)

    if changed:
        temporary = args.server.with_name(f".{args.server.name}.new-{os.getpid()}")
        temporary.write_text(source, encoding="utf-8")
        os.chmod(temporary, args.server.stat().st_mode)
        os.replace(temporary, args.server)
        print("Patched Computer Use for portal-only Wayland input: " + ", ".join(changed))
    else:
        print("Computer Use portal-only Wayland hardening already applied.")


if __name__ == "__main__":
    main()
