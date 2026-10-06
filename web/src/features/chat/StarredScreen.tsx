/**
 * 收藏列表(对应 iOS StarredListView)。
 *
 * 消息是 E2EE 的:服务器只存密文,收藏列表只返回 iv/cipher。要显示内容,
 * 必须按 roomId 分组拉取会话密钥(wrapped keys → unwrapSessionKey),再逐条
 * decryptMessage 解回原文。解密失败(密钥丢失/被移出群/密文损坏)降级为「无法解密」,不崩溃。
 */
import { useEffect, useState } from 'react';
import { useAuth } from '../../auth';
import { chatApi } from '../../api';
import { msgExt, type StarredItem } from '../api-ext';
import { decryptMessage, decodeMessageBody } from '../../crypto/message';
import { unwrapSessionKey, type Bytes } from '../../crypto/session';

interface StarredRow {
  item: StarredItem;
  senderLabel: string;
  summary: string;
  attMime: string | null;
  failed: boolean;
}

function mimeIcon(mime: string): string {
  if (mime.startsWith('image/')) return '🖼';
  if (mime.startsWith('audio/')) return '🎙';
  return '📎';
}

/** 拉取并解包某个房间的会话密钥;失败抛错(由调用方降级处理) */
async function getRoomKey(roomId: string, deviceId: string, token: string): Promise<Bytes> {
  const wrapped = await chatApi.keys(roomId, deviceId, token);
  for (const w of wrapped.keys) {
    try {
      return await unwrapSessionKey(w);
    } catch {
      /* 尝试下一个 wrapped key */
    }
  }
  throw new Error('no session key');
}

export default function StarredScreen({ onBack }: { onBack: () => void }) {
  const { session, identity } = useAuth();
  const [rows, setRows] = useState<StarredRow[]>([]);
  const [err, setErr] = useState('');

  useEffect(() => {
    if (!session) return;
    let cancelled = false;
    const token = session.token;
    const deviceId = identity?.deviceId || session.deviceId || 'default';
    const myId = session.userId;
    (async () => {
      try {
        const { starred } = await msgExt.starred(token);
        const keyCache = new Map<string, Bytes>();
        const histCache = new Map<string, { seq: number; ts: number; iv: string; cipher: string; senderId: number | null }[]>();
        const built: StarredRow[] = [];
        for (const it of starred) {
          try {
            let key = keyCache.get(it.roomId);
            if (!key) {
              key = await getRoomKey(it.roomId, deviceId, token);
              keyCache.set(it.roomId, key);
            }
            // ⚠️ 服务端不返回收藏消息的密文正文,只给 iv + seq → 必须去该房间历史里按 seq 取
            let hist = histCache.get(it.roomId);
            if (!hist) {
              const h = await chatApi.history(it.roomId, token, 0, 1000);
              hist = h.messages.map((m) => ({ seq: m.seq, ts: m.ts, iv: m.iv, cipher: m.cipher, senderId: m.senderId }));
              histCache.set(it.roomId, hist);
            }
            const msg = hist.find((m) => m.seq === it.seq);
            if (!msg) throw new Error('源消息不在该房间历史中');
            const senderLabel = msg.senderId == null ? '系统' : msg.senderId === myId ? '我' : `用户 #${msg.senderId}`;
            const raw = await decryptMessage(key, { iv: msg.iv, ct: msg.cipher }, it.roomId, it.seq, it.ts);
            const body = decodeMessageBody(raw);
            if (it.kind === 'attachment' && body.f) {
              built.push({ item: it, senderLabel, summary: body.f.name, attMime: body.f.mime, failed: false });
            } else {
              built.push({ item: it, senderLabel, summary: body.t ?? '', attMime: null, failed: false });
            }
          } catch {
            built.push({ item: it, senderLabel: '—', summary: '', attMime: null, failed: true });
          }
        }
        if (!cancelled) setRows(built);
      } catch (e) {
        if (!cancelled) setErr(String((e as Error)?.message || e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [session, identity]);

  const unstar = async (msgId: string) => {
    if (!session) return;
    try {
      await msgExt.unstar(msgId, session.token);
      setRows((prev) => prev.filter((r) => r.item.msgId !== msgId));
    } catch (e) {
      setErr(String((e as Error)?.message || e));
    }
  };

  return (
    <div className="mv-page">
      <div className="mv-navbar">
        <button className="mv-back" onClick={onBack}>‹</button>
        <span className="mv-navbar-title">收藏</span>
        <span style={{ width: 40 }} />
      </div>
      {err && <p className="mv-error">{err}</p>}
      {rows.length === 0 && !err && <p className="mv-hint">暂无收藏消息</p>}
      <div className="mv-card">
        {rows.map((r) => (
          <div key={r.item.msgId} className="mv-row mv-row-static">
            <span className="mv-row-icon">{r.failed ? '🔒' : r.attMime ? mimeIcon(r.attMime) : '💬'}</span>
            <span className="mv-row-main">
              <span className="mv-row-title">{r.failed ? '无法解密' : r.summary || '(空消息)'}</span>
              <span className="mv-row-sub">
                {r.senderLabel} · {new Date(r.item.ts).toLocaleString('zh-CN')}
              </span>
            </span>
            <button className="mv-link-btn mv-link-danger" onClick={() => unstar(r.item.msgId)}>
              取消收藏
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}
