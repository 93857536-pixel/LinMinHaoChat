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
  // ⚠️ 目标必须是本房间成员:否则任意成员可给任意账号/设备写入或覆盖密钥包
  // (INSERT OR REPLACE 会覆盖他人已上传的 wrapped key → 密钥包篡改/DoS)
  if (!isMember(roomId, uid)) return res.status(403).json({ error: 'target_not_member' });
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
  // 仅创建者可添加成员
  const room = db.prepare('SELECT created_by FROM rooms WHERE id=?').get(roomId) as { created_by: number } | undefined;
  if (!room || room.created_by !== req.user!.id) return res.status(403).json({ error: 'not_creator' });
  const existing = db.prepare('SELECT 1 FROM room_members WHERE room_id=? AND user_id=?').get(roomId, uid);
  if (existing) return res.status(409).json({ error: 'already_member' });
  db.prepare('INSERT OR IGNORE INTO room_members (room_id, user_id, joined_at) VALUES (?,?,?)').run(roomId, uid, Date.now());
  logger.info('room_member_added', { roomId, userId: uid, by: req.user!.id });
  res.json({ ok: true });
});

/** 获取房间成员列表(仅创建者可管理) */
chatRouter.get('/rooms/:id/members', (req, res) => {
  const roomId = String(req.params.id);
  if (!isMember(roomId, req.user!.id)) return res.status(404).json({ error: 'not_found' });
  const room = db.prepare('SELECT created_by FROM rooms WHERE id=?').get(roomId) as { created_by: number } | undefined;
  if (!room) return res.status(404).json({ error: 'not_found' });
  // 仅创建者可见完整成员列表
  const isCreator = room.created_by === req.user!.id;
  const rows = db.prepare('SELECT rm.user_id, u.handle, u.nickname, u.avatar_mime, u.avatar_updated_at, rm.joined_at FROM room_members rm JOIN users u ON u.id = rm.user_id WHERE rm.room_id=? ORDER BY rm.joined_at ASC').all(roomId) as { user_id: number; handle: string; nickname: string | null; avatar_mime: string | null; avatar_updated_at: number | null; joined_at: number }[];
  const members = rows.map(r => ({
    userId: r.user_id,
    handle: isCreator ? r.handle : null,
    nickname: isCreator ? (r.nickname ?? r.handle) : null,
    hasAvatar: isCreator ? !!r.avatar_mime : false,
    avatarUpdatedAt: isCreator ? r.avatar_updated_at : null,
    joinedAt: r.joined_at,
    isCreator: r.user_id === room.created_by
  }));
  res.json({ ok: true, members, isCreator });
});

