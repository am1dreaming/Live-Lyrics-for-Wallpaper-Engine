# Security Policy

## Supported Versions

Live Lyrics ships as a rolling release — fixes land on `main` and in the latest
GitHub release only. Older snapshots are not patched.

| Version                        | Supported          |
| ------------------------------ | ------------------ |
| Latest release / `main`        | :white_check_mark: |
| Anything older                 | :x:                |

If you installed via `install-web.ps1` or `Install.bat`, simply re-run the
installer to get the current version — completed steps are skipped.

## Reporting a Vulnerability

**Please do not open a public issue for security problems.**

- Preferred: [**GitHub → Security → Report a vulnerability**](https://github.com/am1dreaming/Live-Lyrics-for-Wallpaper-Engine/security/advisories/new)
  (private advisory).

Include what you can: affected file (e.g. `bridge/bridge-server.js`,
`install.ps1`), reproduction steps or PoC, impact, and your OS/Spotify/
Spicetify versions if relevant.

What to expect:

- **Acknowledgement within 72 hours.**
- A status update at least **every 7 days** while we investigate.
- If accepted: a fix in the next release and credit in the release notes
  (unless you prefer to stay anonymous).
- If declined: an explanation of why (e.g. out of scope, works as intended).

This is a hobby project maintained by one person — critical issues are
prioritized, but there is no formal SLA and no bug bounty.

## Scope

In scope - vulnerabilities in code shipped by this repository:

- **Installer / uninstaller** (`install.ps1`, `install-web.ps1`, `Install.bat`,
  `uninstall.ps1`) — they run elevated, so anything like command injection,
  insecure downloads, or unsafe file operations matters most.
- **Bridge relay** (`bridge/bridge-server.js`) — it binds to `127.0.0.1:8973`
  by default and exposes a WebSocket relay plus HTTP endpoints (`/art`, cover
  proxy). Examples: bypass of the proxy host blocklist (SSRF), path traversal
  in served files, anything that lets a remote origin reach the relay.
- **Spicetify extension** (`bridge/spicetify-lyrics-bridge.js`) — runs inside
  Spotify's renderer.
- **Wallpaper** (`wallpaper/*.js`, `index.html`) — e.g. HTML/script injection
  through lyrics, track metadata, or cover URLs rendered in the Wallpaper
  Engine webview.

Out of scope:

- Vulnerabilities in third-party software the installer sets up (Spotify,
  Spicetify, Node.js, ffmpeg, Wallpaper Engine) — report those upstream.
- Configurations you changed yourself, e.g. exposing the relay with
  `BRIDGE_HOST=0.0.0.0` on an untrusted network.
- Issues requiring an already-compromised machine or physical access.
- The bundled demo/mock track data.

## Hardening notes for users

- The relay is loopback-only by default; keep it that way unless you know why
  you need otherwise.
- The one-line install pipes a script from GitHub into PowerShell
  (`iwr / iex`). If that concerns you, download the repo and inspect
  `install.ps1` before running `Install.bat` instead.
