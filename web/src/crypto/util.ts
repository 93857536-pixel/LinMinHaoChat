/** Web Crypto 工具 */

export const subtle: SubtleCrypto = globalThis.crypto.subtle;

/** 字节类型(ArrayBuffer 泛型,兼容 TS 5.7+ BufferSource) */
export type Bytes = Uint8Array<ArrayBuffer>;

export function randomBytes(n: number): string {
  const buf = new Uint8Array(n);
  crypto.getRandomValues(buf);
  return bytesToBase64(buf);
}

export function bytesToBase64(bytes: Uint8Array): string {
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

export function base64ToBytes(b64: string): Bytes {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** base64url → base64(padded) */
export function b64uToB64(s: string): string {
  const pad = s.replace(/-/g, '+').replace(/_/g, '/');
  return pad + '='.repeat((4 - (pad.length % 4)) % 4);
}

/** base64 → base64url */
export function b64ToB64u(s: string): string {
  return s.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

/** JWK 的 x(或 x+y)字段 → base64 公钥 */
export function jwkPubToB64(x: string, y?: string): string {
  const xb = base64ToBytes(b64uToB64(x));
  if (y) {
    const yb = base64ToBytes(b64uToB64(y));
    const out = new Uint8Array(xb.length + yb.length);
    out.set(xb, 0);
    out.set(yb, xb.length);
    return bytesToBase64(out);
  }
  return bytesToBase64(xb);
}

export function b64UrlRandom(bytes: number): string {
  return b64ToB64u(bytesToBase64(crypto.getRandomValues(new Uint8Array(bytes))));
}

export async function sha256Hex(s: string): Promise<string> {
  const digest = await subtle.digest('SHA-256', new TextEncoder().encode(s));
  const bytes = new Uint8Array(digest);
  let hex = '';
  for (let i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, '0');
  return hex;
}
