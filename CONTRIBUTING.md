# Contributing to Live Lyrics for Wallpaper Engine

Thanks for taking the time to help out! 🩵 This project is intentionally small and
dependency-light — **vanilla JS/CSS, no build step, no framework**. Contributions that
keep it that way are the easiest to merge.

This guide covers how the project is laid out, how to run each part locally, the coding
standards, how to file good bug reports and feature ideas, the pull-request flow, and
the security rules you must follow when touching the network code.

---

## 🧩 The three moving parts

| Part | Folder | Runtime | What it is |
|------|--------|---------|------------|
| **Wallpaper** | `wallpaper/` | Wallpaper Engine's CEF (Chromium) browser | The visible web wallpaper — lyrics rendering, backgrounds, cover art. Plain JS + CSS. |
| **Bridge** | `bridge/` | Node.js + a Spicetify extension | A tiny WebSocket relay (`bridge-server.js`) plus the Spicetify extension (`spicetify-lyrics-bridge.js`) that feeds it. |
| **Installers** | repo root | PowerShell 5.1 / Batch | `install.ps1`, `install-web.ps1`, `uninstall.ps1` and their `.bat` launchers. |

A Spicetify extension can't open a server (it runs inside Spotify's renderer), so it acts
as a **client**; the Node relay rebroadcasts everything to the wallpaper and also resolves
animated album covers. See **How it works** in the [README](README.md).

```
Spotify (Spicetify ext) ──ws client──▶ bridge-server (Node, :8973) ──ws relay──▶ Wallpaper (WE)
```

---

## 🛠 Setting up a dev environment

You don't need the full installer to develop. Pick the part you're changing.

### Wallpaper (front-end)

No build, no server needed for quick iteration:

1. Open `wallpaper/index.html` directly in a Chromium-based browser.
2. With no relay connected, it falls back to a **demo track** (`mock-data.js`) after a few
   seconds, so you can see lyrics, scrolling, and layout without Spotify at all.
3. Use the browser DevTools (F12) to iterate on `app.js`, `lyrics-engine.js`,
   `background.js`, `style.css`, etc.
4. For a real end-to-end check, load it in **Wallpaper Engine**: *Open wallpaper → Open
   from file → `wallpaper/project.json`*.

> ⚠️ WE's browser has **no H.264** — any bundled video must be `.webm`/`.ogv`. Settings
> live in `project.json` (grouped, English) and are read in `app.js`.

### Bridge (relay)

Requires **Node.js LTS**.

```bash
cd bridge
npm install ws            # the only runtime dependency
node bridge-server.js
```

Then sanity-check it:

```bash
# should print the relay banner and bind to 127.0.0.1
curl http://127.0.0.1:8973/
```

