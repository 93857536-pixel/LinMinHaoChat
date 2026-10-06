import { Router } from 'express';
import { db } from '../db.js';
import { newId } from '../crypto-util.js';
import { rateLimit, clientIp } from '../ratelimit.js';
import { authRequired } from '../middleware.js';
import { logger } from '../logger.js';

/**
 * 好友系统(双向关注):
 * - friendships(user_id, friend_id) 存一条即双向可见(查询用 user_id IN (me, X) 去重)
 * - 加好友为即时互加(无"好友申请-同意"两步;产品定位:小范围可信圈,双方都是登录用户)
 * - 搜索返回脱敏信息(handle + 掩码号码),不返回明文手机号/邮箱
 */
export const friendsRouter = Router();

friendsRouter.use(authRequired);

/** 我的人际关系列表(我的好友 + 我发出/收到的好友关系,统一去重) */
friendsRouter.get('/', (req, res) => {
  const me = req.user!.id;
  const rows = db.prepare(
    `SELECT u.id, u.handle, u.phone_masked, u.email_masked, f.created_at,
            CASE WHEN f.user_id = ? THEN 'mine' ELSE 'theirs' END AS initiator
     FROM friendships f
     JOIN users u ON u.id = (CASE WHEN f.user_id = ? THEN f.friend_id ELSE f.user_id END)
     WHERE (f.user_id = ? OR f.friend_id = ?) AND u.banned = 0
     ORDER BY f.created_at DESC`
  ).all(me, me, me, me) as {
    id: number; handle: string | null; phone_masked: string | null; email_masked: string | null;
    created_at: number; initiator: string;
  }[];
  res.json({
    ok: true,
    friends: rows.map((r) => ({
      userId: r.id,
      handle: r.handle ?? `user_${r.id}`,
      phoneMasked: r.phone_masked,
      emailMasked: r.email_masked,
      addedAt: r.created_at,
      initiator: r.initiator,
    })),
  });
});

/**
 * 搜索用户(handle 模糊 / 掩码号码后缀):
 *  - query 全数字且长度 >= 4 → 按 phone_masked 后缀匹配(脱敏号末 4 位可搜)
 *  - 否则 → handle 模糊匹配
 * 返回脱敏信息,最多 20 条;排除自己
 */
friendsRouter.get('/search', (req, res) => {
  const q = String(req.query.query || '').trim().replace(/[<>"']/g, '').slice(0, 64);
  if (q.length < 2) return res.status(400).json({ error: 'query_too_short' });
  const like = q.replace(/%/g, '\\%').replace(/_/g, '\\_');

  const usePhone = /^\d{4,}$/.test(q);
  const rows = usePhone
    ? db.prepare(
        `SELECT id, handle, phone_masked, email_masked FROM users
         WHERE banned = 0 AND phone_masked LIKE ? ESCAPE '\\'
           ORDER BY created_at DESC LIMIT 20`
      ).all(`%${like}%`)
    : db.prepare(
        `SELECT id, handle, phone_masked, email_masked FROM users
         WHERE banned = 0 AND handle LIKE ? ESCAPE '\\'
           ORDER BY created_at DESC LIMIT 20`
      ).all(`%${like}%`);

  const me = req.user!.id;
  res.json({
    ok: true,
    users: (rows as { id: number; handle: string | null; phone_masked: string | null; email_masked: string | null }[]).map((u) => ({
      userId: u.id,
      handle: u.handle ?? `user_${u.id}`,
      phoneMasked: u.phone_masked,
      emailMasked: u.email_masked,
      isFriend: !!db.prepare(
        'SELECT 1 FROM friendships WHERE (user_id=? AND friend_id=?) OR (user_id=? AND friend_id=?)'
      ).get(me, u.id, u.id, me),
    })),
  });
});

/** 添加好友(双向互加;幂等) */
friendsRouter.post('/', (req, res) => {
  const me = req.user!.id;
  const target = Number(req.body?.userId);
  if (!Number.isInteger(target) || target <= 0) return res.status(400).json({ error: 'bad_user' });
  if (target === me) return res.status(400).json({ error: 'self' });

  const targetRow = db.prepare('SELECT id, banned FROM users WHERE id=?').get(target) as
    | { id: number; banned: number } | undefined;
  if (!targetRow) return res.status(404).json({ error: 'user_not_found' });
  if (targetRow.banned) return res.status(403).json({ error: 'user_banned' });

  const rl = rateLimit(`friend:add:${me}`, 20, 3_600_000);
  if (!rl.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: rl.retryAfterSec });

  db.prepare('INSERT OR IGNORE INTO friendships (user_id, friend_id, created_at) VALUES (?,?,?)')
    .run(me, target, Date.now());
  logger.info('friend_added', { by: me, target });
  res.json({ ok: true });
});

/** 移除好友(幂等) */
friendsRouter.delete('/:userId', (req, res) => {
  const me = req.user!.id;
  const target = Number(req.params.userId);
  if (!Number.isInteger(target) || target <= 0) return res.status(400).json({ error: 'bad_user' });
  db.prepare(
    'DELETE FROM friendships WHERE (user_id=? AND friend_id=?) OR (user_id=? AND friend_id=?)'
  ).run(me, target, target, me);
  logger.info('friend_removed', { by: me, target });
  res.json({ ok: true });
});
