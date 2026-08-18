// 协议级验证:WS 令牌复用(重连不重复 join)+ 断线轮询补收(E2EE 解密链路)
// 复刻 web/src/crypto/message.ts 的 HKDF+AES-GCM 算法,与浏览器一致
import WebSocket from 'ws';
import crypto from 'node:crypto';

const BASE = process.env.BASE_URL || 'http://127.0.0.1:3100';
const WS_URL = process.env.WS_URL || 'ws://127.0.0.1:3100/ws';

const b64 = (b) => Buffer.from(b).toString('base64');
const ub64 = (s) => new Uint8Array(Buffer.from(s, 'base64'));
const enc = new TextEncoder();

async function deriveKey(sessionKey, iv, roomId, seq) {
  const base = await crypto.subtle.importKey('raw', sessionKey, 'HKDF', false, ['deriveKey']);
  const info = enc.encode(`lmh-msg-v1:${roomId}:${seq}`);
  return crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: iv, info },
    base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}
async function encryptMsg(sessionKey, plain, roomId, seq, ts) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await deriveKey(sessionKey, iv, roomId, seq);
  const aad = enc.encode(`${roomId}:${seq}:${ts}`);
  const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: aad }, key, enc.encode(plain));
  return { iv: b64(iv), ct: b64(new Uint8Array(ct)) };
}
async function decryptMsg(sessionKey, payload, roomId, seq, ts) {
  const iv = ub64(payload.iv);
  const key = await deriveKey(sessionKey, iv, roomId, seq);
  const aad = enc.encode(`${roomId}:${seq}:${ts}`);
  const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv, additionalData: aad }, key, ub64(payload.ct));
  return new TextDecoder().decode(plain);
}

let PASS = 0, FAIL = 0;
const ok = (name) => { PASS++; console.log(`  OK   ${name}`); };
const no = (name, detail) => { FAIL++; console.log(`  FAIL ${name}${detail ? ' — ' + detail : ''}`); };

