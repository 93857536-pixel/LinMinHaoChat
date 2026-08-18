// WebCrypto 端交叉验证(与 web/src/crypto/message.ts 相同算法,node 内置 webcrypto)
// 用法: node verify_web.mjs < encrypt.json | node verify_web.mjs '{"mode":"..."}'
import { webcrypto } from 'node:crypto';
const subtle = webcrypto.subtle;

const b64ToBytes = (s) => Uint8Array.from(Buffer.from(s, 'base64'));
const bytesToB64 = (b) => Buffer.from(b).toString('base64');

const TEST_KEY = 'MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY='; // 与 swift harness 相同

async function deriveMessageKey(sessionKey, iv, roomId, seq) {
  const base = await subtle.importKey('raw', sessionKey, 'HKDF', false, ['deriveKey']);
  const info = new TextEncoder().encode(`lmh-msg-v1:${roomId}:${seq}`);
  return subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: iv, info },
    base,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt']
  );
}

async function encrypt(roomId, seq, ts, plain, keyB64) {
  const sessionKey = b64ToBytes(keyB64);
  const iv = webcrypto.getRandomValues(new Uint8Array(12));
  const key = await deriveMessageKey(sessionKey, iv, roomId, seq);
  const aad = new TextEncoder().encode(`${roomId}:${seq}:${ts}`);
  const ct = await subtle.encrypt({ name: 'AES-GCM', iv, additionalData: aad }, key, new TextEncoder().encode(plain));
  return { iv: bytesToB64(iv), ct: bytesToB64(new Uint8Array(ct)) };
}

async function decrypt(roomId, seq, ts, ivB64, ctB64, keyB64) {
  const sessionKey = b64ToBytes(keyB64);
  const iv = b64ToBytes(ivB64);
  const ct = b64ToBytes(ctB64);
  const key = await deriveMessageKey(sessionKey, iv, roomId, seq);
  const aad = new TextEncoder().encode(`${roomId}:${seq}:${ts}`);
  const plain = await subtle.decrypt({ name: 'AES-GCM', iv, additionalData: aad }, key, ct);
  return { plain: new TextDecoder().decode(plain) };
}

