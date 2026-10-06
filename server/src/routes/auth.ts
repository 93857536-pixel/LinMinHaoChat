import { Router } from 'express';
import crypto from 'node:crypto';
import { db } from '../db.js';
import { issueCode, verifyCode, CODE_TTL_MS } from '../otp.js';
import { isValidPhone, isValidEmail, normalizeEmail, maskPhone, maskEmail, randomToken, newId } from '../crypto-util.js';
import { rateLimit, clientIp } from '../ratelimit.js';
import { signUserJwt, authRequired } from '../middleware.js';
import { logger } from '../logger.js';
import { generateHandle, sanitizeNickname } from '../handle.js';

export const authRouter = Router();

const SESSION_TTL_MS = 30 * 24 * 3600 * 1000; // 30 天

function hashTarget(target: string): string {
  return crypto.createHash('sha256').update(target).digest('hex');
}

/** 发送验证码:手机 or 邮箱 */
authRouter.post('/send-code', async (req, res) => {
  const { type, target } = req.body || {};
  if (type !== 'sms' && type !== 'email') return res.status(400).json({ error: 'bad_type' });
  const t = String(target || '').trim();
  if (type === 'sms' && !isValidPhone(t)) return res.status(400).json({ error: 'bad_phone' });
  if (type === 'email' && !isValidEmail(t)) return res.status(400).json({ error: 'bad_email' });
  const norm = type === 'email' ? normalizeEmail(t) : t;

  // 限流:IP 60 次/小时;目标 5 次/小时;发送间隔 60s(otp.ts 内)
  const ip = clientIp(req);
  const rIp = rateLimit(`otp:ip:${ip}`, 60, 3600_000, 3600_000);
  if (!rIp.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: rIp.retryAfterSec });
  const rTarget = rateLimit(`otp:target:${hashTarget(norm)}`, 5, 3600_000, 3600_000);
  if (!rTarget.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: rTarget.retryAfterSec });

  const out = await issueCode(norm, type);
  if (!out.ok) {
    if (out.error === 'rate_limited') return res.status(429).json({ error: 'rate_limited', retryAfterSec: out.retryAfterSec });
    return res.status(503).json({ error: out.error });
  }
  logger.info('otp_issued', { type, target: type === 'sms' ? maskPhone(norm) : maskEmail(norm), ip });
  // 统一响应,不泄露目标是否存在
  return res.json({ ok: true, expiresInSec: CODE_TTL_MS / 1000 });
});

