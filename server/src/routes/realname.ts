import { Router } from 'express';
import { db } from '../db.js';
import { config } from '../config.js';
import { rateLimit, clientIp } from '../ratelimit.js';
import { logger } from '../logger.js';
import { authRequired } from '../middleware.js';
import {
  isValidIdCard,
  isValidRealName,
  maskRealName,
  maskIdCard,
  idCardFingerprint,
} from '../realname-util.js';

export const realnameRouter = Router();

// 云市场「身份证二要素实名认证」(杭州九天创界)。APPCODE 简单认证,**AppCode 只存服务端**。
const VENDOR_URL = 'https://jtidcard.market.alicloudapi.com/idcardcheck';

// 服务商错误码 → 我们对外暴露的语义(不把服务商细节直接透给客户端)
const VENDOR_ERROR_MAP: Record<number, string> = {
  400: 'bad_input',
  500: 'vendor_error',
  501: 'vendor_error',
  604: 'vendor_disabled',
  1001: 'vendor_error',
  1002: 'vendor_quota',   // 号段不支持 / 调用超限
  1003: 'no_record',
};

interface RnRow {
  rn_status: string | null;
  rn_name_mask: string | null;
  rn_idcard_mask: string | null;
  rn_verified_at: number | null;
}

function statusPayload(userId: number) {
  const r = db
    .prepare('SELECT rn_status, rn_name_mask, rn_idcard_mask, rn_verified_at FROM users WHERE id=?')
    .get(userId) as RnRow | undefined;
  return {
    status: r?.rn_status ?? 'none',
    verified: r?.rn_status === 'verified',
    nameMasked: r?.rn_name_mask ?? null,
    idcardMasked: r?.rn_idcard_mask ?? null,
    verifiedAt: r?.rn_verified_at ?? null,
  };
}

/** 服务端启动时暴露一次能力状态,便于运维核对 */
export const realnameEnabled = (): boolean => !!config.realnameAppCode;

realnameRouter.use(authRequired);

/** 查询当前实名状态 */
realnameRouter.get('/status', (req, res) => {
  res.json({ ok: true, enabled: realnameEnabled(), ...statusPayload(req.user!.id) });
});

/**
 * 提交实名认证(姓名 + 身份证号)
 * 成功仅代表「二要素一致」;不一致/无记录不改动已有认证状态。
 */
realnameRouter.post('/verify', async (req, res) => {
  if (!config.realnameAppCode) {
    return res.status(503).json({ error: 'realname_unavailable' });
  }

  const uid = req.user!.id;
  const ip = clientIp(req);

  // 三层限流:①同用户 10 秒 1 次 ②同用户每日 N 次(保护付费配额) ③同 IP 每小时
  const rlFast = rateLimit(`rn:fast:${uid}`, 1, 10_000);
  if (!rlFast.ok) return res.status(429).json({ error: 'too_frequent', retryAfterSec: rlFast.retryAfterSec });
  const rlDay = rateLimit(`rn:day:${uid}`, config.realnameDailyPerUser, 24 * 3600 * 1000, 24 * 3600 * 1000);
  if (!rlDay.ok) return res.status(429).json({ error: 'daily_limit', retryAfterSec: rlDay.retryAfterSec });
  const rlIp = rateLimit(`rn:ip:${ip}`, 20, 3600 * 1000);
  if (!rlIp.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: rlIp.retryAfterSec });

  // 一个账号只能实名一次:已认证账号不支持「重新核验」,也不支持换绑他人身份证。
  // (产品决策,用户明确要求:实名一经绑定不可更改)此判断在调用上游之前 → 不消耗付费配额。
  const already = db.prepare('SELECT rn_status FROM users WHERE id=?').get(uid) as { rn_status: string | null } | undefined;
  if (already?.rn_status === 'verified') {
    logger.info('realname_already_verified', { userId: uid });
    return res.status(409).json({ error: 'already_verified' });
  }

  const name = String(req.body?.name ?? '').trim();
  const idcard = String(req.body?.idcard ?? '').trim().toUpperCase();

  // 本地先校验:格式/校验位不对直接拒,不消耗付费配额
  if (!isValidRealName(name)) return res.status(400).json({ error: 'bad_name' });
  if (!isValidIdCard(idcard)) return res.status(400).json({ error: 'bad_idcard' });

  // 一人一证:同一身份证只能绑定一个账号。
  // 用指纹在【调用上游之前】判重 → 省付费配额。代价是「某证是否已注册」可被探测,
  // 但探测需先持完整身份证号,且受上面三层限流约束(每日默认 5 次)。
  const fp = idCardFingerprint(idcard, config.otpPepper);
  const boundByOther = db
    .prepare("SELECT id FROM users WHERE rn_hash=? AND rn_status='verified' AND id<>?")
    .get(fp, uid) as { id: number } | undefined;
  if (boundByOther) {
    logger.warn('realname_already_bound', { userId: uid });
    return res.status(409).json({ error: 'idcard_already_bound' });
  }

  let payload: any = null;
  try {
    const url = `${VENDOR_URL}?name=${encodeURIComponent(name)}&idcard=${encodeURIComponent(idcard)}`;
    const resp = await fetch(url, {
      method: 'GET',
      headers: { Authorization: `APPCODE ${config.realnameAppCode}` },
      signal: AbortSignal.timeout(config.realnameTimeoutMs),
    });
    payload = await resp.json().catch(() => null);
  } catch (e) {
    // ⚠️ 不打日志正文(可能含上游回显),只记错误类型
    logger.warn('realname_upstream_error', { userId: uid, err: String((e as Error)?.name || 'error') });
    return res.status(502).json({ error: 'upstream_error' });
  }

  const code = Number(payload?.code);
  const upstreamOk = payload?.success === true && code === 200;

  if (!upstreamOk) {
    const mapped = VENDOR_ERROR_MAP[code] || 'vendor_error';
    logger.warn('realname_rejected', { userId: uid, code, mapped });
    if (mapped === 'no_record') {
      const cur = statusPayload(uid);
      return res.json({ ok: true, ...cur, status: cur.verified ? 'verified' : 'no_record' });
    }
    // 不把服务商 msg 原文回显给客户端(可能含内部信息),只给语义化错误
    return res.status(400).json({ error: mapped });
  }

  const result = Number(payload?.data?.result);

  if (result === 0) {
    // 二要素一致 → 通过
    const now = Date.now();
    try {
      db.prepare(
        `UPDATE users SET rn_status='verified', rn_name_mask=?, rn_idcard_mask=?, rn_hash=?, rn_verified_at=?
         WHERE id=?`
      ).run(maskRealName(name), maskIdCard(idcard), fp, now, uid);
    } catch (e) {
      // 并发下同一身份证同时绑定两个账号 → 被部分唯一索引拦下
      const msg = String((e as Error)?.message || '');
      if (/UNIQUE|constraint/i.test(msg)) {
        logger.warn('realname_bound_race', { userId: uid });
        return res.status(409).json({ error: 'idcard_already_bound' });
      }
      throw e;
    }
    logger.info('realname_verified', { userId: uid });
    return res.json({ ok: true, ...statusPayload(uid) });
  }

  // result: 1 不一致 / 2 无记录 —— 不覆盖已有认证状态
  logger.info('realname_not_matched', { userId: uid, result });
  const cur = statusPayload(uid);
  return res.json({
    ok: true,
    ...cur,
    status: cur.verified ? 'verified' : result === 2 ? 'no_record' : 'mismatch',
  });
});
