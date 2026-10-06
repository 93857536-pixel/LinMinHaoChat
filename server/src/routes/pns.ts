import { Router } from 'express';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import { db } from '../db.js';
import { isValidPhone, maskPhone, randomToken, newId } from '../crypto-util.js';
import { rateLimit, clientIp } from '../ratelimit.js';
import { signUserJwt } from '../middleware.js';
import { logger } from '../logger.js';
import { config } from '../config.js';
import { generateHandle, sanitizeNickname } from '../handle.js';

const require = createRequire(import.meta.url);
// 阿里云号码认证服务 SDK(CJS 转译产物,与 channels.ts 同款加载方式)
// default = Client 构造器;模块顶层命名导出含各 Request 类
// ⚠️ openapi-client 必须 new Config({...}) 实例传入 Client,直接传普通对象会 InvalidCredentials
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const DypnsModule: any = require('@alicloud/dypnsapi20170525');
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const DypnsCtor: any = DypnsModule.default;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const OpenApiConfig: any = require('@alicloud/openapi-client').Config;

export const pnsRouter = Router();

const SESSION_TTL_MS = 30 * 24 * 3600 * 1000; // 30 天

function hashTarget(target: string): string {
  return crypto.createHash('sha256').update(target).digest('hex');
}

function newClient() {
  return new DypnsCtor(new OpenApiConfig({
    accessKeyId: config.alibabaKeyId,
    accessKeySecret: config.alibabaKeySecret,
    endpoint: 'dypnsapi.aliyuncs.com',
  }));
}

/**
 * 号码认证换号(一键登录):
 * - 客户端阿里云号码认证 SDK 拉起运营商授权页 → 用户同意 → SDK 回调返回 SpToken(一次性)
 * - 本接口拿 SpToken 调阿里云 GetMobile(native 一键登录取号)换真实手机号
 * - 换号成功后:老号直接登录,新号自动注册(与 register 同逻辑)
 * 请求: { spToken, handle?, deviceId?, ed25519Pub?, ecdhPub? }
 */
pnsRouter.post('/phone-check', async (req, res) => {
  const { spToken, handle, deviceId, ed25519Pub, ecdhPub } = req.body || {};
  const token = String(spToken || '').trim();
  // SpToken 上限 4096:运营商授权页下发的真实登录 token 可超过 256 字符,
  // 过短(<8)视为无效;过长(>4096)才拒绝。拒绝时记长度便于排查。
  if (!token || token.length < 8 || token.length > 4096) {
    logger.warn('pns_bad_token_len', { len: token.length, ip: clientIp(req) });
    return res.status(400).json({ error: 'bad_token' });
  }
  const ip = clientIp(req);
  const r = rateLimit(`auth:ip:${ip}`, 30, 10 * 60_000, 10 * 60_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });

  // 阿里云换号(GetMobile,native 一键登录 SDK 取号专用,SpToken 一次有效)
  // ⚠️ 不能用 GetPhoneWithToken:那是 H5 JavaScript SDK 的取号接口,
  // 传 native SpToken 会被网元拒(实测 isp.SYSTEM_ERROR 网元系统异常)
  let mobile: string;
  try {
    const client = newClient();
    const reqApi = new DypnsModule.GetMobileRequest({
      accessToken: token,
    });
    const resp = await client.getMobile(reqApi);
    const code = resp.body?.code;
    const data = resp.body?.getMobileResultDTO;
    if (code !== 'OK' || !data?.mobile) {
      logger.error('pns_exchange_failed', { code, message: resp.body?.message, ip });
      return res.status(400).json({ error: 'token_invalid' });
    }
    mobile = String(data.mobile);
  } catch (e) {
    logger.error('pns_exchange_exception', { message: (e as Error).message, ip });
    return res.status(502).json({ error: 'pns_upstream_error' });
  }

  if (!isValidPhone(mobile)) {
    logger.error('pns_bad_mobile', { mobile: maskPhone(mobile) });
    return res.status(400).json({ error: 'token_invalid' });
  }

  const th = hashTarget(`sms:${mobile}`);
  const now = Date.now();
  let user = db.prepare('SELECT * FROM users WHERE phone_hash=?').get(th) as
    | { id: number; banned: number }
    | undefined;

  if (!user) {
    // 规范账号 ID:注册时间 + 字母序号(如 202210216pm.A),唯一、不可改
    const handleAuto = generateHandle(now);
    const nickname = sanitizeNickname(handle) || handleAuto;
    const info = db.prepare(
      'INSERT INTO users (phone_hash, email_hash, phone_masked, email_masked, handle, nickname, created_at) VALUES (?,?,?,?,?,?,?)'
    ).run(th, null, maskPhone(mobile), null, handleAuto, nickname, now);
    user = { id: Number(info.lastInsertRowid), banned: 0 };
    logger.info('user_registered_via_pns', { id: user.id, handle: handleAuto, mobile: maskPhone(mobile), ip });
  }
  if (user.banned) return res.status(403).json({ error: 'banned' });

  db.prepare('UPDATE users SET last_login_at=? WHERE id=?').run(now, user.id);
  if (ed25519Pub && ecdhPub) {
    db.prepare(
      `INSERT INTO user_keys (user_id, device_id, ed25519_pub, ecdh_pub, created_at) VALUES (?,?,?,?,?)
       ON CONFLICT(user_id, device_id) DO UPDATE SET ed25519_pub=excluded.ed25519_pub, ecdh_pub=excluded.ecdh_pub`
    ).run(user.id, String(deviceId || 'default'), String(ed25519Pub), String(ecdhPub), now);
  }

  const sessionId = randomToken(24);
  const tokenHash = crypto.createHash('sha256').update(sessionId).digest('hex');
  db.prepare('INSERT INTO sessions (id, user_id, token_hash, created_at, expires_at, device) VALUES (?,?,?,?,?,?)')
    .run(sessionId, user.id, tokenHash, now, now + SESSION_TTL_MS, String(deviceId || 'default'));

  const jwt = await signUserJwt(user.id, String(deviceId || 'default'));
  const u = db.prepare('SELECT handle, nickname FROM users WHERE id=?').get(user.id) as { handle: string; nickname: string | null } | undefined;
  logger.info('pns_login_ok', { id: user.id, ip });
  res.json({ ok: true, token: jwt, sessionId, user: { id: user.id, handle: u?.handle, nickname: u?.nickname ?? u?.handle } });
});