/** 注册(验证码登录即注册) */
authRouter.post('/register', async (req, res) => {
  const { type, target, code, handle, deviceId, ed25519Pub, ecdhPub } = req.body || {};
  if (type !== 'sms' && type !== 'email') return res.status(400).json({ error: 'bad_type' });
  const t = String(target || '').trim();
  if (type === 'sms' && !isValidPhone(t)) return res.status(400).json({ error: 'bad_phone' });
  if (type === 'email' && !isValidEmail(t)) return res.status(400).json({ error: 'bad_email' });
  const norm = type === 'email' ? normalizeEmail(t) : t;
  const codeStr = String(code || '');
  if (!/^\d{6}$/.test(codeStr)) return res.status(400).json({ error: 'bad_code' });

  // 可选公钥(注册时一并上传;也可稍后 /api/keys)
  const pub = ed25519Pub && ecdhPub
    ? { ed25519Pub: String(ed25519Pub), ecdhPub: String(ecdhPub), deviceId: String(deviceId || 'default') }
    : null;

  const ip = clientIp(req);
  const r = rateLimit(`auth:ip:${ip}`, 30, 10 * 60_000, 10 * 60_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });

  const v = verifyCode(norm, type, codeStr);
  if (!v.ok) return res.status(401).json({ error: v.error === 'invalid_code' ? 'invalid_code' : 'too_many_attempts' });

  const th = hashTarget(`${type}:${norm}`);
  let user = db.prepare('SELECT * FROM users WHERE phone_hash=? OR email_hash=?').get(
    type === 'sms' ? th : null, type === 'email' ? th : null
  ) as { id: number; banned: number } | undefined;

  const now = Date.now();
  if (!user) {
    // 规范账号 ID:注册时间 + 字母序号(如 202210216pm.A),唯一、不可改
    const handleAuto = generateHandle(now);
    // 昵称:用户填了就用(可改),否则与账号 ID 相同
    const nickname = sanitizeNickname(handle) || handleAuto;
    const info = db.prepare(
      'INSERT INTO users (phone_hash, email_hash, phone_masked, email_masked, handle, nickname, created_at) VALUES (?,?,?,?,?,?,?)'
    ).run(
      type === 'sms' ? th : null,
      type === 'email' ? th : null,
      type === 'sms' ? maskPhone(norm) : null,
      type === 'email' ? maskEmail(norm) : null,
      handleAuto,
      nickname,
      now
    );
    user = { id: Number(info.lastInsertRowid), banned: 0 };
    logger.info('user_registered', { id: user.id, type, handle: handleAuto, target: type === 'sms' ? maskPhone(norm) : maskEmail(norm) });
  }
  if (user.banned) return res.status(403).json({ error: 'banned' });

  db.prepare('UPDATE users SET last_login_at=? WHERE id=?').run(now, user.id);

  // 保存密钥/设备
  if (pub) {
    db.prepare(
      `INSERT INTO user_keys (user_id, device_id, ed25519_pub, ecdh_pub, created_at) VALUES (?,?,?,?,?)
       ON CONFLICT(user_id, device_id) DO UPDATE SET ed25519_pub=excluded.ed25519_pub, ecdh_pub=excluded.ecdh_pub`
    ).run(user.id, pub.deviceId, pub.ed25519Pub, pub.ecdhPub, now);
  }

  // 会话(session id 存客户端;DB 存 token_hash)
  const sessionId = randomToken(24);
  const tokenHash = crypto.createHash('sha256').update(sessionId).digest('hex');
  db.prepare('INSERT INTO sessions (id, user_id, token_hash, created_at, expires_at, device) VALUES (?,?,?,?,?,?)')
    .run(sessionId, user.id, tokenHash, now, now + SESSION_TTL_MS, String(deviceId || 'default'));

  const jwt = await signUserJwt(user.id, pub?.deviceId || 'default');
  const u = db.prepare('SELECT handle, nickname FROM users WHERE id=?').get(user.id) as { handle: string; nickname: string | null } | undefined;
  res.json({ ok: true, token: jwt, sessionId, user: { id: user.id, handle: u?.handle, nickname: u?.nickname ?? u?.handle } });
});

/** 登录(仅验证码,无需密码) */
authRouter.post('/login', async (req, res) => {
  const { type, target, code, deviceId, ed25519Pub, ecdhPub } = req.body || {};
  if (type !== 'sms' && type !== 'email') return res.status(400).json({ error: 'bad_type' });
  const t = String(target || '').trim();
  if (type === 'sms' && !isValidPhone(t)) return res.status(400).json({ error: 'bad_phone' });
  if (type === 'email' && !isValidEmail(t)) return res.status(400).json({ error: 'bad_email' });
  const norm = type === 'email' ? normalizeEmail(t) : t;
  const codeStr = String(code || '');
  if (!/^\d{6}$/.test(codeStr)) return res.status(400).json({ error: 'bad_code' });

  const ip = clientIp(req);
  const r = rateLimit(`auth:ip:${ip}`, 30, 10 * 60_000, 10 * 60_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });

  const th = hashTarget(`${type}:${norm}`);
  const user = db.prepare('SELECT * FROM users WHERE phone_hash=? OR email_hash=?').get(
    type === 'sms' ? th : null, type === 'email' ? th : null
  ) as { id: number; banned: number } | undefined;
  // 统一返回 invalid_code,不泄露账号是否存在
  if (!user) return res.status(401).json({ error: 'invalid_code' });

  const v = verifyCode(norm, type, codeStr);
  if (!v.ok) return res.status(401).json({ error: v.error === 'invalid_code' ? 'invalid_code' : 'too_many_attempts' });
  if (user.banned) return res.status(403).json({ error: 'banned' });

  db.prepare('UPDATE users SET last_login_at=? WHERE id=?').run(Date.now(), user.id);
  if (ed25519Pub && ecdhPub) {
    db.prepare(
      `INSERT INTO user_keys (user_id, device_id, ed25519_pub, ecdh_pub, created_at) VALUES (?,?,?,?,?)
       ON CONFLICT(user_id, device_id) DO UPDATE SET ed25519_pub=excluded.ed25519_pub, ecdh_pub=excluded.ecdh_pub`
    ).run(user.id, String(deviceId || 'default'), String(ed25519Pub), String(ecdhPub), Date.now());
  }

  const sessionId = randomToken(24);
  const tokenHash = crypto.createHash('sha256').update(sessionId).digest('hex');
  db.prepare('INSERT INTO sessions (id, user_id, token_hash, created_at, expires_at, device) VALUES (?,?,?,?,?,?)')
    .run(sessionId, user.id, tokenHash, Date.now(), Date.now() + SESSION_TTL_MS, String(deviceId || 'default'));

  const jwt = await signUserJwt(user.id, String(deviceId || 'default'));
  const u = db.prepare('SELECT handle, nickname FROM users WHERE id=?').get(user.id) as { handle: string; nickname: string | null } | undefined;
  res.json({ ok: true, token: jwt, sessionId, user: { id: user.id, handle: u?.handle, nickname: u?.nickname ?? u?.handle } });
});

