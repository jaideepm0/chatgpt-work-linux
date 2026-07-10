# Security policy

## Trust model

`chatgpt-work-linux` is an independent Linux compatibility build of the
unified ChatGPT Work application. Trust in the ChatGPT service, account,
content, and network is governed by OpenAI and the user's organization; trust
in the Linux compatibility layer and packaging belongs to this project.
The project does not ask for an OpenAI API key, proxy credentials, or a local
copy of account cookies.

The packaged local renderer uses the application's typed Electron IPC surface.
Remote webview/browser content receives no additional Linux IPC or shell
bridge. Native permissions and external navigations remain mediated in the
main process, and unknown capabilities fail closed.

## Reporting a vulnerability

Do not include session cookies, access tokens, conversation text, private file
paths, screenshots, or proprietary DMG contents in a public report. Provide a
minimal reproduction, application version, distro, Electron version, session
type, and redacted `chatgpt-work-linux doctor --json` output to the repository
maintainer through a private security channel when one is configured.

Issues in `chatgpt.com`, OpenAI authentication, models, or the official desktop
application should be reported to OpenAI through its published security/support
channels, not this project.

## Maintainer requirements

- Never merge a change that disables a browser sandbox, ignores TLS errors,
  exposes raw IPC to remote content, or widens URL/permission policy without a
  threat-model update and tests.
- Keep Rust and Node dependency locks committed. Review dependency provenance
  and native-module ABI changes.
- Pin future CI actions to full commit hashes and generate checksums/SBOM for
  releases.
- Never commit or distribute the DMG, rebuilt application, extracted OpenAI
  code/assets, user profiles, cookies, logs, or screenshots.
- Run `make check`, package inspection, and GUI smoke tests before release.
