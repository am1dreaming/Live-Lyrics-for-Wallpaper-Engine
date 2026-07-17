// MinenkoY
const WebSocket = require("ws");
const http = require("http");
const https = require("https");
const dns = require("dns");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawn, execSync } = require("child_process");

const PORT = Number(process.env.BRIDGE_PORT) || 8973;
const CACHE_DIR = path.join(__dirname, "cache");
const TOKEN_FILE = path.join(__dirname, "am-token.json");
const CONFIG_FILE = path.join(__dirname, "art-config.json");
const CACHE_MAX_BYTES = (Number(process.env.BRIDGE_CACHE_MB) || 600) * 1024 * 1024;

let targetHeight = 486;
try {
  const c = JSON.parse(fs.readFileSync(CONFIG_FILE, "utf8"));
  if (c && c.height) targetHeight = Number(c.height) || 486;
} catch (_) {}

if (!fs.existsSync(CACHE_DIR)) fs.mkdirSync(CACHE_DIR, { recursive: true });

const HOST = process.env.BRIDGE_HOST || "127.0.0.1";

function isPrivateOrReservedIp(ip) {
  ip = String(ip || "").toLowerCase().replace(/^\[|\]$/g, "");
  const m4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip);
  if (m4) {
    if (m4.slice(1).some((o) => +o > 255)) return true;
    const a = +m4[1], b = +m4[2];
    return a === 0 || a === 127 || a === 10 ||
      (a === 169 && b === 254) || (a === 192 && b === 168) ||
      (a === 172 && b >= 16 && b <= 31) || (a === 100 && b >= 64 && b <= 127);
  }
  if (ip.includes(":")) {
    const v4 = /^::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/.exec(ip);
    if (v4) return isPrivateOrReservedIp(v4[1]);
    return ip === "::1" || ip === "::" || ip.startsWith("fe80:") ||
      ip.startsWith("fc") || ip.startsWith("fd");
  }
  return false;
}

function isBlockedProxyHost(host) {
  host = String(host || "").toLowerCase().replace(/^\[|\]$/g, "");
  if (!host || host === "localhost" || host.endsWith(".localhost")) return true;
  if (/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host) || host.includes(":"))
    return isPrivateOrReservedIp(host);
  if (!/[a-z]/.test(host)) return true;
  if (!/^[a-z0-9.-]+$/.test(host)) return true;
  if (/(^|\.)0x[0-9a-f]+(\.|$)/.test(host)) return true;
  return false;
}

// Anti DNS-rebinding: resolve ALL A/AAAA records up front, reject if any one
// is private/reserved, and return the first allowed address so the actual
// socket can be pinned to it (instead of letting http.get re-resolve later).
async function resolveAndValidate(hostname) {
  const addrs = await dns.promises.lookup(hostname, { all: true, verbatim: true });
  if (!addrs || !addrs.length) throw new Error("no dns result: " + hostname);
  for (const a of addrs) {
    if (isPrivateOrReservedIp(a.address)) throw new Error("blocked resolved ip: " + a.address);
  }
  return addrs[0];
}

const MAX_PROXY_BYTES = 25 * 1024 * 1024;

