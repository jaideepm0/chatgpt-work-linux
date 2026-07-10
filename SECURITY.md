# Security policy

## Trust model

`chatgpt-work-linux` is an independent browser shell. Trust in the ChatGPT web
service, account, content, and network is governed by OpenAI and the user's
organization; trust in the Linux shell and packaging belongs to this project.
The project does not ask for an OpenAI API key, proxy credentials, or a local
copy of account cookies.

The web page has no native IPC bridge. Native permissions and external
navigations are mediated in Rust, and unknown capabilities are denied.

## Reporting a vulnerability

Do not include session cookies, access tokens, conversation text, private file
paths, screenshots, or proprietary DMG contents in a public report. Provide a
minimal reproduction, application version, distro, WebKitGTK version, session
type, and redacted `chatgpt-work-linux doctor --json` output to the repository
maintainer through a private security channel when one is configured.

Issues in `chatgpt.com`, OpenAI authentication, models, or the official desktop
application should be reported to OpenAI through its published security/support
channels, not this project.

## Maintainer requirements

- Never merge a change that disables a browser sandbox, ignores TLS errors,
  exposes raw IPC to remote content, or widens URL/permission policy without a
  threat-model update and tests.
- Keep `Cargo.lock` committed. Review dependency provenance and advisories.
- Pin future CI actions to full commit hashes and generate checksums/SBOM for
  releases.
- Never commit or distribute `ChatGPT.dmg`, extracted OpenAI code/assets, user
  profiles, cookies, logs, or screenshots.
- Run `make check`, package inspection, and GUI smoke tests before release.