async function ecdhWrapTest() {
  // 模拟 web 端:JWK x||y → 64B 公钥(util.jwkPubToB64),raw import,unwrap swift 的 wrapped
  const keyPair = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const jwk = await subtle.exportKey('jwk', keyPair.publicKey);
  const xb = Uint8Array.from(Buffer.from(jwk.x, 'base64url'));
  const yb = Uint8Array.from(Buffer.from(jwk.y, 'base64url'));
  const pub64 = new Uint8Array(64); pub64.set(xb, 0); pub64.set(yb, 32);
  const pub64B64 = bytesToB64(pub64);
  return { pub64B64, unwrap: async (wrappedJson) => {
    const w = JSON.parse(wrappedJson);
    // 先试 web 现状:64B 直接 import(记录是否被拒)
    let note = '';
    let peerPub;
    try {
      peerPub = await subtle.importKey('raw', b64ToBytes(w.pk), { name: 'ECDH', namedCurve: 'P-256' }, true, []);
    } catch (e) {
      note = '64B raw rejected by WebCrypto → 按修正方案补 0x04 前缀导入';
      const pk65 = new Uint8Array(65); pk65[0] = 4; pk65.set(b64ToBytes(w.pk), 1);
      peerPub = await subtle.importKey('raw', pk65, { name: 'ECDH', namedCurve: 'P-256' }, true, []);
    }
    const bits = await subtle.deriveBits({ name: 'ECDH', public: peerPub }, keyPair.privateKey, 256);
    const base = await subtle.importKey('raw', new Uint8Array(bits), 'HKDF', false, ['deriveKey']);
    const wrapKey = await subtle.deriveKey(
      { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: new TextEncoder().encode('lmh-session-wrap-v1') },
      base, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
    const plain = await subtle.decrypt({ name: 'AES-GCM', iv: b64ToBytes(w.iv) }, wrapKey, b64ToBytes(w.ct));
    return { sessionKeyB64: bytesToB64(new Uint8Array(plain)), note };
  }};
}

let input;
if (process.argv[2]) {
  input = JSON.parse(process.argv[2]);
} else {
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

try {
  if (input.mode === 'encrypt') {
    console.log(JSON.stringify(await encrypt(input.roomId, input.seq, input.ts, input.plain, input.key || TEST_KEY)));
  } else if (input.mode === 'decrypt') {
    console.log(JSON.stringify(await decrypt(input.roomId, input.seq, input.ts, input.iv, input.ct, input.key || TEST_KEY)));
  } else if (input.mode === 'ecdh-wait') {
    // swift 生成 wrapped 后调回此模式解包
    const e = await ecdhWrapTest();
    const r = await e.unwrap(input.wrapped);
    console.log(JSON.stringify({ ...r, peerPub64: e.pub64B64 }));
  } else if (input.mode === 'ecdh-shared') {
    // 输出与 peerPub 的 ECDH 共享密钥(base64),用于跨端比对
    const priv = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    const jwk = await subtle.exportKey('jwk', priv.publicKey);
    const xb = Uint8Array.from(Buffer.from(jwk.x, 'base64url'));
    const yb = Uint8Array.from(Buffer.from(jwk.y, 'base64url'));
    const pub64 = new Uint8Array(64); pub64.set(xb, 0); pub64.set(yb, 32);
    const pub64B64 = bytesToB64(pub64);
    let peerPub;
    try {
      peerPub = await subtle.importKey('raw', b64ToBytes(input.peerPub), { name: 'ECDH', namedCurve: 'P-256' }, true, []);
      var accepted = '64B';
    } catch (e) {
      const pk65 = new Uint8Array(65); pk65[0] = 4; pk65.set(b64ToBytes(input.peerPub), 1);
      peerPub = await subtle.importKey('raw', pk65, { name: 'ECDH', namedCurve: 'P-256' }, true, []);
      accepted = '65B-fallback';
    }
    const bits = await subtle.deriveBits({ name: 'ECDH', public: peerPub }, priv.privateKey, 256);
    console.log(JSON.stringify({ pub64B64, accepted, shared: bytesToB64(new Uint8Array(bits)) }));
  } else if (input.mode === 'ecdh-keygen') {
    // 生成可导出的 ECDH 密钥对,存 /tmp/node_ecdh_jwk.json,输出 64B 公钥
    const keyPair = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    const privJwk = await subtle.exportKey('jwk', keyPair.privateKey);
    const pubJwk = await subtle.exportKey('jwk', keyPair.publicKey);
    const fs = await import('node:fs');
    fs.writeFileSync('/tmp/node_ecdh_jwk.json', JSON.stringify({ priv: privJwk, pub: pubJwk }));
    const xb = Uint8Array.from(Buffer.from(pubJwk.x, 'base64url'));
    const yb = Uint8Array.from(Buffer.from(pubJwk.y, 'base64url'));
    const pub64 = new Uint8Array(64); pub64.set(xb, 0); pub64.set(yb, 32);
    console.log(JSON.stringify({ pub64B64: bytesToB64(pub64) }));
  } else if (input.mode === 'ecdh-unwrap') {
    // 读回同一密钥对,解包 swift 的 wrapped(peer 公钥 pk 按 65B 修正导入)
    const fs = await import('node:fs');
    const jwk = JSON.parse(fs.readFileSync('/tmp/node_ecdh_jwk.json', 'utf8'));
    const priv = await subtle.importKey('jwk', jwk.priv, { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']);
    const w = input.wrapped ? JSON.parse(input.wrapped) : input;
    let note = '';
    let peerPub;
    try {
      peerPub = await subtle.importKey('raw', b64ToBytes(w.pk), { name: 'ECDH', namedCurve: 'P-256' }, true, []);
    } catch (e) {
      note = '64B raw rejected by WebCrypto → 按修正方案补 0x04 前缀导入';
      const pk65 = new Uint8Array(65); pk65[0] = 4; pk65.set(b64ToBytes(w.pk), 1);
      peerPub = await subtle.importKey('raw', pk65, { name: 'ECDH', namedCurve: 'P-256' }, true, []);
    }
    const bits = await subtle.deriveBits({ name: 'ECDH', public: peerPub }, priv, 256);
    const base = await subtle.importKey('raw', new Uint8Array(bits), 'HKDF', false, ['deriveKey']);
    const wrapKey = await subtle.deriveKey(
      { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: new TextEncoder().encode('lmh-session-wrap-v1') },
      base, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
    const plain = await subtle.decrypt({ name: 'AES-GCM', iv: b64ToBytes(w.iv) }, wrapKey, b64ToBytes(w.ct));
    console.log(JSON.stringify({ sessionKeyB64: bytesToB64(new Uint8Array(plain)), note }));
  } else if (input.mode === 'ecdh-provide') {
    const e = await ecdhWrapTest();
    console.log(JSON.stringify({ pub64B64: e.pub64B64 }));
  } else {
    throw new Error('unknown mode');
  }
} catch (err) {
  console.error(JSON.stringify({ error: String(err.message || err) }));
  process.exit(1);
}
