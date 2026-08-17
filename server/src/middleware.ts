import type { Request, Response, NextFunction } from 'express';
import { config } from './config.js';
import { logger } from './logger.js';
import { clientIp } from './ratelimit.js';
import { jwtVerify, SignJWT } from 'jose';

export interface AuthedUser {
  id: number;
  deviceId: string;
  role: 'user';
}

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      user?: AuthedUser;
      admin?: { user: string };
      _start?: number;
    }
  }
}

const enc = new TextEncoder();

export async function signUserJwt(userId: number, deviceId: string): Promise<string> {
  return new SignJWT({ sub: String(userId), device: deviceId, role: 'user' })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime('7d')
    .sign(enc.encode(config.jwtSecret));
}

export async function signAdminJwt(user: string): Promise<string> {
  return new SignJWT({ sub: user, role: 'admin' })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime('12h')
    .sign(enc.encode(config.jwtSecret));
}

/** Bearer JWT 认证(用户端) */
export async function authRequired(req: Request, res: Response, next: NextFunction) {
  const h = req.headers.authorization || '';
  const token = h.startsWith('Bearer ') ? h.slice(7) : '';
  if (!token) return res.status(401).json({ error: 'unauthorized' });
  try {
    const { payload } = await jwtVerify(token, enc.encode(config.jwtSecret));
    if (payload.role !== 'user') return res.status(401).json({ error: 'unauthorized' });
    req.user = { id: Number(payload.sub), deviceId: String(payload.device || 'default'), role: 'user' };
    next();
  } catch {
    return res.status(401).json({ error: 'unauthorized' });
  }
}

export async function adminAuth(req: Request, res: Response, next: NextFunction) {
  const h = req.headers.authorization || '';
  const token = h.startsWith('Bearer ') ? h.slice(7) : '';
  if (!token) return res.status(401).json({ error: 'unauthorized' });
  try {
    const { payload } = await jwtVerify(token, enc.encode(config.jwtSecret));
    if (payload.role !== 'admin') return res.status(401).json({ error: 'unauthorized' });
    req.admin = { user: String(payload.sub) };
    next();
  } catch {
    return res.status(401).json({ error: 'unauthorized' });
  }
}

/** 安全响应头 */
export function securityHeaders(_req: Request, res: Response, next: NextFunction) {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  res.setHeader('X-XSS-Protection', '0'); // 现代浏览器不再需要,避免误导
  if (config.nodeEnv === 'production') {
    res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  }
  // CSP(前端由 nginx 托管;API 响应默认禁止内联脚本)
  res.setHeader(
    'Content-Security-Policy',
    "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
  );
  next();
}

/** 请求日志:只记方法/路径/状态/耗时/IP,绝不记 body */
export function requestLog(req: Request, res: Response, next: NextFunction) {
  req._start = Date.now();
  res.on('finish', () => {
    const ms = Date.now() - (req._start || Date.now());
    if (res.statusCode >= 500) {
      logger.error('http', { method: req.method, path: req.path, status: res.statusCode, ms, ip: clientIp(req) });
    } else if (res.statusCode >= 400) {
      logger.info('http', { method: req.method, path: req.path, status: res.statusCode, ms, ip: clientIp(req) });
    } else {
      logger.debug('http', { method: req.method, path: req.path, status: res.statusCode, ms });
    }
  });
  next();
}

export function errorHandler(err: unknown, _req: Request, res: Response, _next: NextFunction) {
  const e = err as { status?: number; message?: string; type?: string };
  if (e && e.type === 'entity.too.large') {
    return res.status(413).json({ error: 'payload_too_large' });
  }
  logger.error('unhandled_error', { message: e?.message, stack: (err as Error)?.stack?.slice(0, 2000) });
  return res.status(e?.status || 500).json({ error: e?.status ? e.message : 'internal_error' });
}
