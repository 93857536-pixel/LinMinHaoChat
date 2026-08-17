import fs from 'node:fs';
import path from 'node:path';
import { config } from './config.js';

/** 敏感字段名 —— 日志中一律脱敏/丢弃 */
const SENSITIVE_KEYS = new Set([
  'code', 'otp', 'password', 'token', 'authorization', 'cookie',
  'secret', 'key', 'iv', 'cipher', 'wrappedkey', 'privatekey', 'accesskey',
]);

function maskValue(key: string, value: unknown): unknown {
  const k = key.toLowerCase();
  if (SENSITIVE_KEYS.has(k)) return '[REDACTED]';
  if (typeof value !== 'string') return value;
  if (/^1[3-9]\d{9}$/.test(value)) return value.slice(0, 3) + '****' + value.slice(7);   // 138****1234
  if (/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value)) {
    const [name, domain] = value.split('@');
    const n = name.length <= 3 ? name[0] + '***' : name.slice(0, 3) + '***';
    return `${n}@${domain}`; // abc***@example.com
  }
  return value;
}

function sanitize(obj: unknown, depth = 0): unknown {
  if (depth > 6) return '[DEPTH]';
  if (Array.isArray(obj)) return obj.map((v) => sanitize(v, depth + 1));
  if (obj && typeof obj === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
      out[k] = maskValue(k, v) && typeof v === 'object' && v !== null
        ? sanitize(v, depth + 1)
        : maskValue(k, v);
    }
    return out;
  }
  return obj;
}

type Level = 'debug' | 'info' | 'warn' | 'error';

class Logger {
  private logDir: string;
  private stream?: fs.WriteStream;
  private errStream?: fs.WriteStream;
  private day: string;

  constructor() {
    this.logDir = path.join(config.dataRoot, 'logs');
    fs.mkdirSync(this.logDir, { recursive: true, mode: 0o700 });
    this.day = new Date().toISOString().slice(0, 10);
    this.roll();
  }

  private roll() {
    const today = new Date().toISOString().slice(0, 10);
    if (this.day !== today) {
      this.day = today;
      this.stream?.end();
      this.errStream?.end();
    }
    if (!this.stream || this.stream.closed) {
      this.stream = fs.createWriteStream(path.join(this.logDir, `app.${this.day}.log`), { flags: 'a' });
      this.errStream = fs.createWriteStream(path.join(this.logDir, `error.${this.day}.log`), { flags: 'a' });
      this.cleanupOld();
    }
  }

  /** 保留最近 14 天日志 */
  private cleanupOld() {
    try {
      const files = fs.readdirSync(this.logDir);
      const cutoff = Date.now() - 14 * 24 * 3600 * 1000;
      for (const f of files) {
        const m = f.match(/\.(\d{4}-\d{2}-\d{2})\.log$/);
        if (m) {
          const t = Date.parse(m[1]);
          if (!Number.isNaN(t) && t < cutoff) {
            fs.unlinkSync(path.join(this.logDir, f));
          }
        }
      }
    } catch { /* ignore */ }
  }

  log(level: Level, msg: string, meta?: Record<string, unknown>) {
    this.roll();
    const entry = {
      ts: new Date().toISOString(),
      level,
      msg,
      ...(meta ? (sanitize(meta) as Record<string, unknown>) : {}),
    };
    const line = JSON.stringify(entry);
    const out = this.stream ?? this.errStream!;
    out.write(line + '\n');
    if (level === 'error') this.errStream?.write(line + '\n');
    // console(开发/系统日志)只打 warn+error,避免刷屏
    if (level === 'warn' || level === 'error') {
      console[level === 'error' ? 'error' : 'warn'](`[${level}] ${msg}`);
    }
  }

  info(msg: string, meta?: Record<string, unknown>) { this.log('info', msg, meta); }
  warn(msg: string, meta?: Record<string, unknown>) { this.log('warn', msg, meta); }
  error(msg: string, meta?: Record<string, unknown>) { this.log('error', msg, meta); }
  debug(msg: string, meta?: Record<string, unknown>) {
    if (config.nodeEnv === 'development') this.log('debug', msg, meta);
  }
}

export const logger = new Logger();
