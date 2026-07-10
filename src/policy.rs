use std::fmt;

use url::Url;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NavigationDisposition {
    Internal,
    External,
    Blocked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PermissionKind {
    Microphone,
    Camera,
    CameraAndMicrophone,
    DisplayCapture,
    DeviceInfo,
    Geolocation,
    Notifications,
    WebsiteData,
    Unknown,
}

impl fmt::Display for PermissionKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let label = match self {
            Self::Microphone => "microphone",
            Self::Camera => "camera",
            Self::CameraAndMicrophone => "camera and microphone",
            Self::DisplayCapture => "screen sharing",
            Self::DeviceInfo => "media device information",
            Self::Geolocation => "location",
            Self::Notifications => "notifications",
            Self::WebsiteData => "cross-site website data",
            Self::Unknown => "an unknown capability",
        };
        formatter.write_str(label)
    }
}

const FIRST_PARTY_SUFFIXES: &[&str] = &[
    "chatgpt.com",
    "openai.com",
    "oaistatic.com",
    "oaiusercontent.com",
];

const AUTH_HOSTS: &[&str] = &[
    "accounts.google.com",
    "appleid.apple.com",
    "github.com",
    "login.microsoftonline.com",
];

const PERMISSION_HOSTS: &[&str] = &["chatgpt.com", "www.chatgpt.com"];

pub fn navigation_disposition(uri: &str) -> NavigationDisposition {
    if uri == "about:blank" {
        return NavigationDisposition::Internal;
    }

    let Ok(url) = Url::parse(uri) else {
        return NavigationDisposition::Blocked;
    };

    match url.scheme() {
        "https" => {
            let Some(host) = url.host_str().map(|host| host.to_ascii_lowercase()) else {
                return NavigationDisposition::Blocked;
            };
            if FIRST_PARTY_SUFFIXES
                .iter()
                .any(|suffix| host == *suffix || host.ends_with(&format!(".{suffix}")))
                || AUTH_HOSTS.contains(&host.as_str())
            {
                NavigationDisposition::Internal
            } else {
                NavigationDisposition::External
            }
        }
        "mailto" | "tel" => NavigationDisposition::External,
        "http" => NavigationDisposition::External,
        _ => NavigationDisposition::Blocked,
    }
}

pub fn is_chatgpt_service_url(uri: &str) -> bool {
    Url::parse(uri).is_ok_and(|url| {
        url.scheme() == "https"
            && url.host_str().is_some_and(|host| {
                matches!(
                    host.to_ascii_lowercase().as_str(),
                    "chatgpt.com" | "www.chatgpt.com"
                )
            })
    })
}

pub fn is_google_auth_url(uri: &str) -> bool {
    Url::parse(uri).is_ok_and(|url| {
        url.scheme() == "https"
            && url
                .host_str()
                .is_some_and(|host| host.eq_ignore_ascii_case("accounts.google.com"))
    })
}

pub fn is_authentication_url(uri: &str) -> bool {
    Url::parse(uri).is_ok_and(|url| {
        if url.scheme() != "https" {
            return false;
        }
        let Some(host) = url.host_str().map(str::to_ascii_lowercase) else {
            return false;
        };
        AUTH_HOSTS.contains(&host.as_str())
            || matches!(
                host.as_str(),
                "auth.openai.com" | "auth0.openai.com" | "login.openai.com"
            )
    })
}

pub fn is_allowed_website_data_pair(current_domain: &str, requesting_domain: &str) -> bool {
    let current = normalize_domain(current_domain);
    let requesting = normalize_domain(requesting_domain);
    matches!(current.as_deref(), Some("chatgpt.com" | "www.chatgpt.com"))
        && requesting.is_some_and(|host| {
            host == "chatgpt.com"
                || host == "www.chatgpt.com"
                || host == "openai.com"
                || host.ends_with(".openai.com")
        })
}