const server = http.createServer((req, res) => {

  const m = /^\/art\/([A-Za-z0-9._-]+\.webm)$/.exec(req.url || "");
  if (m) {
    const file = path.join(CACHE_DIR, m[1]);
    let size = -1;
    try { size = fs.statSync(file).size; } catch (_) {}
    if (size >= 0) {
      res.writeHead(200, {
        "Content-Type": "video/webm",
        "Content-Length": size,
        "Cache-Control": "public, max-age=31536000",
        "Access-Control-Allow-Origin": "*",
      });
      const stream = fs.createReadStream(file);
      stream.on("error", () => { try { res.destroy(); } catch (_) {} });
      stream.pipe(res);
      return;
    }
    res.writeHead(404); res.end("not found");
    return;
  }

  if ((req.url || "").startsWith("/img?")) {
    let target;
    try { target = new URL(req.url, "http://localhost").searchParams.get("u"); } catch (_) {}
    if (!target || !/^https?:\/\//i.test(target)) { res.writeHead(400); res.end("bad url"); return; }
    const proxyImage = (url, redirects) => {
      let phost = "";
      try { phost = new URL(url).hostname; } catch (_) {}
      if (isBlockedProxyHost(phost)) { if (!res.headersSent) { res.writeHead(403); res.end("blocked host"); } return; }
      resolveAndValidate(phost).then((addr) => {
        const mod = url.startsWith("https:") ? https : http;
        const up = mod.get(url, {
          headers: { "User-Agent": "Mozilla/5.0", Accept: "image/*" },
          // pin the socket to the pre-validated IP; Host header / TLS SNI
          // still come from the original hostname in `url`
          lookup: (h, opts, cb) => {
            if (opts && opts.all) return cb(null, [{ address: addr.address, family: addr.family }]);
            cb(null, addr.address, addr.family);
          },
        }, (r) => {
          if (r.statusCode >= 301 && r.statusCode <= 308 && r.headers.location && redirects > 0) {
            r.resume();
            return proxyImage(new URL(r.headers.location, url).href, redirects - 1);
          }
          if (r.statusCode !== 200) { r.resume(); res.writeHead(502); res.end("upstream"); return; }
          if (Number(r.headers["content-length"]) > MAX_PROXY_BYTES) {
            r.resume(); up.destroy(); res.writeHead(502); res.end("too large"); return;
          }
          res.writeHead(200, {
            "Content-Type": r.headers["content-type"] || "image/jpeg",
            "Cache-Control": "public, max-age=86400",
            "Access-Control-Allow-Origin": "*",
          });
          let sent = 0;
          r.on("data", (c) => {
            sent += c.length;
            if (sent > MAX_PROXY_BYTES) { up.destroy(); try { res.destroy(); } catch (_) {} }
          });
          r.pipe(res);
        });
        up.on("error", () => { if (!res.headersSent) { res.writeHead(502); res.end("proxy error"); } });
        up.setTimeout(15000, () => up.destroy());
      }).catch(() => { if (!res.headersSent) { res.writeHead(403); res.end("blocked host"); } });
    };
    proxyImage(target, 5);
    return;
  }
  res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
  res.end("lyrics-bridge relay: ws + /art/*.webm cache\n");
});

const wss = new WebSocket.Server({ server });
server.listen(PORT, HOST, () => {
  console.log(`[bridge] relay listening on ws://${HOST}:${PORT} (+ http /art)`);
  console.log(`[bridge] ffmpeg: ${FFMPEG || "NOT FOUND — animated covers disabled"}`);
});

let lastFullMessage = null;
let lastArtMessage = null;
let lastCanvasMessage = null;

function broadcastObj(obj) {
  const str = JSON.stringify(obj);
  for (const client of wss.clients) {
    if (client.readyState === WebSocket.OPEN) client.send(str);
  }
  return str;
}

wss.on("connection", (ws, req) => {
  const who = (req && req.socket && req.socket.remoteAddress) || "?";
  console.log(`[bridge] client connected (${who}); total=${wss.clients.size}`);

  if (lastFullMessage && ws.readyState === WebSocket.OPEN) ws.send(lastFullMessage);
  if (lastArtMessage && ws.readyState === WebSocket.OPEN) ws.send(lastArtMessage);
  if (lastCanvasMessage && ws.readyState === WebSocket.OPEN) ws.send(lastCanvasMessage);

  ws.isAlive = true;
  ws.on("pong", () => (ws.isAlive = true));

  ws.on("message", (data, isBinary) => {
    const str = isBinary ? null : data.toString();

    if (str) {
      let obj = null;
      try { obj = JSON.parse(str); } catch (_) {}
      if (obj && obj.track) {
        lastFullMessage = str;

        onTrack(obj.track).catch((e) =>
          console.warn("[art] pipeline error:", e && e.message ? e.message : e));
      }

      if (obj && Object.prototype.hasOwnProperty.call(obj, "canvasUrl")) {
        onCanvas(obj).catch((e) =>
          console.warn("[canvas] pipeline error:", e && e.message ? e.message : e));
        return;
      }

      if (obj && obj.artConfig && obj.artConfig.height) {
        const h = Math.max(360, Math.min(2160, Number(obj.artConfig.height) || 486));
        if (h !== targetHeight) {
          targetHeight = h;
          fs.writeFileSync(CONFIG_FILE, JSON.stringify({ height: h }));
          console.log(`[art] target quality → ${h}p`);

          if (lastFullMessage) {
            try {
              const last = JSON.parse(lastFullMessage);
              if (last.track) onTrack(last.track).catch(() => {});
            } catch (_) {}
          }
        }
        return;
      }
    }

    for (const client of wss.clients) {
      if (client !== ws && client.readyState === WebSocket.OPEN) {
        client.send(data, { binary: isBinary });
      }
    }
  });

  ws.on("close", () => {
    console.log(`[bridge] client disconnected; total=${wss.clients.size}`);
  });
  ws.on("error", (err) => console.warn("[bridge] client error:", err.message));
});

const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (ws.isAlive === false) { ws.terminate(); continue; }
    ws.isAlive = false;
    try { ws.ping(); } catch (_) {}
  }
}, 15000);
wss.on("close", () => clearInterval(heartbeat));

