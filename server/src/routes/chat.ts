import { Router } from 'express';
import { db } from '../db.js';
import { store } from '../storage.js';
import { newId } from '../crypto-util.js';
import { rateLimit, clientIp } from '../ratelimit.js';
import { authRequired } from '../middleware.js';
import { config } from '../config.js';
import { logger } from '../logger.js';

/**
 * 账号聊天:
 * - 会话密钥由客户端生成,用成员公钥 ECDH 包装后经服务器分发(room_keys.wrapped_key)
 * - 消息明文永远只在客户端;服务器保存密文文件 + 元数据(seq/时间/已读)
 * - 已读状态是纯元数据(消息 seq 级),不含明文内容
 */
export const chatRouter = Router();

chatRouter.use(authRequired);

interface MsgRow {
  id: string; room_id: string; kind: string; seq: number; sender_user_id: number | null;
  sender_anon: string | null; cipher_path: string; iv: string; aad: string; meta_enc: string | null; ts: number;
}

function isMember(roomId: string, userId: number): boolean {
  return !!db.prepare('SELECT 1 FROM room_members WHERE room_id=? AND user_id=?').get(roomId, userId);
}

function roomMeta(roomId: string, userId: number) {
  const room = db.prepare('SELECT id, type, name_enc, created_at, archived FROM rooms WHERE id=?').get(roomId) as
    | { id: string; type: string; name_enc: string | null; created_at: number; archived: number } | undefined;
  if (!room || room.archived) return null;
  if (!isMember(roomId, userId)) return null;
  const memberIds = (db.prepare('SELECT user_id FROM room_members WHERE room_id=?').all(roomId) as { user_id: number }[]).map((m) => m.user_id);
  const lastSeq = (db.prepare('SELECT COALESCE(MAX(seq),0) AS s FROM messages WHERE room_id=?').get(roomId) as { s: number }).s;
  const read = (db.prepare('SELECT last_read_seq FROM room_members WHERE room_id=? AND user_id=?').get(roomId, userId) as { last_read_seq: number }).last_read_seq;
  return {
    id: room.id, type: room.type, nameEnc: room.name_enc, createdAt: room.created_at,
    memberIds, unread: Math.max(0, lastSeq - read), lastSeq,
  };
}

/** 我的房间列表 */
chatRouter.get('/rooms', (req, res) => {
  const rows = db.prepare('SELECT room_id FROM room_members WHERE user_id=?').all(req.user!.id) as { room_id: string }[];
  const rooms = rows.map((r) => roomMeta(r.room_id, req.user!.id)).filter(Boolean);
  res.json({ ok: true, rooms });
});

/** 创建会话(dm/group)。wrappedKeys: [{userId, deviceId, wrappedKey}] */
chatRouter.post('/rooms', (req, res) => {
  const { type, memberIds, nameEnc, wrappedKeys } = req.body || {};
  if (type !== 'dm' && type !== 'group') return res.status(400).json({ error: 'bad_type' });
  if (!Array.isArray(memberIds)) return res.status(400).json({ error: 'bad_members' });
  const members = [...new Set([req.user!.id, ...memberIds.map(Number).filter((n) => Number.isInteger(n) && n > 0)])];
  if (members.length < 2) return res.status(400).json({ error: 'need_member' });
  if (members.length > 50) return res.status(400).json({ error: 'too_many_members' });
  if (!Array.isArray(wrappedKeys) || wrappedKeys.length === 0) return res.status(400).json({ error: 'missing_keys' });

  const now = Date.now();
  let roomId: string;
  if (type === 'dm' && members.length === 2) {
    // 私聊幂等:已存在则复用
    const existing = db.prepare(
      `SELECT r.id FROM rooms r JOIN room_members a ON a.room_id=r.id AND a.user_id=?
       JOIN room_members b ON b.room_id=r.id AND b.user_id=?
       WHERE r.type='dm' AND (SELECT COUNT(*) FROM room_members WHERE room_id=r.id)=2`
    ).get(members[0], members[1]) as { id: string } | undefined;
    roomId = existing?.id || newId('r_');
  } else {
    roomId = newId('r_');
  }
  db.prepare('INSERT OR IGNORE INTO rooms (id, type, name_enc, created_by, created_at) VALUES (?,?,?,?,?)')
    .run(roomId, type, typeof nameEnc === 'string' && nameEnc.length <= 2048 ? nameEnc : null, req.user!.id, now);
  for (const m of members) {
    db.prepare('INSERT OR IGNORE INTO room_members (room_id, user_id, joined_at) VALUES (?,?,?)').run(roomId, m, now);
  }
  // 存 wrapped keys(每成员每设备)
  const ins = db.prepare('INSERT OR REPLACE INTO room_keys (room_id, member_user_id, device_id, wrapped_key) VALUES (?,?,?,?)');
  const tx = db.transaction(() => {
    for (const wk of wrappedKeys) {
      const uid = Number(wk.userId);
      if (!Number.isInteger(uid) || !members.includes(uid)) continue;
      const dev = String(wk.deviceId || 'default').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64) || 'default';
      const key = String(wk.wrappedKey || '');
      if (key.length > 4096) continue;
      ins.run(roomId, uid, dev, key);
    }
  });
  tx();
  logger.info('room_created', { roomId, type, by: req.user!.id, members: members.length });
  res.json({ ok: true, room: roomMeta(roomId, req.user!.id) });
});

