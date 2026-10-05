import { Router } from 'express';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { db } from '../db.js';
import { config } from '../config.js';
import { authRequired } from '../middleware.js';
import { rateLimit } from '../ratelimit.js';
import { logger } from '../logger.js';

/**
 * 云端 E2EE 备份(WeChatExporter 等客户端上传加密导出包)
 * - 全程 E2EE:客户端 AES-GCM 加密后分块上传,服务器只存密文字节 + manifest 元数据,永不解密
 * - manifest.sha256 = 客户端对**明文**文件算的哈希(服务端只记录,无法验证,用于 skip/overwrite 决策)
 * - 首次上传(该用户库内 0 个文件):全部 action=upload
 * - 再次上传:sha256 相同且 state=complete → action=skip(客户端不用重传);不同/新文件 → action=upload(覆盖)
 * - 同名覆盖:manifest 重新提交同名文件时,清理旧 staging 目录,重新开始分块
 * - 配额:单用户 BACKUP_USER_QUOTA_BYTES(默认 1GB),manifest 阶段预检,commit 阶段复算
 */
export const backupRouter = Router();
backupRouter.use(authRequired);

interface BackupFileRow {
  user_id: number;
  name: string;
  category: string;
  sha256: string;
  total_size: number;
  chunk_count: number;
  chunk_size: number;
  state: string; // uploading | complete
  created_at: number;
  updated_at: number;
}

/** 校验文件名:相对路径、≤8 段、每段 ≤100 字符、允许 CJK/点/连字符/下划线/数字/字母 */
function isValidName(name: unknown): name is string {
  if (typeof name !== 'string' || !name || name.length > 256) return false;
  if (name.startsWith('/') || name.startsWith('\\') || name.startsWith('.')) return false;
  const segs = name.split('/');
  if (segs.length > 8) return false;
  for (const s of segs) {
    if (!s || s === '.' || s === '..' || s.length > 100) return false;
    if (!/^[\w.@\-\u4e00-\u9fa5]+$/.test(s)) return false;
    if (/[\u0000-\u001f]/.test(s)) return false;
  }
  return true;
}

const HEX64 = /^[a-f0-9]{64}$/;
const CATEGORIES = new Set(['chats', 'media', 'database', 'config', 'other']);

/** 每用户一个 staging 根;目录名 = sha256(name) 前 16 位(避免路径转义/同名碰撞) */
function fileDir(userId: number, name: string): string {
  const h = crypto.createHash('sha256').update(name).digest('hex').slice(0, 16);
  return path.join(config.dataRoot, 'backup', String(userId), h);
}

function rmFileDir(userId: number, name: string): void {
  try {
    fs.rmSync(fileDir(userId, name), { recursive: true, force: true });
  } catch { /* non-fatal */ }
}

function usedBytes(userId: number): number {
  const row = db.prepare("SELECT COALESCE(SUM(total_size),0) AS s FROM backup_files WHERE user_id=? AND state='complete'").get(userId) as { s: number };
  return row.s;
}

/** GET /api/backup/manifest —— 列出当前用户的全部备份文件 */
backupRouter.get('/manifest', (req, res) => {
  const user = req.user!;
  const rows = db.prepare('SELECT name,category,sha256,total_size,chunk_count,chunk_size,state,created_at,updated_at FROM backup_files WHERE user_id=? ORDER BY name').all(user.id) as BackupFileRow[];
  res.json({
    files: rows.map((r) => ({
      name: r.name,
      category: r.category,
      sha256: r.sha256,
      totalSize: r.total_size,
      chunkCount: r.chunk_count,
      chunkSize: r.chunk_size,
      state: r.state,
      createdAt: r.created_at,
      updatedAt: r.updated_at,
    })),
  });
});

/**
 * POST /api/backup/manifest
 * body: { files: [{ name, category?, sha256, totalSize, chunkCount, chunkSize }] }
 * resp: { actions: [{ name, action: 'skip'|'upload' }], usedBytes, quotaBytes }
 */