fn normalize_domain(domain: &str) -> Option<String> {
    let normalized = domain.trim().trim_end_matches('.').to_ascii_lowercase();
    (!normalized.is_empty()
        && normalized.len() <= 253
        && normalized
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-')))
    .then_some(normalized)
}

pub fn redact_url_for_log(uri: &str) -> String {
    let Ok(url) = Url::parse(uri) else {
        return "<invalid-url>".to_owned();
    };
    match url.host_str() {
        Some(host) => {
            let port = url
                .port()
                .map(|port| format!(":{port}"))
                .unwrap_or_default();
            format!("{}://{}{}", url.scheme(), host.to_ascii_lowercase(), port)
        }
        None => format!("{}:<redacted>", url.scheme()),
    }
}

pub fn is_trusted_origin(uri: Option<&str>) -> bool {
    let Some(uri) = uri else {
        return false;
    };
    let Ok(url) = Url::parse(uri) else {
        return false;
    };
    if url.scheme() != "https" {
        return false;
    }
    let Some(host) = url.host_str().map(|host| host.to_ascii_lowercase()) else {
        return false;
    };
    PERMISSION_HOSTS.contains(&host.as_str())
}

pub fn sanitize_download_filename(suggested: &str) -> String {
    let filename = suggested
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or("download")
        .trim();
    let cleaned: String = filename
        .chars()
        .filter(|character| {
            !character.is_control() && *character != '\0' && !is_bidi_control(*character)
        })
        .collect();
    let cleaned = cleaned.trim().trim_start_matches('.');
    if cleaned.is_empty() || cleaned == "." || cleaned == ".." {
        "download".to_owned()
    } else {
        truncate_filename_preserving_extension(cleaned, 180)
    }
}

fn is_bidi_control(character: char) -> bool {
    matches!(
        character,
        '\u{061c}'
            | '\u{200e}'
            | '\u{200f}'
            | '\u{202a}'..='\u{202e}'
            | '\u{2066}'..='\u{2069}'
    )
}

fn truncate_utf8(value: &str, max_bytes: usize) -> &str {
    if value.len() <= max_bytes {
        return value;
    }
    let mut boundary = max_bytes;
    while !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    &value[..boundary]
}

fn truncate_filename_preserving_extension(filename: &str, max_bytes: usize) -> String {
    if filename.len() <= max_bytes {
        return filename.to_owned();
    }

    let path = std::path::Path::new(filename);
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty() && value.len() <= 32);
    if let Some(extension) = extension {
        let stem = path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("download");
        let stem_bytes = max_bytes.saturating_sub(extension.len() + 1);
        let stem = truncate_utf8(stem, stem_bytes).trim_end();
        if !stem.is_empty() {
            return format!("{stem}.{extension}");
        }
    }
    truncate_utf8(filename, max_bytes).trim_end().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_only_expected_internal_origins() {
        for uri in [
            "https://chatgpt.com/",
            "https://auth.openai.com/login",
            "https://cdn.oaistatic.com/a.js",
            "https://accounts.google.com/o/oauth2/v2/auth",
        ] {
            assert_eq!(
                navigation_disposition(uri),
                NavigationDisposition::Internal,
                "{uri}"
            );
        }
    }

    #[test]
    fn suffix_matching_does_not_allow_confusable_hosts() {
        for uri in [
            "https://chatgpt.com.evil.example/",
            "https://notopenai.com/",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,hello",
        ] {
            assert_ne!(
                navigation_disposition(uri),
                NavigationDisposition::Internal,
                "{uri}"
            );
        }
    }

    #[test]
    fn only_first_party_origins_receive_permissions() {
        assert!(is_trusted_origin(Some("https://chatgpt.com/")));
        assert!(is_trusted_origin(Some("https://www.chatgpt.com/")));
        assert!(!is_trusted_origin(Some("https://accounts.google.com/")));
        assert!(!is_trusted_origin(Some("https://cdn.oaistatic.com/")));
        assert!(!is_trusted_origin(Some(
            "https://files.oaiusercontent.com/"
        )));
        assert!(!is_trusted_origin(Some("https://platform.openai.com/")));
        assert!(!is_trusted_origin(Some("http://chatgpt.com/")));
    }

    #[test]
    fn service_and_auth_hosts_are_distinct() {
        assert!(is_chatgpt_service_url("https://chatgpt.com/"));
        assert!(!is_chatgpt_service_url("https://accounts.google.com/"));
        assert!(!is_chatgpt_service_url("https://cdn.oaistatic.com/"));
        assert!(is_google_auth_url(
            "https://accounts.google.com/o/oauth2/auth"
        ));
        assert!(is_authentication_url("https://auth.openai.com/authorize"));
    }

    #[test]
    fn website_data_pairs_are_narrowly_scoped() {
        assert!(is_allowed_website_data_pair(
            "chatgpt.com",
            "auth.openai.com"
        ));
        assert!(!is_allowed_website_data_pair(
            "evil.example",
            "auth.openai.com"
        ));
        assert!(!is_allowed_website_data_pair(
            "chatgpt.com",
            "accounts.google.com"
        ));
        assert!(!is_allowed_website_data_pair(
            "chatgpt.com",
            "files.oaiusercontent.com"
        ));
    }

    #[test]
    fn log_urls_never_include_credentials_or_paths() {
        let redacted =
            redact_url_for_log("https://user:secret@auth.openai.com/callback?code=token#fragment");
        assert_eq!(redacted, "https://auth.openai.com");
        assert!(!redacted.contains("token"));
        assert_eq!(
            redact_url_for_log("mailto:private@example.com"),
            "mailto:<redacted>"
        );
    }

    #[test]
    fn download_names_cannot_escape() {
        assert_eq!(sanitize_download_filename("../../secret.txt"), "secret.txt");
        assert_eq!(sanitize_download_filename(".."), "download");
        assert_eq!(sanitize_download_filename("a/b\\c.txt"), "c.txt");
        assert_eq!(sanitize_download_filename(".hidden"), "hidden");
        assert_eq!(
            sanitize_download_filename("safe\u{202e}cod.exe"),
            "safecod.exe"
        );

        let long = format!("{}.pdf", "界".repeat(100));
        let sanitized = sanitize_download_filename(&long);
        assert!(sanitized.len() <= 180);
        assert!(sanitized.ends_with(".pdf"));
    }
}
