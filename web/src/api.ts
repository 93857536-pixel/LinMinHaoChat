/** REST API 客户端(统一错误处理 + 认证头) */

const BASE = '/api';

export class ApiError extends Error {
  status: number;
  data?: Record<string, unknown>;
  constructor(status: number, message: string, data?: Record<string, unknown>) {
    super(message);
    this.status = status;
    this.data = data;
  }
}

async function request<T>(path: string, opts: { method?: string; body?: unknown; token?: string | null; raw?: boolean } = {}): Promise<T> {
  const headers: Record<string, string> = {};
  if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
  if (opts.token) headers['Authorization'] = `Bearer ${opts.token}`;
  const res = await fetch(BASE + path, {
    method: opts.method || (opts.body !== undefined ? 'POST' : 'GET'),
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
  });
  if (!res.ok) {
    let msg = res.statusText;
    let data: Record<string, unknown> | undefined;
    try {
      const j = await res.json();
      msg = j.error || msg;
      data = j;
    } catch { /* ignore */ }
    throw new ApiError(res.status, msg, data);
  }
  if (opts.raw) return res as unknown as T;
  return (await res.json()) as T;
}

/* ---------- 认证 ---------- */
export const authApi = {
  sendCode: (type: 'sms' | 'email', target: string) =>
    request<{ ok: true; expiresInSec: number }>('/auth/send-code', { body: { type, target } }),
  register: (body: { type: 'sms' | 'email'; target: string; code: string; handle?: string; deviceId?: string; ed25519Pub?: string; ecdhPub?: string }) =>
    request<{ ok: true; token: string; sessionId: string; user: { id: number; handle?: string } }>('/auth/register', { body }),
  login: (body: { type: 'sms' | 'email'; target: string; code: string; deviceId?: string; ed25519Pub?: string; ecdhPub?: string }) =>
    request<{ ok: true; token: string; sessionId: string; user: { id: number; handle?: string } }>('/auth/login', { body }),
  logout: (sessionId: string) => request('/auth/logout', { body: { sessionId } }),
};

/* ---------- 密钥 ---------- */
export const keysApi = {
  register: (body: { ed25519Pub: string; ecdhPub: string; deviceId: string }, token: string) =>
    request('/keys/register', { body, token }),
  saveExportPackage: (pkg: string, deviceId: string, token: string) =>
    request('/keys/export-package', { body: { pkg, deviceId }, token }),
  getExportPackage: (deviceId: string, token: string) =>
    request<{ ok: true; pkg: string | null }>(`/keys/export-package?deviceId=${encodeURIComponent(deviceId)}`, { token }),
  getUserKeys: (userId: number, token: string) =>
    request<{ ok: true; devices: { device_id: string; ed25519_pub: string; ecdh_pub: string }[] }>(`/keys/public/${userId}`, { token }),
  lookup: (q: string, token: string) =>
    request<{ ok: true; user: { id: number; handle: string } }>(`/keys/lookup?q=${encodeURIComponent(q)}`, { token }),
};

/* ---------- 临时聊天 ---------- */
export const tempApi = {
  create: () => request<{ ok: true; roomId: string; expiresAt: number }>('/temp/rooms', { method: 'POST' }),
  info: (roomId: string) =>
    request<{ ok: true; roomId: string; createdAt: number; expiresAt: number; expired: boolean; status: string; messageCount: number }>(`/temp/rooms/${roomId}`),
  join: (roomId: string, anonId?: string) =>
    request<{ ok: true; anonId: string; wsToken: string; wsUrl: string }>(`/temp/rooms/${roomId}/join`, { method: 'POST', body: anonId ? { anonId } : undefined }),
  send: (roomId: string, body: { iv: string; cipher: string; anonId?: string; meta?: string; seq: number; ts: number }) =>
    request<{ ok: true; seq: number; id: string; ts: number }>(`/temp/rooms/${roomId}/messages`, { method: 'POST', body }),
  history: (roomId: string, afterSeq?: number, limit = 100) =>
    request<{ ok: true; messages: TempMsg[]; hasMore: boolean }>(`/temp/rooms/${roomId}/messages?afterSeq=${afterSeq || 0}&limit=${limit}`),
  leave: (roomId: string) => request(`/temp/rooms/${roomId}/leave`, { method: 'POST' }),
};

/* ---------- 邀请聊天 ---------- */
export const inviteApi = {
  create: () =>
    request<{ ok: true; inviteId: string; roomId: string; code: string; expiresAt: number; codeExpiresAt: number; link: string }>('/invite/create', { method: 'POST' }),
  info: (inviteId: string) =>
    request<{ ok: true; inviteId: string; roomId: string; codeExpired: boolean; roomExpired: boolean; roomStatus: string; messageCount: number; roomKind: string }>(`/invite/${inviteId}`),
  join: (inviteId: string, body: { code: string; token?: string | null; anonId?: string | null }) =>
    request<{ ok: true; roomId: string; anonId: string; displayName: string; wsToken: string; wsUrl: string }>(`/invite/${inviteId}/join`, { method: 'POST', body }),
  room: (inviteId: string) =>
    request<{ ok: true; roomId: string; createdAt: number; expiresAt: number; expired: boolean; messageCount: number }>(`/invite/${inviteId}/room`),
};

