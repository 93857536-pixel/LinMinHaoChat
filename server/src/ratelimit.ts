/**
 * 内存滑动窗口限流器(单进程足够)。
 * 按 key(ip:action / target:action)限流,支持 burst。
 */
interface Bucket {
  hits: number[];
  blockedUntil: number;
}

const buckets = new Map<string, Bucket>();
let lastSweep = Date.now();

function sweep(now: number) {
  if (now - lastSweep < 60_000) return;
  lastSweep = now;
  for (const [k, b] of buckets) {
    if (b.hits.length === 0 && b.blockedUntil < now) buckets.delete(k);
  }
}

export interface RateResult {
  ok: boolean;
  remaining: number;
  retryAfterSec: number;
}

/**
 * @param key 限流键
 * @param limit 窗口内最大次数
 * @param windowMs 窗口毫秒
 * @param blockMs 超限后封禁毫秒(0=不封禁)
 */
export function rateLimit(key: string, limit: number, windowMs: number, blockMs = 0): RateResult {
  const now = Date.now();
  sweep(now);
  let b = buckets.get(key);
  if (!b) {
    b = { hits: [], blockedUntil: 0 };
    buckets.set(key, b);
  }
  if (b.blockedUntil > now) {
    return { ok: false, remaining: 0, retryAfterSec: Math.ceil((b.blockedUntil - now) / 1000) };
  }
  b.hits = b.hits.filter((t) => now - t < windowMs);
  if (b.hits.length >= limit) {
    if (blockMs > 0) b.blockedUntil = now + blockMs;
    return { ok: false, remaining: 0, retryAfterSec: Math.ceil(blockMs / 1000) || Math.ceil(windowMs / 1000) };
  }
  b.hits.push(now);
  return { ok: true, remaining: limit - b.hits.length, retryAfterSec: 0 };
}

/** 内存占用保护:定期清空(保留最近 30 分钟活跃键) */
setInterval(() => {
  const cutoff = Date.now() - 30 * 60 * 1000;
  for (const [k, b] of buckets) {
    if (b.hits.every((t) => t < cutoff) && b.blockedUntil < Date.now()) {
      buckets.delete(k);
    }
  }
}, 10 * 60 * 1000).unref();

export function clientIp(req: { headers: Record<string, string | string[] | undefined>; socket?: { remoteAddress?: string } }): string {
  // 只信任 nginx 直连场景的 X-Forwarded-For(生产由 nginx 设置);不回退信任任意头
  const xff = req.headers['x-forwarded-for'];
  if (Array.isArray(xff)) return String(xff[0]).split(',')[0].trim();
  if (typeof xff === 'string' && xff.length > 0) return xff.split(',')[0].trim();
  return req.socket?.remoteAddress || 'unknown';
}
