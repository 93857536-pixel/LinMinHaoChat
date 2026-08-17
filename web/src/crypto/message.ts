/**
 * 消息加密:AES-256-GCM + 每消息独立 IV + HKDF 派生消息密钥 + AAD 防篡改。
 *
 * 加密后的消息载荷(发送给服务器,服务器只转发/存档):
 *   { iv: base64(12B), ct: base64(iv||ciphertext||tag) }
 * 明文格式(应用层): { t: 文本内容 } / { f: { name, size, mime } } (附件元数据)
 *
 * AAD = `${roomId}:${seq}:${ts}` —— 服务器篡改任一字段都会导致 GCM 认证失败,
 * 客户端解密时能立即察觉。
 */
import { subtle, bytesToBase64, base64ToBytes, type Bytes } from './util';

export interface EncryptedPayload {
  iv: string;
  ct: string;
}

/** 会话密钥(32B) → HKDF 派生消息密钥(每次消息独立,防 nonce 复用) */
async function deriveMessageKey(sessionKey: Bytes, iv: Bytes, roomId: string, seq: number): Promise<CryptoKey> {
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

/** 加密一条消息。aad 由调用方传入(roomId:seq:ts,服务器保存原文) */
export async function encryptMessage(
  sessionKey: Bytes,
  plaintext: string,
  roomId: string,
  seq: number,
  ts: number
): Promise<EncryptedPayload> {
  const iv: Bytes = crypto.getRandomValues(new Uint8Array(12));
  const key = await deriveMessageKey(sessionKey, iv, roomId, seq);
  const aad = new TextEncoder().encode(`${roomId}:${seq}:${ts}`);
  const ct = await subtle.encrypt(
    { name: 'AES-GCM', iv, additionalData: aad },
    key,
    new TextEncoder().encode(plaintext)
  );
  return { iv: bytesToBase64(iv), ct: bytesToBase64(new Uint8Array(ct)) };
}

/** 解密一条消息。失败(认证失败/密钥错误/密文被篡改)抛错。 */
export async function decryptMessage(
  sessionKey: Bytes,
  payload: EncryptedPayload,
  roomId: string,
  seq: number,
  ts: number
): Promise<string> {
  const iv = base64ToBytes(payload.iv);
  const ct = base64ToBytes(payload.ct);
  const key = await deriveMessageKey(sessionKey, iv, roomId, seq);
  const aad = new TextEncoder().encode(`${roomId}:${seq}:${ts}`);
  const plain = await subtle.decrypt({ name: 'AES-GCM', iv, additionalData: aad }, key, ct);
  return new TextDecoder().decode(plain);
}

/** 附件加密(同 AES-GCM,无 seq 绑定) */
export async function encryptAttachment(sessionKey: Bytes, data: ArrayBuffer, roomId: string, ts: number): Promise<ArrayBuffer> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const base = await subtle.importKey('raw', sessionKey, 'HKDF', false, ['deriveKey']);
  const key = await subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: iv, info: new TextEncoder().encode(`lmh-att-v1:${roomId}:${ts}`) },
    base,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt']
  );
  return subtle.encrypt({ name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(`${roomId}:${ts}`) }, key, data);
}

export async function decryptAttachment(sessionKey: Bytes, data: ArrayBuffer, roomId: string, ts: number): Promise<ArrayBuffer> {
  const ct = new Uint8Array(data);
  const iv = ct.slice(0, 12);
  const body = ct.slice(12);
  const base = await subtle.importKey('raw', sessionKey, 'HKDF', false, ['deriveKey']);
  const key = await subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: iv, info: new TextEncoder().encode(`lmh-att-v1:${roomId}:${ts}`) },
    base,
    { name: 'AES-GCM', length: 256 },
    false,
    ['decrypt']
  );
  return subtle.decrypt({ name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(`${roomId}:${ts}`) }, key, body);
}

/** 应用层消息格式 */
export function encodeMessageBody(text: string): string {
  return JSON.stringify({ t: text });
}

export interface DecodedBody {
  t?: string;
  f?: { attId?: string; name: string; size: number; mime: string };
}

export function decodeMessageBody(raw: string): DecodedBody {
  try {
    return JSON.parse(raw) as DecodedBody;
  } catch {
    return { t: raw };
  }
}
