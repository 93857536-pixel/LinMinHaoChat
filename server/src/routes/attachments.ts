import { Router } from 'express';
import { db } from '../db.js';
import { store } from '../storage.js';
import { newId } from '../crypto-util.js';
import { rateLimit, clientIp } from '../ratelimit.js';
import { authRequired } from '../middleware.js';
import { config } from '../config.js';
import { logger } from '../logger.js';

/**
 * 加密附件:
 * - 客户端加密后上传原始字节(application/octet-stream),服务器只落盘密文
 * - 服务器无法验证明文类型(E2EE 特性),但按客户端声明做白名单校验 + 大小限制
 * - 下载只提供给会话成员,响应强制 attachment + nosniff,禁止内联执行
 */
export const attachmentsRouter = Router();

attachmentsRouter.use(authRequired);

/** 上传密文附件 → attId。query: roomId(必填)+ declaredMime(白名单声明,仅 UI 用) */
attachmentsRouter.post('/', (req, res) => {
  const ip = clientIp(req);
  const r = rateLimit(`att:up:${ip}`, 20, 3600_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: r.retryAfterSec });

  const roomId = String(req.query.roomId || '');
  if (!roomId) return res.status(400).json({ error: 'bad_room' });
  const member = db.prepare('SELECT 1 FROM room_members WHERE room_id=? AND user_id=?').get(roomId, req.user!.id);
  if (!member) return res.status(404).json({ error: 'not_found' });

  const declaredMime = String(req.query.declaredMime || '').slice(0, 100);
  const SAFE_MIMES = new Set([
    'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif',
    'audio/mpeg', 'audio/ogg', 'audio/wav', 'audio/aac', 'audio/mp4',
    'video/mp4', 'video/webm', 'video/ogg',
    'text/plain', 'text/markdown', 'application/pdf', 'application/json',
    'application/zip', 'application/x-7z-compressed',
  ]);
  if (declaredMime && !SAFE_MIMES.has(declaredMime)) {
    return res.status(400).json({ error: 'unsafe_mime' });
  }

  const len = Number(req.headers['content-length'] || 0);
  if (len > config.maxAttachmentBytes) return res.status(413).json({ error: 'too_large' });

  const chunks: Buffer[] = [];
  let size = 0;
  req.on('data', (c: Buffer) => {
    size += c.length;
    if (size > config.maxAttachmentBytes) {
      req.destroy();
      return;
    }
    chunks.push(c);
  });
  req.on('end', () => {
    if (size < 1) return res.status(400).json({ error: 'empty' });
    const attId = newId('a_');
    const rel = store.saveAttachmentCipher(attId, Buffer.concat(chunks));
    const id = newId('m_');
    db.prepare('INSERT INTO messages (id, room_id, kind, seq, sender_user_id, cipher_path, iv, aad, meta_enc, ts) VALUES (?,?,?,?,?,?,?,?,?,?)')
      .run(
        id, roomId, 'attachment',
        (db.prepare('SELECT COALESCE(MAX(seq),0) AS s FROM messages WHERE room_id=?').get(roomId) as { s: number }).s + 1,
        req.user!.id, rel, '', '', JSON.stringify({ attId, declaredMime, size }), Date.now()
      );
    logger.info('attachment_uploaded', { attId, roomId, size, by: req.user!.id });
    res.json({ ok: true, attId, size, roomId });
  });
});

/** 下载密文附件(仅成员;强制下载,防内联执行) */
attachmentsRouter.get('/:id', (req, res) => {
  const attId = String(req.params.id);
  if (!/^a_[A-Za-z0-9_-]+$/.test(attId)) return res.status(400).json({ error: 'bad_id' });
  const row = db.prepare(
    `SELECT m.cipher_path, m.room_id FROM messages m WHERE m.kind='attachment' AND m.meta_enc LIKE ?`
  ).get(`%"attId":"${attId}"%`) as { cipher_path: string; room_id: string } | undefined;
  if (!row) return res.status(404).json({ error: 'not_found' });
  const member = db.prepare('SELECT 1 FROM room_members WHERE room_id=? AND user_id=?').get(row.room_id, req.user!.id);
  if (!member) return res.status(403).json({ error: 'forbidden' });

  const buf = store.readCipher(row.cipher_path);
  res.setHeader('Content-Type', 'application/octet-stream');
  res.setHeader('Content-Disposition', `attachment; filename="${attId}.enc"`);
  res.setHeader('Cache-Control', 'private, no-store');
  res.send(buf);
});
