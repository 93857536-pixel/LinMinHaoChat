import express from 'express';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { config } from '../config.js';
import { rateLimit, clientIp } from '../ratelimit.js';
import { logger } from '../logger.js';

/**
 * 诊断日志上传端点(iOS 客户端「上传日志到服务器」按钮)。
 * 挂在 /api/diag/upload —— 刻意避开 Cloudflare 边缘规则遮蔽的 /api/logs* 前缀。
 *
 * 请求体 JSON { log, meta }:
 *   - log:  纯文本日志行(PNS SDK 环形缓冲,客户端已截断)
 *   - meta: 可选设备上下文(os / device / appVersion / locale)
 *
 * 落盘 <dataRoot>/diag-logs/YYYY/MM/DD/<ts>_<rand>.log(mode 0600),
 * 首行为 JSON header(含 ip/meta),便于后续解析。
 * 按客户端 IP 限流(10 次/分钟)。
 *
 * ⚠️ 2026-10-06 修复:该路由曾只存在于服务器 dist/routes/diag.js 而 app.js 未挂载,
 * 导致按钮一直报 not_found(请求落到 app.ts 末尾的 /api catch-all)。
 * 现已补回 src 并在 app.ts 挂载 —— 不要再让 dist 与 src 脱节。
 */
const router = express.Router();

const MAX_LOG_BYTES = 96 * 1024;
const MAX_META_VALUE = 120;

/** 生成并确保 <base>/YYYY/MM/DD 存在(与 messages/attachments 归档同构) */
function dayDir(base: string): string {
  const d = new Date();
  const dir = path.join(
    base,
    String(d.getFullYear()),
    String(d.getMonth() + 1).padStart(2, '0'),
    String(d.getDate()).padStart(2, '0')
  );
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

function safeStr(v: unknown, max = MAX_META_VALUE): string | undefined {
  return typeof v === 'string' ? v.slice(0, max) : undefined;
}

router.post('/upload', (req, res) => {
  const ip = clientIp(req);
  const rl = rateLimit('diag:' + ip, 10, 60_000, 0);
  if (!rl.ok) {
    res.set('Retry-After', String(rl.retryAfterSec));
    return res.status(429).json({ error: 'rate_limited', retryAfterSec: rl.retryAfterSec });
  }
  const body: { log?: unknown; meta?: unknown } = req.body || {};
  if (typeof body.log !== 'string' || body.log.length === 0) {
    return res.status(400).json({ error: 'log_required' });
  }
  const bytes = Buffer.byteLength(body.log, 'utf8');
  if (bytes > MAX_LOG_BYTES) {
    return res.status(400).json({ error: 'log_too_large' });
  }
  const rawMeta = (body.meta && typeof body.meta === 'object') ? body.meta as Record<string, unknown> : {};
  const meta = {
    os: safeStr(rawMeta.os),
    device: safeStr(rawMeta.device),
    appVersion: safeStr(rawMeta.appVersion, 40),
    locale: safeStr(rawMeta.locale, 40),
  };
  const dir = dayDir(path.join(config.dataRoot, 'diag-logs'));
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  const filename = `${ts}_${crypto.randomBytes(4).toString('hex')}.log`;
  const file = path.join(dir, filename);
  const header = JSON.stringify({ receivedAt: new Date().toISOString(), ip, meta }) + '\n';
  fs.writeFileSync(file, header + body.log, { mode: 0o600 });
  logger.info('diag_log_uploaded', { file, bytes });
  return res.json({ ok: true, bytes });
});

export { router as diagRouter };