/**
 * 当前账号资料(供 App 启动时恢复用户名/账号 ID)
 * GET /api/auth/me → { ok, user: { id, handle, nickname, createdAt } }
 */
authRouter.get('/me', authRequired, (req, res) => {
  const u = db.prepare('SELECT id, handle, nickname, created_at, banned, rn_status, rn_name_mask, rn_verified_at, avatar_mime, avatar_updated_at FROM users WHERE id=?').get(req.user!.id) as
    | { id: number; handle: string | null; nickname: string | null; created_at: number; banned: number;
        rn_status: string | null; rn_name_mask: string | null; rn_verified_at: number | null;
        avatar_mime: string | null; avatar_updated_at: number | null }
    | undefined;
  if (!u) return res.status(404).json({ error: 'not_found' });
  if (u.banned) return res.status(403).json({ error: 'banned' });
  res.json({
    ok: true,
    user: {
      id: u.id,
      handle: u.handle,
      nickname: u.nickname ?? u.handle,
      createdAt: u.created_at,
      // 头像:客户端用 avatarUpdatedAt 作缓存版本号(换头像即失效)
      hasAvatar: !!u.avatar_mime,
      avatarUpdatedAt: u.avatar_updated_at,
      // 实名认证状态(客户端据此显示徽标/入口)
      realnameStatus: u.rn_status ?? 'none',
      realnameVerified: u.rn_status === 'verified',
      realnameNameMasked: u.rn_name_mask,
      realnameVerifiedAt: u.rn_verified_at,
    },
  });
});

/**
 * 修改昵称(账号名称)
 * POST /api/auth/nickname { nickname } — 账号 ID(handle)不可改,仅改显示名
 */
authRouter.post('/nickname', authRequired, (req, res) => {
  const r = rateLimit(`nickname:${req.user!.id}`, 10, 3600_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });

  const nickname = sanitizeNickname((req.body || {}).nickname);
  if (nickname.length < 1) return res.status(400).json({ error: 'bad_nickname' });
  if (nickname.length > 24) return res.status(400).json({ error: 'nickname_too_long' });

  db.prepare('UPDATE users SET nickname=? WHERE id=?').run(nickname, req.user!.id);
  logger.info('nickname_updated', { id: req.user!.id, nickname });
  const u = db.prepare('SELECT handle, nickname FROM users WHERE id=?').get(req.user!.id) as { handle: string; nickname: string | null } | undefined;
  res.json({ ok: true, user: { id: req.user!.id, handle: u?.handle, nickname: u?.nickname ?? nickname } });
});

/** 登出:作废当前 session
 *  ⚠️ 凭证型撤销:持有 sessionId 即视为持有该会话凭证(与 refresh token 撤销同理),
 *  故此端点不强制 JWT(iOS 会带 token,web 旧版不带 —— 保持兼容)。
 *  加 IP 限流,避免被用来做批量探测/销毁。
 */
authRouter.post('/logout', (req, res) => {
  const r = rateLimit(`logout:${clientIp(req)}`, 30, 60_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });
  const sid = String((req.body || {}).sessionId || '').slice(0, 128);
  if (sid) db.prepare('DELETE FROM sessions WHERE id=?').run(sid);
  res.json({ ok: true });
});
