import { Router } from 'express';
import crypto from 'node:crypto';
import { jwtVerify } from 'jose';
import { db } from '../db.js';
import { otpHmac, newId, randomToken } from '../crypto-util.js';
import { rateLimit, clientIp } from '../ratelimit.js';
import { config } from '../config.js';
import { logger } from '../logger.js';

/**
 * 邀请聊天(链接 + 验证码):
 * - 创建者生成一个邀请房间 + 6 位验证码,分享「链接 + 验证码」给朋友
 * - 朋友打开链接,输入验证码校验通过后进入聊天
 * - 可以选「账号身份进入」(登录)或「游客身份进入」(不登录)
 * - 房间长效(1 年),聊天记录保留;密文归档与临时聊天一致,服务器不解密
 * - 密钥在分享链接 #fragment 传递(不经过服务器)
 */
export const inviteRouter = Router();

interface InviteRow {
  id: string;
  room_id: string;
  code_hash: string;
  created_at: number;
  expires_at: number;
  attempts: number;
  used: number;
}

function getInvite(id: string): InviteRow | undefined {
  return db.prepare('SELECT * FROM invite_rooms WHERE id=?').get(id) as InviteRow | undefined;
}

function roomExists(id: string): { created_at: number; expires_at: number; status: string; msg_count: number; kind: string } | undefined {
  return db.prepare('SELECT created_at, expires_at, status, msg_count, kind FROM temp_rooms WHERE id=?').get(id) as
    | { created_at: number; expires_at: number; status: string; msg_count: number; kind: string } | undefined;
}

/** 生成 6 位数字验证码 */
function genCode(): string {
  return String(crypto.randomInt(0, 1_000_000)).padStart(6, '0');
}

/**
 * 创建邀请聊天:
 * - 创建长效 temp 房间(kind='invite',1 年过期,保留记录)
 * - 生成 6 位验证码(只存 HMAC,不落明文)
 */
inviteRouter.post('/create', (req, res) => {
  const ip = clientIp(req);
  const r = rateLimit(`invite:create:${ip}`, 20, 3600_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });

  const roomId = newId('i_');
  const now = Date.now();
  const roomExp = now + config.inviteRoomTtlMs;

  // 创建长效房间(kind='invite')
  db.prepare('INSERT INTO temp_rooms (id, created_at, expires_at, last_activity, msg_count, status, kind) VALUES (?,?,?,?,0,\'active\',\'invite\')')
    .run(roomId, now, roomExp, now);

  // 生成验证码
  const code = genCode();
  const inviteId = newId('v_');
  const codeExp = now + config.inviteCodeTtlMs;
  db.prepare('INSERT INTO invite_rooms (id, room_id, code_hash, created_at, expires_at) VALUES (?,?,?,?,?)')
    .run(inviteId, roomId, otpHmac(code), now, codeExp);

  logger.info('invite_created', { inviteId, roomId, ip });
  res.json({
    ok: true,
    inviteId,
    roomId,
    code,
    expiresAt: roomExp,
    codeExpiresAt: codeExp,
    // 分享链接:不带密钥 fragment,由客户端追加 #k=<sessionKey>
    link: `/i/${inviteId}`,
  });
});

/** 邀请信息(用于打开链接后检查房间状态) */
inviteRouter.get('/:id', (req, res) => {
  const inv = getInvite(String(req.params.id));
  if (!inv) return res.status(404).json({ error: 'not_found' });
  const room = roomExists(inv.room_id);
  if (!room) return res.status(404).json({ error: 'room_not_found' });

  const codeExpired = Date.now() > inv.expires_at;
  const roomExpired = Date.now() > room.expires_at;
  res.json({
    ok: true,
    inviteId: inv.id,
    roomId: inv.room_id,
    codeExpired,
    roomExpired,
    roomStatus: room.status,
    messageCount: room.msg_count,
    roomKind: room.kind,
  });
});

/**
 * 校验验证码 + 加入房间(游客或账号身份):
 * - body: { code, token? } token 为可选 JWT(账号身份进入)
 * - 校验通过后颁发短期 WS 令牌(绑定 room + 身份)
 */