backupRouter.post('/manifest', (req, res) => {
  const user = req.user!;
  const rl = rateLimit(`bk:manifest:${user.id}`, 30, 60_000, 60_000);
  if (!rl.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: rl.retryAfterSec });

  const files = Array.isArray((req.body || {}).files) ? (req.body as { files: unknown[] }).files : null;
  if (!files || files.length === 0 || files.length > 2000) return res.status(400).json({ error: 'bad_manifest' });

  const now = Date.now();
  const quota = config.backupUserQuotaBytes;
  const actions: { name: string; action: 'skip' | 'upload' }[] = [];
  const prepared: { name: string; category: string; sha256: string; totalSize: number; chunkCount: number; chunkSize: number }[] = [];

  // 先解析校验全部条目(任一非法 → 整体 400,不落库)
  for (const raw of files) {
    const f = raw as Record<string, unknown>;
    const name = String(f.name || '');
    const category = CATEGORIES.has(String(f.category || 'other')) ? String(f.category) : 'other';
    const sha256 = String(f.sha256 || '');
    const totalSize = Number(f.totalSize);
    const chunkCount = Number(f.chunkCount);
    const chunkSize = Number(f.chunkSize);
    if (!isValidName(name) || !HEX64.test(sha256) || !Number.isInteger(totalSize) || totalSize <= 0
      || !Number.isInteger(chunkCount) || chunkCount < 1 || chunkCount > 100_000
      || !Number.isInteger(chunkSize) || chunkSize < 65_536 || chunkSize > 8 * 1024 * 1024
      || chunkCount * chunkSize < totalSize) {
      return res.status(400).json({ error: 'bad_file_entry', name: name.slice(0, 100) });
    }
    prepared.push({ name, category, sha256, totalSize, chunkCount, chunkSize });
  }

  // 去重(manifest 内同名只留最后一条)
  const byName = new Map<string, (typeof prepared)[number]>();
  for (const p of prepared) byName.set(p.name, p);

  // 首次上传判定:该用户无任何备份文件
  const hasAny = (db.prepare('SELECT 1 FROM backup_files WHERE user_id=? LIMIT 1').get(user.id) as unknown) !== undefined;

  let projectedUsed = usedBytes(user.id);
  for (const [name, p] of byName) {
    const existing = db.prepare('SELECT * FROM backup_files WHERE user_id=? AND name=?').get(user.id, name) as BackupFileRow | undefined;
    const skip = !!existing && existing.sha256 === p.sha256 && existing.state === 'complete' && existing.total_size === p.totalSize;
    if (!skip) {
      // 即将上传:配额预检(complete 部分 + 本次全部新传/覆盖)
      if (existing && existing.state === 'complete') projectedUsed -= existing.total_size;
      projectedUsed += p.totalSize;
      if (projectedUsed > quota) {
        return res.status(409).json({ error: 'quota_exceeded', usedBytes: usedBytes(user.id), quotaBytes: quota, name });
      }
      // 覆盖/新传:清旧 staging,重置行
      rmFileDir(user.id, name);
      if (existing) {
        db.prepare("UPDATE backup_files SET sha256=?, total_size=?, chunk_count=?, chunk_size=?, category=?, state='uploading', updated_at=? WHERE user_id=? AND name=?")
          .run(p.sha256, p.totalSize, p.chunkCount, p.chunkSize, p.category, now, user.id, name);
      } else {
        db.prepare('INSERT INTO backup_files (user_id,name,category,sha256,total_size,chunk_count,chunk_size,state,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)')
          .run(user.id, name, p.category, p.sha256, p.totalSize, p.chunkCount, p.chunkSize, 'uploading', now, now);
      }
      actions.push({ name, action: 'upload' });
    } else {
      actions.push({ name, action: 'skip' });
    }
  }

  if (hasAny === false && actions.length > 0) logger.info('backup_first_upload', { userId: user.id, files: actions.length });
  res.json({ actions, usedBytes: usedBytes(user.id), quotaBytes: quota });
});

/**
 * POST /api/backup/chunk
 * body: { name, chunkIdx, data(base64) }  (chunk 路由单独放宽 body 上限,见 app.ts)
 */
backupRouter.post('/chunk', (req, res) => {
  const user = req.user!;
  const rl = rateLimit(`bk:chunk:${user.id}`, 600, 60_000, 60_000);
  if (!rl.ok) return res.status(429).json({ error: 'rate_limited', retryAfterSec: rl.retryAfterSec });

  const b = (req.body || {}) as Record<string, unknown>;
  const name = String(b.name || '');
  const chunkIdx = Number(b.chunkIdx);
  if (!isValidName(name) || !Number.isInteger(chunkIdx) || chunkIdx < 0) return res.status(400).json({ error: 'bad_chunk' });
  const row = db.prepare('SELECT * FROM backup_files WHERE user_id=? AND name=?').get(user.id, name) as BackupFileRow | undefined;
  if (!row || row.state !== 'uploading') return res.status(409).json({ error: 'file_not_pending', name });
  if (chunkIdx >= row.chunk_count) return res.status(400).json({ error: 'bad_chunk_index' });

  const dataB64 = String(b.data || '');
  const buf = Buffer.from(dataB64, 'base64');
  const expectSize = chunkIdx === row.chunk_count - 1 ? row.total_size - (row.chunk_count - 1) * row.chunk_size : row.chunk_size;
  if (expectSize <= 0 || buf.length !== expectSize) return res.status(400).json({ error: 'bad_chunk_size', expected: expectSize, got: buf.length });

  const dir = fileDir(user.id, name);
  try {
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    fs.writeFileSync(path.join(dir, String(chunkIdx)), buf, { mode: 0o600 });
  } catch (e) {
    logger.error('backup_chunk_write', { userId: user.id, name, chunkIdx, err: (e as Error).message });
    return res.status(507).json({ error: 'storage_full' });
  }
  res.json({ ok: true, received: buf.length });
});