function fetchText(url, headers, redirects) {
  redirects = redirects == null ? 5 : redirects;
  return new Promise((resolve, reject) => {
    const req = https.get(url, { headers: headers || {} }, (res) => {
      if (res.statusCode >= 301 && res.statusCode <= 308 && res.headers.location && redirects > 0) {
        res.resume();
        return resolve(fetchText(new URL(res.headers.location, url).href, headers, redirects - 1));
      }
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (c) => (body += c));
      res.on("end", () => resolve({ status: res.statusCode, body }));
    });
    req.on("error", reject);
    req.setTimeout(20000, () => req.destroy(new Error("timeout: " + url)));
  });
}

function findFfmpeg() {
  try {
    execSync("ffmpeg -version", { stdio: "ignore" });
    return "ffmpeg";
  } catch (_) {}
  const local = process.env.LOCALAPPDATA || "";
  const shim = path.join(local, "Microsoft", "WinGet", "Links", "ffmpeg.exe");
  if (fs.existsSync(shim)) return shim;
  const pkgs = path.join(local, "Microsoft", "WinGet", "Packages");
  try {
    for (const dir of fs.readdirSync(pkgs)) {
      if (!/ffmpeg/i.test(dir)) continue;
      const base = path.join(pkgs, dir);
      for (const sub of fs.readdirSync(base)) {
        const cand = path.join(base, sub, "bin", "ffmpeg.exe");
        if (fs.existsSync(cand)) return cand;
      }
    }
  } catch (_) {}
  return null;
}
const FFMPEG = findFfmpeg();

const SCRAPE_NET_ATTEMPTS = 3;
const SCRAPE_COOLDOWN_MAX = 5 * 60 * 1000;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const BUNDLE_PATTERNS = [
  /crossorigin src="(\/assets\/index[^"]+\.js)"/g,
  /src="(\/assets\/index[^"]+\.js)"/g,
  /src="(\/assets\/[^"]+\.js)"/g,
];
const TOKEN_RE = /eyJ[A-Za-z0-9._-]{100,}/;

let amToken = null;
try { amToken = JSON.parse(fs.readFileSync(TOKEN_FILE, "utf8")).token || null; } catch (_) {}

let scrapeInProgress = null;
let scrapeFailures = 0;
let scrapeCooldownUntil = 0;

async function fetchTextRetry(url, headers) {
  let lastErr;
  for (let i = 0; i < SCRAPE_NET_ATTEMPTS; i++) {
    try { return await fetchText(url, headers); }
    catch (e) { lastErr = e; if (i < SCRAPE_NET_ATTEMPTS - 1) await sleep(500 * (i + 1)); }
  }
  throw lastErr;
}

async function doScrapeToken() {
  const page = await fetchTextRetry("https://music.apple.com/us/browse");
  const bundles = [];
  for (const re of BUNDLE_PATTERNS) {
    let m;
    while ((m = re.exec(page.body))) if (!bundles.includes(m[1])) bundles.push(m[1]);
  }
  if (!bundles.length) throw new Error("bundle path not found on music.apple.com");
  for (const b of bundles.slice(0, 6)) {
    const bundle = await fetchTextRetry("https://music.apple.com" + b);
    const tok = TOKEN_RE.exec(bundle.body);
    if (!tok) continue;
    amToken = tok[0];
    fs.writeFileSync(TOKEN_FILE, JSON.stringify({ token: amToken, at: Date.now() }));
    console.log("[art] scraped fresh Apple Music web token");
    return amToken;
  }
  throw new Error("token not found in bundle");
}

