/**
 * 通讯录 Tab(对齐 iOS ContactsTab + FindFriendsSheet):
 *  - 好友列表:头像 + 昵称(主 15px)+ 账号 ID(副 12px),点行弹「发消息 / 移除好友」
 *  - 搜索加好友:输入 ≥2 字符(纯数字按掩码手机号后 4 位)→ friendsExt.search → 一键添加
 *    (好友是即时互加,无申请/同意两步;未加显示「添加」,已是好友显示灰色「已添加」)
 *  - 发消息:复用(或新建)与对方的 DM 会话,成功后 goTab('chats')
 *  - 头像:avatarUrl 取 objectURL,失败回退 initialOf 首字母占位圆
 * 端点与类型全部在 ../api-ext.ts(只读契约,不要改)。
 */
import { useCallback, useEffect, useState } from 'react';
import { chatApi, keysApi } from '../../api';
import { useAuth } from '../../auth';
import { ensureIdentityKeys } from '../../crypto/keys';
import { generateSessionKey, wrapSessionKey } from '../../crypto/session';
import { friendsExt, avatarUrl, initialOf, type FriendEntry, type SearchUser } from '../api-ext';
import { goTab } from '../shell/tabNav';

/** 好友/搜索结果行的头像:有头像显示 objectURL 图片,否则回退首字母占位圆 */
function Avatar({ userId, updatedAt, nickname, token }: {
  userId: number;
  updatedAt: number | null;
  nickname: string;
  token: string;
}) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    if (!token) return;
    avatarUrl(userId, updatedAt, token).then((u) => {
      if (alive) setUrl(u);
    });
    return () => {
      alive = false;
    };
  }, [userId, updatedAt, token]);

  if (url) return <img className="mv-avatar" src={url} alt="" />;
  return <div className="mv-avatar">{initialOf(nickname)}</div>;
}

