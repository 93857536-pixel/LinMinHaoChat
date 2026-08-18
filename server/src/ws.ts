import { WebSocketServer, WebSocket } from 'ws';
import type { Server } from 'node:http';
import crypto from 'node:crypto';
import { db } from './db.js';
import { config } from './config.js';
import { logger } from './logger.js';
import { setTempBroadcast } from './routes/temp.js';
import { setChatBroadcast, setOnlineMembers } from './routes/chat.js';
import { jwtVerify } from 'jose';

/**
 * WebSocket 网关 /ws:
 * - 账号连接:?token=<user JWT>(HS256 校验)
 * - 临时连接:?wsToken=<join 颁发的短期令牌>(sessions 表,temp: 前缀;有效期内可重连复用)
 * - 认证后加入房间订阅;消息转发只做中继,永不解密
 * - 消息大小限制(config.wsMaxPayloadBytes);心跳保活;在线状态
 */
const enc = new TextEncoder();

interface Conn {
  ws: WebSocket;
  kind: 'user' | 'temp';
  userId?: number;
  roomId: string;
  anonId?: string;
  ip: string;
  lastSeen: number;
}

const conns = new Map<WebSocket, Conn>();

function hashToken(t: string): string {
  return crypto.createHash('sha256').update(t).digest('hex');
}

/** 解析客户端真实 IP(只信任 nginx 设置的 X-Forwarded-For 首值,与 ratelimit.clientIp 一致) */
function connIp(req: { headers: Record<string, string | string[] | undefined>; socket?: { remoteAddress?: string } }): string {
  const xff = req.headers['x-forwarded-for'];
  if (Array.isArray(xff)) return String(xff[0]).split(',')[0].trim();
  if (typeof xff === 'string' && xff.length > 0) return xff.split(',')[0].trim();
  return req.socket?.remoteAddress || 'unknown';
}

export function startWs(server: Server) {
  const wss = new WebSocketServer({ server, path: '/ws', maxPayload: config.wsMaxPayloadBytes });

  wss.on('connection', async (ws, req) => {
    const url = new URL(req.url || '/', 'http://localhost');
    const token = url.searchParams.get('token') || url.searchParams.get('wsToken') || '';
    const ip = connIp(req);

    let conn: Conn | null = null;
    // 先尝试短令牌(sessions 表,temp: 设备前缀);否则按账号 JWT 校验
    const row = db.prepare('SELECT * FROM sessions WHERE id=? AND expires_at>?').get(token, Date.now()) as
      | { user_id: number; device: string } | undefined;
    if (row && String(row.device).startsWith('temp:')) {
      // 临时聊天短令牌(由 POST /api/temp/rooms/:id/join 颁发)
      // 令牌在有效期内(5 分钟)可重复连接:断线重连复用同一令牌,避免每次重连重新
      // join 触发限流(重连风暴 → 429 锁死)。失效后连接被拒(4001),客户端再重新 join。
      const [, roomId, anonId] = String(row.device).split(':');
      conn = { ws, kind: 'temp', roomId, anonId, ip, lastSeen: Date.now() };
    } else if (token) {
      // 账号 JWT
      try {
        const { payload } = await jwtVerify(token, enc.encode(config.jwtSecret));
        if (payload.role !== 'user') throw new Error('role');
        const uid = Number(payload.sub);
        const banned = db.prepare('SELECT banned FROM users WHERE id=?').get(uid) as { banned: number } | undefined;
        if (!banned || banned.banned) { ws.close(4003, 'banned'); return; }
        conn = { ws, kind: 'user', userId: uid, roomId: '', ip, lastSeen: Date.now() };
      } catch {
        ws.close(4001, 'unauthorized');
        return;
      }
    }

    if (!conn) {
      ws.close(4001, 'unauthorized');
      return;
    }
    conns.set(ws, conn);
    logger.debug('ws_connected', { kind: conn.kind, room: conn.roomId, user: conn.userId });

    ws.on('message', (raw) => {
      if (!conn) return;
      conn.lastSeen = Date.now();
      let msg: { type?: string; roomId?: string; [k: string]: unknown };
      try {
        msg = JSON.parse(String(raw));
      } catch {
        ws.send(JSON.stringify({ type: 'error', error: 'bad_json' }));
        return;
      }
      if (typeof msg.type !== 'string') return;

      if (conn.kind === 'user') {
        handleUserMessage(conn, msg);
      } else {
        handleTempMessage(conn, msg);
      }
    });

    ws.on('close', () => {
      conns.delete(ws);
      if (conn) broadcastPresence(conn);
    });

    ws.on('error', (e) => logger.debug('ws_error', { message: e.message }));

    // 欢迎 + 在线列表
    ws.send(JSON.stringify({ type: 'hello', serverTime: Date.now() }));
    broadcastPresence(conn);
  });

  // 心跳:60s 无消息断开
  setInterval(() => {
    const now = Date.now();
    for (const [ws, c] of conns) {
      if (now - c.lastSeen > 90_000) {
        ws.close(4008, 'timeout');
        conns.delete(ws);
      }
    }
  }, 30_000).unref();

  // ---- 广播注入(路由层调用) ----
  setTempBroadcast((roomId, payload) => broadcastToRoom('temp', roomId, payload));
  setChatBroadcast((roomId, payload) => broadcastToRoom('user', roomId, payload));
  setOnlineMembers((roomId) => {
    const set = new Set<number>();
    for (const c of conns.values()) {
      if (c.kind === 'user' && c.roomId === roomId && c.userId) set.add(c.userId);
    }
    return [...set];
  });
}

