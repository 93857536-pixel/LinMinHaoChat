// 验证两个 web 端协议 bug 的修复:
//  Bug A: P-256 公钥 64B(x||y) 直接 importKey('raw') 必失败 → 需补 0x04(65B)
//  Bug B: 附件 encryptAttachment 返回裸 ct||tag(iv 丢失),decrypt 按 iv(12)||body 切 → 必失败
//         → 修复后 encrypt 返回 iv||ct||tag 自描述格式
// 复刻修复后的 web/src/crypto/keys.ts 与 message.ts 算法(WebCrypto,与浏览器一致)
import crypto from 'node:crypto';

let PASS = 0, FAIL = 0;
const ok = (n) => { PASS++; console.log(`  OK   ${n}`); };
const no = (n, d) => { FAIL++; console.log(`  FAIL ${n} — ${d}`); };

const subtle = crypto.subtle;
const enc = new TextEncoder();
const b64u = (buf) => Buffer.from(buf).toString('base64url');
const ub64 = (s) => new Uint8Array(Buffer.from(s, 'base64'));

// ---- 修复后的 importPeerEcdhPub ----
async function importPeerEcdhPub(b64) {
  const raw = ub64(b64);
  const point = raw.length === 64 ? new Uint8Array([0x04, ...raw]) : raw;
  return subtle.importKey('raw', point, { name: 'ECDH', namedCurve: 'P-256' }, true, []);
}
// 导出为 64B 线格式(JWK x||y 拼接,同 keys.ts jwkPubToB64)
async function exportEcdhPub64(pubKey) {
  const jwk = await subtle.exportKey('jwk', pubKey);
  const x = Buffer.from(jwk.x, 'base64url');
  const y = Buffer.from(jwk.y, 'base64url');
  return b64u(Buffer.concat([x, y]));
}
// wrap/unwrap(复刻 session.ts deriveWrapKey)
const HKDF_INFO = 'lmh-session-wrap-v1';
async function deriveWrapKey(myPriv, peerPub) {
  const bits = await subtle.deriveBits({ name: 'ECDH', public: peerPub }, myPriv, 256);
  const base = await subtle.importKey('raw', new Uint8Array(bits), 'HKDF', false, ['deriveKey']);
  return subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: enc.encode(HKDF_INFO) },
    base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}
// ---- 修复后的 encryptAttachment(iv||ct||tag) ----
async function encryptAttachment(sessionKey, data, roomId, ts) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const base = await subtle.importKey('raw', sessionKey, 'HKDF', false, ['deriveKey']);
  const key = await subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: iv, info: enc.encode(`lmh-att-v1:${roomId}:${ts}`) },
    base, { name: 'AES-GCM', length: 256 }, false, ['encrypt']);
  const ct = await subtle.encrypt({ name: 'AES-GCM', iv, additionalData: enc.encode(`${roomId}:${ts}`) }, key, data);
  const out = new Uint8Array(12 + ct.byteLength);
  out.set(iv, 0);
  out.set(new Uint8Array(ct), 12);
  return out.buffer;
}
// 现有 decryptAttachment(不变)
async function decryptAttachment(sessionKey, data, roomId, ts) {
  const ct = new Uint8Array(data);
  const iv = ct.slice(0, 12);
  const body = ct.slice(12);
  const base = await subtle.importKey('raw', sessionKey, 'HKDF', false, ['deriveKey']);
  const key = await subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: iv, info: enc.encode(`lmh-att-v1:${roomId}:${ts}`) },
    base, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
  return subtle.decrypt({ name: 'AES-GCM', iv, additionalData: enc.encode(`${roomId}:${ts}`) }, key, body);
}