function scrapeToken() {
  if (scrapeInProgress) return scrapeInProgress;
  if (Date.now() < scrapeCooldownUntil) {
    if (amToken) return Promise.resolve(amToken);
    return Promise.reject(new Error("token scrape in cooldown, no cached token"));
  }
  scrapeInProgress = doScrapeToken()
    .then((tok) => { scrapeFailures = 0; scrapeCooldownUntil = 0; return tok; })
    .catch((err) => {
      scrapeFailures++;
      const wait = Math.min(SCRAPE_COOLDOWN_MAX, 15000 * 2 ** (scrapeFailures - 1));
      scrapeCooldownUntil = Date.now() + wait;
      console.warn(`[art] token scrape failed (${scrapeFailures}x): ${err.message}; ` +
        (amToken ? `using stale token, cooldown ${Math.round(wait / 1000)}s`
                 : `no cached token, cooldown ${Math.round(wait / 1000)}s`));
      if (amToken) return amToken;
      throw err;
    })
    .finally(() => { scrapeInProgress = null; });
  return scrapeInProgress;
}

async function ampApi(pathPart, retry) {
  if (!amToken) await scrapeToken();
  const res = await fetchText("https://amp-api.music.apple.com" + pathPart, {
    Authorization: "Bearer " + amToken,
    Origin: "https://music.apple.com",
  });
  if ((res.status === 401 || res.status === 403) && retry !== false) {
    const before = amToken;
    await scrapeToken();
    if (amToken && amToken !== before) return ampApi(pathPart, false);
  }
  if (res.status !== 200) throw new Error("amp-api " + res.status);
  return JSON.parse(res.body);
}