/** 会话详情(成员校验) */
chatRouter.get('/rooms/:id', (req, res) => {
  const room = roomMeta(String(req.params.id), req.user!.id);
  if (!room) return res.status(404).json({ error: 'not_found' });
  res.json({ ok: true, room });
});

/** 拉取会话密钥包(仅返回"我的" wrapped keys,不含他人) */
chatRouter.get('/rooms/:id/keys', (req, res) => {
  const roomId = String(req.params.id);
  if (!isMember(roomId, req.user!.id)) return res.status(404).json({ error: 'not_found' });
  const dev = String(req.query.deviceId || 'default').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64) || 'default';
  const rows = db.prepare('SELECT wrapped_key FROM room_keys WHERE room_id=? AND member_user_id=? AND device_id=?')
    .all(roomId, req.user!.id, dev) as { wrapped_key: string }[];
  res.json({ ok: true, keys: rows.map((r) => r.wrapped_key) });
});

/** 追加 wrapped key(群聊邀请新成员 / 新设备加入时,由成员上传) */
chatRouter.post('/rooms/:id/keys', (req, res) => {
  const roomId = String(req.params.id);
  if (!isMember(roomId, req.user!.id)) return res.status(404).json({ error: 'not_found' });
  const { userId, deviceId, wrappedKey } = req.body || {};
  const uid = Number(userId);
  if (!Number.isInteger(uid) || uid <= 0) return res.status(400).json({ error: 'bad_user' });
  const key = String(wrappedKey || '');
  if (key.length < 8 || key.length > 4096) return res.status(400).json({ error: 'bad_key' });
  const dev = String(deviceId || 'default').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64) || 'default';
  // 新成员必须先在成员表(群聊邀请流程:创建者先调 /rooms/:id/add-member)
  db.prepare('INSERT OR REPLACE INTO room_keys (room_id, member_user_id, device_id, wrapped_key) VALUES (?,?,?,?)')
    .run(roomId, uid, dev, key);
  logger.info('room_key_added', { roomId, for: uid, by: req.user!.id });
  res.json({ ok: true });
});

/** 群聊添加成员(创建者或现有成员,配合 wrapped key 上传) */
chatRouter.post('/rooms/:id/add-member', (req, res) => {
  const roomId = String(req.params.id);
  if (!isMember(roomId, req.user!.id)) return res.status(404).json({ error: 'not_found' });
  const { userId } = req.body || {};
  const uid = Number(userId);
  if (!Number.isInteger(uid) || uid <= 0) return res.status(400).json({ error: 'bad_user' });
  const exists = db.prepare('SELECT 1 FROM users WHERE id=?').get(uid);
  if (!exists) return res.status(404).json({ error: 'user_not_found' });
  db.prepare('INSERT OR IGNORE INTO room_members (room_id, user_id, joined_at) VALUES (?,?,?)').run(roomId, uid, Date.now());
  logger.info('room_member_added', { roomId, userId: uid, by: req.user!.id });
  res.json({ ok: true });
});

