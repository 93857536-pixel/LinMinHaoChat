/**
 * Android 端新增端点封装(共享契约层 —— 主会话维护,业务代理只读不写)。
 *
 * 为什么单独一个文件:web/src/api.ts 是只读锚点,移动端新功能所需的端点在此追加,
 * 不污染既有 Web 端。所有字段名与 server/src/routes/*.ts 的响应**逐字对齐**。
 *
 * ⚠️ 好友模型是「即时互加」(server/src/routes/friends.ts 注释明确:无申请/同意两步),
 *    不要设计「待同意」流程。
 */
import { ApiError } from '../api';

const BASE = (globalThis as unknown as { __LMH_API_BASE__?: string }).__LMH_API_BASE__ || '/api';

export { ApiError };

async function req<T>(
  path: string,
  opts: { method?: string; body?: unknown; token?: string; raw?: boolean } = {}
): Promise<T> {
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
      const j = (await res.json()) as Record<string, unknown>;
      msg = String(j.error || msg);
      data = j;
    } catch { /* ignore */ }
    throw new ApiError(res.status, msg, data);
  }
  if (opts.raw) return res as unknown as T;
  return (await res.json()) as T;
}

/* ---------------- 类型(与 server 响应逐字对齐) ---------------- */

export interface MeUser {
  id: number;
  handle: string;
  nickname: string;
  createdAt: number;
  banned: boolean;
  hasAvatar: boolean;
  avatarUpdatedAt: number | null;
  realnameStatus: 'none' | 'pending' | 'verified' | string;
  realnameVerified: boolean;
  realnameNameMasked: string | null;
  realnameVerifiedAt: number | null;
}

export interface FriendEntry {
  userId: number;
  handle: string;
  nickname: string;
  hasAvatar: boolean;
  avatarUpdatedAt: number | null;
  phoneMasked: string | null;
  emailMasked: string | null;
  addedAt: number;
  initiator: 'mine' | 'theirs';
}

export interface SearchUser {
  userId: number;
  handle: string;
  nickname: string;
  hasAvatar: boolean;
  avatarUpdatedAt: number | null;
  phoneMasked: string | null;
  emailMasked: string | null;
  isFriend: boolean;
}

export interface RealnameStatus {
  ok: true;
  enabled: boolean;
  status: string;
  verified: boolean;
  nameMasked: string | null;
  idcardMasked: string | null;
  verifiedAt: number | null;
}

export interface RoomMember {
  userId: number;
  handle: string;
  nickname: string;
  hasAvatar: boolean;
  avatarUpdatedAt: number | null;
  role?: string;
}

/** 收藏项(严格对齐 server:GET /chat/starred 返回的 starred[] 元素)
 *  ⚠️ 服务端**故意不返回密文正文**(cipherPath 是内部相对路径),只给 iv + 定位信息;
 *     要读正文必须用 roomId + seq 去该房间的历史接口取(chatApi.history)。
 */
export interface StarredItem {
  msgId: string;
  roomId: string;
  seq: number;
  ts: number;
  kind: 'msg' | 'attachment';
  metaEnc: string | null;
  iv: string;
}

/* ---------------- 端点 ---------------- */

/** 我的资料(nickname / 头像版本 / 实名状态) */
export const meApi = {
  me: (token: string) => req<{ ok: true; user: MeUser }>('/auth/me', { token }),
  setNickname: (nickname: string, token: string) =>
    req<{ ok: true; user: { id: number; handle: string; nickname: string } }>('/auth/nickname', {
      body: { nickname },
      token,
    }),
};

/** 头像:上传/下载/删除。可见性=任何已登录用户(查找好友阶段就要能看到) */
export const avatarExt = {
  /** 上传原始图片字节(≤2MB;jpeg/png/webp) */
  upload: async (bytes: ArrayBuffer, mime: string, token: string): Promise<{ ok: true; hasAvatar: boolean; avatarUpdatedAt: number; size: number }> => {
    const res = await fetch(`${BASE}/avatars`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': mime },
      body: bytes,
    });
    if (!res.ok) throw new ApiError(res.status, 'avatar_upload_failed');
    return res.json();
  },
  download: async (userId: number | 'me', token: string): Promise<ArrayBuffer> => {
    const res = await fetch(`${BASE}/avatars/${userId}`, { headers: { Authorization: `Bearer ${token}` } });
    if (!res.ok) throw new ApiError(res.status, res.status === 404 ? 'no_avatar' : 'avatar_download_failed');
    return res.arrayBuffer();
  },
  remove: (token: string) => req<{ ok: true; hasAvatar: false }>('/avatars', { method: 'DELETE', token }),
};

