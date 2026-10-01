// NetPulse app icon, drawn on a 2D canvas at any size.
// drawNetPulseIcon(ctx, size, variant) paints the full icon canvas
// (Apple's grid: the body fills 824 of every 1024 units, centred).
(function (global) {
  const BLUE = '#0A84FF', ORANGE = '#F0A020';

  function squircle(ctx, x, y, s, n = 5) {
    const r = s / 2, cx = x + r, cy = y + r, steps = 360;
    ctx.beginPath();
    for (let i = 0; i <= steps; i++) {
      const t = (i / steps) * Math.PI * 2, c = Math.cos(t), sn = Math.sin(t);
      const px = cx + r * Math.sign(c) * Math.abs(c) ** (2 / n);
      const py = cy + r * Math.sign(sn) * Math.abs(sn) ** (2 / n);
      i ? ctx.lineTo(px, py) : ctx.moveTo(px, py);
    }
    ctx.closePath();
  }

  // Body: blue gradient plus the Liquid Glass cues (a soft top sheen and a
  // bright rim that fades toward the bottom).
  function body(ctx, u, top, bottom) {
    const x = 100 * u, s = 824 * u;
    ctx.save();
    ctx.shadowColor = 'rgba(0,0,0,0.28)'; ctx.shadowBlur = 28 * u; ctx.shadowOffsetY = 12 * u;
    squircle(ctx, x, x, s);
    const g = ctx.createLinearGradient(0, x, 0, x + s);
    g.addColorStop(0, top); g.addColorStop(1, bottom);
    ctx.fillStyle = g; ctx.fill();
    ctx.restore();
    // Hairline edge so light bodies still separate from a white desktop.
    squircle(ctx, x, x, s);
    ctx.strokeStyle = 'rgba(0,0,0,0.10)'; ctx.lineWidth = 2 * u; ctx.stroke();

    ctx.save();
    squircle(ctx, x, x, s); ctx.clip();
    const sheen = ctx.createRadialGradient(512 * u, 60 * u, 0, 512 * u, 60 * u, 620 * u);
    sheen.addColorStop(0, 'rgba(255,255,255,0.38)');
    sheen.addColorStop(0.55, 'rgba(255,255,255,0.06)');
    sheen.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.fillStyle = sheen; ctx.fillRect(x, x, s, s);
    ctx.restore();

    ctx.save();
    squircle(ctx, x + 3 * u, x + 3 * u, s - 6 * u);
    const rim = ctx.createLinearGradient(0, x, 0, x + s);
    rim.addColorStop(0, 'rgba(255,255,255,0.75)');
    rim.addColorStop(0.45, 'rgba(255,255,255,0.12)');
    rim.addColorStop(1, 'rgba(255,255,255,0.35)');
    ctx.strokeStyle = rim; ctx.lineWidth = 5 * u; ctx.stroke();
    ctx.restore();
  }

  function glyphShadow(ctx, u) {
    ctx.shadowColor = 'rgba(0,25,90,0.35)'; ctx.shadowBlur = 18 * u; ctx.shadowOffsetY = 8 * u;
  }

  function line(ctx, u, pts, w, color) {
    ctx.beginPath();
    pts.forEach(([px, py], i) => i ? ctx.lineTo(px * u, py * u) : ctx.moveTo(px * u, py * u));
    ctx.lineWidth = w * u; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    ctx.strokeStyle = color; ctx.stroke();
  }

  // Colorways for the pulse design: body gradient, trace, dot, and the
  // tint of the glyph's drop shadow.
  const palettes = {
    blue:   { top: '#4FB0FF', bottom: '#0057D9', line: '#FFFFFF', dot: ORANGE, shadow: 'rgba(0,25,90,0.35)' },
    navy:   { top: '#2C3E63', bottom: '#111A30', line: '#F1E4C6', dot: '#D4AF6A', shadow: 'rgba(0,0,0,0.40)' },
    jade:   { top: '#2F6B5E', bottom: '#12332C', line: '#F4EEDF', dot: '#C9A15B', shadow: 'rgba(0,20,15,0.40)' },
    slate:  { top: '#5A6A86', bottom: '#2A3348', line: '#FFFFFF', dot: '#E8A08A', shadow: 'rgba(10,15,35,0.35)' },
    plum:   { top: '#5E4466', bottom: '#2B1D33', line: '#F3E6EC', dot: '#D9B26F', shadow: 'rgba(20,0,25,0.40)' },
    ivory:  { top: '#FBF8F2', bottom: '#E4DDD0', line: '#1F2D4D', dot: '#C0974E', shadow: 'rgba(60,45,20,0.18)' },
  };

  function pulse(ctx, u, p) {
    body(ctx, u, p.top, p.bottom);
    ctx.save();
    ctx.shadowColor = p.shadow; ctx.shadowBlur = 18 * u; ctx.shadowOffsetY = 8 * u;
    line(ctx, u, [[230, 540], [370, 540], [430, 400], [520, 700], [590, 330], [650, 540], [730, 540]], 58, p.line);
    ctx.beginPath(); ctx.arc(790 * u, 540 * u, 44 * u, 0, Math.PI * 2);
    ctx.fillStyle = p.dot; ctx.fill();
    ctx.restore();
  }

  const variants = {
    // One heartbeat-style trace with a live dot at its end.
    pulse(ctx, u) { pulse(ctx, u, palettes.blue); },
    // Download and upload as two rounded arrows.
    arrows(ctx, u) {
      body(ctx, u, '#4FB0FF', '#0057D9');
      ctx.save(); glyphShadow(ctx, u);
      line(ctx, u, [[410, 300], [410, 700]], 78, '#fff');
      line(ctx, u, [[300, 600], [410, 715], [520, 600]], 78, '#fff');
      line(ctx, u, [[614, 724], [614, 324]], 78, ORANGE);
      line(ctx, u, [[504, 424], [614, 309], [724, 424]], 78, ORANGE);
      ctx.restore();
    },
    // A throughput gauge: blue-to-orange arc and a needle.
    gauge(ctx, u) {
      body(ctx, u, '#3C9BFF', '#0046C2');
      const cx = 512 * u, cy = 560 * u, r = 250 * u;
      const a0 = Math.PI * 0.75, a1 = Math.PI * 2.25, av = Math.PI * 1.85;
      ctx.save(); ctx.lineCap = 'round';
      ctx.beginPath(); ctx.arc(cx, cy, r, a0, a1);
      ctx.strokeStyle = 'rgba(255,255,255,0.22)'; ctx.lineWidth = 64 * u; ctx.stroke();
      glyphShadow(ctx, u);
      const g = ctx.createLinearGradient(cx - r, 0, cx + r, 0);
      g.addColorStop(0, '#fff'); g.addColorStop(0.6, '#FFE2A8'); g.addColorStop(1, ORANGE);
      ctx.beginPath(); ctx.arc(cx, cy, r, a0, av);
      ctx.strokeStyle = g; ctx.lineWidth = 64 * u; ctx.stroke();
      const nx = cx + Math.cos(av - 0.02) * (r - 70 * u), ny = cy + Math.sin(av - 0.02) * (r - 70 * u);
      ctx.beginPath(); ctx.moveTo(cx, cy); ctx.lineTo(nx, ny);
      ctx.strokeStyle = '#fff'; ctx.lineWidth = 40 * u; ctx.stroke();
      ctx.beginPath(); ctx.arc(cx, cy, 52 * u, 0, Math.PI * 2); ctx.fillStyle = '#fff'; ctx.fill();
      ctx.restore();
    },
    // Per-app traffic as rising bars, the busiest one in orange.
    bars(ctx, u) {
      body(ctx, u, '#4FB0FF', '#0057D9');
      ctx.save(); glyphShadow(ctx, u);
      const w = 104, gap = 44, base = 730, hs = [190, 300, 250, 420];
      const left = 512 - (hs.length * w + (hs.length - 1) * gap) / 2;
      hs.forEach((h, i) => {
        const x = (left + i * (w + gap)) * u, y = (base - h) * u;
        ctx.beginPath(); ctx.roundRect(x, y, w * u, h * u, (w / 2) * u);
        ctx.fillStyle = i === hs.length - 1 ? ORANGE : '#fff'; ctx.fill();
      });
      ctx.restore();
    },
  };

  function drawNetPulseIcon(ctx, size, variant = 'pulse') {
    const u = size / 1024;
    ctx.clearRect(0, 0, size, size);
    variants[variant](ctx, u);
  }
  for (const k of Object.keys(palettes)) {
    if (k !== 'blue') variants['pulse-' + k] = (ctx, u) => pulse(ctx, u, palettes[k]);
  }
  drawNetPulseIcon.variants = Object.keys(variants);
  global.drawNetPulseIcon = drawNetPulseIcon;
})(typeof window !== 'undefined' ? window : globalThis);
