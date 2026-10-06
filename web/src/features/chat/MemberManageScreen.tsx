/**
 * 群成员管理:成员列表(头像+昵称+账号ID)、移出成员、邀请好友、退出群聊。
 */
import { useEffect, useState } from 'react';
import { useAuth } from '../../auth';
import {
  membersExt,
  friendsExt,
  avatarUrl,
  initialOf,
  type RoomMember,
  type FriendEntry,
} from '../api-ext';

function MemberAvatar({
  userId,
  name,
  updatedAt,
}: {
  userId: number;
  name: string;
  updatedAt: number | null;
}) {
  const { session } = useAuth();
  const [url, setUrl] = useState<string | null>(null);

  useEffect(() => {
    if (!session) return;
    let cancelled = false;
    avatarUrl(userId, updatedAt, session.token)
      .then((u) => {
        if (!cancelled) setUrl(u);
      })
      .catch(() => {
        /* 回退到首字母占位 */
      });
    return () => {
      cancelled = true;
    };
  }, [userId, updatedAt, session]);

  return (
    <span className="mv-avatar">
      {url ? <img src={url} alt="" className="mv-avatar-img" /> : initialOf(name)}
    </span>
  );
}

export default function MemberManageScreen({ roomId, onBack }: { roomId: string; onBack: () => void }) {
  const { session } = useAuth();
  const [members, setMembers] = useState<RoomMember[]>([]);
  const [friends, setFriends] = useState<FriendEntry[]>([]);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!session) return;
    let cancelled = false;
    Promise.all([membersExt.list(roomId, session.token), friendsExt.list(session.token)])
      .then(([m, f]) => {
        if (cancelled) return;
        setMembers(m.members);
        setFriends(f.friends);
      })
      .catch((e) => {
        if (!cancelled) setErr(String((e as Error)?.message || e));
      });
    return () => {
      cancelled = true;
    };
  }, [roomId, session]);

  if (!session) return null;
  const myId = session.userId;
  const memberIds = new Set(members.map((m) => m.userId));
  const candidates = friends.filter((f) => !memberIds.has(f.userId));

  const removeMember = async (m: RoomMember) => {
    if (!window.confirm(`确定将「${m.nickname || m.handle || `用户 #${m.userId}`}」移出群聊?`)) return;
    setBusy(true);
    setErr('');
    try {
      await membersExt.remove(roomId, m.userId, session.token);
      setMembers((prev) => prev.filter((x) => x.userId !== m.userId));
    } catch (e) {
      setErr(String((e as Error)?.message || e));
    } finally {
      setBusy(false);
    }
  };

  const addMember = async (f: FriendEntry) => {
    setBusy(true);
    setErr('');
    try {
      await membersExt.add(roomId, f.userId, session.token);
      setMembers((prev) =>
        prev.some((m) => m.userId === f.userId)
          ? prev
          : [
              ...prev,
              {
                userId: f.userId,
                handle: f.handle,
                nickname: f.nickname,
                hasAvatar: f.hasAvatar,
                avatarUpdatedAt: f.avatarUpdatedAt,
              },
            ],
      );
    } catch (e) {
      setErr(String((e as Error)?.message || e));
    } finally {
      setBusy(false);
    }
  };

  const leaveRoom = async () => {
    if (!window.confirm('确定退出该群聊?退出后将无法查看历史消息。')) return;
    setBusy(true);
    setErr('');
    try {
      await membersExt.leave(roomId, session.token);
      onBack();
    } catch (e) {
      setErr(String((e as Error)?.message || e));
      setBusy(false);
    }
  };

  const displayName = (m: { nickname: string; handle: string; userId: number }) =>
    m.nickname || m.handle || `用户 #${m.userId}`;

  return (
    <div className="mv-page">
      <div className="mv-navbar">
        <button className="mv-back" onClick={onBack}>‹</button>
        <span className="mv-navbar-title">群成员</span>
        <span style={{ width: 40 }} />
      </div>
      {err && <p className="mv-error">{err}</p>}

      <div className="mv-section-label">成员({members.length})</div>
      <div className="mv-card">
        {members.map((m) => (
          <div key={m.userId} className="mv-row mv-row-static">
            <MemberAvatar userId={m.userId} name={m.nickname || m.handle} updatedAt={m.avatarUpdatedAt} />
            <span className="mv-row-main">
              <span className="mv-row-title">
                {displayName(m)}
                {m.userId === myId ? ' (我)' : ''}
                {m.role ? ` · ${m.role}` : ''}
              </span>
              <span className="mv-row-sub">
                账号 #{m.userId}
                {m.handle ? ` · @${m.handle}` : ''}
              </span>
            </span>
            {m.userId !== myId && (
              <button className="mv-link-btn mv-link-danger" onClick={() => removeMember(m)} disabled={busy}>
                移出
              </button>
            )}
          </div>
        ))}
        {members.length === 0 && !err && <p className="mv-hint">暂无成员</p>}
      </div>

      <div className="mv-section-label">邀请好友</div>
      <div className="mv-card">
        {candidates.length === 0 && <p className="mv-hint">没有可邀请的好友</p>}
        {candidates.map((f) => (
          <div key={f.userId} className="mv-row mv-row-static">
            <MemberAvatar userId={f.userId} name={f.nickname || f.handle} updatedAt={f.avatarUpdatedAt} />
            <span className="mv-row-main">
              <span className="mv-row-title">{displayName(f)}</span>
              <span className="mv-row-sub">
                账号 #{f.userId}
                {f.handle ? ` · @${f.handle}` : ''}
              </span>
            </span>
            <button className="mv-link-btn" onClick={() => addMember(f)} disabled={busy}>
              邀请
            </button>
          </div>
        ))}
      </div>

      <button className="mv-btn mv-btn-danger mv-btn-block" onClick={leaveRoom} disabled={busy}>
        退出群聊
      </button>
    </div>
  );
}
