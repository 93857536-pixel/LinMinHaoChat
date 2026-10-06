import express from 'express';
import type { Express } from 'express';
import { config } from './config.js';
import { securityHeaders, requestLog, errorHandler } from './middleware.js';
import { authRouter } from './routes/auth.js';
import { keysRouter } from './routes/keys.js';
import { tempRouter } from './routes/temp.js';
import { inviteRouter } from './routes/invite.js';
import { chatRouter } from './routes/chat.js';
import { friendsRouter } from './routes/friends.js';
import { pnsRouter } from './routes/pns.js';
import { attachmentsRouter } from './routes/attachments.js';
import { avatarsRouter } from './routes/avatars.js';
import { adminRouter } from './routes/admin.js';
import { backupRouter } from './routes/backup.js';
import { diagRouter } from './routes/diag.js';
import { realnameRouter } from './routes/realname.js';
import { clientIp, rateLimit } from './ratelimit.js';
import { logger } from './logger.js';
import { healthCheckDb } from './db.js';

export function buildApp(): Express {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', true); // nginx 直连

  app.use(securityHeaders);
  app.use(requestLog);

  // CORS 严格限制:仅允许本站源
  app.use((req, res, next) => {
    const origin = req.headers.origin;
    if (origin && origin !== config.corsOrigin) {
      return res.status(403).json({ error: 'origin_not_allowed' });
    }
    res.setHeader('Access-Control-Allow-Origin', origin === config.corsOrigin ? config.corsOrigin : '');
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,DELETE,OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    res.setHeader('Access-Control-Max-Age', '600');
    if (req.method === 'OPTIONS') return res.sendStatus(204);
    next();
  });

  app.use((req, _res, next) => {
    // 备份分块走独立大上限解析器(见下方 /api/backup 挂载),其余用全局小上限
    if (req.path.startsWith('/api/backup')) return next();
    express.json({ limit: config.maxBodyBytes })(req, _res, next);
  });

  // 健康检查(无需认证,不含敏感信息)
  app.get('/api/health', (_req, res) => {
    res.json({ ok: true, db: healthCheckDb(), uptime: process.uptime(), ts: Date.now() });
  });

  app.use('/api/auth', authRouter);
  app.use('/api/pns', pnsRouter);
  app.use('/api/keys', keysRouter);
  app.use('/api/temp', tempRouter);
  app.use('/api/invite', inviteRouter);
  app.use('/api/chat', chatRouter);
  app.use('/api/friends', friendsRouter);
  app.use('/api/attachments', attachmentsRouter);
  // 用户头像(自主上传/好友可见)。刻意用 /api/avatars/* 独立前缀:
  // 避免与 CF ingress 里 /api/logs* 等既有遮蔽规则相撞。
  app.use('/api/avatars', avatarsRouter);
  app.use('/api/admin', adminRouter);
  // 备份:分块 body 上限 10MB(独立解析器,manifest 等小请求同样走这里)
  app.use('/api/backup', express.json({ limit: config.maxBackupChunkBytes }), backupRouter);
  // 诊断日志上传(iOS「上传日志到服务器」)。刻意用 /api/diag/* 前缀:
  // CF 边缘对 /api/logs* 有遮蔽规则,走 /api/logs/device 会 403。
  app.use('/api/diag', diagRouter);

  // 实名认证(云市场「身份证二要素」,服务端代理;AppCode 只存服务端,不下发客户端)
  app.use('/api/realname', realnameRouter);

  // 404
  app.use('/api', (_req, res) => res.status(404).json({ error: 'not_found' }));

  app.use(errorHandler);
  return app;
}