/** 当前在线连接数 */
export function getOnlineCount(): number {
  return conns.size;
}

function handleUserMessage(conn: Conn, msg: { type?: string; roomId?: string; [k: string]: unknown }) {
  const roomId = String(msg.roomId || '');
  if (!roomId) return;
  const member = db.prepare('SELECT 1 FROM room_members WHERE room_id=? AND user_id=?').get(roomId, conn.userId);
  if (!member) {
    conn.ws.send(JSON.stringify({ type: 'error', error: 'not_member' }));
    return;
  }
  if (msg.type === 'subscribe') {
    conn.roomId = roomId;
    conn.ws.send(JSON.stringify({ type: 'subscribed', roomId }));
    broadcastPresence(conn);
  } else if (msg.type === 'read') {
    const lastSeq = Number(msg.lastSeq || 0);
    if (Number.isInteger(lastSeq) && lastSeq >= 0) {
      db.prepare('UPDATE room_members SET last_read_seq=? WHERE room_id=? AND user_id=?')
        .run(lastSeq, roomId, conn.userId);
      broadcastToRoom('user', roomId, { type: 'read', roomId, userId: conn.userId, lastSeq });
    }
  } else if (msg.type === 'ping') {
    conn.ws.send(JSON.stringify({ type: 'pong', t: Date.now() }));
  }
}

function handleTempMessage(conn: Conn, msg: { type?: string; [k: string]: unknown }) {
  if (msg.type === 'ping') {
    conn.ws.send(JSON.stringify({ type: 'pong', t: Date.now() }));
  }
  // 临时聊天消息写入走 REST(带限流+落盘);WS 仅做实时推送
}

function broadcastToRoom(kind: 'user' | 'temp', roomId: string, payload: unknown) {
  const data = JSON.stringify(payload);
  for (const [ws, c] of conns) {
    if (c.kind === kind && c.roomId === roomId && ws.readyState === WebSocket.OPEN) {
      try { ws.send(data); } catch { /* ignore */ }
    }
  }
}

function broadcastPresence(conn: Conn) {
  if (!conn.roomId) return;
  const { list, ips } = onlineFor(conn.roomId, conn.kind);
  const payload = { type: 'presence', roomId: conn.roomId, online: list, onlineIps: ips };
  broadcastToRoom(conn.kind, conn.roomId, payload);
}

/** 返回在线身份列表 + 按 IP 去重后的在线人数(用于"X 个IP在线"统计) */
function onlineFor(roomId: string, kind: 'user' | 'temp'): { list: (number | string)[]; ips: number } {
  const list: (number | string)[] = [];
  const ips = new Set<string>();
  for (const c of conns.values()) {
    if (c.kind === kind && c.roomId === roomId) {
      list.push(c.kind === 'user' ? c.userId! : c.anonId!);
      if (c.ip) ips.add(c.ip);
    }
  }
  return { list, ips: ips.size };
}