const post = async (p, body) => {
  const r = await fetch(BASE + p, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  return { status: r.status, data: await r.json().catch(() => ({})) };
};
const get = async (p) => {
  const r = await fetch(BASE + p);
  return { status: r.status, data: await r.json().catch(() => ({})) };
};

function wsConnect(token, timeoutMs = 4000) {
  return new Promise((resolve) => {
    const ws = new WebSocket(`${WS_URL}?wsToken=${encodeURIComponent(token)}`);
    const t = setTimeout(() => { ws.terminate(); resolve({ ok: false, code: -1, reason: 'timeout', ws }); }, timeoutMs);
    ws.on('message', (raw) => {
      const m = JSON.parse(String(raw));
      if (m.type === 'hello') { clearTimeout(t); resolve({ ok: true, code: 1000, reason: '', ws }); }
    });
    ws.on('close', (code, reason) => { clearTimeout(t); resolve({ ok: false, code, reason: String(reason), ws }); });
    ws.on('error', () => { /* close follows */ });
  });
}

const main = async () => {
  // 0. 创建房间
  const room = await post('/api/temp/rooms', {});
  if (room.status !== 200) { console.log('创建房间失败:', room); process.exit(1); }
  const roomId = room.data.roomId;
  ok(`创建临时房间 ${roomId}`);

  // 1. join → 拿令牌 + g1 身份
  const j1 = await post(`/api/temp/rooms/${roomId}/join`, {});
  if (j1.status !== 200 || !j1.data.wsToken) { no('首次 join', JSON.stringify(j1.data)); process.exit(1); }
  const { wsToken, anonId } = j1.data;
  ok(`首次 join → anonId=${anonId}, wsToken 已颁发`);

  // 2. Bug2 核心:同令牌断开→重连(模拟断线风暴),不重新 join
  let joins = 1;
  const c1 = await wsConnect(wsToken);
  if (!c1.ok) { no('首次 WS 连接', `code=${c1.code} ${c1.reason}`); process.exit(1); }
  ok('WS 首次连接成功(hello)');
  c1.ws.close();
  await new Promise((r) => setTimeout(r, 300));

  const c2 = await wsConnect(wsToken);
  if (!c2.ok) { no('断线重连(复用同令牌)', `code=${c2.code} ${c2.reason}`); }
  else ok('断线重连复用同令牌成功(不再消耗 join)');
  c2.ws.close();
  await new Promise((r) => setTimeout(r, 300));

  const c3 = await wsConnect(wsToken);
  const c3b = await wsConnect(wsToken); // 双连接并行
  if (c3.ok && c3b.ok) ok('同令牌并行双连接均成功(令牌复用不互斥)');
  else no('同令牌并行双连接', `c3=${c3.code} c3b=${c3b.code}`);
  c3.ws.close(); c3b.ws.close();
  await new Promise((r) => setTimeout(r, 300));

  const joinAfter = await get(`/api/temp/rooms/${roomId}/join`); // 探测非 GET 路由?不用
  void joinAfter;

  // 3. 错误令牌 → 4001(客户端据此丢弃令牌重新 join)
  const bad = await wsConnect('this-token-does-not-exist');
  if (!bad.ok && bad.code === 4001) ok('错误令牌 → 4001(客户端会丢弃令牌重新 join)');
  else no('错误令牌应 4001', `code=${bad.code} ${bad.reason}`);

  // 4. 发消息(seq=1)+ 断线 + 轮询补收(E2EE 解密断言)
  const sessionKey = crypto.getRandomValues(new Uint8Array(32));
  const ts1 = Date.now();
  const m1 = await encryptMsg(sessionKey, '{"t":"你好,协议修复验证"}', roomId, 1, ts1);
  const s1 = await post(`/api/temp/rooms/${roomId}/messages`, { iv: m1.iv, cipher: m1.ct, anonId, seq: 1, ts: ts1 });
  if (s1.status !== 200 || s1.data.seq !== 1) { no('发送 msg#1', JSON.stringify(s1.data)); process.exit(1); }
  ok('发送 msg#1(seq=1)');

  const ts2 = Date.now();
  const m2 = await encryptMsg(sessionKey, '{"t":"断线期间的轮询补收"}', roomId, 2, ts2);
  const s2 = await post(`/api/temp/rooms/${roomId}/messages`, { iv: m2.iv, cipher: m2.ct, anonId, seq: 2, ts: ts2 });
  if (s2.status !== 200 || s2.data.seq !== 2) { no('发送 msg#2', JSON.stringify(s2.data)); process.exit(1); }
  ok('发送 msg#2(seq=2)');

  // 模拟:WS 全断,客户端轮询 GET history(即 pullNew 的数据路径)
  const h = await get(`/api/temp/rooms/${roomId}/messages?afterSeq=0&limit=50`);
  if (h.status !== 200 || !Array.isArray(h.data.messages)) { no('GET history', JSON.stringify(h.data)); process.exit(1); }
  let decOk = 0;
  for (const m of h.data.messages) {
    try {
      const text = await decryptMsg(sessionKey, { iv: m.iv, ct: m.cipher }, roomId, m.seq, m.ts);
      if (text.includes('协议修复验证') || text.includes('轮询补收')) decOk++;
    } catch { /* fail */ }
  }
  if (decOk === 2) ok('轮询补收:E2EE 密文全部解密成功(明文一致)');
  else no('轮询补收解密', `成功 ${decOk}/2`);

  // 5. 身份复用:再次 join 携带 claimed=g1 → 仍返回 g1(不影响编号)
  const j2 = await post(`/api/temp/rooms/${roomId}/join`, { anonId: 'g1' });
  if (j2.status === 200 && j2.data.anonId === 'g1') ok('身份复用:claimed g1 → 返回 g1');
  else no('身份复用', JSON.stringify(j2.data));

  // 6. seq 冲突保护仍在(409 + expectedSeq)
  const ts3 = Date.now();
  const m3 = await encryptMsg(sessionKey, '{"t":"错误seq"}', roomId, 99, ts3);
  const s3 = await post(`/api/temp/rooms/${roomId}/messages`, { iv: m3.iv, cipher: m3.ct, anonId, seq: 99, ts: ts3 });
  if (s3.status === 409 && s3.data.seq === 3) ok('seq 冲突 → 409 expectedSeq=3(保护未破坏)');
  else no('409 seq 保护', `status=${s3.status} ${JSON.stringify(s3.data)}`);

  console.log(`\n===== PROTOCOL VERIFY: ${PASS} passed / ${FAIL} failed =====`);
  process.exit(FAIL === 0 ? 0 : 1);
};

main().catch((e) => { console.error('脚本异常:', e); process.exit(1); });
