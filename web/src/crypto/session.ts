/**
 * 会话密钥生命周期。
 *
 * 私聊/群聊:
 *  1. 创建者生成 32B 随机 sessionKey
 *  2. 对每个成员(含自己)每个设备:ECDH(myPriv, memberPub) → HKDF → AES-GCM 包装 sessionKey
 *  3. wrappedKey 上传服务器(room_keys),成员拉取自己的,用私钥解开
 *  4. 服务器只有 wrappedKey 密文,永远无法还原 sessionKey
 *
 * 临时聊天:
 *  创建者生成 sessionKey,直接放进分享链接 fragment(#k=...)
 *  —— fragment 不经过服务器,nginx 日志/后端均不可见。
 */
import { subtle, randomBytes, bytesToBase64, base64ToBytes, type Bytes } from './util';
import { getEcdhPrivateKey, importPeerEcdhPub } from './keys';

const HKDF_INFO = 'lmh-session-wrap-v1';

async function deriveWrapKey(myPriv: CryptoKey, peerPub: CryptoKey): Promise<CryptoKey> {
  const bits = await subtle.deriveBits({ name: 'ECDH', public: peerPub }, myPriv, 256);
  const base = await subtle.importKey('raw', new Uint8Array(bits), 'HKDF', false, ['deriveKey']);
  return subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: new TextEncoder().encode(HKDF_INFO) },
    base,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt']
  );
}

/** 用成员公钥包装会话密钥(附带包装者公钥,便于对方解包) */
export async function wrapSessionKey(sessionKey: Bytes, peerEcdhPubB64: string): Promise<string> {
  const myPriv = await getEcdhPrivateKey();
  const myKeys = await ensureIdentityKeysRef();
  const peerPub = await importPeerEcdhPub(peerEcdhPubB64);
  const key = await deriveWrapKey(myPriv, peerPub);
  const iv: Bytes = crypto.getRandomValues(new Uint8Array(12));
  const ct = await subtle.encrypt({ name: 'AES-GCM', iv }, key, sessionKey);
  return JSON.stringify({ v: 1, iv: bytesToBase64(iv), ct: bytesToBase64(new Uint8Array(ct)), pk: myKeys.ecdhPub });
}

/** 用我的私钥解开 wrappedKey(wrapped 内含包装者公钥 pk) */
export async function unwrapSessionKey(wrapped: string): Promise<Bytes> {
  const parsed = JSON.parse(wrapped) as { v: number; iv: string; ct: string; pk?: string };
  if (parsed.v !== 1) throw new Error('unsupported wrap version');
  const myPriv = await getEcdhPrivateKey();
  const peerPub = await importPeerEcdhPub(parsed.pk || '');
  const key = await deriveWrapKey(myPriv, peerPub);
  const plain = await subtle.decrypt(
    { name: 'AES-GCM', iv: base64ToBytes(parsed.iv) },
    key,
    base64ToBytes(parsed.ct)
  );
  return new Uint8Array(plain);
}

async function ensureIdentityKeysRef() {
  const { ensureIdentityKeys } = await import('./keys');
  return ensureIdentityKeys();
}

/** 生成新会话密钥 */
export function generateSessionKey(): Bytes {
  return crypto.getRandomValues(new Uint8Array(32));
}

/** 临时聊天:生成分享链接(密钥放 fragment,不经过服务器) */
export function buildTempShareUrl(roomId: string, sessionKey: Bytes): string {
  const k = bytesToBase64(sessionKey).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return `${location.origin}/t/${roomId}#k=${k}`;
}

/** 从分享链接 fragment 提取会话密钥 */
export function parseTempShareKey(hash: string): Bytes | null {
  if (!hash.startsWith('#k=')) return null;
  const k = hash.slice(3);
  try {
    const b64 = k.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (k.length % 4)) % 4);
    return base64ToBytes(b64);
  } catch {
    return null;
  }
}

/** 便捷:32B base64url */
export function sessionKeyToB64url(key: Bytes): string {
  return bytesToBase64(key).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function sessionKeyFromB64url(s: string): Bytes {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4);
  return base64ToBytes(b64);
}

export type { Bytes } from './util';

export { randomBytes };