const main = async () => {
  console.log('=== Bug A: P-256 公钥 64B vs 65B ===');
  const alice = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const bob = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const alicePub64 = await exportEcdhPub64(alice.publicKey); // 64B 线格式
  const raw64 = ub64(alicePub64);
  if (raw64.length !== 64) no('线格式长度', `期望 64,实得 ${raw64.length}`);
  else ok(`导出线格式为 64B(x||y),长度=64`);

  let legacyFailed = false;
  try {
    await subtle.importKey('raw', raw64, { name: 'ECDH', namedCurve: 'P-256' }, true, []);
  } catch { legacyFailed = true; }
  if (legacyFailed) ok('旧代码路径:64B 直接 importKey → 抛错(证明原 bug 存在)');
  else no('旧代码路径 64B importKey', '竟然成功了(浏览器可能不同,Node 证实会失败)');

  // 修复后:B 导入 A 的 64B 公钥(自动补 0x04)
  const alicePubKey = await importPeerEcdhPub(alicePub64);
  ok('修复后:importPeerEcdhPub(64B) → 自动补 0x04 → 导入成功');

  // ECDH 双向一致:双方用对方公钥 deriveBits 相等
  const bobPub64 = await exportEcdhPub64(bob.publicKey);
  const bobImported = await importPeerEcdhPub(bobPub64);
  const s1 = new Uint8Array(await subtle.deriveBits({ name: 'ECDH', public: bobImported }, alice.privateKey, 256));
  const s2 = new Uint8Array(await subtle.deriveBits({ name: 'ECDH', public: alicePubKey }, bob.privateKey, 256));
  if (Buffer.from(s1).equals(Buffer.from(s2))) ok('ECDH 双向 deriveBits 一致(双方用同一 64B 格式互通)');
  else no('ECDH 双向一致', '共享秘密不同');

  // 完整 wrap/unwrap 链路(A wrap 会话密钥 → B 解包;格式同 session.ts:v1 JSON,iv/ct/pk 独立字段)
  const sessionKey = crypto.getRandomValues(new Uint8Array(32));
  const wrapIv = crypto.getRandomValues(new Uint8Array(12));
  const wrapKey = await deriveWrapKey(alice.privateKey, bobImported);
  const wrapCt = new Uint8Array(await subtle.encrypt({ name: 'AES-GCM', iv: wrapIv }, wrapKey, sessionKey));
  const wrapped = JSON.stringify({ v: 1, iv: Buffer.from(wrapIv).toString('base64'), ct: Buffer.from(wrapCt).toString('base64'), pk: alicePub64 });
  // B 解包(与 unwrapSessionKey 一致:pk 是 64B → 走 importPeerEcdhPub 补 0x04)
  const parsed = JSON.parse(wrapped);
  const pkImported = await importPeerEcdhPub(parsed.pk);
  const unwrapKey = await deriveWrapKey(bob.privateKey, pkImported);
  const unwrapped = new Uint8Array(await subtle.decrypt(
    { name: 'AES-GCM', iv: ub64(parsed.iv) }, unwrapKey, ub64(parsed.ct)));
  if (Buffer.from(sessionKey).equals(Buffer.from(unwrapped))) ok('wrap/unwrap 闭环:sessionKey 还原一致(账号聊天密钥包装可用)');
  else no('wrap/unwrap 闭环', '还原不一致');

  console.log('\n=== Bug B: 附件密文格式 iv||ct||tag ===');
  const roomId = 't_verify_att';
  const ts = Date.now();
  const fileBytes = crypto.randomBytes(1024);
  const encBuf = await encryptAttachment(sessionKey, fileBytes.buffer, roomId, ts);
  if (encBuf.byteLength === 12 + 1024 + 16) ok(`encryptAttachment 输出 iv(12)||ct||tag,长度=${encBuf.byteLength}(=12+1024+16)`);
  else no('encryptAttachment 输出长度', `=${encBuf.byteLength}`);
  const dec = await decryptAttachment(sessionKey, encBuf, roomId, ts);
  if (Buffer.from(new Uint8Array(dec)).equals(fileBytes)) ok('decryptAttachment(iv||body 切片)解密成功,字节完全一致');
  else no('附件解密', '字节不一致');

  // 证明旧格式(裸 ct||tag)按新 decrypt 必失败 → 原 bug 致命
  const oldEnc = await (async () => {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const base = await subtle.importKey('raw', sessionKey, 'HKDF', false, ['deriveKey']);
    const key = await subtle.deriveKey(
      { name: 'HKDF', hash: 'SHA-256', salt: iv, info: enc.encode(`lmh-att-v1:${roomId}:${ts}`) },
      base, { name: 'AES-GCM', length: 256 }, false, ['encrypt']);
    return subtle.encrypt({ name: 'AES-GCM', iv, additionalData: enc.encode(`${roomId}:${ts}`) }, key, fileBytes);
  })();
  let oldFailed = false;
  try { await decryptAttachment(sessionKey, oldEnc, roomId, ts); } catch { oldFailed = true; }
  if (oldFailed) ok('旧格式(裸 ct||tag)按 iv||body 切 → 解密抛错(证明原 bug 必现)');
  else no('旧格式解密', '竟然成功');

  console.log(`\n===== PROTOCOL BUGS VERIFY: ${PASS} passed / ${FAIL} failed =====`);
  process.exit(FAIL === 0 ? 0 : 1);
};
main().catch((e) => { console.error('脚本异常:', e); process.exit(1); });
