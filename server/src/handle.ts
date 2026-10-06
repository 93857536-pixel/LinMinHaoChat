/**
 * 规范账号 ID 生成器
 *
 * 规则:注册时间 + 字母序号
 *   例:2022-10-21 18:00 注册的第 1 个账号 → 202210216pm.A
 *       同一时刻第二个 → 202210216pm.B ... 第 26 个 → 202210216pm.Z
 *       第 27 个 → 202210216pm.AA,第 28 个 → 202210216pm.AB
 *
 * - 日期:YYYYMMDD
 * - 时间:12 小时制小写 + am/pm(00:xx → 12am,12:xx → 12pm)
 * - 序号:Excel 列名风格(A..Z, AA..AZ, BA..),保证同一小时内并发注册不冲突
 */

import { db } from './db.js';

/** 时间戳 → 账号 ID 前缀,如 2022-10-21 18:00 → "202210216pm" */
export function handlePrefix(ts: number): string {
  const d = new Date(ts);
  const y = d.getFullYear();
  const mo = String(d.getMonth() + 1).padStart(2, '0');
  const da = String(d.getDate()).padStart(2, '0');
  let h = d.getHours();
  const ampm = h < 12 ? 'am' : 'pm';
  h = h % 12;
  if (h === 0) h = 12;
  return `${y}${mo}${da}${h}${ampm}`;
}

/** 序号 → 字母(A, B, ..., Z, AA, AB, ...);0 基 */
export function seqLetters(i: number): string {
  let s = '';
  let n = i + 1;
  while (n > 0) {
    n -= 1;
    s = String.fromCharCode(65 + (n % 26)) + s;
    n = Math.floor(n / 26);
  }
  return s;
}

/**
 * 生成未被占用的规范账号 ID。
 * 从 .A 起递增探测,遇到已占用则换下一个字母(理论 10000 次内必成功)。
 */
export function generateHandle(ts: number): string {
  const prefix = handlePrefix(ts);
  const stmt = db.prepare('SELECT 1 FROM users WHERE handle=?');
  for (let i = 0; i < 10000; i++) {
    const candidate = `${prefix}.${seqLetters(i)}`;
    if (!stmt.get(candidate)) return candidate;
  }
  // 极端情况(同一小时注册 >10000 人):退化为随机后缀保证可用
  return `${prefix}.${seqLetters(10000)}${Math.random().toString(36).slice(2, 6).toUpperCase()}`;
}

/** 清理并校验用户自定义昵称 */
export function sanitizeNickname(raw: unknown): string {
  const s = String(raw ?? '')
    .replace(/[<>&"'`\\]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 24);
  return s;
}
