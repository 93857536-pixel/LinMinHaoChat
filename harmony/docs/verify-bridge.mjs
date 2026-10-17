// verify-bridge.mjs — 离线对拍: JS 侧 b64encode ↔ ArkTS 侧 b64Json 的 base64 契约是否对称。
// Node 的 Buffer 对应 ArkTS @kit.ArkBuffer; btoa/atob 与 Chromium V8 一致(均为标准 base64)。
// 两端「JSON → 其 UTF-8 字节的 base64」, 只要字节一致即对称; 中文/emoji 必须不破坏。

// ---------- JS 侧(与 lmh-bridge.js 逐字一致) ----------
function jsB64encode(jsonStr) {
  // 浏览器全局 btoa; Node 16+ 也有 globalThis.btoa
  return btoa(unescape(encodeURIComponent(jsonStr)));
}
function jsB64decode(b64) {
  if (!b64) return {};
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  const text = new TextDecoder('utf-8').decode(bytes);
  try { return JSON.parse(text); } catch { return {}; }
}

// ---------- ArkTS 侧(与 BridgeDispatcher.ets 逐字一致) ----------
function arkTsB64Json(obj) {
  const json = JSON.stringify(obj);
  return Buffer.from(json, 'utf-8').toString('base64'); // buffer.from(json,'utf-8').toString('base64')
}
function arkTsOnJsPost(b64) {
  return JSON.parse(Buffer.from(b64, 'base64').toString('utf-8')); // buffer.from(b64,'base64').toString('utf-8') → JSON.parse
}

// ---------- 用例(覆盖 前端真实调用面 + 中文错误信息 + emoji) ----------
const cases = [
  // 前端 registerPlugin 实际会发的: VoiceRecorder/PnsAuth/App
  { kind: 'call', plugin: 'VoiceRecorder', method: 'stop', options: {}, id: '3' },
  { kind: 'call', plugin: 'PnsAuth', method: 'isAvailable', options: {}, id: '4' },
  { kind: 'call', plugin: 'App', method: 'getLaunchUrl', options: {}, id: '5' },
  { kind: 'listen', plugin: 'App', event: 'appUrlOpen', key: '6' },
  { kind: 'unlisten', plugin: 'App', event: 'appUrlOpen', key: '6' },
  // 原生回投 payload(含中文错误信息 + base64 音频占位)
  { base64: 'QUJD', mime: 'audio/mp4', durationMs: 5000 },
  { error: '当前系统暂不支持一键登录，请使用下方验证码登录', code: 'UNAVAILABLE' },
  { url: 'https://chat.linminhao.top/i/abc#k=Zm9v', type: 'appUrlOpen', plugin: 'App' },
  { emoji: '🚀端到端加密聊天✅', mix: 123 },
];

let fail = 0, pass = 0;
for (const c of cases) {
  // 正向: JS 编码 → ArkTS 解码
  const b64js = jsB64encode(JSON.stringify(c));
  const backFromArk = arkTsOnJsPost(b64js);
  const sameF = JSON.stringify(backFromArk) === JSON.stringify(c);

  // 反向: ArkTS 编码 → JS 解码
  const b64ark = arkTsB64Json(c);
  const backFromJs = jsB64decode(b64ark);
  const sameR = JSON.stringify(backFromJs) === JSON.stringify(c);

  // 对称: 两端 base64 是否字字相同(最严格)
  const b64Match = b64js === b64ark;

  const ok = sameF && sameR && b64Match;
  if (!ok) fail++; else pass++;
  console.log((ok ? 'PASS' : 'FAIL') + (b64Match ? '' : ' [b64 不一致!]') + (sameF ? '' : ' [正反向失败]') +
    '  ' + JSON.stringify(c).slice(0, 60));
  if (!b64Match) {
    console.log('   js :', b64js.slice(0, 40));
    console.log('   ark:', b64ark.slice(0, 40));
  }
}
console.log(`\n=== 桥 base64 契约对拍: ${pass} PASS / ${fail} FAIL (共 ${cases.length}) ===`);
process.exit(fail ? 1 : 0);
