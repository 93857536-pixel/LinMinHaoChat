import crypto from 'node:crypto';
import { config } from './config.js';

/** 随机 token(base64url) */
export function randomToken(bytes = 32): string {
  return crypto.randomBytes(bytes).toString('base64url');
}

/** 短 ID(如房间/消息 ID):16 字节 base64url */
export function newId(prefix = ''): string {
  return prefix + crypto.randomBytes(16).toString('base64url');
}

/** 验证码:HMAC-SHA256(pepper, code) —— 服务器不存明文验证码 */
export function otpHmac(code: string): string {
  return crypto.createHmac('sha256', config.otpPepper).update(code).digest('hex');
}

export function scryptHash(pw: string): string {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(pw, salt, 64).toString('hex');
  return `${salt}:${hash}`;
}

export function scryptVerify(pw: string, stored: string): boolean {
  const [salt, hash] = stored.split(':');
  if (!salt || !hash) return false;
  const calc = crypto.scryptSync(pw, salt, 64).toString('hex');
  const a = Buffer.from(calc, 'hex');
  const b = Buffer.from(hash, 'hex');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

export function maskPhone(phone: string): string {
  if (!/^1[3-9]\d{9}$/.test(phone)) return '[invalid]';
  return phone.slice(0, 3) + '****' + phone.slice(7);
}

export function maskEmail(email: string): string {
  const m = email.match(/^([^@\s]+)@([^@\s]+\.[^@\s]+)$/);
  if (!m) return '[invalid]';
  const name = m[1];
  const n = name.length <= 3 ? name[0] + '***' : name.slice(0, 3) + '***';
  return `${n}@${m[2]}`;
}

export function isValidPhone(s: string): boolean {
  return /^1[3-9]\d{9}$/.test(s);
}

export function isValidEmail(s: string): boolean {
  return /^[^@\s]{1,64}@[^@\s]{1,255}\.[a-zA-Z]{2,}$/.test(s) && s.length <= 254;
}

/** 规范化邮箱:小写+去空格 */
export function normalizeEmail(s: string): string {
  return s.trim().toLowerCase();
}

export function safeJsonParse<T>(s: string): T | null {
  try { return JSON.parse(s) as T; } catch { return null; }
}

/** 恒定时间字符串比较 */
export function safeEqual(a: string, b: string): boolean {
  const ba = Buffer.from(a);
  const bb = Buffer.from(b);
  return ba.length === bb.length && crypto.timingSafeEqual(ba, bb);
}
