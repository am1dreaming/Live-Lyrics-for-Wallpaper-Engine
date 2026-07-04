// MinenkoY
window.ScrollController = (function () {
  "use strict";

  let viewport = null, content = null, spring = null;
  let anchor = 0;
  let lastEl = null;
  let lastApplied = null;

  const FREQUENCY = 2.5;
  const DAMPING = 1.0;

  function init(viewportEl, contentEl) {
    viewport = viewportEl;
    content = contentEl;
    spring = new Spring(FREQUENCY, DAMPING, 0);
    apply();
  }

  function setActiveLine(el, snap) {
    if (!el || !viewport || !spring) return;
    lastEl = el;
    const vpRect = viewport.getBoundingClientRect();
    const elRect = el.getBoundingClientRect();
    const elCenter = elRect.top - vpRect.top + elRect.height / 2;
    const delta = elCenter - (viewport.clientHeight / 2 + anchor);
    const target = spring.position + delta;
    spring.setGoal(target);
    if (snap) { spring.reset(target); apply(); }
  }

  function setAnchorPercent(pct) {
    if (!viewport) { anchor = 0; return; }
    anchor = viewport.clientHeight * (pct / 100);
    if (lastEl) setActiveLine(lastEl, false);
  }

  function step(dt) {
    if (!spring) return;
    spring.Step(dt);
    apply();
  }

  function apply() {
    if (!content) return;
    const v = (-spring.position).toFixed(2);
    if (v === lastApplied) return;
    lastApplied = v;
    content.style.transform = `translate3d(0, ${v}px, 0)`;
  }

  return { init, setActiveLine, setAnchorPercent, step };
})();
