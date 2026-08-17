import express from 'express';
import type { Express } from 'express';
import { config } from './config.js';
import { securityHeaders, requestLog, errorHandler } from './middleware.js';
import { authRouter } from './routes/auth.js';
import { keysRouter } from './routes/keys.js';
import { tempRouter } from './routes/temp.js';
import { inviteRouter } from './routes/invite.js';
import { chatRouter } from './routes/chat.js';
import { attachmentsRouter } from './routes/attachments.js';
import { adminRouter } from './routes/admin.js';
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

  app.use(express.json({ limit: config.maxBodyBytes }));

  // 健康检查(无需认证,不含敏感信息)
  app.get('/api/health', (_req, res) => {
    res.json({ ok: true, db: healthCheckDb(), uptime: process.uptime(), ts: Date.now() });
  });

  app.use('/api/auth', authRouter);
  app.use('/api/keys', keysRouter);
  app.use('/api/temp', tempRouter);
  app.use('/api/invite', inviteRouter);
  app.use('/api/chat', chatRouter);
  app.use('/api/attachments', attachmentsRouter);
  app.use('/api/admin', adminRouter);

  // 404
  app.use('/api', (_req, res) => res.status(404).json({ error: 'not_found' }));

  app.use(errorHandler);
  return app;
}