function norm(s) {
  return String(s || "").toLowerCase()
    .replace(/\(.*?\)|\[.*?\]/g, "")
    .replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

const itunesSearchCache = new Map();

async function itunesSearchAlbum(artist, album) {
  const cacheKey = artist + "|" + album;
  if (itunesSearchCache.has(cacheKey)) return itunesSearchCache.get(cacheKey);

  const term = encodeURIComponent(artist + " " + album);
  const res = await fetchText(
    `https://itunes.apple.com/search?term=${term}&entity=album&limit=5&country=us`);
  const data = JSON.parse(res.body);
  let match = null;
  if (data.results && data.results.length) {
    const wantA = norm(artist), wantB = norm(album);
    match =
      data.results.find((r) => norm(r.collectionName) === wantB && norm(r.artistName).includes(wantA)) ||
      data.results.find((r) => norm(r.collectionName).startsWith(wantB)) ||
      data.results[0];
  }
  itunesSearchCache.set(cacheKey, match);
  setTimeout(() => itunesSearchCache.delete(cacheKey), 5 * 60 * 1000);
  return match;
}

async function itunesAlbumId(artist, album) {
  const m = await itunesSearchAlbum(artist, album);
  return m ? m.collectionId : null;
}

async function itunesCoverUrl(artist, album) {
  const m = await itunesSearchAlbum(artist, album);
  if (!m || !m.artworkUrl100) return "";
  return m.artworkUrl100.replace(/100x100bb(\.\w+)$/, "1200x1200bb$1");
}

async function directM3u8(artist, album) {
  const id = await itunesAlbumId(artist, album);
  if (!id) return null;
  const json = await ampApi(`/v1/catalog/us/albums/${id}?extend=editorialVideo`);
  const ev =
    json && json.data && json.data[0] &&
    json.data[0].attributes && json.data[0].attributes.editorialVideo;
  if (!ev) return null;
  const v =
    (ev.motionDetailSquare && ev.motionDetailSquare.video) ||
    (ev.motionSquareVideo1x1 && ev.motionSquareVideo1x1.video) ||
    null;
  return v;
}

async function m8tecM3u8(artist, album) {
  const url =
    "https://artwork.m8tec.top/api/v1/artwork/search" +
    `?artist=${encodeURIComponent(artist)}&album=${encodeURIComponent(album)}`;
  const res = await fetchText(url);
  if (res.status !== 200) return null;
  const data = JSON.parse(res.body);
  return data && data.url ? data.url : null;
}

async function pickVariant(masterUrl) {
  const res = await fetchText(masterUrl);
  const lines = res.body.split(/\r?\n/);
  let best = null;
  for (let i = 0; i < lines.length - 1; i++) {
    const inf = /^#EXT-X-STREAM-INF:.*RESOLUTION=(\d+)x(\d+)/.exec(lines[i]);
    if (!inf) continue;

    if (/hvc1/.test(lines[i])) continue;
    const h = Number(inf[2]);
    const uri = lines[i + 1].trim();
    if (!uri || uri.startsWith("#")) continue;
    const score = Math.abs(h - targetHeight);
    if (!best || score < best.score) {
      best = { score, url: new URL(uri, masterUrl).href, h };
    }
  }
  if (best) console.log(`[art] variant: ${best.h}p (target ${targetHeight}p)`);
  return best ? best.url : masterUrl;
}

const TRANSCODE_TIMEOUT_MS = 90 * 1000;

function transcode(m3u8Url, outFile) {
  return new Promise((resolve, reject) => {
    const tmp = outFile + ".tmp.webm";
    const args = [
      "-y", "-loglevel", "error",
      "-protocol_whitelist", "http,https,tcp,tls,crypto",
      "-i", m3u8Url,
      "-an",
      "-c:v", "libvpx-vp9", "-crf", "34", "-b:v", "0",
      "-deadline", "realtime", "-cpu-used", "5", "-row-mt", "1",
      "-pix_fmt", "yuv420p",
      "-f", "webm",
      tmp,
    ];
    const p = spawn(FFMPEG, args, { stdio: ["ignore", "ignore", "pipe"] });
    let err = "";
    let settled = false;
    const finish = (fn, arg) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn(arg);
    };
    const timer = setTimeout(() => {
      try { p.kill("SIGKILL"); } catch (_) {}
      try { fs.unlinkSync(tmp); } catch (_) {}
      finish(reject, new Error("ffmpeg timeout after " + (TRANSCODE_TIMEOUT_MS / 1000) + "s"));
    }, TRANSCODE_TIMEOUT_MS);
    p.stderr.on("data", (d) => (err += d));
    p.on("error", (e) => {
      try { fs.unlinkSync(tmp); } catch (_) {}
      finish(reject, new Error("ffmpeg spawn failed: " + e.message));
    });
    p.on("close", (code) => {
      if (code === 0 && fs.existsSync(tmp)) {
        fs.renameSync(tmp, outFile);
        finish(resolve, outFile);
      } else {
        try { fs.unlinkSync(tmp); } catch (_) {}
        finish(reject, new Error("ffmpeg exit " + code + ": " + err.slice(0, 300)));
      }
    });
  });
}

const NO_ART = new Set();
let inFlight = null;
let currentKey = null;

function cacheFileFor(key) {
  const hash = crypto.createHash("sha1").update(key).digest("hex").slice(0, 16);

  return path.join(CACHE_DIR, hash + "-" + targetHeight + ".webm");
}

function announce(artist, album, file) {
  try { const t = Date.now() / 1000; fs.utimesSync(file, t, t); } catch (_) {}
  const url = `http://localhost:${PORT}/art/${path.basename(file)}`;
  lastArtMessage = broadcastObj({ animatedArt: { artist, album, url } });
  console.log(`[art] → ${artist} — ${album}: ${url}`);
}

function pruneCache() {
  let names;
  try { names = fs.readdirSync(CACHE_DIR); } catch (_) { return; }
  const items = [];
  let total = 0;
  for (const name of names) {
    if (!/^[0-9a-f]{16}-\d+\.webm$/.test(name)) continue;
    try {
      const st = fs.statSync(path.join(CACHE_DIR, name));
      items.push({ name, size: st.size, mtime: st.mtimeMs });
      total += st.size;
    } catch (_) {}
  }
  if (total <= CACHE_MAX_BYTES) return;
  items.sort((a, b) => a.mtime - b.mtime);
  let removed = 0;
  for (const it of items) {
    if (total <= CACHE_MAX_BYTES) break;
    try { fs.unlinkSync(path.join(CACHE_DIR, it.name)); total -= it.size; removed++; } catch (_) {}
  }
  if (removed) console.log(`[art] cache pruned: removed ${removed}, now ${(total / 1048576).toFixed(0)} MB`);
}

