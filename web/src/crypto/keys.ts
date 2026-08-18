/**
 * 客户端密钥管理(Web Crypto / IndexedDB)。
 *
 * 身份密钥(每设备一对):
 *  - Ed25519: 签名身份(用户身份证明;当前用于设备标识,预留消息签名)
 *  - ECDH P-256: 密钥交换(用于包装/解包会话密钥)
 *
 * 私钥只存在本设备 IndexedDB(lmh-keys),绝不上传服务器。
 * 服务器只收到 base64 编码的公钥(spki/raw)。
 *
 * 多设备:通过「口令加密导出包」迁移 — 私钥 JWK 用 PBKDF2+AES-GCM
 * 加密后导出,新设备输入同一口令导入。服务器仅中转密文包,不可解。
 */
import { subtle, randomBytes, bytesToBase64, base64ToBytes, jwkPubToB64, b64UrlRandom } from './util';

const DB_NAME = 'lmh-keys';
const DB_VERSION = 1;
const STORE = 'keys';

export interface IdentityKeys {
  deviceId: string;
  ed25519Pub: string; // base64 (raw)
  ecdhPub: string;    // base64 (raw)
}

export type { Bytes } from './util';

interface Stored {
  deviceId: string;
  ed25519: JsonWebKey;
  ecdh: JsonWebKey;
}

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function idbGet<T>(key: string): Promise<T | undefined> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readonly');
    const req = tx.objectStore(STORE).get(key);
    req.onsuccess = () => resolve(req.result as T | undefined);
    req.onerror = () => reject(req.error);
  });
}

async function idbSet(key: string, value: unknown): Promise<void> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readwrite');
    tx.objectStore(STORE).put(value, key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

async function idbDelete(key: string): Promise<void> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readwrite');
    tx.objectStore(STORE).delete(key);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

function keysFromStored(stored: Stored): IdentityKeys {
  return {
    deviceId: stored.deviceId,
    ed25519Pub: jwkPubToB64(stored.ed25519.x || ''),
    ecdhPub: jwkPubToB64(stored.ecdh.x || '', stored.ecdh.y || ''),
  };
}

/** 生成本设备身份密钥对(幂等:已存在则复用) */
export async function ensureIdentityKeys(): Promise<IdentityKeys> {
  const existing = await idbGet<Stored>('identity');
  if (existing) return keysFromStored(existing);

  const deviceId = (b64UrlRandom(9).replace(/[^A-Za-z0-9_-]/g, 'x') || 'dev').slice(0, 12);
  const ed = await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
  const ec = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const stored: Stored = {
    deviceId,
    ed25519: await subtle.exportKey('jwk', ed.privateKey),
    ecdh: await subtle.exportKey('jwk', ec.privateKey),
  };
  await idbSet('identity', stored);
  return keysFromStored(stored);
}

async function importEcdh(jwk: JsonWebKey): Promise<CryptoKey> {
  return subtle.importKey('jwk', jwk, { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
}

/** 我的 ECDH 私钥(用于解包会话密钥) */
export async function getEcdhPrivateKey(): Promise<CryptoKey> {
  const existing = await idbGet<Stored>('identity');
  if (!existing) throw new Error('no identity');
  return importEcdh(existing.ecdh);
}

export async function hasIdentity(): Promise<boolean> {
  return !!(await idbGet<Stored>('identity'));
}

/** 清除本设备密钥(登出/设备重置) */
export async function wipeIdentity(): Promise<void> {
  await idbDelete('identity');
}

/** 导入他人的 ECDH 公钥(raw base64;线格式 64B x||y) */
export async function importPeerEcdhPub(b64: string): Promise<CryptoKey> {
  const raw = base64ToBytes(b64);
  // ⚠️ WebCrypto importKey('raw') 对 P-256 要求 65B 未压缩点格式(0x04||x||y);
  // 我们的线格式是 64B(JWK x/y 拼接),必须补 0x04 前缀,否则 importKey 报 DataError
  const point = raw.length === 64 ? new Uint8Array([0x04, ...raw]) : raw;
  return subtle.importKey('raw', point, { name: 'ECDH', namedCurve: 'P-256' }, true, []);
}

/* ---------------- 口令加密导出包(多设备迁移) ---------------- */

const PBKDF2_ITER = 250_000;

export async function exportEncryptedPackage(pin: string): Promise<string> {
  const stored = await idbGet<Stored>('identity');
  if (!stored) throw new Error('no identity');
  const salt = randomBytes(16);
  const iv = randomBytes(12);
  const baseKey = await subtle.importKey('raw', new TextEncoder().encode(pin), 'PBKDF2', false, ['deriveKey']);
  const key = await subtle.deriveKey(
    { name: 'PBKDF2', salt: base64ToBytes(salt), iterations: PBKDF2_ITER, hash: 'SHA-256' },
    baseKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt']
  );
  const plain = new TextEncoder().encode(JSON.stringify({ ...stored, kdf: 'PBKDF2-SHA256', iter: PBKDF2_ITER }));
  const ct = await subtle.encrypt({ name: 'AES-GCM', iv: base64ToBytes(iv) }, key, plain);
  return JSON.stringify({ v: 1, kdf: 'PBKDF2-SHA256', iter: PBKDF2_ITER, salt, iv, ct: bytesToBase64(new Uint8Array(ct)) });
}

export async function importEncryptedPackage(pkg: string, pin: string): Promise<IdentityKeys> {
  let parsed: { v: number; kdf: string; iter: number; salt: string; iv: string; ct: string };
  try {
    parsed = JSON.parse(pkg);
  } catch {
    throw new Error('bad package');
  }
  if (parsed.v !== 1 || parsed.kdf !== 'PBKDF2-SHA256') throw new Error('unsupported package');
  const baseKey = await subtle.importKey('raw', new TextEncoder().encode(pin), 'PBKDF2', false, ['deriveKey']);
  const key = await subtle.deriveKey(
    { name: 'PBKDF2', salt: base64ToBytes(parsed.salt), iterations: parsed.iter, hash: 'SHA-256' },
    baseKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['decrypt']
  );
  let stored: Stored;
  try {
    const plain = await subtle.decrypt({ name: 'AES-GCM', iv: base64ToBytes(parsed.iv) }, key, base64ToBytes(parsed.ct));
    stored = JSON.parse(new TextDecoder().decode(plain));
  } catch {
    throw new Error('wrong pin or corrupted package');
  }
  await idbSet('identity', stored);
  return keysFromStored(stored);
}