/** 好友(即时互加,无申请/同意) */
export const friendsExt = {
  list: (token: string) => req<{ ok: true; friends: FriendEntry[] }>('/friends', { token }),
  /** query ≥2 字符;纯数字(≥4 位)按掩码手机号后缀搜,否则按 handle/nickname 模糊搜 */
  search: (query: string, token: string) =>
    req<{ ok: true; users: SearchUser[] }>(`/friends/search?query=${encodeURIComponent(query)}`, { token }),
  add: (userId: number, token: string) => req<{ ok: true }>('/friends', { body: { userId }, token }),
  remove: (userId: number, token: string) => req<{ ok: true }>(`/friends/${userId}`, { method: 'DELETE', token }),
};

/** 实名认证(一次性:已认证再提交必返 409 already_verified) */
export const realnameExt = {
  status: (token: string) => req<RealnameStatus>('/realname/status', { token }),
  verify: (name: string, idcard: string, token: string) =>
    req<RealnameStatus>('/realname/verify', { body: { name, idcard }, token }),
};

/** 群成员管理 */
export const membersExt = {
  list: (roomId: string, token: string) =>
    req<{ ok: true; members: RoomMember[] }>(`/chat/rooms/${roomId}/members`, { token }),
  remove: (roomId: string, userId: number, token: string) =>
    req<{ ok: true }>(`/chat/rooms/${roomId}/members/${userId}`, { method: 'DELETE', token }),
  add: (roomId: string, userId: number, token: string) =>
    req<{ ok: true }>(`/chat/rooms/${roomId}/add-member`, { body: { userId }, token }),
  leave: (roomId: string, token: string) =>
    req<{ ok: true }>(`/chat/rooms/${roomId}/leave`, { method: 'POST', token }),
};

/** 转发 + 收藏
 *  ⚠️ 转发契约以 server/src/routes/chat.ts 的 `/rooms/:id/forward` 为准(:id = 目标房间):
 *     服务端读取 { sourceMsgId, srcRoomId, cipher, iv, kind, meta, ts },并校验调用者同时是
 *     源/目标房间成员;目标 seq 由服务端计算(客户端加密时须用同样的 seq,故按目标房间 lastSeq+1 预估)。
 */
export const msgExt = {
  forward: (targetRoomId: string, body: { sourceMsgId: string; srcRoomId: string; cipher: string; iv: string; kind?: string; meta?: string; ts: number }, token: string) =>
    req<{ ok: true; seq: number; id: string; ts: number }>(`/chat/rooms/${targetRoomId}/forward`, { body, token }),
  star: (msgId: string, token: string) => req<{ ok: true }>(`/chat/messages/${msgId}/star`, { token }),
  unstar: (msgId: string, token: string) => req<{ ok: true }>(`/chat/messages/${msgId}/star`, { method: 'DELETE', token }),
  /** 返回字段是 `starred`(不是 items);已收藏再收藏会 409 already_starred */
  starred: (token: string) => req<{ ok: true; starred: StarredItem[] }>('/chat/starred', { token }),
};

/* ---------------- 工具 ---------------- */

/** 头像缓存(版本号 key),避免重复下载 */
const avatarCache = new Map<string, string>();

/** 取头像的 objectURL;失败返回 null(调用方回退到首字母占位) */
export async function avatarUrl(userId: number, updatedAt: number | null, token: string): Promise<string | null> {
  const key = `${userId}:${updatedAt ?? 0}`;
  const hit = avatarCache.get(key);
  if (hit) return hit;
  try {
    const buf = await avatarExt.download(userId, token);
    const url = URL.createObjectURL(new Blob([buf]));
    avatarCache.set(key, url);
    return url;
  } catch {
    return null;
  }
}

/** 显示名 → 首字母/首字(占位头像用) */
export function initialOf(name: string): string {
  const s = (name || '?').trim();
  return s ? Array.from(s)[0] : '?';
}
