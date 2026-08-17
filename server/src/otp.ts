import crypto from 'node:crypto';
import { db } from './db.js';
import { otpHmac, maskPhone, maskEmail } from './crypto-util.js';
import { logger } from './logger.js';
import { config } from './config.js';
import { sendSmsCode, sendEmailCode } from './channels.js';

const CODE_TTL_MS = 5 * 60 * 1000;
const MAX_ATTEMPTS = 5;

interface OtpRow {
  id: number;
  code_hash: string;
  created_at: number;
  expires_at: number;
  attempts: number;
  used: number;
}

function targetHash(target: string, type: string): string {
  return crypto.createHash('sha256').update(`${type}:${target}`).digest('hex');
}

/** 生成并发送验证码。返回 {ok, error?} */
export async function issueCode(target: string, type: 'sms' | 'email'): Promise<{ ok: boolean; error?: string; retryAfterSec?: number }> {
  // 单目标:60 秒内不重复发送
  const recent = db.prepare('SELECT created_at FROM otp_codes WHERE target_hash=? AND type=? ORDER BY created_at DESC LIMIT 1')
    .get(targetHash(target, type), type) as { created_at: number } | undefined;
  if (recent && Date.now() - recent.created_at < 60_000) {
    return { ok: false, error: 'rate_limited', retryAfterSec: Math.ceil((60_000 - (Date.now() - recent.created_at)) / 1000) };
  }

  const code = String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
  const now = Date.now();
  db.prepare('INSERT INTO otp_codes (target_hash, type, code_hash, created_at, expires_at) VALUES (?,?,?,?,?)')
    .run(targetHash(target, type), type, otpHmac(code), now, now + CODE_TTL_MS);

  // 通道发送。dev 模式:验证码写入安全日志(仅测试;生产必须配置真实通道)
  const masked = type === 'sms' ? maskPhone(target) : maskEmail(target);
  if (type === 'sms') {
    if (config.verifyChannel !== 'alibaba') {
      await appendDevOtp(type, masked, code, now);
    } else {
      const sent = await sendSmsCode(target, code);
      if (!sent.ok) return { ok: false, error: sent.error };
    }
  } else {
    if (config.mailChannel === 'dev') {
      await appendDevOtp(type, masked, code, now);
    } else {
      const sent = await sendEmailCode(target, code);
      if (!sent.ok) return { ok: false, error: sent.error };
    }
  }
  return { ok: true };
}

async function appendDevOtp(type: 'sms' | 'email', maskedTarget: string, code: string, now: number): Promise<void> {
  const log = `[DEV-OTP] ${type} target=${maskedTarget} code=${code} expires=${new Date(now + CODE_TTL_MS).toISOString()}`;
  logger.info('dev-otp-issued', { type, target: maskedTarget });
  const fs = await import('node:fs');
  const path = await import('node:path');
  fs.appendFileSync(path.join(config.dataRoot, 'logs', 'dev-otp.log'), log + '\n', { mode: 0o600 });
}

/** 校验验证码:有效期内、未使用、尝试次数未超限;成功后立即作废 */
export function verifyCode(target: string, type: 'sms' | 'email', code: string): { ok: boolean; error?: string } {
  const th = targetHash(target, type);
  const rows = db.prepare(
    'SELECT * FROM otp_codes WHERE target_hash=? AND type=? AND used=0 ORDER BY created_at DESC LIMIT 3'
  ).all(th, type) as OtpRow[];
  const now = Date.now();
  for (const row of rows) {
    if (row.expires_at < now) {
      db.prepare('UPDATE otp_codes SET used=1 WHERE id=?').run(row.id); // 过期即废
      continue;
    }
    if (row.attempts >= MAX_ATTEMPTS) {
      return { ok: false, error: 'too_many_attempts' };
    }
    // 恒定时间比较,防时序侧信道
    const a = Buffer.from(otpHmac(code), 'hex');
    const b = Buffer.from(row.code_hash, 'hex');
    const match = a.length === b.length && crypto.timingSafeEqual(a, b);
    if (match) {
      db.prepare('UPDATE otp_codes SET used=1 WHERE id=?').run(row.id); // 立即失效
      return { ok: true };
    }
    db.prepare('UPDATE otp_codes SET attempts = attempts + 1 WHERE id=?').run(row.id);
    return { ok: false, error: 'invalid_code' };
  }
  return { ok: false, error: 'invalid_code' };
}

export { CODE_TTL_MS, MAX_ATTEMPTS };