/** 移除成员(仅创建者可操作) */
chatRouter.delete('/rooms/:id/members/:userId', (req, res) => {
  const roomId = String(req.params.id);
  const targetId = Number(req.params.userId);
  if (!isMember(roomId, req.user!.id)) return res.status(404).json({ error: 'not_found' });
  const room = db.prepare('SELECT created_by FROM rooms WHERE id=?').get(roomId) as { created_by: number } | undefined;
  if (!room || room.created_by !== req.user!.id) return res.status(403).json({ error: 'not_creator' });
  if (targetId === req.user!.id) return res.status(400).json({ error: 'cannot_remove_self' });
  const result = db.prepare('DELETE FROM room_members WHERE room_id=? AND user_id=?').run(roomId, targetId);
  if (result.changes === 0) return res.status(404).json({ error: 'member_not_found' });
  db.prepare('DELETE FROM room_keys WHERE room_id=? AND member_user_id=?').run(roomId, targetId);
  logger.info('room_member_removed', { roomId, userId: targetId, by: req.user!.id });
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

/** 转发消息:从源房间复制到目标房间(重新加密) */
chatRouter.post('/rooms/:id/forward', (req, res) => {
  const targetRoomId = String(req.params.id);
  if (!isMember(targetRoomId, req.user!.id)) return res.status(404).json({ error: 'not_found' });
  const { sourceMsgId, srcRoomId, cipher, iv, kind, meta, ts: clientTs } = req.body || {};
  
  // 校验源消息存在且可访问
  if (!sourceMsgId || !srcRoomId || !cipher || !iv) {
    return res.status(400).json({ error: 'missing_fields' });
  }
  
  const srcRoom = db.prepare('SELECT id FROM rooms WHERE id=?').get(srcRoomId);
  if (!srcRoom) return res.status(404).json({ error: 'source_room_not_found' });

  // ⚠️ 调用者必须同时是「源房间」成员:否则可借 404/200 差异探测任意消息是否存在
  if (!isMember(srcRoomId, req.user!.id)) return res.status(404).json({ error: 'source_room_not_found' });

  const srcMsg = db.prepare('SELECT id, kind, seq, ts, cipher_path, meta_enc FROM messages WHERE id=? AND room_id=?').get(sourceMsgId, srcRoomId) as MsgRow | undefined;
  if (!srcMsg) return res.status(404).json({ error: 'source_msg_not_found' });

  // 密文/IV 形状校验(与 /messages 一致,防非法值落库)
  if (typeof iv !== 'string' || iv.length > 64) return res.status(400).json({ error: 'bad_iv' });
  if (typeof cipher !== 'string' || cipher.length < 8) return res.status(400).json({ error: 'bad_cipher' });
  
  // 校验时间戳
  const now = Number(clientTs);
  if (!Number.isInteger(now) || now <= 0 || Math.abs(now - Date.now()) > 30 * 60_000) {
    return res.status(400).json({ error: 'bad_ts' });
  }
  
  // 校验密文长度
  if (cipher.length > config.maxBodyBytes) {
    return res.status(400).json({ error: 'cipher_too_large' });
  }
  
  // 获取目标房间当前 seq
  const expectedSeq = (db.prepare('SELECT COALESCE(MAX(seq),0) AS s FROM messages WHERE room_id=?').get(targetRoomId) as { s: number }).s + 1;
  
  // 存储密文
  const rel = store.saveMessageCipher(targetRoomId, expectedSeq, Buffer.from(cipher, 'utf8'));
  const id = newId('m_');
  const metaEnc = typeof meta === 'string' && meta.length <= 1024 ? meta : null;
  const aad = `${targetRoomId}:${expectedSeq}:${now}`;
  
  db.prepare('INSERT INTO messages (id, room_id, kind, seq, sender_user_id, cipher_path, iv, aad, meta_enc, ts) VALUES (?,?,?,?,?,?,?,?,?,?)')
    .run(id, targetRoomId, kind || 'msg', expectedSeq, req.user!.id, rel, iv, aad, metaEnc, now);
  
  broadcast(targetRoomId, {
    type: 'msg', roomId: targetRoomId, seq: expectedSeq, id, senderId: req.user!.id, ts: now, kind: kind || 'msg',
  });
  
  logger.info('msg_forwarded', { from: srcRoomId, to: targetRoomId, msgId: sourceMsgId, seq: expectedSeq });
  res.json({ ok: true, seq: expectedSeq, id, ts: now });
});

type BroadcastFn = (roomId: string, payload: unknown) => void;
let broadcast: BroadcastFn = () => {};
export function setChatBroadcast(fn: BroadcastFn) { broadcast = fn; }

/** 收藏消息 */
chatRouter.post('/messages/:msgId/star', (req, res) => {
  const msgId = String(req.params.msgId);
  const msg = db.prepare('SELECT id, room_id, seq, ts FROM messages WHERE id=?').get(msgId) as MsgRow | undefined;
  if (!msg) return res.status(404).json({ error: 'not_found' });
  if (!isMember(msg.room_id, req.user!.id)) return res.status(403).json({ error: 'not_member' });
  
  const existing = db.prepare('SELECT 1 FROM user_starred_messages WHERE user_id=? AND msg_id=?').get(req.user!.id, msgId);
  if (existing) return res.status(409).json({ error: 'already_starred' });
  
  db.prepare('INSERT INTO user_starred_messages (user_id, room_id, msg_id, seq, ts, created_at) VALUES (?,?,?,?,?,?)')
    .run(req.user!.id, msg.room_id, msgId, msg.seq, msg.ts, Date.now());
  
  logger.info('message_starred', { msgId, roomId: msg.room_id, userId: req.user!.id });
  res.json({ ok: true });
});

/** 取消收藏 */
chatRouter.delete('/messages/:msgId/star', (req, res) => {
  const msgId = String(req.params.msgId);
  const result = db.prepare('DELETE FROM user_starred_messages WHERE user_id=? AND msg_id=?')
    .run(req.user!.id, msgId);
  if (result.changes === 0) return res.status(404).json({ error: 'not_found' });
  res.json({ ok: true });
});

/** 我的收藏列表 */
chatRouter.get('/starred', (req, res) => {
  const rows = db.prepare(`
    SELECT s.room_id, s.msg_id, s.seq, s.ts, m.kind, m.meta_enc, m.cipher_path, m.iv
    FROM user_starred_messages s
    JOIN messages m ON m.id = s.msg_id
    WHERE s.user_id = ?
    ORDER BY s.created_at DESC
    LIMIT 100
  `).all(req.user!.id) as (MsgRow & { room_id: string; msg_id: string; seq: number; ts: number; kind: string; meta_enc: string | null; cipher_path: string; iv: string })[];
  
  const result = rows.map(r => ({
    msgId: r.msg_id,
    roomId: r.room_id,
    seq: r.seq,
    ts: r.ts,
    kind: r.kind,
    metaEnc: r.meta_enc,
    iv: r.iv
    // 不返回 cipherPath:服务器内部相对路径,客户端取正文走各自房间的历史接口
  }));
  
  res.json({ ok: true, starred: result });
});

type OnlineFn = (roomId: string) => number[];
let onlineMembers: OnlineFn = () => [];
export function setOnlineMembers(fn: OnlineFn) { onlineMembers = fn; }

/** 退出房间 */
chatRouter.post('/rooms/:id/leave', (req, res) => {
  const roomId = String(req.params.id);
  if (!isMember(roomId, req.user!.id)) return res.status(404).json({ error: 'not_found' });
  const room = db.prepare('SELECT created_by FROM rooms WHERE id=?').get(roomId) as { created_by: number } | undefined;
  if (room && room.created_by === req.user!.id) return res.status(400).json({ error: 'creator_cannot_leave' });
  const result = db.prepare('DELETE FROM room_members WHERE room_id=? AND user_id=?').run(roomId, req.user!.id);
  if (result.changes === 0) return res.status(404).json({ error: 'member_not_found' });
  db.prepare('DELETE FROM room_keys WHERE room_id=? AND member_user_id=?').run(roomId, req.user!.id);
  logger.info('room_left', { roomId, userId: req.user!.id });
  res.json({ ok: true });
});
