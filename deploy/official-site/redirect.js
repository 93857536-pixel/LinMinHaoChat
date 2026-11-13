/* Root-domain redirect: legacy chat deep-links (linminhao.top/t/<id>#k=... , /i/<id>)
   must keep working after the official site takes over the root domain.
   They forward to the chat subdomain, preserving query + fragment. */
(function () {
  var p = location.pathname;
  var m = p.match(/^\/([ti])\/([A-Za-z0-9]+)(\/.*)?$/);
  if (m && location.hostname !== 'chat.linminhao.top') {
    var to = 'https://chat.linminhao.top/' + m[1] + '/' + m[2] + (m[3] || '') + location.search + location.hash;
    window.location.replace(to);
    document.documentElement.innerHTML = '<p style="font-family:monospace;padding:40px;color:#888">正在跳转到 chat.linminhao.top …</p>';
  }
})();