- Port is `8973` by default — override with `BRIDGE_PORT`.
- The server binds to **loopback** (`127.0.0.1`) by default — override with `BRIDGE_HOST`
  only if you understand the exposure (see [Security](#-security)).
- `node --check bridge/bridge-server.js` catches syntax errors before you run it.

### Spicetify extension

```bash
copy bridge\spicetify-lyrics-bridge.js %APPDATA%\spicetify\Extensions\
spicetify config extensions spicetify-lyrics-bridge.js
spicetify apply
```

Open Spotify's DevTools (Spicetify enables them) to see the `[LyricsBridge]` logs.

### Installers

They target **Windows PowerShell 5.1** and **self-elevate to admin**. Test on a Windows
box (ideally a VM/spare account) — they install/patch Spotify, Node, ffmpeg and Spicetify.
Re-running is designed to be safe (done steps are skipped).

---

## 🔌 The WebSocket message contract

If you touch lyrics, playback sync, or the connection layer, keep to this contract. All
messages are JSON.

**Extension / producer → relay → wallpaper**

```jsonc
// full update (on song change)
{ "track": { "title": "...", "artist": "...", "album": "...", "coverUrl": "...", "durationMs": 0 },
  "position": 0, "isPlaying": true, "timestamp": 0, "lyrics": { /* see below */ } }

// light update (progress / play-pause), throttled
{ "position": 0, "isPlaying": true, "timestamp": 0 }

// wallpaper → relay: animated-cover quality (persisted, clamped 360–2160)
{ "artConfig": { "height": 486 } }
```

**Relay → wallpaper only**

```jsonc
{ "animatedArt": { "artist": "...", "album": "...", "url": "http://localhost:8973/art/<hash>.webm" } }
```

**`lyrics` shape**

```jsonc
{ "type": "line" | "syllable" | "static",
  "lines": [ { "startMs": 0, "endMs": 0, "text": "...", "isBackground": false,
               "words": [ { "text": "...", "startMs": 0, "endMs": 0 } ] } ] }
```

---

## 🎨 Coding standards

**Keep the spirit of the codebase:** small, readable, no unnecessary dependencies.

- **Wallpaper (JS/CSS):** vanilla ES — **no** React/build tooling and **no** new runtime
  dependencies. 2-space indent, semicolons, double quotes. Match the style of the file
  you're editing. Everything must run in WE's CEF (no Node APIs, remember no H.264).
- **Bridge (Node.js):** keep dependencies to the essentials (`ws` is the only one today).
  2-space indent, semicolons. Prefer the existing terse helpers over adding libraries.
- **Installers (PowerShell/Batch):** use `param()` blocks, small functions, and
  `-LiteralPath` on file ops. Keep `uninstall.ps1` ASCII-only. Never widen a
  `Remove-Item -Recurse -Force` beyond a specific, known path.
- **Comments explain _why_, not _what_.** Add one when a line's intent isn't obvious.
- Don't reformat unrelated code in your PR — it makes review harder.

---

## ✅ Testing & verification

There's no CI or automated test suite yet, so verify by hand and describe what you did in
the PR. A good checklist:

- [ ] `node --check bridge/bridge-server.js` passes (if you touched the bridge).
- [ ] Relay starts, binds to `127.0.0.1:8973`, and `curl http://127.0.0.1:8973/` responds.
- [ ] Front-end change verified in a browser via the demo track **and** — for anything
      timing/rendering related — live in Wallpaper Engine with a real song.
- [ ] Lyrics still sync (word-by-word and line modes), auto-scroll centers the active line.
- [ ] If you touched connection code: pull the plug on the relay and confirm the wallpaper
      reconnects (it uses a backoff ladder) and the extension re-attaches.
- [ ] If you touched animated covers: a track with editorial art still resolves and plays.
- [ ] If you touched an installer: it still elevates, and re-running is safe.

---

## 🐞 Reporting bugs

Open an issue with enough detail to reproduce. Please include:

- **OS:** Windows 10 / 11 build.
- **Wallpaper Engine** version, and your aspect ratio / resolution (esp. ultrawide).
- **Spotify** version and **Spicetify** version (`spicetify -v`).
- **Which path** you're on: Spicetify relay, or the built-in WE-native path.
- **Is the relay running?** (Task Manager → `node.exe`, port `8973`.)
- **Bridge logs:** run `node bridge-server.js` in a visible terminal and paste the output.
- **Wallpaper console:** open `wallpaper/index.html` in a browser (or WE's debugging) and
  copy any red errors from DevTools.
- Steps to reproduce, what you expected, what happened, and a screenshot/GIF if visual.

> 🔐 If the bug is a **security vulnerability**, do **not** open a public issue — see below.

---

## 💡 Suggesting features

Feature ideas are welcome as issues. Helpful things to spell out:

- **Lyric styles / rendering:** new emphasis, scroll behavior, interlude visuals.
- **Cover FX & backgrounds:** effects, framing, new background modes.
- **Connection / protocol:** new lyric sources, message-contract additions, other players.
- Ultrawide / multi-monitor presets, accessibility, and performance wins.

Keep the "no bloat" ethos in mind — the smaller and more self-contained the idea, the
faster it lands. For big changes, open an issue to discuss before writing code.

---

## 🔀 Pull request workflow

1. **Fork** the repo and create a topic branch off `main`
   (`fix/lyrics-scroll-jitter`, `feat/vertical-layout`).
2. Make focused changes — one concern per PR.
3. **Verify** using the checklist above.
4. Open the PR against `main` with:
   - what changed and **why**,
   - how you tested it (WE version, track, screenshots/GIF for visual changes),
   - any settings added to `project.json`.
5. Be ready for review feedback. Keep the diff tight and avoid drive-by reformatting.

By contributing you agree your changes are released under the project's **MIT License**.

---

## 🔐 Security

This project runs a local server and talks to Spotify, so a few rules are firm:

- **Keep the relay on loopback.** `bridge-server.js` binds `127.0.0.1` by default. Do
  **not** reintroduce a bind with no host (that listens on all interfaces and exposes the
  WS relay + the `/img` proxy to your whole LAN). Only `BRIDGE_HOST` should change that.
- **Don't weaken the `/img` SSRF guard.** The image proxy refuses internal / loopback /
  private / link-local targets (including numeric-IP encodings and across redirects). If
  you change the proxy, keep that guard intact.
- **Never handle, log, or transmit the Spotify access token.** The Spicetify extension
  uses `Spicetify.CosmosAsync`, which authenticates internally — don't add code that reads
  the token or forwards it anywhere. Messages on the wire carry only track metadata,
  timing, and lyrics.
- **Don't commit secrets or generated state.** `am-token.json` (an anonymous Apple *web*
  token), `cache/`, `node_modules/`, and `art-config.json` are git-ignored — keep them so.
- **Keep untrusted URLs out of shells.** `ffmpeg` is invoked with an argument array and a
  `-protocol_whitelist`; don't route resolved URLs through a shell or drop the whitelist.

**Reporting a vulnerability:** please report privately via GitHub's *Security → Report a
vulnerability* (private advisory) or by contacting the maintainer directly — **not** in a
public issue. Give us a chance to fix it before disclosure.

---

<div align="center">
<sub>Thanks for contributing to <b>Live Lyrics for Wallpaper Engine</b> · MIT License</sub>
</div>