export interface TempMsg {
  id: string;
  seq: number;
  anonId: string | null;
  ts: number;
  iv: string;
  aad: string;
  meta: string | null;
  cipher: string;
}

/* ---------- 账号聊天 ---------- */
export const chatApi = {
  rooms: (token: string) =>
    request<{ ok: true; rooms: RoomMeta[] }>('/chat/rooms', { token }),
  createRoom: (body: { type: 'dm' | 'group'; memberIds: number[]; nameEnc?: string; wrappedKeys: { userId: number; deviceId: string; wrappedKey: string }[] }, token: string) =>
    request<{ ok: true; room: RoomMeta }>('/chat/rooms', { body, token }),
  room: (roomId: string, token: string) =>
    request<{ ok: true; room: RoomMeta }>(`/chat/rooms/${roomId}`, { token }),
  keys: (roomId: string, deviceId: string, token: string) =>
    request<{ ok: true; keys: string[] }>(`/chat/rooms/${roomId}/keys?deviceId=${encodeURIComponent(deviceId)}`, { token }),
  addKey: (roomId: string, body: { userId: number; deviceId: string; wrappedKey: string }, token: string) =>
    request(`/chat/rooms/${roomId}/keys`, { body, token }),
  addMember: (roomId: string, userId: number, token: string) =>
    request(`/chat/rooms/${roomId}/add-member`, { body: { userId }, token }),
  send: (roomId: string, body: { iv: string; cipher: string; kind?: 'msg' | 'attachment'; meta?: string; seq: number; ts: number }, token: string) =>
    request<{ ok: true; seq: number; id: string; ts: number }>(`/chat/rooms/${roomId}/messages`, { method: 'POST', body, token }),
  history: (roomId: string, token: string, afterSeq?: number, limit = 100) =>
    request<{ ok: true; messages: ChatMsg[]; hasMore: boolean }>(`/chat/rooms/${roomId}/messages?afterSeq=${afterSeq || 0}&limit=${limit}`, { token }),
  read: (roomId: string, lastSeq: number, token: string) =>
    request(`/chat/rooms/${roomId}/read`, { body: { lastSeq }, token }),
  online: (roomId: string, token: string) =>
    request<{ ok: true; online: number[] }>(`/chat/rooms/${roomId}/online`, { token }),
};

export interface RoomMeta {
  id: string;
  type: 'dm' | 'group';
  nameEnc: string | null;
  createdAt: number;
  memberIds: number[];
  unread: number;
  lastSeq: number;
}

export interface ChatMsg {
  id: string;
  seq: number;
  senderId: number | null;
  ts: number;
  iv: string;
  aad: string;
  kind: 'msg' | 'attachment';
  meta: string | null;
  cipher: string;
}

/* ---------- 附件 ---------- */
export const attachmentApi = {
  upload: async (roomId: string, declaredMime: string, data: ArrayBuffer, token: string): Promise<{ ok: true; attId: string; size: number }> => {
    const res = await fetch(`${BASE}/attachments?roomId=${encodeURIComponent(roomId)}&declaredMime=${encodeURIComponent(declaredMime)}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}` },
      body: data,
    });
    if (!res.ok) throw new ApiError(res.status, 'upload_failed');
    return res.json();
  },
  download: async (attId: string, token: string): Promise<ArrayBuffer> => {
    const res = await fetch(`${BASE}/attachments/${attId}`, { headers: { Authorization: `Bearer ${token}` } });
    if (!res.ok) throw new ApiError(res.status, 'download_failed');
    return res.arrayBuffer();
  },
};

/* ---------- 管理员 ---------- */
export const adminApi = {
  login: (username: string, password: string) =>
    request<{ ok: true; token: string }>('/admin/login', { body: { username, password } }),
  stats: (token: string) =>
    request<{ ok: true; stats: Record<string, unknown> }>('/admin/stats', { token }),
  users: (token: string, page = 1) =>
    request<{ ok: true; users: Record<string, unknown>[]; total: number; page: number }>(`/admin/users?page=${page}`, { token }),
  banUser: (id: number, ban: boolean, token: string, reason?: string) =>
    request(`/admin/users/${id}/ban`, { body: { ban, reason }, token }),
  deleteUser: (id: number, token: string) => request(`/admin/users/${id}`, { method: 'DELETE', token }),
  tempRooms: (token: string, page = 1) =>
    request<{ ok: true; rooms: Record<string, unknown>[]; total: number; page: number }>(`/admin/temp-rooms?page=${page}`, { token }),
  banTempRoom: (id: string, ban: boolean, token: string) =>
    request(`/admin/temp-rooms/${id}/ban`, { body: { ban }, token }),
  deleteTempRoom: (id: string, token: string) => request(`/admin/temp-rooms/${id}`, { method: 'DELETE', token }),
  logs: (token: string, lines = 100) =>
    request<{ ok: true; logs: string[] }>(`/admin/logs?lines=${lines}`, { token }),
  audit: (token: string) =>
    request<{ ok: true; audit: Record<string, unknown>[] }>('/admin/audit', { token }),
  health: () => request<{ ok: true; db: boolean; uptime: number; ts: number }>('/health'),
};
