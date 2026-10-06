import crypto from 'node:crypto';

/**
 * 实名认证工具:身份证校验、姓名校验、脱敏、指纹。
 *
 * 安全约定(重要):
 * - **绝不落明文身份证号**。库里只存掩码(前4后2)+ HMAC 指纹(不可逆,可审计/去重)。
 * - 本地先做格式与校验位校验,不合法直接拒,不消耗付费配额。
 * - 日志只记结果码,不记姓名/身份证号。
 */

const ID_WEIGHTS = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
const ID_CHECK_CODES = '10X98765432';

/** 18 位大陆身份证:正则 + 出生日期合法性 + GB11643 校验位 */
export function isValidIdCard(raw: unknown): boolean {
  const s = String(raw ?? '').trim().toUpperCase();
  if (!/^\d{17}[0-9X]$/.test(s)) return false;
  // 首 2 位须是有效省级代码(11-82),避免明显伪造
  const prov = parseInt(s.slice(0, 2), 10);
  if (!(prov >= 11 && prov <= 82)) return false;
  const y = parseInt(s.slice(6, 10), 10);
  const m = parseInt(s.slice(10, 12), 10);
  const d = parseInt(s.slice(12, 14), 10);
  if (m < 1 || m > 12 || d < 1 || d > 31) return false;
  const dt = new Date(Date.UTC(y, m - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return false;
  if (y < 1900 || dt.getTime() > Date.now()) return false;
  let sum = 0;
  for (let i = 0; i < 17; i++) sum += Number(s[i]) * ID_WEIGHTS[i];
  return ID_CHECK_CODES[sum % 11] === s[17];
}

/** 真实姓名:2~20 字符,首字符为中文或字母;禁止控制符/零宽字符 */
export function isValidRealName(raw: unknown): boolean {
  const s = String(raw ?? '').trim();
  if (s.length < 2 || s.length > 20) return false;
  if (/[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]/.test(s)) return false;
  return /^[\u4e00-\u9fa5A-Za-z][\u4e00-\u9fa5A-Za-z\u00B7\u2022\s.]*$/.test(s);
}

/** 姓名脱敏:张三 → 张* ;张小三 → 张*三 ;欧阳小四 → 欧**四 */
export function maskRealName(name: unknown): string {
  const s = String(name ?? '').trim();
  if (s.length <= 1) return s;
  if (s.length === 2) return `${s[0]}*`;
  return `${s[0]}${'*'.repeat(s.length - 2)}${s[s.length - 1]}`;
}

/** 身份证脱敏:保留前 4 位与后 2 位 */
export function maskIdCard(id: unknown): string {
  const s = String(id ?? '').trim().toUpperCase();
  if (s.length < 8) return '*'.repeat(s.length);
  return `${s.slice(0, 4)}${'*'.repeat(s.length - 6)}${s.slice(-2)}`;
}

/** 身份证指纹:HMAC-SHA256(带服务端 pepper),不可逆;用于审计与去重 */
export function idCardFingerprint(id: unknown, pepper: string): string {
  return crypto.createHmac('sha256', pepper).update(String(id ?? '').trim().toUpperCase()).digest('hex');
}
