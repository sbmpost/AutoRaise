# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | :white_check_mark: |
| Older releases | :x: |

Only the latest release receives security fixes.

## Scope

AutoRaise is a macOS accessibility utility that:
- Uses Accessibility APIs (`AXUIElement`) to observe and raise windows
- Reads a local configuration file (`~/.AutoRaise` or `~/.config/AutoRaise/config`)
- Runs as a user-space process with no network access

Relevant attack surfaces include:
- **Config file parsing** — malformed or malicious `~/.AutoRaise` values
- **Accessibility API abuse** — privilege escalation via the granted Accessibility permission
- **Binary distribution** — unsigned or tampered binaries

Out of scope: issues requiring physical access or root privileges the attacker already possesses.

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Instead, report privately via one of these channels:
1. **GitHub Private Advisory** — use the "Report a vulnerability" button on the [Security tab](https://github.com/sbmpost/AutoRaise/security/advisories/new)
2. **Email** — contact the maintainer directly (see GitHub profile for contact info)

Include in your report:
- A description of the vulnerability and its impact
- Steps to reproduce or a proof-of-concept
- Affected version(s)
- Any suggested mitigations

## Response Timeline

| Step | Target |
|------|--------|
| Acknowledgement | Within 7 days |
| Status update | Within 30 days |
| Fix / advisory | Depends on severity |

## Security Considerations for Users

- Grant Accessibility permission only to trusted builds
- Download releases from the [official GitHub releases page](https://github.com/sbmpost/AutoRaise/releases) only
- Verify the binary is not tampered with (check SHA or Gatekeeper status)
- Review your `~/.AutoRaise` config if shared or sourced from untrusted sources
