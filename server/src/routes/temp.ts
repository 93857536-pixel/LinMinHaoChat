import { Router } from 'express';
import crypto from 'node:crypto';
import { db } from '../db.js';
import { store } from '../storage.js';
import { newId, randomToken } from '../crypto-util.js';
import { rateLimit, clientIp } from '../ratelimit.js';
import { config } from '../config.js';
import { logger } from '../logger.js';

/**
 * 临时聊天(无需账号):
 * - 服务器只保存密文文件 + 元数据(roomId/时间/序号),没有密钥,无法解密
 * - 会话密钥在分享链接的 #fragment 中传递(不经过服务器,nginx/日志均不可见)
 * - 过期:创建后 7 天;超期后服务器继续保留密文归档,但新消息被拒绝
 * - 访问控制:房间 ID 即访问凭证,配合过期 + 消息数上限 + 限流
 */
export const tempRouter = Router();

const CIPHER_BODY_LIMIT = 64 * 1024;

interface MsgRow {
  id: string; room_id: string; kind: string; seq: number; sender_anon: string | null;
  cipher_path: string; iv: string; aad: string; ts: number; meta_enc: string | null;
}

function roomExists(id: string): { created_at: number; expires_at: number; status: string; msg_count: number; kind: string } | undefined {
  return db.prepare('SELECT created_at, expires_at, status, msg_count, kind FROM temp_rooms WHERE id=?').get(id) as
    | { created_at: number; expires_at: number; status: string; msg_count: number; kind: string } | undefined;
}

/** 创建临时房间 → roomId(密钥在 fragment,不由服务器生成) */
tempRouter.post('/rooms', (req, res) => {
  const ip = clientIp(req);
  const r = rateLimit(`temp:create:${ip}`, 10, 3600_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });

  const id = newId('t_');
  const now = Date.now();
  db.prepare('INSERT INTO temp_rooms (id, created_at, expires_at, last_activity, msg_count, status) VALUES (?,?,?,?,0,\'active\')')
    .run(id, now, now + config.tempRoomTtlMs, now);
  logger.info('temp_room_created', { roomId: id, ip });
  res.json({ ok: true, roomId: id, expiresAt: now + config.tempRoomTtlMs });
});

/** 获取临时房间元数据(用于加入前检查) */
tempRouter.get('/rooms/:id', (req, res) => {
  const room = roomExists(String(req.params.id));
  if (!room) return res.status(404).json({ error: 'not_found' });
  const expired = Date.now() > room.expires_at;
  res.json({
    ok: true,
    roomId: String(req.params.id),
    createdAt: room.created_at,
    expiresAt: room.expires_at,
    expired,
    status: room.status,
    messageCount: room.msg_count,
  });
});

/** 加入临时房间 → 颁发短期 WS 令牌(绑定 room + 匿名身份,5 分钟有效) */
tempRouter.post('/rooms/:id/join', (req, res) => {
  const ip = clientIp(req);
  const r = rateLimit(`temp:join:${ip}`, 30, 10 * 60_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });

  const room = roomExists(String(req.params.id));
  if (!room) return res.status(404).json({ error: 'not_found' });
  if (room.kind === 'invite') return res.status(403).json({ error: 'invite_required' });
  if (room.status !== 'active') return res.status(403).json({ error: 'room_banned' });
  if (Date.now() > room.expires_at) return res.status(403).json({ error: 'room_expired' });

  // 身份复用:客户端可携带自己此前的 anonId(本房间消息里出现过)则沿用,否则分配新编号
  // (防止 WS 断线重连/刷新后同一个人被当成多个访客)
  const claimed = String((req.body || {}).anonId || '').slice(0, 24);
  let anonId: string | null = null;
  if (claimed && /^[gu][A-Za-z0-9_-]*$/.test(claimed)) {
    const known = db.prepare('SELECT 1 FROM messages WHERE room_id=? AND sender_anon=? LIMIT 1').get(String(req.params.id), claimed);
    if (known) anonId = claimed;
  }
  if (anonId === null) {
    // 全局访客编号:房间内原子递增(g1/g2/g3...),所有客户端对同一人显示相同编号
    db.prepare('UPDATE temp_rooms SET guest_count=guest_count+1 WHERE id=?').run(String(req.params.id));
    const gc = db.prepare('SELECT guest_count FROM temp_rooms WHERE id=?').get(String(req.params.id)) as { guest_count: number };
    anonId = `g${gc.guest_count}`;
  }
  const wsToken = randomToken(24);
  const tokenHash = crypto.createHash('sha256').update(wsToken).digest('hex');
  db.prepare('INSERT INTO sessions (id, user_id, token_hash, created_at, expires_at, device) VALUES (?,?,?,?,?,?)')
    .run(wsToken, -1, tokenHash, Date.now(), Date.now() + 5 * 60_000, `temp:${String(req.params.id)}:${anonId}`);
  logger.info('temp_room_joined', { roomId: String(req.params.id), anonId, ip });
  res.json({ ok: true, anonId, wsToken, wsUrl: '/ws' });
});