async function onTrack(track) {
  const artist = track.artist, album = track.album;
  if (!artist || !album) return;
  const key = artist + "|" + album;
  currentKey = key;

  const file = cacheFileFor(key);
  if (fs.existsSync(file)) { announce(artist, album, file); return; }
  if (NO_ART.has(key)) return;
  if (!FFMPEG) return;
  if (inFlight === key) return;

  while (inFlight) await new Promise((r) => setTimeout(r, 500));
  if (currentKey !== key) return;
  if (fs.existsSync(file)) { announce(artist, album, file); return; }

  inFlight = key;
  try {
    console.log(`[art] resolving: ${artist} — ${album}`);
    let m3u8 = null;
    try { m3u8 = await directM3u8(artist, album); }
    catch (e) { console.warn("[art] direct path failed:", e.message); }
    if (!m3u8) {
      try { m3u8 = await m8tecM3u8(artist, album); }
      catch (e) { console.warn("[art] m8tec fallback failed:", e.message); }
    }
    if (!m3u8) {
      NO_ART.add(key);
      console.log(`[art] no animated artwork: ${artist} — ${album}`);
      return;
    }
    const variant = await pickVariant(m3u8);
    console.log(`[art] transcoding ${variant.slice(0, 90)}…`);
    const t0 = Date.now();
    await transcode(variant, file);
    console.log(`[art] done in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
    if (currentKey === key) announce(artist, album, file);
    else announce(artist, album, file);
    pruneCache();
  } finally {
    inFlight = null;
  }
}

// ---- Spotify Canvas: filter junk (static "ad" Canvas) + transcode to webm ----
let canvasInFlight = null;
let canvasKey = null;
const CANVAS_FREEZE_RATIO = Number(process.env.BRIDGE_CANVAS_FREEZE) || 0.85;

function canvasCacheFile(trackId) {
  const hash = crypto.createHash("sha1").update("canvas:" + trackId).digest("hex").slice(0, 16);
  return path.join(CACHE_DIR, hash + "-" + targetHeight + ".webm");
}

function downloadFile(url, dest, redirects) {
  redirects = redirects == null ? 5 : redirects;
  return new Promise((resolve, reject) => {
    const mod = url.startsWith("http:") ? http : https;
    const r = mod.get(url, { headers: { "User-Agent": "Mozilla/5.0" } }, (res) => {
      if (res.statusCode >= 301 && res.statusCode <= 308 && res.headers.location && redirects > 0) {
        res.resume();
        return resolve(downloadFile(new URL(res.headers.location, url).href, dest, redirects - 1));
      }
      if (res.statusCode !== 200) { res.resume(); return reject(new Error("canvas download HTTP " + res.statusCode)); }
      const out = fs.createWriteStream(dest);
      res.pipe(out);
      out.on("finish", () => out.close(() => resolve(dest)));
      out.on("error", reject);
    });
    r.on("error", reject);
    r.setTimeout(20000, () => r.destroy(new Error("canvas download timeout")));
  });
}

// Fraction of the clip that is "frozen" (no motion) — static ad Canvas ≈ 1.0.
function freezeRatio(file) {
  return new Promise((resolve) => {
    const args = ["-hide_banner", "-i", file, "-vf", "scale=64:-2,freezedetect=n=-55dB:d=0.3", "-map", "0:v", "-f", "null", "-"];
    const p = spawn(FFMPEG, args, { stdio: ["ignore", "ignore", "pipe"] });
    let err = "";
    p.stderr.on("data", (d) => (err += d));
    p.on("error", () => resolve({ ratio: 0, dur: 0 }));
    p.on("close", () => {
      let frozen = 0, m;
      const re = /freeze_duration:\s*([0-9.]+)/g;
      while ((m = re.exec(err))) frozen += parseFloat(m[1]);
      const dm = /Duration:\s*(\d+):(\d+):([0-9.]+)/.exec(err);
      const dur = dm ? (+dm[1]) * 3600 + (+dm[2]) * 60 + parseFloat(dm[3]) : 0;
      resolve({ ratio: dur > 0 ? Math.min(1, frozen / dur) : 0, dur });
    });
  });
}

function announceCanvas(trackId, file) {
  try { const t = Date.now() / 1000; fs.utimesSync(file, t, t); } catch (_) {}
  const url = `http://localhost:${PORT}/art/${path.basename(file)}`;
  lastCanvasMessage = broadcastObj({ canvasVideo: { trackId, url } });
  console.log(`[canvas] → ${trackId}: ${url}`);
}

function clearCanvas(trackId) {
  lastCanvasMessage = broadcastObj({ canvasVideo: { trackId, url: null } });
}

async function onCanvas(obj) {
  const trackId = String(obj.trackId || "");
  const url = obj.canvasUrl || "";
  canvasKey = trackId;
  if (!url) { clearCanvas(trackId); return; }       // no/image Canvas → static cover
  if (!FFMPEG) return;

  const file = canvasCacheFile(trackId);
  if (fs.existsSync(file)) { announceCanvas(trackId, file); return; }
  if (canvasInFlight === trackId) return;
  while (canvasInFlight) await new Promise((r) => setTimeout(r, 300));
  if (canvasKey !== trackId) return;
  if (fs.existsSync(file)) { announceCanvas(trackId, file); return; }

  canvasInFlight = trackId;
  const tmp = file + ".src.mp4";
  try {
    await downloadFile(url, tmp);
    const fr = await freezeRatio(tmp);
    console.log(`[canvas] ${trackId}: frozen ${(fr.ratio * 100).toFixed(0)}% of ${fr.dur.toFixed(1)}s`);
    if (fr.ratio >= CANVAS_FREEZE_RATIO) {
      console.log(`[canvas] static/ad junk — skipped: ${trackId}`);
      clearCanvas(trackId);
      return;
    }
    await transcode(tmp, file);
    announceCanvas(trackId, file);
    pruneCache();
  } catch (e) {
    console.warn("[canvas] failed:", e && e.message ? e.message : e);
    clearCanvas(trackId);
  } finally {
    try { fs.unlinkSync(tmp); } catch (_) {}
    canvasInFlight = null;
  }
}

function parseLrc(text) {

  const rows = [];
  const re = /^\[(\d+):(\d+(?:\.\d+)?)\](.*)$/;
  for (const raw of text.split(/\r?\n/)) {
    const m = re.exec(raw);
    if (!m) continue;
    const startMs = Math.round((Number(m[1]) * 60 + Number(m[2])) * 1000);
    const t = m[3].trim();
    rows.push({ startMs, text: t });
  }
  return rows;
}

function buildLinesFromLrc(rows, durationMs) {
  return rows
    .map((r, i) => {
      const endMs = i < rows.length - 1 ? rows[i + 1].startMs : (durationMs || r.startMs + 4000);
      const isBackground = r.text.length > 1 && r.text.startsWith("(") && r.text.endsWith(")");
      return { startMs: r.startMs, endMs, text: r.text, isBackground, words: [] };
    })
    .filter((l) => l.text.length > 0);
}

async function lrclibLookup(artist, track, album, durationMs) {
  const durationSec = durationMs ? Math.round(durationMs / 1000) : null;
  const q = (extra) =>
    `artist_name=${encodeURIComponent(artist)}&track_name=${encodeURIComponent(track)}` + extra;

  try {
    let url = `https://lrclib.net/api/get?${q(album ? `&album_name=${encodeURIComponent(album)}` : "")}`;
    if (durationSec) url += `&duration=${durationSec}`;
    const res = await fetchText(url);
    if (res.status === 200) {
      const data = JSON.parse(res.body);
      return lrcResultToLyrics(data, durationMs);
    }
  } catch (_) {  }

  try {
    const res = await fetchText(`https://lrclib.net/api/search?${q("")}`);
    if (res.status !== 200) return null;
    const list = JSON.parse(res.body);
    if (!Array.isArray(list) || !list.length) return null;

    let best = list[0];
    if (durationSec) {
      let bestDiff = Infinity;
      for (const c of list) {
        const d = Math.abs((c.duration || 0) - durationSec);
        if (d < bestDiff) { bestDiff = d; best = c; }
      }
    }
    return lrcResultToLyrics(best, durationMs);
  } catch (e) {
    console.warn("[lyrics] lrclib lookup failed:", e.message);
    return null;
  }
}

function lrcResultToLyrics(data, durationMs) {
  if (!data) return null;
  if (data.instrumental) return null;
  if (data.syncedLyrics) {
    const rows = parseLrc(data.syncedLyrics);
    const lines = buildLinesFromLrc(rows, durationMs);
    if (lines.length) return { type: "line", lines };
  }
  if (data.plainLyrics) {
    const lines = data.plainLyrics
      .split(/\r?\n/)
      .filter((t) => t.trim().length)
      .map((t, i) => ({ startMs: i, endMs: i + 1, text: t.trim(), isBackground: false, words: [] }));
    if (lines.length) return { type: "static", lines };
  }
  return null;
}

function resolvePowershell() {
  const candidates = [
    "powershell.exe",
    "powershell",
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
  ];
  for (const c of candidates) {
    try { execSync(`"${c}" -Command "$null"`, { stdio: "ignore" }); return c; } catch (_) {}
  }
  return null;
}

function startSmtcProducer() {
  const ps = resolvePowershell();
  const script = path.join(__dirname, "nowplaying.ps1");
  if (!ps || !fs.existsSync(script)) {
    console.warn("[nowplaying] disabled (powershell or nowplaying.ps1 not found)");
    return;
  }

  let lastTrackKey = null;
  let lastAnchorMs = null;
  let lastIsPlaying = null;
  let fetchToken = 0;

  const proc = spawn(ps, ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script], {
    stdio: ["ignore", "pipe", "pipe"],
  });
  console.log("[nowplaying] SMTC producer started (PID " + proc.pid + ")");

  let buf = "";
  proc.stdout.on("data", (chunk) => {
    buf += chunk.toString();
    const lines = buf.split(/\r?\n/);
    buf = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      let o;
      try { o = JSON.parse(line); } catch (_) { continue; }
      if (!o.present) continue;
      handleTick(o).catch((e) => console.warn("[nowplaying] tick error:", e.message));
    }
  });
  proc.stderr.on("data", (d) => console.warn("[nowplaying] stderr:", d.toString().trim()));
  proc.on("close", (code) => {
    console.warn(`[nowplaying] exited (code ${code}); restarting in 3s`);
    setTimeout(startSmtcProducer, 3000);
  });

  async function handleTick(o) {
    const key = (o.title || "") + "|" + (o.artist || "");
    const isNewTrack = key !== lastTrackKey;

    if (isNewTrack) {
      lastTrackKey = key;
      lastAnchorMs = o.anchorMs;
      lastIsPlaying = o.isPlaying;
      const myToken = ++fetchToken;

      const track = {
        title: o.title || "Unknown",
        artist: o.artist || "Unknown Artist",
        album: o.album || "",
        coverUrl: "",
        durationMs: o.durationMs || 0,
      };

      let coverUrl = "";
      try { coverUrl = await itunesCoverUrl(track.artist, track.album); } catch (_) {}
      if (fetchToken !== myToken) return;
      track.coverUrl = coverUrl || "";

      let lyrics = null;
      try { lyrics = await lrclibLookup(track.artist, track.title, track.album, track.durationMs); }
      catch (e) { console.warn("[lyrics] error:", e.message); }
      if (fetchToken !== myToken) return;

      const msg = {
        track,
        position: o.positionMs,
        isPlaying: o.isPlaying,
        timestamp: o.anchorMs,
        lyrics,
      };
      lastFullMessage = broadcastObj(msg);
      console.log(`[nowplaying] ${track.artist} — ${track.title} | lyrics: ${lyrics ? lyrics.type : "none"}`);
      onTrack(track).catch((e) => console.warn("[art] pipeline error:", e.message));
    } else if (o.anchorMs !== lastAnchorMs || o.isPlaying !== lastIsPlaying) {
      lastAnchorMs = o.anchorMs;
      lastIsPlaying = o.isPlaying;
      broadcastObj({ position: o.positionMs, isPlaying: o.isPlaying, timestamp: o.anchorMs });
    }
  }
}

pruneCache();
startSmtcProducer();

process.on("SIGINT", () => {
  console.log("\n[bridge] shutting down");
  wss.close(() => process.exit(0));
});

process.on("unhandledRejection", (e) => {
  console.error("[bridge] unhandledRejection:", (e && e.stack) || e);
});
process.on("uncaughtException", (e) => {
  console.error("[bridge] uncaughtException:", (e && e.stack) || e);
});