/**
 * POST /api/backup/commit  { name }
 * 校验全部分块齐整 → 标记 complete;清理多余分块文件
 */
backupRouter.post('/commit', (req, res) => {
  const user = req.user!;
  const name = String(((req.body || {}) as { name?: string }).name || '');
  if (!isValidName(name)) return res.status(400).json({ error: 'bad_name' });
  const row = db.prepare('SELECT * FROM backup_files WHERE user_id=? AND name=?').get(user.id, name) as BackupFileRow | undefined;
  if (!row) return res.status(404).json({ error: 'not_found' });

  const dir = fileDir(user.id, name);
  let diskSum = 0;
  for (let i = 0; i < row.chunk_count; i++) {
    const p = path.join(dir, String(i));
    if (!fs.existsSync(p)) return res.status(409).json({ error: 'chunks_missing', chunkIdx: i });
    const st = fs.statSync(p);
    diskSum += st.size;
  }
  // 最后一块允许小于 chunk_size,但总和必须精确等于 total_size
  if (diskSum !== row.total_size) return res.status(409).json({ error: 'size_mismatch', expected: row.total_size, got: diskSum });

  // 清掉多余文件(防残留)
  for (const f of fs.readdirSync(dir)) {
    if (/^\d+$/.test(f) && Number(f) >= row.chunk_count) fs.rmSync(path.join(dir, f), { force: true });
  }

  db.prepare("UPDATE backup_files SET state='complete', updated_at=? WHERE user_id=? AND name=?").run(Date.now(), user.id, name);
  res.json({ ok: true, size: row.total_size, usedBytes: usedBytes(user.id), quotaBytes: config.backupUserQuotaBytes });
});

/** GET /api/backup/chunk?name=&idx= —— 下载单个密文分块(仅 complete 文件) */
backupRouter.get('/chunk', (req, res) => {
  const user = req.user!;
  const name = String(req.query.name || '');
  const idx = Number(req.query.idx);
  if (!isValidName(name) || !Number.isInteger(idx) || idx < 0) return res.status(400).json({ error: 'bad_params' });
  const row = db.prepare('SELECT * FROM backup_files WHERE user_id=? AND name=?').get(user.id, name) as BackupFileRow | undefined;
  if (!row || row.state !== 'complete' || idx >= row.chunk_count) return res.status(404).json({ error: 'not_found' });
  const p = path.join(fileDir(user.id, name), String(idx));
  if (!fs.existsSync(p)) return res.status(409).json({ error: 'chunk_missing', chunkIdx: idx });
  res.setHeader('Content-Type', 'application/octet-stream');
  res.setHeader('Content-Length', String(fs.statSync(p).size));
  fs.createReadStream(p).pipe(res);
});

/** DELETE /api/backup/file  { name } */
backupRouter.delete('/file', (req, res) => {
  const user = req.user!;
  const name = String(((req.body || {}) as { name?: string }).name || '');
  if (!isValidName(name)) return res.status(400).json({ error: 'bad_name' });
  const row = db.prepare('SELECT * FROM backup_files WHERE user_id=? AND name=?').get(user.id, name) as BackupFileRow | undefined;
  if (!row) return res.status(404).json({ error: 'not_found' });
  rmFileDir(user.id, name);
  db.prepare('DELETE FROM backup_files WHERE user_id=? AND name=?').run(user.id, name);
  logger.info('backup_file_deleted', { userId: user.id, name, size: row.total_size });
  res.json({ ok: true });
});

/** GET /api/backup/usage */
backupRouter.get('/usage', (req, res) => {
  const user = req.user!;
  const cnt = (db.prepare('SELECT COUNT(*) AS c FROM backup_files WHERE user_id=?').get(user.id) as { c: number }).c;
  res.json({ usedBytes: usedBytes(user.id), quotaBytes: config.backupUserQuotaBytes, fileCount: cnt });
});
