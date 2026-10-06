import { Router } from 'express';
import { db } from '../db.js';
import { store } from '../storage.js';
import { rateLimit, clientIp } from '../ratelimit.js';
import { authRequired } from '../middleware.js';
import { logger } from '../logger.js';

/**
 * 用户头像(用户自主上传):
 * - 头像不是聊天内容,属于「公开给好友的身份标识」,故以明文文件落盘(dataRoot/avatars/<userId>.<ext>)
 * - 上传:原始图片字节(image/jpeg|image/png|image/webp),服务器按 magic bytes 校验真实类型(不信 Content-Type)
 * - 下载:仅本人 / 好友 / 同一会话成员可见 —— 未授权一律 404(不泄露「该用户是否存在头像」)
 * - 大小上限 2MB;iOS 端上传前已压到 512px 方图(顺带清掉 EXIF/GPS)
 */
export const avatarsRouter = Router();

const MAX_AVATAR_BYTES = 2 * 1024 * 1024;

/** 真实图片类型探测(只看文件头,不信 Content-Type) */
function sniffImage(buf: Buffer): 'jpg' | 'png' | 'webp' | null {
  if (buf.length < 12) return null;
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'jpg';
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47 &&
      buf[4] === 0x0d && buf[5] === 0x0a && buf[6] === 0x1a && buf[7] === 0x0a) return 'png';
  if (buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') return 'webp';
  return null;
}

function mimeOf(ext: string): string {
  return ext === 'png' ? 'image/png' : ext === 'webp' ? 'image/webp' : 'image/jpeg';
}

/** 可见性:本人 / 好友(双向关系行) / 同一会话成员 */
function canViewAvatar(me: number, target: number): boolean {
  if (me === target) return true;
  const friend = db.prepare(
    'SELECT 1 FROM friendships WHERE (user_id=? AND friend_id=?) OR (user_id=? AND friend_id=?)'
  ).get(me, target, target, me);
  if (friend) return true;
  const roommate = db.prepare(
    `SELECT 1 FROM room_members a JOIN room_members b ON a.room_id = b.room_id
     WHERE a.user_id=? AND b.user_id=? LIMIT 1`
  ).get(me, target);
  return !!roommate;
}

avatarsRouter.use(authRequired);

/** 上传/更换我的头像(原始字节;field=body) */
avatarsRouter.post('/', (req, res) => {
  const me = req.user!.id;
  const rl = rateLimit(`avatar:up:${me}`, 20, 3600_000);
  if (!rl.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: rl.retryAfterSec });

  const declared = Number(req.headers['content-length'] || 0);
  if (declared > MAX_AVATAR_BYTES) return res.status(413).json({ error: 'too_large' });

  const chunks: Buffer[] = [];
  let size = 0;
  let aborted = false;
  req.on('data', (c: Buffer) => {
    if (aborted) return;
    size += c.length;
    if (size > MAX_AVATAR_BYTES) {
      aborted = true;
      req.destroy();
      return;
    }
    chunks.push(c);
  });
  req.on('end', () => {
    if (aborted) return;
    if (size < 32) return res.status(400).json({ error: 'empty' });
    const buf = Buffer.concat(chunks);
    const ext = sniffImage(buf);
    if (!ext) return res.status(400).json({ error: 'unsupported_image' });

    const rel = store.saveAvatar(me, ext, buf);
    const now = Date.now();
    db.prepare('UPDATE users SET avatar_mime=?, avatar_updated_at=? WHERE id=?')
      .run(mimeOf(ext), now, me);
    logger.info('avatar_uploaded', { userId: me, ext, size, ip: clientIp(req) });
    res.json({ ok: true, hasAvatar: true, avatarUpdatedAt: now, size });
  });
});

/** 删除我的头像 */
avatarsRouter.delete('/', (req, res) => {
  const me = req.user!.id;
  const row = db.prepare('SELECT avatar_mime, avatar_updated_at FROM users WHERE id=?')
    .get(me) as { avatar_mime: string | null; avatar_updated_at: number | null } | undefined;
  if (row?.avatar_mime) {
    const ext = row.avatar_mime === 'image/png' ? 'png' : row.avatar_mime === 'image/webp' ? 'webp' : 'jpg';
    store.deleteAvatar(`avatars/${me}.${ext}`);
  }
  db.prepare('UPDATE users SET avatar_mime=NULL, avatar_updated_at=NULL WHERE id=?').run(me);
  logger.info('avatar_deleted', { userId: me });
  res.json({ ok: true, hasAvatar: false });
});

/**
 * 读取头像(二进制图片)。
 * :userId 可为数字 ID 或 "me"。不可见时 404(与「没有头像」同一响应,不泄露信息)。
 */
avatarsRouter.get('/:userId', (req, res) => {
  const me = req.user!.id;
  const raw = String(req.params.userId);
  const target = raw === 'me' ? me : Number(raw);
  if (!Number.isInteger(target) || target <= 0) return res.status(400).json({ error: 'bad_user' });

  const rl = rateLimit(`avatar:get:${me}`, 300, 60_000);
  if (!rl.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: rl.retryAfterSec });

  if (!canViewAvatar(me, target)) return res.status(404).json({ error: 'not_found' });

  const row = db.prepare('SELECT avatar_mime, avatar_updated_at FROM users WHERE id=?')
    .get(target) as { avatar_mime: string | null; avatar_updated_at: number | null } | undefined;
  if (!row?.avatar_mime || !row.avatar_updated_at) return res.status(404).json({ error: 'no_avatar' });

  const ext = row.avatar_mime === 'image/png' ? 'png' : row.avatar_mime === 'image/webp' ? 'webp' : 'jpg';
  const buf = store.readAvatar(`avatars/${target}.${ext}`);
  if (!buf) return res.status(404).json({ error: 'no_avatar' });

  res.setHeader('Content-Type', mimeOf(ext));
  res.setHeader('Cache-Control', 'private, max-age=600');
  res.setHeader('ETag', `W/"${target}-${row.avatar_updated_at}"`);
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.send(buf);
});