/** 发送密文消息 */
chatRouter.post('/rooms/:id/messages', (req, res) => {
  const ip = clientIp(req);
  const r = rateLimit(`chat:msg:${ip}`, 60, 60_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });

  const roomId = String(req.params.id);
  if (!isMember(roomId, req.user!.id)) return res.status(404).json({ error: 'not_found' });
  const { iv, cipher, kind, meta, seq: clientSeq, ts: clientTs } = req.body || {};
  if (typeof iv !== 'string' || iv.length > 64) return res.status(400).json({ error: 'bad_iv' });
  if (typeof cipher !== 'string' || cipher.length < 8 || cipher.length > config.maxBodyBytes) {
    return res.status(400).json({ error: 'bad_cipher' });
  }
  const k = kind === 'attachment' ? 'attachment' : 'msg';
  const metaEnc = typeof meta === 'string' && meta.length <= 1024 ? meta : null;

  // 使用客户端加密时的时间戳作为 AAD 的一部分(接收方用同一 ts 解密);校验合理性防滥用
  const now = Number(clientTs);
  if (!Number.isInteger(now) || now <= 0 || Math.abs(now - Date.now()) > 30 * 60_000) {
    return res.status(400).json({ error: 'bad_ts' });
  }
  const expectedSeq = (db.prepare('SELECT COALESCE(MAX(seq),0) AS s FROM messages WHERE room_id=?').get(roomId) as { s: number }).s + 1;
  if (Number(clientSeq) !== expectedSeq) {
    return res.status(409).json({ error: 'seq_conflict', seq: expectedSeq });
  }
  const seq = expectedSeq;
  const aad = `${roomId}:${seq}:${now}`;
  const rel = store.saveMessageCipher(roomId, seq, Buffer.from(cipher, 'utf8'));
  const id = newId('m_');
  db.prepare('INSERT INTO messages (id, room_id, kind, seq, sender_user_id, cipher_path, iv, aad, meta_enc, ts) VALUES (?,?,?,?,?,?,?,?,?,?)')
    .run(id, roomId, k, seq, req.user!.id, rel, iv, aad, metaEnc, now);

  broadcast(roomId, {
    type: 'msg', roomId, seq, id, senderId: req.user!.id, ts: now, kind: k,
  });
  res.json({ ok: true, seq, id, ts: now });
});

/** 拉取历史密文(分页) */
chatRouter.get('/rooms/:id/messages', (req, res) => {
  const roomId = String(req.params.id);
  if (!isMember(roomId, req.user!.id)) return res.status(404).json({ error: 'not_found' });
  const ip = clientIp(req);
  const r = rateLimit(`chat:read:${ip}`, 120, 60_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });

  const after = Number(req.query.afterSeq || 0);
  const before = Number(req.query.beforeSeq || 0);
  const limit = Math.min(Math.max(Number(req.query.limit || 100), 1), 500);
  let rows: MsgRow[];
  if (before > 0) {
    rows = db.prepare('SELECT * FROM messages WHERE room_id=? AND seq<? ORDER BY seq DESC LIMIT ?').all(roomId, before, limit) as MsgRow[];
    rows.reverse();
  } else {
    rows = db.prepare('SELECT * FROM messages WHERE room_id=? AND seq>? ORDER BY seq ASC LIMIT ?').all(roomId, after, limit) as MsgRow[];
  }
  const out = rows.map((m) => ({
    id: m.id, seq: m.seq, senderId: m.sender_user_id, ts: m.ts, iv: m.iv, aad: m.aad,
    kind: m.kind, meta: m.meta_enc,
    cipher: store.readCipher(m.cipher_path).toString('utf8'),
  }));
  res.json({ ok: true, messages: out, hasMore: rows.length === limit });
});

/** 已读回执(元数据) */
chatRouter.post('/rooms/:id/read', (req, res) => {
  const roomId = String(req.params.id);
  if (!isMember(roomId, req.user!.id)) return res.status(404).json({ error: 'not_found' });
  const lastSeq = Number(req.body?.lastSeq || 0);
  if (!Number.isInteger(lastSeq) || lastSeq < 0) return res.status(400).json({ error: 'bad_seq' });
  db.prepare('UPDATE room_members SET last_read_seq=? WHERE room_id=? AND user_id=?')
    .run(Math.max(lastSeq, 0), roomId, req.user!.id);
  broadcast(roomId, { type: 'read', roomId, userId: req.user!.id, lastSeq });
  res.json({ ok: true });
});

/** 在线成员列表 */
chatRouter.get('/rooms/:id/online', (req, res) => {
  const roomId = String(req.params.id);
  if (!isMember(roomId, req.user!.id)) return res.status(404).json({ error: 'not_found' });
  res.json({ ok: true, online: onlineMembers(roomId) });
});

type BroadcastFn = (roomId: string, payload: unknown) => void;
let broadcast: BroadcastFn = () => {};
export function setChatBroadcast(fn: BroadcastFn) { broadcast = fn; }

type OnlineFn = (roomId: string) => number[];
let onlineMembers: OnlineFn = () => [];
export function setOnlineMembers(fn: OnlineFn) { onlineMembers = fn; }
