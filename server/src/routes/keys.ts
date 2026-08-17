import { Router } from 'express';
import { db } from '../db.js';
import { authRequired } from '../middleware.js';
import { rateLimit, clientIp } from '../ratelimit.js';
import { logger } from '../logger.js';

/**
 * 密钥管理:服务器只保存公钥和"加密导出包",绝不保存私钥。
 * - ed25519_pub / ecdh_pub: 客户端生成的公钥(base64),用于 ECDH 密钥交换
 * - export_pkg: 客户端用口令加密的密钥导出包(多设备迁移),服务器无法解密
 */
export const keysRouter = Router();

keysRouter.use(authRequired);

/** 上传/更新我的公钥(每设备) */
keysRouter.post('/register', (req, res) => {
  const { ed25519Pub, ecdhPub, deviceId } = req.body || {};
  if (!ed25519Pub || !ecdhPub) return res.status(400).json({ error: 'missing_pubkeys' });
  if (typeof ed25519Pub !== 'string' || typeof ecdhPub !== 'string' || ed25519Pub.length > 512 || ecdhPub.length > 512) {
    return res.status(400).json({ error: 'bad_key' });
  }
  const dev = String(deviceId || 'default').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64) || 'default';
  db.prepare(
    `INSERT INTO user_keys (user_id, device_id, ed25519_pub, ecdh_pub, created_at) VALUES (?,?,?,?,?)
     ON CONFLICT(user_id, device_id) DO UPDATE SET ed25519_pub=excluded.ed25519_pub, ecdh_pub=excluded.ecdh_pub`
  ).run(req.user!.id, dev, ed25519Pub, ecdhPub, Date.now());
  res.json({ ok: true });
});

/** 保存加密导出包(仅保留最新一份) */
keysRouter.post('/export-package', (req, res) => {
  const { pkg } = req.body || {};
  if (!pkg || typeof pkg !== 'string' || pkg.length > 64 * 1024) return res.status(400).json({ error: 'bad_pkg' });
  const dev = String((req.body || {}).deviceId || 'default').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64) || 'default';
  db.prepare('UPDATE user_keys SET export_pkg=? WHERE user_id=? AND device_id=?').run(pkg, req.user!.id, dev);
  logger.info('export_package_saved', { userId: req.user!.id, device: dev });
  res.json({ ok: true });
});

/** 拉取我的加密导出包 */
keysRouter.get('/export-package', (req, res) => {
  const dev = String(req.query.deviceId || 'default').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 64) || 'default';
  const row = db.prepare('SELECT export_pkg FROM user_keys WHERE user_id=? AND device_id=?').get(req.user!.id, dev) as
    { export_pkg: string | null } | undefined;
  res.json({ ok: true, pkg: row?.export_pkg || null });
});

/** 查询用户公钥(用于创建会话;允许查任意用户,方便加好友) */
keysRouter.get('/public/:userId', (req, res) => {
  const uid = Number(req.params.userId);
  if (!Number.isInteger(uid) || uid <= 0) return res.status(400).json({ error: 'bad_id' });
  const rows = db.prepare('SELECT device_id, ed25519_pub, ecdh_pub FROM user_keys WHERE user_id=?').all(uid) as
    { device_id: string; ed25519_pub: string; ecdh_pub: string }[];
  res.json({ ok: true, devices: rows });
});

/** 我的设备列表 */
keysRouter.get('/my', (req, res) => {
  const rows = db.prepare('SELECT device_id, created_at FROM user_keys WHERE user_id=?').all(req.user!.id);
  res.json({ ok: true, devices: rows });
});

/** 用户搜索(按 ID 精确;用于建立会话) */
keysRouter.get('/lookup', (req, res) => {
  const q = String(req.query.q || '').trim();
  const id = Number(q);
  if (!Number.isInteger(id) || id <= 0) return res.status(400).json({ error: 'bad_query' });
  const u = db.prepare('SELECT id, handle FROM users WHERE id=? AND banned=0').get(id) as { id: number; handle: string } | undefined;
  if (!u) return res.status(404).json({ error: 'not_found' });
  const r = rateLimit(`lookup:ip:${clientIp(req)}`, 60, 60_000);
  if (!r.ok) return res.status(429).json({ error: 'rate_limited' });
  res.json({ ok: true, user: u });
});
