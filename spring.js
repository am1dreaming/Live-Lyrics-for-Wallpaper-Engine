// MinenkoY
(function () {
  "use strict";

  class Spring {
    constructor(frequency, dampingRatio, initial) {
      this.frequency = frequency != null ? frequency : 2.5;
      this.dampingRatio = dampingRatio != null ? dampingRatio : 1;
      this.position = initial || 0;
      this.velocity = 0;
      this.goal = initial || 0;
    }

    setGoal(g) { this.goal = g; }

    reset(pos) {
      this.position = pos;
      this.velocity = 0;
      this.goal = pos;
    }

    Step(dt) {
      if (dt <= 0) return this.position;
      if (dt > 0.1) dt = 0.1;

      const w = 2 * Math.PI * this.frequency;
      const z = this.dampingRatio;
      const g = this.goal;
      const x0 = this.position - g;
      const v0 = this.velocity;
      const decay = Math.exp(-z * w * dt);

      let x1, v1;
      if (Math.abs(z - 1) < 1e-4) {
        const B = v0 + w * x0;
        x1 = (x0 + B * dt) * decay;
        v1 = (v0 - w * B * dt) * decay;
      } else if (z < 1) {
        const wd = w * Math.sqrt(1 - z * z);
        const c = Math.cos(wd * dt), s = Math.sin(wd * dt);
        x1 = decay * (x0 * c + ((v0 + z * w * x0) / wd) * s);
        v1 = decay * (v0 * c - ((w * w * x0 + z * w * v0) / wd) * s);
      } else {
        const r = w * Math.sqrt(z * z - 1);
        const ch = Math.cosh(r * dt), sh = Math.sinh(r * dt);
        x1 = decay * (x0 * ch + ((v0 + z * w * x0) / r) * sh);
        v1 = decay * (v0 * ch - ((w * w * x0 + z * w * v0) / r) * sh);
      }

      this.position = x1 + g;
      this.velocity = v1;
      if (Math.abs(this.position - g) < 1e-3 && Math.abs(this.velocity) < 1e-3) {
        this.position = g;
        this.velocity = 0;
      }
      return this.position;
    }
  }

  window.Spring = Spring;
})();
