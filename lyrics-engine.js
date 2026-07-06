// MinenkoY
window.LyricsEngine = (function () {
  "use strict";

  const contentEl = () => document.getElementById("lyrics-content");

  let lines = [];
  let type = "none";
  let activeIndex = -1;
  let snapNext = false;
  let emphasisMode = "spicy";
  let emphStrength = 1;
  let glowStrength = 1;
  let interludesOn = true;
  const INTERLUDE_MIN_GAP = 2500;

  const SCALE_LONG = [[0, 0.95], [0.7, 1.175], [1, 1]];
  const SCALE_SHORT = [[0, 0.95], [0.7, 1.07],  [1, 1]];
  const YOFF_LONG = [[0, 0.01786], [0.9, -0.01786], [1, 0]];
  const YOFF_SHORT = [[0, 0.01],    [0.9, -0.01613], [1, 0]];
  const GLOW = [[0, 0], [0.15, 1], [0.6, 1], [1, 0]];
  const LONGER_THAN_MS = 1000;
  const GLOW_OPACITY_MULT = 1.85;
  const DIST_SCALE_EXP = 2.8;
  const DIST_GLOW_K = 0.9;

  const SP_SCALE = [2.3, 0.70];
  const SP_YOFF = [2.6, 0.55];
  const SP_GLOW = [1.6, 0.56];

  function sampleSpline(pts, t) {
    if (t <= pts[0][0]) return pts[0][1];
    const last = pts[pts.length - 1];
    if (t >= last[0]) return last[1];
    for (let i = 0; i < pts.length - 1; i++) {
      const a = pts[i], b = pts[i + 1];
      if (t >= a[0] && t <= b[0]) {
        let u = (t - a[0]) / (b[0] - a[0]);
        u = u * u * (3 - 2 * u);
        return a[1] + (b[1] - a[1]) * u;
      }
    }
    return last[1];
  }

  function getElementState(currentTime, startTime, endTime) {
    if (currentTime < startTime) return "NotSung";
    if (currentTime >= endTime) return "Sung";
    return "Active";
  }

  function gradPos(currentTime, startTime, endTime) {
    let p = (currentTime - startTime) / (endTime - startTime);
    if (!isFinite(p) || p < 0) p = 0; else if (p > 1) p = 1;
    return -20 + p * 120;
  }

  function setPos(el, percent) {
    const v = percent.toFixed(1) + "%";
    if (el.__gp === v) return;
    el.__gp = v;
    el.style.setProperty("--gradient-position", v);
  }

  function blurForDistance(d) {
    if (d <= 0) return 0;
    if (d === 1) return 2;
    if (d === 2) return 4;
    return 6;
  }

  function clear() {
    contentEl().innerHTML = "";
    lines = [];
    activeIndex = -1;
    type = "none";
  }

  function buildWord(text, startMs, endMs) {
    const wg = document.createElement("span");
    wg.className = "wg";
    const letters = [];
    Array.from(text).forEach((ch) => {
      const lt = document.createElement("span");
      lt.className = "fill ltr";
      lt.textContent = ch;
      letters.push({
        el: lt,
        scaleSpring: new Spring(SP_SCALE[0], SP_SCALE[1], 1),
        ySpring: new Spring(SP_YOFF[0], SP_YOFF[1], 0),
        glowSpring: new Spring(SP_GLOW[0], SP_GLOW[1], 0),
        last: null,
      });
      wg.appendChild(lt);
    });
    return { wg, startMs, endMs, state: null, letters };
  }

  function spaceEl() {
    const s = document.createElement("span");
    s.className = "fill sp";
    s.textContent = " ";
    return s;
  }

  function pushInterlude(startMs, endMs, frag) {
    const el = document.createElement("div");
    el.className = "interlude";
    el.style.setProperty("--BlurAmount", "0px");
    const dots = [];
    for (let i = 0; i < 3; i++) {
      const d = document.createElement("span");
      d.className = "dot";
      el.appendChild(d);
      dots.push(d);
    }
    frag.appendChild(el);
    lines.push({
      el, startMs, endMs, isInterlude: true, isBackground: false,
      state: null, lineMode: false, words: [], allLetters: [], dots,
    });
  }

  function setLyrics(data) {
    clear();
    if (!data || !data.lines || !data.lines.length) { type = "none"; return; }
    type = data.type || "line";
    const frag = document.createDocumentFragment();
    let prevEnd = null;

    data.lines.forEach((l) => {
      const gapStart = prevEnd == null ? 0 : prevEnd;
      if (l.startMs - gapStart >= INTERLUDE_MIN_GAP) pushInterlude(gapStart, l.startMs, frag);
      prevEnd = l.endMs;

      const el = document.createElement("div");
      el.className = "line NotSung" + (l.isBackground ? " bg-line" : "");
      el.style.setProperty("--BlurAmount", "0px");

      const rec = {
        el, startMs: l.startMs, endMs: l.endMs,
        isBackground: !!l.isBackground, state: null,
        lineMode: true, words: [], allLetters: [],
      };

      let wordDefs;
      if (type === "syllable" && Array.isArray(l.words) && l.words.length) {
        rec.lineMode = false;
        wordDefs = l.words.map((w) => ({ text: String(w.text).trim(), startMs: w.startMs, endMs: w.endMs }));
      } else {

        const tokens = (l.text || " ").split(" ").filter((t) => t.length);
        const total = tokens.reduce((a, t) => a + t.length, 0) || 1;
        const dur = l.endMs - l.startMs;
        let cum = 0;
        wordDefs = tokens.map((t) => {
          const s = l.startMs + (cum / total) * dur;
          cum += t.length;
            return {
                text: t, startMs: s, endMs: l.startMs + (cum / total) * dur
            };
        });
      }

      wordDefs.forEach((w, i) => {
        const word = buildWord(w.text, w.startMs, w.endMs);
        rec.words.push(word);
        rec.allLetters.push(...word.letters);
        el.appendChild(word.wg);
        if (i < wordDefs.length - 1) el.appendChild(spaceEl());
      });

      frag.appendChild(el);
      lines.push(rec);
    });

    contentEl().appendChild(frag);
    contentEl().classList.toggle("no-interludes", !interludesOn);

    if (type === "static") {
      lines.forEach((r) => {
        r.el.classList.remove("NotSung");
        r.el.classList.add("Active");
        setPos(r.el, 100);
      });
      return;
    }
    snapNext = true;
  }

  function setLineState(rec, state) {
    if (rec.state === state) return false;
    rec.state = state;
    rec.el.classList.remove("Active", "Sung", "NotSung");
    rec.el.classList.add(state);
    return true;
  }

  function applyDepth(active) {
    for (let i = 0; i < lines.length; i++) {
      const d = active < 0 ? 99 : Math.abs(i - active);
      lines[i].el.style.setProperty("--BlurAmount", blurForDistance(d) + "px");
    }
  }

  function clearLetter(lt) {
    lt.scaleSpring.reset(1);
    lt.ySpring.reset(0);
    lt.glowSpring.reset(0);
    lt.el.style.transform = "";
    lt.el.style.removeProperty("--ts-blur");
    lt.el.style.removeProperty("--ts-op");
    lt.last = null;
  }

  function resetLetters(rec) {
    if (!rec) return;
    for (const lt of rec.allLetters) clearLetter(lt);
  }

  function emphasizeSegment(letters, start, end, currentTime, dt, long) {
    const dur = end - start || 1;
    let p = (currentTime - start) / dur;
    if (p < 0) p = 0; else if (p > 1) p = 1;

    const active = currentTime >= start && currentTime < end;
    const baseScale = active ? sampleSpline(long ? SCALE_LONG : SCALE_SHORT, p) : 1;
    const baseY = active ? sampleSpline(long ? YOFF_LONG : YOFF_SHORT, p) : 0;
    const baseGlow = active ? sampleSpline(GLOW, p) : 0;
    const activePos = p * letters.length;

    for (let i = 0; i < letters.length; i++) {
      const lt = letters[i];
      const dist = Math.abs(i - activePos);
      const fScale = Math.max(0, 1 / (1 + Math.pow(dist, DIST_SCALE_EXP)));
      const fGlow = Math.max(0, 1 / (1 + dist * DIST_GLOW_K));

      lt.scaleSpring.setGoal(1 + (baseScale - 1) * fScale * emphStrength);
      lt.ySpring.setGoal(baseY * fScale * emphStrength);
      lt.glowSpring.setGoal(Math.min(1.4, baseGlow * fGlow * glowStrength));
      const s = lt.scaleSpring.Step(dt);
      const y = lt.ySpring.Step(dt);
      const g = lt.glowSpring.Step(dt);

      const key = (s * 1000 | 0) + ":" + (y * 10000 | 0) + ":" + (g * 1000 | 0);
      if (lt.last === key) continue;
      lt.last = key;

      lt.el.style.transform =
        `translate3d(0, calc(var(--DefaultLyricsSize) * ${(y * 2).toFixed(4)}), 0) scale(${s.toFixed(4)})`;
      lt.el.style.setProperty("--ts-blur", (4 + 12 * g).toFixed(2) + "px");
      lt.el.style.setProperty("--ts-op", Math.min(1, g * GLOW_OPACITY_MULT).toFixed(3));
    }
  }

  function emphasizeLine(rec, currentTime, dt) {
    for (const w of rec.words) {
      const long = rec.lineMode || (w.endMs - w.startMs) >= LONGER_THAN_MS;
      emphasizeSegment(w.letters, w.startMs, w.endMs, currentTime, dt, long);
    }
  }

  function updateInterlude(rec, currentTime) {
    let p = (currentTime - rec.startMs) / (rec.endMs - rec.startMs);
    if (p < 0) p = 0; else if (p > 1) p = 1;
    for (let i = 0; i < 3; i++) {
      let local = p * 3 - i;
      if (local < 0) local = 0; else if (local > 1) local = 1;
      const breathe = 0.06 * Math.sin(currentTime / 280 + i * 1.1);
      rec.dots[i].style.opacity = (0.28 + 0.72 * local).toFixed(3);
      rec.dots[i].style.transform = `scale(${(0.72 + 0.42 * local + breathe).toFixed(3)})`;
    }
  }

  function update(currentTime, dt) {
    if (type === "none" || type === "static" || !lines.length) return;
    if (dt == null || !isFinite(dt) || dt <= 0) dt = 1 / 60;

    let ai = -1, aiPrimary = -1;
    for (let i = 0; i < lines.length; i++) {
      const r = lines[i];
      if (r.isInterlude && !interludesOn) continue;
      if (r.startMs <= currentTime) {
        ai = i;
        if (!r.isBackground && currentTime < r.endMs) aiPrimary = i;
      } else break;
    }

    let scrollTarget = ai;
    if (ai >= 0 && lines[ai].isBackground && aiPrimary >= 0 && aiPrimary !== ai) {
      scrollTarget = aiPrimary;
    }

    for (let i = 0; i < lines.length; i++) {
      const rec = lines[i];
      if (rec.isInterlude) continue;
      const st = getElementState(currentTime, rec.startMs, rec.endMs);
      const changed = setLineState(rec, st);

      if (rec.lineMode) {
        if (st === "Active") setPos(rec.el, gradPos(currentTime, rec.startMs, rec.endMs));
        else if (changed) setPos(rec.el, st === "Sung" ? 100 : -20);
      } else {
        for (const w of rec.words) {
          const ws = getElementState(currentTime, w.startMs, w.endMs);
          if (ws === "Active") { setPos(w.wg, gradPos(currentTime, w.startMs, w.endMs)); w.state = "Active"; }
          else if (w.state !== ws) { setPos(w.wg, ws === "Sung" ? 100 : -20); w.state = ws; }
        }
      }
    }

    if (scrollTarget !== activeIndex) {
      const prev = lines[activeIndex];
      if (prev) { if (prev.isInterlude) prev.el.classList.remove("active"); else resetLetters(prev); }
      activeIndex = scrollTarget;
      applyDepth(scrollTarget);
      if (scrollTarget >= 0) {
        const cur = lines[scrollTarget];
        if (cur.isInterlude) cur.el.classList.add("active");
        ScrollController.setActiveLine(cur.el, snapNext);
        snapNext = false;
      }
    }

    if (scrollTarget >= 0) {
      const cur = lines[scrollTarget];
      if (cur.isInterlude) updateInterlude(cur, currentTime);
      else if (emphasisMode === "spicy") emphasizeLine(cur, currentTime, dt);
    }
  }

  function forceSnap() { snapNext = true; }

  function setEmphasis(mode) {
    emphasisMode = (mode === false || mode === "simple") ? "simple" : "spicy";
    if (emphasisMode === "simple" && activeIndex >= 0) resetLetters(lines[activeIndex]);
  }

  function setEmphasisStrength(f) { emphStrength = isFinite(f) ? f : 1; }
  function setGlowStrength(f) { glowStrength = isFinite(f) ? f : 1; }
  function setInterludes(on) {
    interludesOn = !!on;
    contentEl().classList.toggle("no-interludes", !interludesOn);
  }

  return {
    setLyrics, update, forceSnap, setEmphasis,
    setEmphasisStrength, setGlowStrength, setInterludes,
  };
})();
