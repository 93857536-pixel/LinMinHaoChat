/**
 * 临时聊天页(/t/:roomId#k=密钥)
 *
 * 核心语义:
 *  - 会话密钥在 URL fragment(#k=)中,不经过服务器
 *  - 「刷新即焚」:本页挂载时若检测到本会话的 active 标记,
 *    立即清除 URL fragment + sessionStorage + 内存密钥,界面清空
 *  - 「退出」:同样清除本地一切临时状态;服务器保留密文归档
 *  - 消息:客户端 AES-GCM 加密后经 REST 上传,WS 只做实时事件通知
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { tempApi, ApiError } from '../api';
import { parseTempShareKey, type Bytes } from '../crypto/session';
import { encryptMessage, decryptMessage, encodeMessageBody, decodeMessageBody } from '../crypto/message';
import { connectWs, type WsMsg, type WsHandle } from '../ws';

interface DecryptedMsg {
  id: string;
  seq: number;
  sender: 'me' | 'other' | string;
  anonId?: string;
  ts: number;
  text: string;
}

const ACTIVE_KEY = 'lmh.temp.active';

export default function TempChat() {
  const nav = useNavigate();
  const roomId = location.pathname.split('/t/')[1] || '';
  const [phase, setPhase] = useState<'loading' | 'ready' | 'burned' | 'error' | 'expired'>('loading');
  const [messages, setMessages] = useState<DecryptedMsg[]>([]);
  const [shareUrl, setShareUrl] = useState('');
  const [online, setOnline] = useState<(string | number)[]>([]);
  const [onlineIps, setOnlineIps] = useState(0);
  const [input, setInput] = useState('');
  const [sending, setSending] = useState(false);
  const [burnMsg, setBurnMsg] = useState('');
  const keyRef = useRef<Bytes | null>(null);
  const anonRef = useRef('');
  /** 匿名身份 → 全局统一标签:服务器分配 g{房间内递增序号}/u{账号id},所有客户端看到同一人相同 */
  const labelFor = useCallback((anonId: string) => {
    if (!anonId) return '???';
    const g = anonId.match(/^g(\d+)$/);
    if (g) return `访客${String(Number(g[1])).padStart(3, '0')}`; // g5 → 访客005
    if (anonId.startsWith('u')) return `账号${anonId.slice(1)}`; // u3 → 账号3
    // 旧数据(随机串)兜底:确定性散列,所有人对同一人编号一致
    let h = 0;
    for (let i = 0; i < anonId.length; i++) h = (h * 31 + anonId.charCodeAt(i)) >>> 0;
    return `访客${100 + (h % 900)}`;
  }, []);
  const lastSeqRef = useRef(0);
  const closeWsRef = useRef<WsHandle | null>(null);
  const reconnectTimer = useRef<number | null>(null);
  const cancelledRef = useRef(false);
  /** 当前短令牌(join 颁发,5 分钟有效期内可重复连接;失效后重新 join) */
  const wsTokenRef = useRef<string | null>(null);
  /** WS 当前是否在线(断线期间靠轮询兜底补收) */
  const wsConnectedRef = useRef(false);
  const listRef = useRef<HTMLDivElement>(null);

  /** 刷新/退出即焚:清 fragment + 标记 + 内存密钥 */
  const burn = useCallback((reason: string) => {
    keyRef.current = null;
    anonRef.current = '';
    wsTokenRef.current = null;
    wsConnectedRef.current = false;
    closeWsRef.current?.close();
    closeWsRef.current = null;
    sessionStorage.removeItem(ACTIVE_KEY);
    try {
      history.replaceState(null, '', location.pathname); // 去掉 #k= fragment
    } catch { /* ignore */ }
    setMessages([]);
    setBurnMsg(reason);
    setPhase('burned');
  }, []);

  useEffect(() => {
    const fragment = location.hash;
    let cancelled = false;
    let pollTimer: number | undefined;

    (async () => {
      // 刷新检测:已有 active 标记 → 立即即焚
      if (sessionStorage.getItem(ACTIVE_KEY) === roomId) {
        burn('页面已刷新,本地会话状态与临时密钥已立即清除。\n(服务器上的加密归档仍保留)');
        return;
      }

      // 需要密钥:来自分享链接 fragment
      const key = parseTempShareKey(fragment);
      if (!key) {
        setPhase('error');
        return;
      }

      try {
        const info = await tempApi.info(roomId);
        if (cancelled) return;
        if (info.expired || info.status !== 'active') {
          setPhase('expired');
          return;
        }

        keyRef.current = key;
        sessionStorage.setItem(ACTIVE_KEY, roomId);
        setShareUrl(location.href);

        // 加入房间(拿 WS 短令牌);携带持久化身份,刷新/重连保持同一编号
        const prevAnon = sessionStorage.getItem('anon:' + roomId) || undefined;
        const join = await tempApi.join(roomId, prevAnon);
        sessionStorage.setItem('anon:' + roomId, join.anonId);
        anonRef.current = join.anonId;
        labelFor(join.anonId); // 注册自己的全局编号

        // 拉历史并解密
        const hist = await tempApi.history(roomId, 0, 500);
        const decrypted: DecryptedMsg[] = [];
        for (const m of hist.messages) {
          try {
            const text = await decryptMessage(key, { iv: m.iv, ct: m.cipher }, roomId, m.seq, m.ts);
            decrypted.push({ id: m.id, seq: m.seq, sender: m.anonId === join.anonId ? 'me' : 'other', anonId: m.anonId || undefined, ts: m.ts, text });
          } catch { /* 无法解密的消息(密钥不匹配)跳过 */ }
        }
        decrypted.sort((a, b) => a.seq - b.seq);
        setMessages(decrypted);
        lastSeqRef.current = decrypted.length ? decrypted[decrypted.length - 1].seq : 0;

        // WS 实时通知(断线自动重连;令牌存入 ref,重连时复用避免重复 join 触发限流)
        wsTokenRef.current = join.wsToken;
        void connectRoomWs(0);

        // 断线兜底:WS 断开期间定时轮询补收,避免断线期间的消息丢失
        pollTimer = window.setInterval(() => {
          if (!wsConnectedRef.current && !cancelled) pullNew();
        }, 15_000);

        if (!cancelled) setPhase('ready');
      } catch (e) {
        if (cancelled) return;
        if (e instanceof ApiError && (e.status === 403 || e.status === 404)) setPhase('expired');
        else setPhase('error');
      }
    })();

    return () => {
      cancelled = true;
      cancelledRef.current = true;
      if (pollTimer !== undefined) window.clearInterval(pollTimer);
      if (reconnectTimer.current !== null) window.clearTimeout(reconnectTimer.current);
      closeWsRef.current?.close();
    };
  }, [roomId, burn]);

  const pullNew = useCallback(async () => {
    const key = keyRef.current;
    if (!key) return;
    try {
      const hist = await tempApi.history(roomId, lastSeqRef.current, 200);
      const decrypted: DecryptedMsg[] = [];
      for (const m of hist.messages) {
        if (m.seq <= lastSeqRef.current) continue;
        try {
          const text = await decryptMessage(key, { iv: m.iv, ct: m.cipher }, roomId, m.seq, m.ts);
          decrypted.push({ id: m.id, seq: m.seq, sender: m.anonId === anonRef.current ? 'me' : 'other', anonId: m.anonId || undefined, ts: m.ts, text });
        } catch { /* skip */ }
      }
      if (decrypted.length) {
        lastSeqRef.current = Math.max(lastSeqRef.current, ...decrypted.map((d) => d.seq));
        setMessages((prev) => {
          const seen = new Set(prev.map((p) => p.seq));
          return [...prev, ...decrypted.filter((d) => !seen.has(d.seq))].sort((a, b) => a.seq - b.seq);
        });
      }
    } catch { /* ignore */ }
  }, [roomId]);

  useEffect(() => {
    listRef.current?.scrollTo({ top: listRef.current.scrollHeight });
  }, [messages]);

  /** 断线自动重连:优先复用已颁发的短令牌(5 分钟有效期内可重复连接,不再每次重连都 join,
   *  避免重连风暴烧光 join 限流导致 429 锁死);令牌失效(4001)才重新 join,
   *  携带原身份保持编号不变 */
  const connectRoomWs = useCallback(async (attempt: number) => {
    if (cancelledRef.current) return;
    let token = wsTokenRef.current;
    if (!token) {
      try {
        const join = await tempApi.join(roomId, anonRef.current || undefined);
        anonRef.current = join.anonId;
        wsTokenRef.current = join.wsToken;
        token = join.wsToken;
      } catch {
        if (cancelledRef.current) return;
        const delay = Math.min(1000 * 2 ** attempt, 15000);
        reconnectTimer.current = window.setTimeout(() => connectRoomWs(attempt + 1), delay);
        return;
      }
    }
    const handle = connectWs(token, {
      onMessage: (m: WsMsg) => {
        if (m.type === 'presence') {
          setOnline(Array.isArray(m.online) ? m.online : []);
          if (typeof m.onlineIps === 'number') setOnlineIps(m.onlineIps);
        }
        if (m.type === 'msg' && m.seq > lastSeqRef.current) pullNew();
      },
      onOpen: () => {
        wsConnectedRef.current = true;
        pullNew(); // 补收断线期间的消息
      },
      onClose: (e) => {
        wsConnectedRef.current = false;
        if (cancelledRef.current) return;
        // 4001 = 令牌失效/过期 → 丢弃令牌,下次重连重新 join
        if (e?.code === 4001) wsTokenRef.current = null;
        const delay = Math.min(1000 * 2 ** attempt, 15000);
        reconnectTimer.current = window.setTimeout(() => connectRoomWs(attempt + 1), delay);
      },
    });
    closeWsRef.current?.close();
    closeWsRef.current = handle;
  }, [roomId, pullNew]);

  const send = async () => {
    const text = input.trim();
    const key = keyRef.current;
    if (!text || !key || sending || phase !== 'ready') return;
    setSending(true);
    setInput('');
    try {
      for (let attempt = 0; attempt < 3; attempt++) {
        const targetSeq = lastSeqRef.current + 1;
        const ts = Date.now();
        const enc = await encryptMessage(key, encodeMessageBody(text), roomId, targetSeq, ts);
        try {
          const resp = await tempApi.send(roomId, { iv: enc.iv, cipher: enc.ct, anonId: anonRef.current, seq: targetSeq, ts });
          lastSeqRef.current = resp.seq;
          setMessages((prev) => {
            const seen = new Set(prev.map((p) => p.seq));
            return seen.has(resp.seq) ? prev : [...prev, { id: resp.id, seq: resp.seq, sender: 'me', anonId: anonRef.current, ts: resp.ts, text }].sort((a, b) => a.seq - b.seq);
          });
          break;
        } catch (e) {
          if (e instanceof ApiError && e.status === 409 && typeof e.data?.seq === 'number') {
            // seq 冲突(并发):用服务器期望序号对齐本地计数,重新加密发送
            lastSeqRef.current = (e.data.seq as number) - 1;
            continue;
          }
          throw e;
        }
      }
    } catch (e) {
      setInput(text); // 失败恢复输入
      alert('发送失败,请重试');
    }
    setSending(false);
  };

  const leave = async () => {
    try { await tempApi.leave(roomId); } catch { /* ignore */ }
    burn('已退出临时聊天,本地密钥与记录已清除。\n(服务器保留加密归档)');
  };

  const copyLink = async () => {
    try {
      await navigator.clipboard.writeText(shareUrl);
      alert('链接已复制,请通过安全渠道分享');
    } catch {
      prompt('请复制以下链接:', shareUrl);
    }
  };

  /* ---------- 渲染 ---------- */
  if (phase === 'loading') {
    return <div className="boot"><div className="spinner" /></div>;
  }

  if (phase === 'burned') {
    return (
      <div className="card" style={{ marginTop: 60, textAlign: 'center' }}>
        <h2 style={{ fontSize: 18, marginBottom: 12 }}>🔒 会话已清除</h2>
        <p className="hint" style={{ whiteSpace: 'pre-line', lineHeight: 1.8 }}>{burnMsg}</p>
        <div style={{ marginTop: 18 }}>
          <Link to="/" className="btn btn-primary" style={{ marginRight: 8 }}>返回首页</Link>
          <Link to="/" className="btn btn-ghost" onClick={() => setTimeout(() => nav(0), 0)}>新建临时聊天</Link>
        </div>
      </div>
    );
  }

  if (phase === 'error' || phase === 'expired') {
    return (
      <div className="card" style={{ marginTop: 60, textAlign: 'center' }}>
        <h2 style={{ fontSize: 18, marginBottom: 12 }}>{phase === 'expired' ? '⏰ 房间不存在或已过期' : '⚠️ 无法进入聊天'}</h2>
        <p className="hint">
          {phase === 'expired'
            ? '临时房间已过期或被管理员封禁。密文归档仍保留在服务器,但无法继续发送消息。'
            : '缺少会话密钥:请使用完整的分享链接(包含 #k= 部分)进入。'}
        </p>
        <div style={{ marginTop: 18 }}>
          <Link to="/" className="btn btn-primary">返回首页</Link>
        </div>
      </div>
    );
  }

  return (
    <div className="chat-page">
      <div className="chat-head">
        <Link to="/" style={{ color: 'var(--text-dim)' }}>←</Link>
        <span className={`presence-dot ${online.length > 0 ? 'online' : ''}`} />
        <div className="title">
          临时聊天 <span className="sub">#{roomId.slice(0, 8)}</span>
        </div>
        <button className="btn btn-small btn-danger" onClick={leave}>退出</button>
      </div>

      <div className="card" style={{ padding: 10, margin: '8px 0', fontSize: 12.5 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
          <span className="hint" style={{ margin: 0, flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }} title={shareUrl}>
            🔑 分享链接(内含密钥):{shareUrl}
          </span>
          <button className="btn btn-small" onClick={copyLink}>复制</button>
        </div>
        <p className="hint" style={{ margin: '6px 0 0' }}>
          {onlineIps} 个IP在线 · 刷新页面 = 立即清除本地密钥 · 服务器仅保存密文归档
        </p>
      </div>

      <div className="msg-list" ref={listRef}>
        {messages.length === 0 && (
          <div className="msg sys">🔒 已建立端到端加密会话,开始聊天吧(仅你和持有链接密钥的人可读)</div>
        )}
        {messages.map((m) => (
          <div key={m.id} className={`msg ${m.sender === 'me' ? 'own' : 'other'}`}>
            {m.sender !== 'me' && <div className="sender">{m.anonId ? labelFor(m.anonId) : '访客'}</div>}
            <div className="bubble">{decodeMessageBody(m.text).t || m.text}</div>
            <div className="meta">
              <span>{new Date(m.ts).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}</span>
              {m.sender === 'me' && <span className="read">已发送</span>}
            </div>
          </div>
        ))}
      </div>

      <div className="input-row">
        <textarea
          placeholder="输入消息…(仅端到端加密)"
          value={input}
          maxLength={4000}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } }}
        />
        <button className="btn btn-primary send" onClick={send} disabled={sending || !input.trim()}>➤</button>
      </div>
    </div>
  );
}
