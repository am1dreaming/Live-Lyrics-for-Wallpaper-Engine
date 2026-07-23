(function () {
  "use strict";

  let port = 8973;
  const BACKOFF = [1000, 2000, 5000];
  const RESYNC_THRESHOLD = 300;
  const FALLBACK_AFTER = 5000;

  let lyricsOffset = 300;

  const statusEl = document.getElementById("status");
  const artEl = document.getElementById("art");
  const titleEl = document.getElementById("title");
  const artistEl = document.getElementById("artist");
  const viewportEl = document.getElementById("lyrics-viewport");
  const contentEl = document.getElementById("lyrics-content");
  const noLyricsEl = document.getElementById("no-lyrics");
  const nlTitle = document.getElementById("nl-title");
  const nlArtist = document.getElementById("nl-artist");
  const progressEl = document.getElementById("progress");
  const progressFillEl = document.getElementById("progress-fill");
  const timeCurEl = document.getElementById("time-cur");
  const timeTotalEl = document.getElementById("time-total");
  const artVideoEl = document.getElementById("art-video");
  let durationMs = 0;

  let liveCoversOn = true;
  let currentArtist = "";
  let currentAlbum = "";
  let pendingArt = null;
  let artQuality = 0;

  function sendArtConfig() {
    if (artQuality && ws && ws.readyState === WebSocket.OPEN) {
      try { ws.send(JSON.stringify({ artConfig: { height: artQuality } })); } catch (_) {}
    }
  }

  function clearArtVideo() {
    artVideoEl.classList.remove("show");
    artVideoEl.removeAttribute("src");
    try { artVideoEl.load(); } catch (_) {}
  }

  function applyAnimatedArt(info) {
    pendingArt = info;
    if (!liveCoversOn || !info) return;
    if (info.artist !== currentArtist || info.album !== currentAlbum) return;
    if (artVideoEl.getAttribute("src") === info.url) return;
    artVideoEl.muted = true;
    artVideoEl.src = info.url;
    artVideoEl.addEventListener("canplay", function onCan() {
      artVideoEl.removeEventListener("canplay", onCan);
      artVideoEl.classList.add("show");
      artVideoEl.play().catch(() => {});
    });
    artVideoEl.play().catch(() => {});
  }

  ScrollController.init(viewportEl, contentEl);

  let ws = null;
  let connected = false;
  let backoffIndex = 0;
  let reconnectTimer = null;

  const state = {
    trackKey: null,
    position: 0,
    timestamp: Date.now(),
    isPlaying: false,
    currentTime: 0,
  };

  let usingMock = false;
  let everReceived = false;
  let lastRealMessage = Date.now();
  const appStart = Date.now();

  let lyricsSource = "auto";
  let lastBridgeMsg = 0;

  function setStatus(cls) { statusEl.className = cls; }

  function weColorToCss(v) {
    const p = String(v).trim().split(/\s+/).map(Number);
    if (p.length < 3 || p.some(isNaN)) return "#0b0b12";
    return `rgb(${Math.round(p[0] * 255)}, ${Math.round(p[1] * 255)}, ${Math.round(p[2] * 255)})`;
  }

  function normalizeLocal(v) {
    let s = String(v || "").trim();
    if (!s) return "";
    if (/^(https?:|file:|data:)/i.test(s)) return s;
    try { s = decodeURIComponent(s); } catch (e) {}
    s = s.replace(/\\/g, "/");
    if (/^[A-Za-z]:\//.test(s)) return "file:///" + encodeURI(s);
    return s;
  }

  function connect() {
    clearTimeout(reconnectTimer);
    try {
      ws = new WebSocket(`ws://localhost:${port}`);
    } catch (e) {
      scheduleReconnect();
      return;
    }
    ws.onopen = () => {
      connected = true;
      backoffIndex = 0;
      setStatus("connected");
      Background.setProxyBase(`http://localhost:${port}`);
      sendArtConfig();
    };
    ws.onmessage = (ev) => handleMessage(ev.data);
    ws.onerror = () => { try { ws.close(); } catch (_) {} };
    ws.onclose = () => {
      connected = false;
      if (!usingMock) setStatus("disconnected");
      scheduleReconnect();
    };
  }

  function scheduleReconnect() {
    const delay = BACKOFF[Math.min(backoffIndex, BACKOFF.length - 1)];
    backoffIndex++;
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(connect, delay);
  }

  function reconnectNow() {
    try { if (ws) ws.close(); } catch (_) {}
    backoffIndex = 0;
    connect();
  }

  function handleMessage(raw) {
    let msg;
    try { msg = JSON.parse(raw); } catch (_) { return; }
    lastBridgeMsg = Date.now();
    if (lyricsSource === "windows") return;
    lastRealMessage = Date.now();
    everReceived = true;
    usingMock = false;
    setStatus("connected");
    applyMessage(msg, false);
  }

  function bridgeActive() {
    return connected && (Date.now() - lastBridgeMsg) < 10000;
  }

  function onNativeMessage(msg) {
    if (lyricsSource === "relay") return;
    if (lyricsSource === "auto" && bridgeActive()) return;
    lastRealMessage = Date.now();
    everReceived = true;
    usingMock = false;
    setStatus("connected");
    applyMessage(msg, false);
  }

  function applyMessage(msg, isMock) {
    if (msg.animatedArt) { applyAnimatedArt(msg.animatedArt); return; }

    if (typeof msg.position === "number" && typeof msg.timestamp === "number") {
      resync(msg.position, msg.timestamp, msg.isPlaying);
    } else if (typeof msg.isPlaying === "boolean") {
      state.position = extrapolate();
      state.timestamp = Date.now();
      state.isPlaying = msg.isPlaying;
    }

    if (msg.track) {
      const key = msg.track.title + " | " + msg.track.artist;
      const trackChanged = key !== state.trackKey;
      state.trackKey = key;
      currentArtist = msg.track.artist || "";
      currentAlbum = msg.track.album || "";

      updateMeta(msg.track);
      if (trackChanged || isMock) {
        Background.setCover(msg.track.coverUrl || "");
        clearArtVideo();
        if (pendingArt && pendingArt.artist === currentArtist &&
            pendingArt.album === currentAlbum) {
          applyAnimatedArt(pendingArt);
        }
      }

      const lyrics = msg.lyrics || null;
      if (lyrics && lyrics.lines && lyrics.lines.length) {
        noLyricsEl.classList.remove("show");
        viewportEl.style.visibility = "";
        LyricsEngine.setLyrics(lyrics);
        LyricsEngine.update(extrapolate());
      } else {
        showNoLyrics(msg.track);
      }
    }
  }

  function extrapolate() {
    return state.position + (state.isPlaying ? Date.now() - state.timestamp : 0);
  }

  function resync(position, timestamp, isPlaying) {
    const local = extrapolate();
    const nextPlaying = typeof isPlaying === "boolean" ? isPlaying : state.isPlaying;
    const incoming = position + (nextPlaying ? Date.now() - timestamp : 0);
    state.position = position;
    state.timestamp = timestamp;
    state.isPlaying = nextPlaying;
    if (Math.abs(incoming - local) > RESYNC_THRESHOLD) LyricsEngine.forceSnap();
  }

  function updateMeta(track) {
    titleEl.textContent = track.title || "";
    artistEl.textContent = track.artist || "";
    artEl.style.backgroundImage = track.coverUrl ? `url("${track.coverUrl}")` : "none";
    durationMs = Number(track.durationMs) || 0;
  }

  function fmtTime(ms) {
    const s = Math.max(0, Math.floor(ms / 1000));
    return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
  }

  let lastProgressF = null;
  let lastTimeText = null;

  function updateProgress(rawMs) {
    if (!durationMs) return;
    let f = rawMs / durationMs;
    if (f < 0) f = 0; else if (f > 1) f = 1;
    const fs = f.toFixed(4);
    if (fs !== lastProgressF) {
      lastProgressF = fs;
      progressFillEl.style.transform = `scaleX(${fs})`;
    }
    const t = fmtTime(rawMs);
    if (t !== lastTimeText) {
      lastTimeText = t;
      timeCurEl.textContent = t;
      timeTotalEl.textContent = fmtTime(durationMs);
    }
  }

  function showNoLyrics(track) {
    LyricsEngine.setLyrics(null);
    viewportEl.style.visibility = "hidden";
    nlTitle.textContent = "";
    nlArtist.textContent = "";
    noLyricsEl.classList.remove("show");
  }

  function enterMock() {
    usingMock = true;
    setStatus("mock");
    const data = JSON.parse(JSON.stringify(window.MOCK_DATA));
    data.timestamp = Date.now();
    data.position = 0;
    applyMessage(data, true);
    state.position = 0;
    state.timestamp = Date.now();
    state.isPlaying = true;
  }

  function mockTick() {
    const loop = (window.MOCK_DATA && window.MOCK_DATA.__loopMs) || 40000;
    if (extrapolate() > loop) {
      state.position = 0;
      state.timestamp = Date.now();
      LyricsEngine.forceSnap();
    }
  }

  setInterval(() => {
    if (usingMock) return;
    const silent = Date.now() - lastRealMessage;
    if (Date.now() - appStart > FALLBACK_AFTER && silent > FALLBACK_AFTER && !everReceived) {
      enterMock();
    }
  }, 1000);

  let lastFrame = performance.now();
  let lastEngineTime = -1;
  let engineIdleFrames = 0;

  function frame(now) {
    const dt = (now - lastFrame) / 1000;
    lastFrame = now;

    if (usingMock) mockTick();
    const raw = extrapolate();
    state.currentTime = raw + lyricsOffset;

    if (state.currentTime === lastEngineTime) engineIdleFrames++;
    else { engineIdleFrames = 0; lastEngineTime = state.currentTime; }
    if (engineIdleFrames < 120) LyricsEngine.update(state.currentTime, dt);

    ScrollController.step(dt);
    updateProgress(raw);
    requestAnimationFrame(frame);
  }

  let audioLevel = 0;
  let audioEnabled = true;
  let lastAudioWritten = -1;

  function initAudio() {
    if (typeof window.wallpaperRegisterAudioListener !== "function") return;
    window.wallpaperRegisterAudioListener(function (data) {
      if (!audioEnabled || !data || !data.length) return;
      let sum = 0;
      for (let i = 0; i < 20; i++) sum += data[i] || 0;
      const target = Math.min(1, (sum / 20) * 2.4);
      audioLevel += (target - audioLevel) * 0.25;
      if (Math.abs(audioLevel - lastAudioWritten) < 0.008) return;
      lastAudioWritten = audioLevel;
      document.documentElement.style.setProperty("--audio-level", audioLevel.toFixed(3));
    });
  }

  const FORMAT_PRESETS = {
    "16:9": { col: "30%", width: "88", font: "100" },
    "21:9": { col: "33%", width: "75", font: "100" },
    "32:9": { col: "22%", width: "55", font: "95" },
  };
  let lastScreenFormat = null;
  function applyScreenFormat(fmt) {
    let key = fmt;
    if (key === "auto") {
      const r = window.innerWidth / window.innerHeight;
      key = r >= 2.6 ? "32:9" : r >= 1.9 ? "21:9" : "16:9";
    }
    const p = FORMAT_PRESETS[key] || FORMAT_PRESETS["21:9"];
    const s = document.documentElement.style;
    s.setProperty("--col-left", p.col);
    s.setProperty("--lyrics-width", p.width + "%");
    s.setProperty("--font-scale", (p.font / 100).toFixed(3));
  }

  const bgPos = { x: 50, y: 50 };
  function applyBgPos() {
    document.documentElement.style.setProperty("--bgc-pos", bgPos.x + "% " + bgPos.y + "%");
  }
  function applyBgFit(mode) {
    const map = {
      cover: ["cover", "no-repeat", "cover"],
      contain:["contain", "no-repeat", "contain"],
      fill: ["100% 100%", "no-repeat", "fill"],
      tile: ["auto", "repeat", "cover"],
    };
    const m = map[mode] || map.cover;
    const s = document.documentElement.style;
    s.setProperty("--bgc-size", m[0]);
    s.setProperty("--bgc-repeat", m[1]);
    s.setProperty("--bgc-objfit", m[2]);
  }

  const CSS_PROPS = {
    fontSize:          ["--font-scale",            (v) => (v / 100).toFixed(3)],
    lyricsWidth:       ["--lyrics-width",          (v) => v + "%"],
    visibleAmount:     ["--lyrics-vh",             (v) => v + "%"],
    activeLineOpacity: ["--Vocal-Active-opacity",  (v) => (v / 100).toFixed(3)],
    notSungOpacity:    ["--Vocal-NotSung-opacity", (v) => (v / 100).toFixed(3)],
    sungOpacity:       ["--Vocal-Sung-opacity",    (v) => (v / 100).toFixed(3)],
    activeLineScale:   ["--active-scale",          (v) => (v / 100).toFixed(3)],
    activeHighlight:   ["--highlight-enabled",     (v) => (v ? "1" : "0")],
    highlightBlur:     ["--highlight-blur",        (v) => v + "px"],
    offsetX:           ["--offset-x",              (v) => v + "vw"],
    offsetY:           ["--offset-y",              (v) => v + "vh"],
    columnSplit:       ["--col-left",              (v) => v + "%"],
    showAlbumArt:      ["--art-visible",           (v) => (v ? "1" : "0")],
    albumArtSize:      ["--art-scale",             (v) => (v / 100).toFixed(3)],
    infoOpacity:       ["--info-opacity",          (v) => (v / 100).toFixed(2)],
    infoSize:          ["--info-scale",            (v) => (v / 100).toFixed(3)],
    infoOffsetX:       ["--info-dx",               (v) => v + "vw"],
    infoOffsetY:       ["--info-dy",               (v) => v + "vh"],
    titleOffsetX:      ["--title-dx",              (v) => v + "vw"],
    titleOffsetY:      ["--title-dy",              (v) => v + "vh"],
    artistOffsetX:     ["--artist-dx",             (v) => v + "vw"],
    artistOffsetY:     ["--artist-dy",             (v) => v + "vh"],
    progressOffsetX:   ["--prog-dx",               (v) => v + "vw"],
    progressOffsetY:   ["--prog-dy",               (v) => v + "vh"],
    artRadius:         ["--art-radius",            (v) => v + "%"],
    artOpacity:        ["--art-opacity",           (v) => (v / 100).toFixed(2)],
    artShadow:         ["--art-shadow",            (v) => (v / 100).toFixed(2)],
    artGlow:           ["--art-glow",              (v) => (v / 100).toFixed(2)],
    artBorder:         ["--art-border-w",          (v) => v + "px"],
    artRotate:         ["--art-rot",               (v) => v + "deg"],
    artOffsetX:        ["--art-dx",                (v) => v + "vw"],
    artOffsetY:        ["--art-dy",                (v) => v + "vh"],
    backgroundBlur:    ["--bg-blur",               (v) => v + "px"],
    backgroundDim:     ["--bg-dim-extra",          (v) => (v / 100).toFixed(2)],
    customBgBlur:      ["--custom-blur",           (v) => v + "px"],
    bgZoom:            ["--bgc-zoom",              (v) => (v / 100).toFixed(3)],
    bgSaturation:      ["--bgc-sat",               (v) => (v / 100).toFixed(2)],
    bgBrightness:      ["--bgc-bri",               (v) => (v / 100).toFixed(2)],
    bgFlipH:           ["--bgc-flip",              (v) => (v ? "-1" : "1")],
    audioStrength:     ["--audio-strength",        (v) => (v / 100).toFixed(2)],
  };

  const ACTION_PROPS = {
    lyricsOffset:     (v) => { lyricsOffset = Number(v) || 0; },
    lyricsAnchor:     (v) => ScrollController.setAnchorPercent(v),
    screenFormat:     (v) => {

      if (lastScreenFormat !== null && v !== lastScreenFormat) applyScreenFormat(v);
      lastScreenFormat = v;
    },
    letterEmphasis:   (v) => LyricsEngine.setEmphasis(!!v),
    emphasisStrength: (v) => LyricsEngine.setEmphasisStrength(v / 100),
    glowStrength:     (v) => LyricsEngine.setGlowStrength(v / 100),
    interludeDots:    (v) => LyricsEngine.setInterludes(!!v),
    liveCovers:       (v) => {
      liveCoversOn = !!v;
      if (!liveCoversOn) clearArtVideo();
      else if (pendingArt) applyAnimatedArt(pendingArt);
    },
    artQuality:       (v) => { artQuality = Number(v) || 0; sendArtConfig(); },
    grain:            (v) => {
      const n = Number(v) || 0;

      document.documentElement.style.setProperty("--grain", (n / 100 * 0.55).toFixed(3));
      document.body.classList.toggle("grain-on", n > 0);
    },
    showArtist:       (v) => { artistEl.style.display = v ? "" : "none"; },
    showProgress:     (v) => progressEl.classList.toggle("hidden", !v),
    backgroundMode:   (v) => Background.setMode(v),
    backgroundColor:  (v) => Background.setColor(weColorToCss(v)),
    backgroundImage:  (v) => Background.setImage(normalizeLocal(v)),
    backgroundVideo:  (v) => Background.setVideo(normalizeLocal(v)),
    bgFit:            (v) => applyBgFit(v),
    bgPosX:           (v) => { bgPos.x = v; applyBgPos(); },
    bgPosY:           (v) => { bgPos.y = v; applyBgPos(); },
    audioReactive:    (v) => {
      audioEnabled = !!v;
      if (!audioEnabled) document.documentElement.style.setProperty("--audio-level", "0");
    },
    showStatusDot:    (v) => { statusEl.style.display = v ? "block" : "none"; },
    lyricsSource:     (v) => { lyricsSource = String(v || "auto"); },
    websocketPort:    (v) => {
      const p = parseInt(v, 10);
      if (p && p !== port) { port = p; reconnectNow(); }
    },
  };

  window.wallpaperPropertyListener = {
    applyUserProperties: function (props) {
      const rootStyle = document.documentElement.style;
      for (const key in props) {
        const cssMap = CSS_PROPS[key];
        if (cssMap) { rootStyle.setProperty(cssMap[0], cssMap[1](props[key].value)); continue; }
        const action = ACTION_PROPS[key];
        if (action) action(props[key].value);
      }
    },
  };

  connect();
  if (window.MediaNative) MediaNative.start(onNativeMessage);
  initAudio();
  requestAnimationFrame(frame);
})();