inviteRouter.post('/:id/join', async (req, res) => {
  const ip = clientIp(req);
  const r = rateLimit(`invite:join:${ip}`, 30, 10 * 60_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });

  const inv = getInvite(String(req.params.id));
  if (!inv) return res.status(404).json({ error: 'not_found' });
  const room = roomExists(inv.room_id);
  if (!room) return res.status(404).json({ error: 'room_not_found' });
  if (room.status !== 'active') return res.status(403).json({ error: 'room_banned' });
  if (Date.now() > room.expires_at) return res.status(403).json({ error: 'room_expired' });
  if (Date.now() > inv.expires_at) return res.status(403).json({ error: 'code_expired' });

  // 验证码校验(恒定时间比较;防爆破)
  const code = String((req.body || {}).code || '');
  if (!/^\d{6}$/.test(code)) return res.status(400).json({ error: 'bad_code' });
  if (inv.attempts >= config.inviteMaxAttempts) {
    return res.status(429).json({ error: 'too_many_attempts', retryAfterSec: 3600 });
  }
  const a = Buffer.from(otpHmac(code), 'hex');
  const b = Buffer.from(inv.code_hash, 'hex');
  const match = a.length === b.length && crypto.timingSafeEqual(a, b);
  if (!match) {
    db.prepare('UPDATE invite_rooms SET attempts=attempts+1 WHERE id=?').run(inv.id);
    return res.status(401).json({ error: 'invalid_code' });
  }
  db.prepare('UPDATE invite_rooms SET attempts=0 WHERE id=?').run(inv.id);

  // 身份:可选 JWT → 账号身份;否则游客
  let userId: number | null = null;
  let displayName = '';
  const token = String((req.body || {}).token || '');
  if (token) {
    // 手动验证 JWT(账号身份进入)
    try {
      const enc = new TextEncoder();
      const { payload } = await jwtVerify(token, enc.encode(config.jwtSecret));
      if (payload.role === 'user') {
        const uid = Number(payload.sub);
        const user = db.prepare('SELECT handle, banned FROM users WHERE id=?').get(uid) as
          | { handle: string | null; banned: number } | undefined;
        if (user && !user.banned) {
          userId = uid;
          displayName = user.handle || `用户${uid}`;
        }
      }
    } catch { /* 无效 token 则降级为游客 */ }
  }

  // 身份标识:账号用户 u{id}(全局稳定);游客 g{房间内原子递增编号}(全局一致)
  let anonId = '';
  if (userId !== null) {
    anonId = `u${userId}`;
  } else {
    // 身份复用:携带此前 anonId(本房间消息里出现过)则沿用,防重连/刷新变新访客
    const claimed = String((req.body || {}).anonId || '').slice(0, 24);
    if (claimed && /^[gu][A-Za-z0-9_-]*$/.test(claimed)) {
      const known = db.prepare('SELECT 1 FROM messages WHERE room_id=? AND sender_anon=? LIMIT 1').get(inv.room_id, claimed);
      if (known) anonId = claimed;
    }
    if (!anonId) {
      db.prepare('UPDATE temp_rooms SET guest_count=guest_count+1 WHERE id=?').run(inv.room_id);
      const gc = db.prepare('SELECT guest_count FROM temp_rooms WHERE id=?').get(inv.room_id) as { guest_count: number };
      anonId = `g${gc.guest_count}`;
    }
  }
  const display = displayName || (userId !== null ? `用户${userId}` : `游客${anonId}`);

  // 颁发短期 WS 令牌(sessions 表,temp: 前缀;带身份信息)
  const wsToken = randomToken(24);
  const tokenHash = crypto.createHash('sha256').update(wsToken).digest('hex');
  const device = userId !== null
    ? `temp:${inv.room_id}:${anonId}:user:${userId}`
    : `temp:${inv.room_id}:${anonId}`;
  db.prepare('INSERT INTO sessions (id, user_id, token_hash, created_at, expires_at, device) VALUES (?,?,?,?,?,?)')
    .run(wsToken, userId ?? -1, tokenHash, Date.now(), Date.now() + 5 * 60_000, device);

  logger.info('invite_joined', { inviteId: inv.id, roomId: inv.room_id, userId, ip });
  res.json({ ok: true, roomId: inv.room_id, anonId, displayName: display, wsToken, wsUrl: '/ws' });
});

/** 获取邀请房间的聊天记录(验证码通过后由客户端持有 roomId 走 temp API,此接口用于展示房间信息) */
inviteRouter.get('/:id/room', (req, res) => {
  const inv = getInvite(String(req.params.id));
  if (!inv) return res.status(404).json({ error: 'not_found' });
  const room = roomExists(inv.room_id);
  if (!room) return res.status(404).json({ error: 'room_not_found' });
  res.json({
    ok: true,
    roomId: inv.room_id,
    createdAt: room.created_at,
    expiresAt: room.expires_at,
    expired: Date.now() > room.expires_at,
    messageCount: room.msg_count,
  });
});
