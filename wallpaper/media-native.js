// MinenkoY
// Built-in lyrics path (no install required): reads the currently playing track
// from Wallpaper Engine's native media integration (Windows SMTC) and fetches
// LINE-synced lyrics straight from LRCLIB in the browser - no Spicetify, no relay.
// Word-by-word (syllable) sync still comes only from the Spotify/Spicetify bridge;
// this path is the automatic fallback when the bridge is not running.
window.MediaNative = (function () {
  "use strict";

  var handler = null;              // app.js callback, receives bridge-shaped messages
  var cur = { title: "", artist: "", album: "", coverUrl: "", durationMs: 0 };
  var lastKey = "";
  var isPlaying = true;
  var lastPosMs = 0;
  var fetchToken = 0;
  var haveDuration = false;

  // WE timeline/duration can arrive in seconds or ms; normalize to ms.
  function toMs(v) {
    v = Number(v) || 0;
    if (v <= 0) return 0;
    return v < 10000 ? Math.round(v * 1000) : Math.round(v);
  }

  function computePlaying(state) {
    var WM = window.wallpaperMediaIntegration;
    if (WM) {
      if (state === WM.PLAYBACK_PLAYING) return true;
      if (state === WM.PLAYBACK_PAUSED || state === WM.PLAYBACK_STOPPED) return false;
    }
    // Unknown enum: assume playing unless it is clearly a "stopped/paused" 0.
    return state !== 0 && state !== false;
  }

  function normThumb(t) {
    if (!t) return "";
    t = String(t);
    if (/^(data:|https?:|file:)/i.test(t)) return t;   // already a URL
    return "data:image/png;base64," + t;               // raw base64 from WE
  }

  // ---- LRCLIB (public API, CORS-open) ---------------------------------------
  function parseLrc(text) {
    var rows = [], re = /^\[(\d+):(\d+(?:\.\d+)?)\](.*)$/;
    var lines = String(text).split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
      var m = re.exec(lines[i]);
      if (!m) continue;
      rows.push({
        startMs: Math.round((Number(m[1]) * 60 + Number(m[2])) * 1000),
        text: m[3].trim(),
      });
    }
    return rows;
  }

  function buildLines(rows, durationMs) {
    var out = [];
    for (var i = 0; i < rows.length; i++) {
      if (!rows[i].text) continue;
      var endMs = i < rows.length - 1
        ? rows[i + 1].startMs
        : (durationMs || rows[i].startMs + 4000);
      var t = rows[i].text;
      var bg = t.length > 1 && t.charAt(0) === "(" && t.charAt(t.length - 1) === ")";
      out.push({ startMs: rows[i].startMs, endMs: endMs, text: t, isBackground: bg, words: [] });
    }
    return out;
  }

  // LRCLIB has no word-level timing -> always line ("line") or unsynced ("static").
  function toLyrics(data, durationMs) {
    if (!data || data.instrumental) return null;
    if (data.syncedLyrics) {
      var lines = buildLines(parseLrc(data.syncedLyrics), durationMs);
      if (lines.length) return { type: "line", lines: lines };
    }
    if (data.plainLyrics) {
      var pl = String(data.plainLyrics).split(/\r?\n/)
        .filter(function (x) { return x.trim(); })
        .map(function (x, i) {
          return { startMs: i, endMs: i + 1, text: x.trim(), isBackground: false, words: [] };
        });
      if (pl.length) return { type: "static", lines: pl };
    }
    return null;
  }

  function q(s) { return encodeURIComponent(s || ""); }

  function fetchLyrics(artist, track, album, durationMs) {
    if (!artist || !track) return Promise.resolve(null);
    var durSec = durationMs ? Math.round(durationMs / 1000) : 0;
    var getUrl = "https://lrclib.net/api/get?artist_name=" + q(artist) +
      "&track_name=" + q(track) +
      (album ? "&album_name=" + q(album) : "") +
      (durSec ? "&duration=" + durSec : "");
    return fetch(getUrl).then(function (r) {
      if (r.ok) return r.json().then(function (d) { return toLyrics(d, durationMs); });
      // no exact match -> search and pick the closest duration
      return fetch("https://lrclib.net/api/search?artist_name=" + q(artist) + "&track_name=" + q(track))
        .then(function (r2) { return r2.ok ? r2.json() : []; })
        .then(function (list) {
          if (!Array.isArray(list) || !list.length) return null;
          var best = list[0];
          if (durSec) {
            var bd = Infinity;
            for (var i = 0; i < list.length; i++) {
              var d = Math.abs((list[i].duration || 0) - durSec);
              if (d < bd) { bd = d; best = list[i]; }
            }
          }
          return toLyrics(best, durationMs);
        });
    }).catch(function () { return null; });
  }

  // ---- emit to app.js -------------------------------------------------------
  function trackObj() {
    return {
      title: cur.title, artist: cur.artist, album: cur.album,
      coverUrl: cur.coverUrl, durationMs: cur.durationMs,
    };
  }

  function emitMeta() {
    if (handler && cur.title) {
      handler({ track: trackObj(), position: lastPosMs, isPlaying: isPlaying, timestamp: Date.now(), lyrics: pendingLyrics });
    }
  }

  var pendingLyrics = null;

  function onNewTrack() {
    var key = cur.title + "|" + cur.artist;
    if (!cur.title || key === lastKey) { emitMeta(); return; }
    lastKey = key;
    pendingLyrics = null;
    var myTok = ++fetchToken;
    emitMeta(); // show title/cover/progress immediately, lyrics follow
    fetchLyrics(cur.artist, cur.title, cur.album, cur.durationMs).then(function (lyrics) {
      if (myTok !== fetchToken) return;          // a newer track won
      pendingLyrics = lyrics;
      emitMeta();                                // now with lyrics
    });
  }

  function emitPosition() {
    if (handler && cur.title) {
      handler({ position: lastPosMs, isPlaying: isPlaying, timestamp: Date.now() });
    }
  }

  // ---- Wallpaper Engine media listeners -------------------------------------
  // WE exposes media via register FUNCTIONS (window.wallpaperRegisterMedia*Listener),
  // and each callback receives the event object directly. Timeline values are in
  // seconds; thumbnail is a raw base64 PNG string.
  function register() {
    var w = window;
    if (typeof w.wallpaperRegisterMediaPropertiesListener === "function") {
      w.wallpaperRegisterMediaPropertiesListener(function (e) {
        e = e || {};
        cur.title = e.title || "";
        cur.artist = e.artist || e.albumArtist || "";
        cur.album = e.albumTitle || "";
        onNewTrack();
      });
    }
    if (typeof w.wallpaperRegisterMediaThumbnailListener === "function") {
      w.wallpaperRegisterMediaThumbnailListener(function (e) {
        e = e || {};
        cur.coverUrl = normThumb(e.thumbnail);
        emitMeta();
      });
    }
    if (typeof w.wallpaperRegisterMediaTimelineListener === "function") {
      w.wallpaperRegisterMediaTimelineListener(function (e) {
        e = e || {};
        var dur = toMs(e.duration);
        if (dur) { cur.durationMs = dur; if (!haveDuration) { haveDuration = true; emitMeta(); } }
        lastPosMs = toMs(e.position);
        emitPosition();
      });
    }
    if (typeof w.wallpaperRegisterMediaPlaybackListener === "function") {
      w.wallpaperRegisterMediaPlaybackListener(function (e) {
        e = e || {};
        isPlaying = computePlaying(e.state);
        emitPosition();
      });
    }
  }

  return {
    start: function (cb) { handler = cb; register(); },
    // true if WE actually delivered a real track through the native path
    hasTrack: function () { return !!cur.title; },
  };
})();
