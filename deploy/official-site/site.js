/* Official site interactions: particle network, reveal, terminal typing, live status, card glow. */
(function () {
  'use strict';

  /* ---------- particle network ---------- */
  var canvas = document.getElementById('net');
  if (canvas && canvas.getContext) {
    var ctx = canvas.getContext('2d');
    var W = 0, H = 0, DPR = Math.min(window.devicePixelRatio || 1, 2);
    var parts = [];
    var mouse = { x: -9999, y: -9999 };

    function resize() {
      W = window.innerWidth; H = window.innerHeight;
      canvas.width = W * DPR; canvas.height = H * DPR;
      ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    }
    function seed() {
      var n = Math.max(28, Math.min(80, Math.floor(W * H / 26000)));
      parts = [];
      for (var i = 0; i < n; i++) {
        parts.push({
          x: Math.random() * W, y: Math.random() * H,
          vx: (Math.random() - 0.5) * 0.35, vy: (Math.random() - 0.5) * 0.35,
          r: Math.random() * 1.4 + 0.6
        });
      }
    }
    function tick() {
      ctx.clearRect(0, 0, W, H);
      for (var i = 0; i < parts.length; i++) {
        var p = parts[i];
        p.x += p.vx; p.y += p.vy;
        if (p.x < -20) p.x = W + 20; if (p.x > W + 20) p.x = -20;
        if (p.y < -20) p.y = H + 20; if (p.y > H + 20) p.y = -20;
        // gentle mouse repulsion
        var dxm = p.x - mouse.x, dym = p.y - mouse.y;
        var dm2 = dxm * dxm + dym * dym;
        if (dm2 < 16000) { var f = 0.02; p.x += dxm * f; p.y += dym * f; }
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.r, 0, 6.2832);
        ctx.fillStyle = 'rgba(120,130,255,0.55)';
        ctx.fill();
      }
      for (var a = 0; a < parts.length; a++) {
        for (var b = a + 1; b < parts.length; b++) {
          var pa = parts[a], pb = parts[b];
          var dx = pa.x - pb.x, dy = pa.y - pb.y;
          var d2 = dx * dx + dy * dy;
          if (d2 < 13000) {
            var alpha = 0.14 * (1 - d2 / 13000);
            ctx.beginPath();
            ctx.moveTo(pa.x, pa.y); ctx.lineTo(pb.x, pb.y);
            ctx.strokeStyle = 'rgba(99,102,241,' + alpha.toFixed(3) + ')';
            ctx.lineWidth = 1;
            ctx.stroke();
          }
        }
      }
      requestAnimationFrame(tick);
    }
    resize(); seed(); tick();
    window.addEventListener('resize', function () { resize(); seed(); });
    window.addEventListener('mousemove', function (e) { mouse.x = e.clientX; mouse.y = e.clientY; }, { passive: true });
  }

  /* ---------- scroll reveal ---------- */
  var io = ('IntersectionObserver' in window)
    ? new IntersectionObserver(function (es) {
        es.forEach(function (en) { if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); } });
      }, { threshold: 0.12 })
    : null;
  document.querySelectorAll('.reveal').forEach(function (el) {
    if (io) io.observe(el); else el.classList.add('in');
  });

  /* ---------- card mouse-tracked glow ---------- */
  document.querySelectorAll('.card').forEach(function (card) {
    card.addEventListener('mousemove', function (e) {
      var r = card.getBoundingClientRect();
      card.style.setProperty('--mx', (e.clientX - r.left) + 'px');
      card.style.setProperty('--my', (e.clientY - r.top) + 'px');
    }, { passive: true });
  });

  /* ---------- terminal typing (security section) ---------- */
  var LINES = [
    ['k', '$ lmh security audit'],
    ['cm', '  key exchange ......... ECDH P-256 + AES-256-GCM key wrap'],
    ['cm', '  message cipher ....... AES-256-GCM, per-message nonce'],
    ['cm', '  server knowledge ..... ciphertext only, keys stay on device'],
    ['s', '> 服务器拿到的:'],
    ['s', '  {"iv":"gX4_…","cipher":"9f2a…","seq":42,"ts":1789…}'],
    ['ok', '✓ E2EE verified — even the admin cannot read your messages'],
    ['cm', '', null]
  ];
  var termBody = document.getElementById('termBody');
  if (termBody) {
    var made = false;
    function buildTerm() {
      if (made) return; made = true;
      LINES.forEach(function (ln, i) {
        var span = document.createElement('span');
        span.className = 'ln' + (ln[0] === 'cm' ? ' cm' : '');
        span.innerHTML = ln[1]
          .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
          .replace(/^(\$|\||>|✓)(.*)$/, function (m, pre, rest) {
            if (pre === '✓') return '<span class="ok">✓</span>' + rest;
            if (pre === '>') return '<span class="s">' + pre + '</span>' + rest;
            if (pre === '$') return '<span class="k">$</span>' + rest;
            return m;
          });
        termBody.appendChild(span);
        setTimeout(function () { span.classList.add('show'); }, 150 * (i + 1));
      });
      var cur = document.createElement('span');
      cur.className = 'ln'; cur.innerHTML = '<span class="k">$</span> <span class="cursor"></span>';
      termBody.appendChild(cur);
      setTimeout(function () { cur.classList.add('show'); }, 150 * (LINES.length + 1));
    }
    var tio = ('IntersectionObserver' in window)
      ? new IntersectionObserver(function (es) { es.forEach(function (en) { if (en.isIntersecting) { buildTerm(); tio.disconnect(); } }); }, { threshold: 0.3 })
      : null;
    if (tio) tio.observe(termBody); else buildTerm();
  }

  /* ---------- live status pill: check /api/health on this host ---------- */
  var pill = document.getElementById('statusPill');
  if (pill) {
    fetch('/api/health', { cache: 'no-store' })
      .then(function (r) { if (!r.ok) throw new Error('http ' + r.status); return r.json(); })
      .then(function (d) {
        pill.dataset.state = 'ok';
        var val = pill.querySelector('.val');
        if (val) val.textContent = 'online' + (d && d.ok ? ' · ' + (typeof d.uptime === 'number' ? Math.round(d.uptime / 60) + 'min' : '') : '');
      })
      .catch(function () { pill.dataset.state = 'err'; var v = pill.querySelector('.val'); if (v) v.textContent = 'offline'; });
  }
})();
