# Security Policy

## Supported Versions

Spyglass is distributed as a rolling release: only the latest version on the
`main` branch and the most recent published build receive security fixes. If
you are running an older build, update before reporting an issue.

| Version        | Supported          |
| -------------- | ------------------ |
| Latest release | :white_check_mark: |
| Older builds   | :x:                |

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report privately through one of:

- **GitHub Security Advisories** — open a draft advisory at
  <https://github.com/magicelk235/Spyglass/security/advisories/new>
  (preferred).
- **Email** — yehonatan.2350@icloud.com with subject line `SECURITY: spyglass`.

Please include:

- A description of the vulnerability and its impact.
- Steps to reproduce (a proof-of-concept if you have one).
- Affected version, macOS version, and any relevant configuration.

## What to Expect

- **Acknowledgement** within 5 business days.
- An assessment and, where confirmed, a fix timeline. Most issues are patched
  in the next release.
- Credit in the release notes once a fix ships, unless you ask to stay
  anonymous.

Please give a reasonable window to release a fix before any public disclosure.

## Scope Notes

Spyglass is a Quick Look Preview Extension plus a host app that signs into
Google (OAuth) to fetch rendered previews of Google Workspace files. Reports
touching credential handling, OAuth token storage, the Google client secret
configuration, or preview fetching are in scope. Do **not** include real
secrets, tokens, or personal documents in a report — redact them.