/** 发送密文消息(客户端已加密;服务器只落盘 + 编号,不解密) */
tempRouter.post('/rooms/:id/messages', (req, res) => {
  const ip = clientIp(req);
  const r = rateLimit(`temp:msg:${ip}`, 60, 60_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });

  const roomId = String(req.params.id);
  const room = roomExists(roomId);
  if (!room) return res.status(404).json({ error: 'not_found' });
  if (room.status !== 'active') return res.status(403).json({ error: 'room_banned' });
  if (Date.now() > room.expires_at) return res.status(403).json({ error: 'room_expired' });
  if (room.msg_count >= config.tempRoomMaxMessages) return res.status(403).json({ error: 'room_full' });

  const { iv, cipher, seq: clientSeq, ts: clientTs } = req.body || {};
  if (typeof iv !== 'string' || iv.length > 64) return res.status(400).json({ error: 'bad_iv' });
  if (typeof cipher !== 'string' || cipher.length < 8 || cipher.length > CIPHER_BODY_LIMIT) {
    return res.status(400).json({ error: 'bad_cipher' });
  }
  const metaEnc = typeof req.body?.meta === 'string' && req.body.meta.length <= 1024 ? req.body.meta : null;

  // AAD 绑定 seq:客户端必须用服务器下一个序号加密;并发冲突时返回最新 seq 供重试
  const expectedSeq = room.msg_count + 1;
  if (Number(clientSeq) !== expectedSeq) {
    return res.status(409).json({ error: 'seq_conflict', seq: expectedSeq });
  }
  const seq = expectedSeq;
  // 使用客户端加密时的时间戳作为 AAD 的一部分(接收方用同一 ts 解密);校验合理性防滥用
  const now = Number(clientTs);
  if (!Number.isInteger(now) || now <= 0 || Math.abs(now - Date.now()) > 30 * 60_000) {
    return res.status(400).json({ error: 'bad_ts' });
  }
  const aad = `${roomId}:${seq}:${now}`;
  const rel = store.saveMessageCipher(roomId, seq, Buffer.from(cipher, 'utf8'));
  const id = newId('m_');
  db.prepare('INSERT INTO messages (id, room_id, kind, seq, sender_anon, cipher_path, iv, aad, meta_enc, ts) VALUES (?,?,?,?,?,?,?,?,?,?)')
    .run(id, roomId, 'msg', seq, String(req.body?.anonId || '').slice(0, 24) || null, rel, iv, aad, metaEnc, now);
  db.prepare('UPDATE temp_rooms SET msg_count=?, last_activity=? WHERE id=?').run(seq, now, roomId);

  broadcast(roomId, { type: 'msg', roomId, seq, id, anonId: String(req.body?.anonId || '').slice(0, 24) || null, ts: now });
  res.json({ ok: true, seq, id, ts: now });
});

/** 拉取历史密文(分页,新→旧可逆序拉取) */
tempRouter.get('/rooms/:id/messages', (req, res) => {
  const roomId = String(req.params.id);
  const room = roomExists(roomId);
  if (!room) return res.status(404).json({ error: 'not_found' });

  const after = Number(req.query.afterSeq || 0);
  const before = Number(req.query.beforeSeq || 0);
  const limit = Math.min(Math.max(Number(req.query.limit || 100), 1), 500);
  const ip = clientIp(req);
  const r = rateLimit(`temp:read:${ip}`, 120, 60_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });

  let rows: MsgRow[];
  if (before > 0) {
    rows = db.prepare('SELECT * FROM messages WHERE room_id=? AND seq<? ORDER BY seq DESC LIMIT ?').all(roomId, before, limit) as MsgRow[];
    rows.reverse();
  } else {
    rows = db.prepare('SELECT * FROM messages WHERE room_id=? AND seq>? ORDER BY seq ASC LIMIT ?').all(roomId, after, limit) as MsgRow[];
  }
  const out = rows.map((m) => ({
    id: m.id, seq: m.seq, anonId: m.sender_anon, ts: m.ts, iv: m.iv, aad: m.aad, meta: m.meta_enc,
    cipher: store.readCipher(m.cipher_path).toString('utf8'),
  }));
  res.json({ ok: true, messages: out, hasMore: rows.length === limit });
});

/** 退出(客户端销毁本地状态;服务器保留密文归档) */
tempRouter.post('/rooms/:id/leave', (req, res) => {
  const room = roomExists(String(req.params.id));
  if (!room) return res.status(404).json({ error: 'not_found' });
  logger.info('temp_room_left', { roomId: String(req.params.id) });
  res.json({ ok: true, note: 'server archive retained' });
});

// ---- WS 广播(由 ws.ts 注册) ----
type BroadcastFn = (roomId: string, payload: unknown) => void;
let broadcast: BroadcastFn = () => {};
export function setTempBroadcast(fn: BroadcastFn) { broadcast = fn; }
