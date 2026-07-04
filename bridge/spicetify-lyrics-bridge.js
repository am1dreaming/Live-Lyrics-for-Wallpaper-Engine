// MinenkoY
(function LyricsBridge() {
  "use strict";

  const PORT = Number(localStorage.getItem("lyricsBridge:port")) || 8973;
  const WS_URL = `ws://localhost:${PORT}`;

  const BACKOFF = [1000, 2000, 5000];

  const PROGRESS_THROTTLE_MS = 250;

  const LOG_PREFIX = "%c[LyricsBridge]";
  const LOG_STYLE = "color:#1db954;font-weight:bold";
  const log = (...a) => console.log(LOG_PREFIX, LOG_STYLE, ...a);
  const warn = (...a) => console.warn(LOG_PREFIX, LOG_STYLE, ...a);

  let ws = null;
  let backoffIndex = 0;
  let reconnectTimer = null;

  let currentLyrics = undefined;
  let currentTrackId = null;
  let lastProgressSent = 0;

  function init() {
    const ready =
      window.Spicetify &&
      Spicetify.Player &&
      Spicetify.Platform &&
      Spicetify.CosmosAsync &&
      typeof Spicetify.Player.addEventListener === "function";

    if (!ready) {
      setTimeout(init, 100);
      return;
    }
    log("Spicetify ready, starting bridge →", WS_URL);
    main();
  }

  function main() {
    connect();

    Spicetify.Player.addEventListener("songchange", onSongChange);
    Spicetify.Player.addEventListener("onprogress", onProgress);
    Spicetify.Player.addEventListener("onplaypause", onPlayPause);

    if (Spicetify.Player.data && Spicetify.Player.data.item) {
      onSongChange();
    }
  }

  function connect() {
    clearTimeout(reconnectTimer);
    try {
      ws = new WebSocket(WS_URL);
    } catch (e) {
      scheduleReconnect();
      return;
    }

    ws.onopen = () => {
      backoffIndex = 0;
      log("connected to relay");

      if (currentLyrics === undefined) {
        onSongChange();
      } else {
        sendFull();
      }
    };

    ws.onmessage = () => {

    };

    ws.onerror = () => {
      try { ws.close(); } catch (_) {}
    };

    ws.onclose = () => {
      scheduleReconnect();
    };
  }

  function scheduleReconnect() {
    const delay = BACKOFF[Math.min(backoffIndex, BACKOFF.length - 1)];
    backoffIndex++;
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(connect, delay);
  }

  function send(obj) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      try {
        ws.send(JSON.stringify(obj));
      } catch (e) {
        warn("send failed", e);
      }
    }
  }

  function computePosition() {
    const d = Spicetify.Player.data;
    if (
      d &&
      typeof d.timestamp === "number" &&
      typeof d.positionAsOfTimestamp === "number"
    ) {

      const pos = Date.now() - (d.timestamp - d.positionAsOfTimestamp);
      return Math.max(0, pos);
    }

    try { return Spicetify.Player.getProgress() || 0; } catch (_) { return 0; }
  }

  function isPlaying() {
    try {
      if (typeof Spicetify.Player.isPlaying === "function") {
        return Spicetify.Player.isPlaying();
      }
    } catch (_) {}
    const d = Spicetify.Player.data;
    return d ? !d.isPaused : false;
  }

  function normalizeImage(uri) {
    if (!uri) return "";

    if (uri.startsWith("spotify:image:")) {
      return "https://i.scdn.co/image/" + uri.slice("spotify:image:".length);
    }
    return uri;
  }

  function getTrack() {
    const item = (Spicetify.Player.data && Spicetify.Player.data.item) || {};
    const meta = item.metadata || {};
    const durationMs =
      Number(
        (item.duration && item.duration.milliseconds) ||
          meta.duration ||
          (Spicetify.Player.getDuration && Spicetify.Player.getDuration()) ||
          0
      ) || 0;

    return {
      title: meta.title || item.name || "Unknown",
      artist:
        meta.artist_name ||
        meta.album_artist_name ||
        "Unknown Artist",

      album: meta.album_title || "",
      coverUrl: normalizeImage(
        meta.image_xlarge_url ||
          meta.image_large_url ||
          meta.image_url ||
          ""
      ),
      durationMs,
    };
  }

  function getTrackId() {
    const uri =
      Spicetify.Player.data &&
      Spicetify.Player.data.item &&
      Spicetify.Player.data.item.uri;
    if (!uri || typeof uri !== "string") return null;

    const parts = uri.split(":");
    return parts[parts.length - 1] || null;
  }

  async function fetchLyrics(trackId) {
    if (!trackId) return null;

    const url =
      `https://spclient.wg.spotify.com/color-lyrics/v2/track/${trackId}` +
      `?format=json&vocalRemoval=false&market=from_token`;

    try {
      const res = await Spicetify.CosmosAsync.get(url, null, {
        "App-platform": "WebPlayer",
      });
      return parseLyrics(res);
    } catch (e) {
      warn("lyrics fetch failed (non-fatal):", e && e.message ? e.message : e);
      return null;
    }
  }

  function num(v) {
    const n = Number(v);
    return Number.isFinite(n) ? n : 0;
  }

  function parseLyrics(res) {
    const L = res && res.lyrics;
    if (!L || !Array.isArray(L.lines) || L.lines.length === 0) return null;

    const sync = L.syncType;
    const hasSyllables = L.lines.some(
      (ln) => Array.isArray(ln.syllables) && ln.syllables.length > 0
    );

    let type = "line";
    if (sync === "UNSYNCED") type = "static";
    else if (sync === "SYLLABLE_SYNCED" || hasSyllables) type = "syllable";

    const rawLines = L.lines;
    const lines = rawLines
      .map((ln, i) => {
        const startMs = num(ln.startTimeMs);
        let endMs = num(ln.endTimeMs);
        if (!endMs) {

          endMs = rawLines[i + 1]
            ? num(rawLines[i + 1].startTimeMs)
            : startMs + 4000;
        }

        const text = typeof ln.words === "string" ? ln.words : ln.text || "";

        const trimmed = text.trim();
        const isBackground =
          trimmed.length > 1 &&
          trimmed.startsWith("(") &&
          trimmed.endsWith(")");

        let words = [];
        if (Array.isArray(ln.syllables) && ln.syllables.length) {
          words = ln.syllables.map((s) => {
            const ws = num(s.startTimeMs);
            const we = s.endTimeMs
              ? num(s.endTimeMs)
              : ws + num(s.durationMs);
            return {
              text: s.chars != null ? String(s.chars) : String(s.text || ""),
              startMs: ws,
              endMs: we,
            };
          });
        }

        return { startMs, endMs, text, isBackground, words };
      })

      .filter((ln) => ln.text !== undefined && ln.text !== null);

    return { type, lines };
  }

  function sendFull() {
    const msg = {
      track: getTrack(),
      position: computePosition(),
      isPlaying: isPlaying(),
      timestamp: Date.now(),
      lyrics: currentLyrics === undefined ? null : currentLyrics,
    };
    send(msg);
  }

  function sendLight(positionOverride) {
    const position =
      typeof positionOverride === "number"
        ? positionOverride
        : computePosition();
    send({
      position,
      isPlaying: isPlaying(),
      timestamp: Date.now(),
    });
  }

  async function onSongChange() {
    const trackId = getTrackId();
    currentTrackId = trackId;

    const fetched = await fetchLyrics(trackId);
    if (currentTrackId !== trackId) return;

    currentLyrics = fetched;
    sendFull();
  }

  function onProgress(e) {
    const now = Date.now();
    if (now - lastProgressSent < PROGRESS_THROTTLE_MS) return;
    lastProgressSent = now;

    const pos = e && typeof e.data === "number" ? e.data : undefined;
    sendLight(pos);
  }

  function onPlayPause() {
    sendLight();
  }

  init();
})();
