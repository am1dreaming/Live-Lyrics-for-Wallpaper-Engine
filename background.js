// MinenkoY
window.Background = (function () {
  "use strict";

  const bg = document.getElementById("bg");
  const layers = [document.getElementById("cover0"), document.getElementById("cover1")];
  const customEl = document.getElementById("bg-custom");
  const videoEl = document.getElementById("bg-video");

  let front = 0;
  let lastCover = null;
  let mode = "cover";
  let color = "#0b0b12";
  let image = "";
  let video = "";
  let accentEnabled = true;
  let proxyBase = "";
  let accentToken = 0;

  let curAccent = [255, 255, 255];
  let accentRAF = null;
  function applyAccent(r, g, b) {
    const target = [r, g, b];
    if (accentRAF) cancelAnimationFrame(accentRAF);
    if (document.hidden) {
      curAccent = target;
      document.documentElement.style.setProperty("--accent-rgb", target.join(", "));
      return;
    }
    const start = curAccent.slice();
    const t0 = performance.now();
    function stepFn(now) {
      const k = Math.min(1, (now - t0) / 800);
      const e = k * k * (3 - 2 * k);
      curAccent = [0, 1, 2].map((i) => Math.round(start[i] + (target[i] - start[i]) * e));
      document.documentElement.style.setProperty("--accent-rgb", curAccent.join(", "));
      if (k < 1) accentRAF = requestAnimationFrame(stepFn);
    }
    accentRAF = requestAnimationFrame(stepFn);
  }
  function resetAccent() { applyAccent(255, 255, 255); }

  function accentSources(url) {
    if (/^(data:|blob:|file:)/i.test(url)) return [{ src: url, cors: false }];
    const list = [];
    if (proxyBase) list.push({ src: proxyBase + "/img?u=" + encodeURIComponent(url), cors: true });
    list.push({ src: url, cors: true });
    return list;
  }

  function dominantColor(data) {
    const buckets = new Map();
    let grayR = 0, grayG = 0, grayB = 0, grayN = 0;
    for (let i = 0; i < data.length; i += 4) {
      if (data[i + 3] < 128) continue;
      const r = data[i], g = data[i + 1], b = data[i + 2];
      grayR += r; grayG += g; grayB += b; grayN++;
      const mx = Math.max(r, g, b), mn = Math.min(r, g, b);
      const sat = mx === 0 ? 0 : (mx - mn) / mx;
      const lum = mx / 255;
      if (sat < 0.18 || lum < 0.12 || lum > 0.97) continue;
      const w = sat * (0.4 + 0.6 * (1 - Math.abs(lum - 0.55) * 1.4));
      const key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4);
      const acc = buckets.get(key) || [0, 0, 0, 0];
      acc[0] += r * w; acc[1] += g * w; acc[2] += b * w; acc[3] += w;
      buckets.set(key, acc);
    }
    let best = null, bestW = 0;
    for (const acc of buckets.values()) {
      if (acc[3] > bestW) { bestW = acc[3]; best = acc; }
    }
    let col = best
      ? [best[0] / best[3], best[1] / best[3], best[2] / best[3]]
      : grayN ? [grayR / grayN, grayG / grayN, grayB / grayN] : [255, 255, 255];

    const mx = Math.max(col[0], col[1], col[2], 1);
    const k = Math.min(2.4, 205 / mx);
    return col.map((v) => Math.round(Math.min(255, Math.max(v * k, v))));
  }

  function extractAccent(url) {
    if (!accentEnabled || !url) return;
    const token = ++accentToken;
    const sources = accentSources(url);
    const tryLoad = (idx) => {
      if (idx >= sources.length) return;
      const { src, cors } = sources[idx];
      const img = new Image();
      if (cors) img.crossOrigin = "anonymous";
      img.onload = () => {
        if (token !== accentToken) return;
        try {
          const S = 40;
          const c = document.createElement("canvas");
          c.width = S; c.height = S;
          const x = c.getContext("2d", { willReadFrequently: true });
          x.drawImage(img, 0, 0, S, S);
          const d = x.getImageData(0, 0, S, S).data;
          const rgb = dominantColor(d);
          applyAccent(rgb[0], rgb[1], rgb[2]);
        } catch (e) { tryLoad(idx + 1); }
      };
      img.onerror = () => { if (token === accentToken) tryLoad(idx + 1); };
      img.src = src;
    };
    tryLoad(0);
  }

  function refreshAccent() {
    if (!accentEnabled) { resetAccent(); return; }
    extractAccent(lastCover);
  }

  function setAccentEnabled(on) {
    accentEnabled = !!on;
    if (!accentEnabled) resetAccent(); else refreshAccent();
  }

  function setProxyBase(base) {
    const next = base || "";
    if (next === proxyBase) return;
    proxyBase = next;
    refreshAccent();
  }

  function applyCover(url) {
    const next = front ^ 1;
    const el = layers[next];
    el.style.backgroundImage = url ? `url("${url}")` : "none";
    void el.offsetWidth;
    el.classList.add("active");
    layers[front].classList.remove("active");
    front = next;
  }

  function setCover(url) {
    lastCover = url;
    if (mode === "cover") applyCover(url);
    if (accentEnabled) extractAccent(url);
  }

  function applyCustom() {
    if (mode === "solid") {
      customEl.style.backgroundColor = color;
      customEl.style.backgroundImage = "none";
    } else if (mode === "image") {
      customEl.style.backgroundColor = "#000";
      customEl.style.backgroundImage = image ? `url("${image}")` : "none";
    }
  }

  videoEl.addEventListener("error", () => {
    console.warn("[bg] video failed: " + video +
      " — Wallpaper Engine plays only .webm/.ogv (not .mp4). Use convert-to-webm.bat.");
  });

  function applyVideo() {
    if (!video) return;
    videoEl.muted = true;
    if (videoEl.getAttribute("src") !== video) {
      videoEl.src = video;
      videoEl.addEventListener("canplay", () => {
        if (mode === "video" && videoEl.paused) videoEl.play().catch(() => {});
      }, { once: true });
    }
    videoEl.play().catch(() => {});
  }

  function stopVideo() { if (!videoEl.paused) videoEl.pause(); }

  function refresh() {
    bg.classList.toggle("video", mode === "video");
    if (mode === "cover") {
      bg.classList.remove("custom");
      stopVideo();
      applyCover(lastCover);
    } else {
      bg.classList.add("custom");
      if (mode === "video") applyVideo();
      else { stopVideo(); applyCustom(); }
    }
  }

  function setMode(m) { if (m && m !== mode) { mode = m; refresh(); } }
  function setColor(c) { color = c; if (mode === "solid") applyCustom(); }
  function setImage(src) { image = src; if (mode === "image") applyCustom(); }
  function setVideo(src) { video = src; if (mode === "video") applyVideo(); }

  return { setCover, setMode, setColor, setImage, setVideo, setAccentEnabled, setProxyBase };
})();
