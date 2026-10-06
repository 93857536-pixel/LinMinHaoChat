/**
 * 转发选择器:底部弹出,列出我的其他会话,选中后调用 forwardTo 转发。
 * 源消息的 seq/ts 不在 props 里(解密原文需要),这里用 msgId 从历史里回查。
 */
import { useEffect, useState } from 'react';
import { useAuth } from '../../auth';
import { chatApi, type RoomMeta } from '../../api';
import { forwardTo } from './forward';

export default function ForwardDialog({
  open,
  roomId,
  msgId,
  payload,
  onClose,
}: {
  open: boolean;
  roomId: string;
  msgId: string;
  payload: { iv: string; cipher: string; kind: string; meta?: string };
  onClose: () => void;
}) {
  const { session } = useAuth();
  const [rooms, setRooms] = useState<RoomMeta[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState('');

  useEffect(() => {
    if (!open || !session) return;
    let cancelled = false;
    chatApi
      .rooms(session.token)
      .then((r) => {
        if (!cancelled) setRooms(r.rooms.filter((x) => x.id !== roomId));
      })
      .catch((e) => {
        if (!cancelled) setErr(String((e as Error)?.message || e));
      });
    return () => {
      cancelled = true;
    };
  }, [open, session, roomId]);

  if (!open || !session) return null;

  const doForward = async (target: RoomMeta) => {
    setBusy(target.id);
    setErr('');
    try {
      // 回查源消息的 seq/ts(decryptMessage 的 AAD 需要)
      const hist = await chatApi.history(roomId, session.token, 0, 1000);
      const src = hist.messages.find((m) => m.id === msgId);
      if (!src) throw new Error('源消息不存在,无法转发');
      await forwardTo(session.token, target.id, payload, { roomId, seq: src.seq, ts: src.ts, msgId });
      onClose();
    } catch (e) {
      setErr(String((e as Error)?.message || e));
    } finally {
      setBusy(null);
    }
  };

  const title = (r: RoomMeta) => {
    if (r.type === 'group') return '群聊';
    const other = r.memberIds.find((id) => id !== session.userId);
    return other ? `用户 #${other}` : '会话';
  };

  return (
    <div className="mv-sheet" onClick={onClose}>
      <div className="mv-sheet-panel" onClick={(e) => e.stopPropagation()}>
        <div className="mv-sheet-title">转发到</div>
        {err && <p className="mv-error">{err}</p>}
        {rooms.length === 0 && !err && <p className="mv-hint">没有其他会话</p>}
        <div className="mv-card">
          {rooms.map((r) => (
            <button
              key={r.id}
              className="mv-row"
              disabled={busy === r.id}
              onClick={() => doForward(r)}
            >
              <span className="mv-row-icon">{r.type === 'group' ? '👥' : '💬'}</span>
              <span className="mv-row-main">
                <span className="mv-row-title">{title(r)}</span>
                <span className="mv-row-sub">#{r.id.slice(0, 8)}</span>
              </span>
              {busy === r.id && <span className="mv-row-sub">发送中…</span>}
            </button>
          ))}
        </div>
        <button className="mv-sheet-action mv-sheet-cancel" onClick={onClose}>取消</button>
      </div>
    </div>
  );
}
