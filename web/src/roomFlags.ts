/**
 * 会话本地开关(免打扰)—— Web / Android 端的 RoomFlagsStore 等价物。
 *
 * 与 iOS `Services/RoomFlagsStore.swift` 语义对齐:
 *  - 纯本地持久化(localStorage),服务端不感知、不上报
 *  - 免打扰只影响「本地通知 / 未读角标提示」,不影响消息正常接收与解密
 *  - key 与 iOS 侧保持一致语义:`lmh.room.muted.v1`
 */

const KEY = 'lmh.room.muted.v1';

type MutedMap = Record<string, number>;

function readAll(): MutedMap {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return {};
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {};
    const out: MutedMap = {};
    for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
      if (typeof v === 'number') out[k] = v;
    }
    return out;
  } catch {
    return {};
  }
}

function writeAll(map: MutedMap): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(map));
  } catch {
    /* 隐私模式 / 配额满:退化为本次会话内存态,不阻断聊天 */
  }
}

/** 该会话是否已开免打扰 */
export function isMuted(roomId: string): boolean {
  return !!readAll()[roomId];
}

/** 切换免打扰,返回切换后的状态 */
export function toggleMuted(roomId: string): boolean {
  const all = readAll();
  if (all[roomId]) {
    delete all[roomId];
  } else {
    all[roomId] = Date.now();
  }
  writeAll(all);
  return !!all[roomId];
}

/** 全部免打扰会话(便于通知层批量判断) */
export function mutedRooms(): string[] {
  return Object.keys(readAll());
}