export default function ContactsScreen() {
  const { session } = useAuth();
  const token = session?.token || '';
  const myId = session?.userId || 0;

  /* 好友列表 */
  const [friends, setFriends] = useState<FriendEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadErr, setLoadErr] = useState('');

  /* 搜索加好友 sheet */
  const [sheetOpen, setSheetOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<SearchUser[]>([]);
  const [searching, setSearching] = useState(false);
  const [searchErr, setSearchErr] = useState('');
  const [addingId, setAddingId] = useState<number | null>(null);

  /* 点好友行的操作面板 + 全局错误 */
  const [actionTarget, setActionTarget] = useState<FriendEntry | null>(null);
  const [busy, setBusy] = useState<'dm' | 'remove' | null>(null);
  const [err, setErr] = useState('');

  const loadFriends = useCallback(
    async (silent = false) => {
      if (!token) return;
      if (!silent) setLoading(true);
      setLoadErr('');
      try {
        const r = await friendsExt.list(token);
        setFriends(r.friends);
      } catch (e) {
        setLoadErr(String((e as Error).message || e));
      } finally {
        if (!silent) setLoading(false);
      }
    },
    [token]
  );

  useEffect(() => {
    loadFriends();
  }, [loadFriends]);

  /* 搜索(≥2 字符,300ms 防抖) */
  useEffect(() => {
    const q = query.trim();
    if (!sheetOpen || q.length < 2) {
      setResults([]);
      setSearchErr('');
      setSearching(false);
      return;
    }
    let alive = true;
    const timer = window.setTimeout(() => {
      setSearching(true);
      setSearchErr('');
      friendsExt
        .search(q, token)
        .then((r) => {
          if (alive) setResults(r.users);
        })
        .catch((e) => {
          if (alive) setSearchErr(String((e as Error).message || e));
        })
        .finally(() => {
          if (alive) setSearching(false);
        });
    }, 300);
    return () => {
      alive = false;
      window.clearTimeout(timer);
    };
  }, [query, sheetOpen, token]);

  const openSheet = () => {
    setSheetOpen(true);
    setQuery('');
    setResults([]);
    setSearchErr('');
    setErr('');
  };

  const addFriend = async (u: SearchUser) => {
    if (addingId !== null) return;
    setAddingId(u.userId);
    setErr('');
    try {
      await friendsExt.add(u.userId, token);
      setResults((prev) => prev.map((x) => (x.userId === u.userId ? { ...x, isFriend: true } : x)));
      void loadFriends(true);
    } catch (e) {
      setErr(String((e as Error).message || e));
    } finally {
      setAddingId(null);
    }
  };

  /** 发消息:复用已有 DM,否则新建(生成会话密钥 + 逐设备包装) */
  const startDm = async (target: FriendEntry) => {
    setBusy('dm');
    setErr('');
    try {
      const roomsResp = await chatApi.rooms(token);
      const existing = roomsResp.rooms.find(
        (r) => r.type === 'dm' && r.memberIds.includes(target.userId)
      );
      if (!existing) {
        const me = await ensureIdentityKeys();
        const peerKeys = await keysApi.getUserKeys(target.userId, token);
        if (!peerKeys.devices.length) {
          setErr('对方还没有上传公钥,暂时无法发起私聊');
          return;
        }
        const key = generateSessionKey();
        const wrappedKeys: { userId: number; deviceId: string; wrappedKey: string }[] = [
          { userId: myId, deviceId: me.deviceId, wrappedKey: await wrapSessionKey(key, me.ecdhPub) },
        ];
        for (const d of peerKeys.devices) {
          wrappedKeys.push({
            userId: target.userId,
            deviceId: d.device_id,
            wrappedKey: await wrapSessionKey(key, d.ecdh_pub),
          });
        }
        await chatApi.createRoom({ type: 'dm', memberIds: [target.userId], wrappedKeys }, token);
      }
      setActionTarget(null);
      goTab('chats');
    } catch (e) {
      setErr(String((e as Error).message || e));
    } finally {
      setBusy(null);
    }
  };

  const removeFriend = async (target: FriendEntry) => {
    if (!window.confirm(`确定移除好友「${target.nickname}」吗?`)) return;
    setBusy('remove');
    setErr('');
    try {
      await friendsExt.remove(target.userId, token);
      setFriends((prev) => prev.filter((f) => f.userId !== target.userId));
      setActionTarget(null);
    } catch (e) {
      setErr(String((e as Error).message || e));
    } finally {
      setBusy(null);
    }
  };

  if (!session) return null;

  return (
    <div className="mv-page">
      <div className="mv-contacts-bar">
        <h2 className="mv-contacts-title">通讯录</h2>
        <button className="mv-link-btn" onClick={openSheet}>
          ＋ 添加
        </button>
      </div>

      {loading ? (
        <p className="mv-hint">加载中…</p>
      ) : loadErr ? (
        <p className="mv-error">{loadErr}</p>
      ) : friends.length === 0 ? (
        <p className="mv-hint">还没有好友,点右上角「＋ 添加」搜索加好友</p>
      ) : (
        <div className="mv-card">
          {friends.map((f) => (
            <button key={f.userId} className="mv-row" onClick={() => setActionTarget(f)}>
              <Avatar userId={f.userId} updatedAt={f.avatarUpdatedAt} nickname={f.nickname} token={token} />
              <span className="mv-row-main">
                <span className="mv-row-title">{f.nickname}</span>
                <span className="mv-row-sub">{f.handle}</span>
              </span>
              <span className="mv-row-chev">›</span>
            </button>
          ))}
        </div>
      )}

      {/* 搜索加好友 sheet(对齐 iOS FindFriendsSheet) */}
      {sheetOpen && (
        <div className="mv-sheet-mask" onClick={() => setSheetOpen(false)}>
          <div className="mv-sheet" onClick={(e) => e.stopPropagation()}>
            <div className="mv-sheet-head">
              <span className="mv-sheet-title">添加好友</span>
              <button className="mv-link-btn" onClick={() => setSheetOpen(false)}>
                取消
              </button>
            </div>
            <input
              className="mv-input"
              placeholder="搜索昵称或手机号后 4 位"
              value={query}
              autoFocus
              onChange={(e) => setQuery(e.target.value)}
            />
            {searching && <p className="mv-hint">搜索中…</p>}
            {searchErr && <p className="mv-error">{searchErr}</p>}
            {err && <p className="mv-error">{err}</p>}
            {!searching && !searchErr && query.trim().length >= 2 && results.length === 0 && (
              <p className="mv-hint">没有找到匹配的用户</p>
            )}
            {results.length > 0 && (
              <div className="mv-sheet-list">
                {results.map((u) => (
                  <div key={u.userId} className="mv-row mv-row-static">
                    <Avatar userId={u.userId} updatedAt={u.avatarUpdatedAt} nickname={u.nickname} token={token} />
                    <span className="mv-row-main">
                      <span className="mv-row-title">{u.nickname}</span>
                      <span className="mv-row-sub">{u.handle}</span>
                    </span>
                    {u.isFriend ? (
                      <span className="mv-chip mv-chip-done">已添加</span>
                    ) : (
                      <button
                        className="mv-chip"
                        disabled={addingId === u.userId}
                        onClick={() => addFriend(u)}
                      >
                        {addingId === u.userId ? '添加中…' : '添加'}
                      </button>
                    )}
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>
      )}

      {/* 点好友行的操作面板 */}
      {actionTarget && (
        <div className="mv-sheet-mask" onClick={() => { if (!busy) setActionTarget(null); }}>
          <div className="mv-sheet" onClick={(e) => e.stopPropagation()}>
            <div className="mv-sheet-head">
              <span className="mv-sheet-title">{actionTarget.nickname}</span>
              <button className="mv-link-btn" onClick={() => setActionTarget(null)} disabled={busy !== null}>
                取消
              </button>
            </div>
            {err && <p className="mv-error">{err}</p>}
            <div className="mv-sheet-list">
              <button className="mv-row" disabled={busy !== null} onClick={() => startDm(actionTarget)}>
                <span className="mv-row-icon">💬</span>
                <span className="mv-row-title">{busy === 'dm' ? '创建会话中…' : '发消息'}</span>
              </button>
              <button className="mv-row" disabled={busy !== null} onClick={() => removeFriend(actionTarget)}>
                <span className="mv-row-icon">🗑️</span>
                <span className="mv-row-title" style={{ color: '#d70015' }}>
                  {busy === 'remove' ? '移除中…' : '移除好友'}
                </span>
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
