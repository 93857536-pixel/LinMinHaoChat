/**
 * 邀请聊天页(/i/:inviteId#k=密钥)
 *
 * 流程:
 *  1. 打开链接(含 #k= 密钥 fragment)
 *  2. 输入邀请验证码(创建者分享时给出)
 *  3. 选择身份:账号进入(已登录)或游客进入(不登录)
 *  4. 进入聊天:密钥持久化 localStorage,刷新不丢失,聊天记录保留
 *
 * 与临时聊天的区别:
 *  - 临时聊天刷新即焚;邀请聊天密钥/记录持久化(房间 1 年有效)
 *  - 临时聊天只有链接即凭证;邀请聊天需要 链接 + 验证码 双重凭证
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { inviteApi, tempApi, ApiError } from '../api';
import { parseTempShareKey, sessionKeyToB64url, type Bytes } from '../crypto/session';
import { encryptMessage, decryptMessage, encodeMessageBody, decodeMessageBody } from '../crypto/message';
import { connectWs, type WsMsg, type WsHandle } from '../ws';
import { useAuth } from '../auth';

interface DecryptedMsg {
  id: string;
  seq: number;
  sender: 'me' | 'other' | string;
  anonId?: string;
  ts: number;
  text: string;
}

const KEY_STORE_PREFIX = 'lmh.invite.key.';

export default function InviteChat() {
  const nav = useNavigate();
  const { session } = useAuth();
  const inviteId = location.pathname.split('/i/')[1] || '';

  const [phase, setPhase] = useState<'loading' | 'gate' | 'chat' | 'error' | 'expired'>('loading');
  const [code, setCode] = useState('');
  const [codeErr, setCodeErr] = useState('');
  const [joining, setJoining] = useState(false);
  const [displayName, setDisplayName] = useState('');
  const [messages, setMessages] = useState<DecryptedMsg[]>([]);
  const [online, setOnline] = useState<(string | number)[]>([]);
  const [onlineIps, setOnlineIps] = useState(0);
  const [input, setInput] = useState('');
  const [sending, setSending] = useState(false);
  const [expireInfo, setExpireInfo] = useState<{ expiresAt: number; messageCount: number } | null>(null);

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
  const roomIdRef = useRef('');
  const lastSeqRef = useRef(0);
  const closeWsRef = useRef<WsHandle | null>(null);
  const reconnectTimer = useRef<number | null>(null);
  const cancelledRef = useRef(false);
  /** 当前短令牌(join 颁发,5 分钟有效期内可重复连接;失效后重新 join) */
  const wsTokenRef = useRef<string | null>(null);
  /** WS 当前是否在线(断线期间靠轮询兜底补收) */
  const wsConnectedRef = useRef(false);
  const listRef = useRef<HTMLDivElement>(null);

  /** 从 fragment 取密钥;若 localStorage 已有则复用(持久化,保留记录) */
  const resolveKey = useCallback((roomId: string): Bytes | null => {
    const stored = localStorage.getItem(KEY_STORE_PREFIX + roomId);
    if (stored) {
      try { return parseTempShareKey('#k=' + stored); } catch { /* ignore */ }
    }
    return parseTempShareKey(location.hash);
  }, []);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        const info = await inviteApi.info(inviteId);
        if (cancelled) return;
        if (!info.ok || info.roomKind !== 'invite') { setPhase('error'); return; }
        if (info.codeExpired || info.roomExpired || info.roomStatus !== 'active') { setPhase('expired'); return; }

        // 密钥:优先持久化的,其次 fragment
        const key = resolveKey(info.roomId);
        if (!key) { setPhase('error'); return; }
        keyRef.current = key;
        roomIdRef.current = info.roomId;
        // 房间过期信息
        try {
          const roomInfo = await inviteApi.room(inviteId);
          if (!cancelled) setExpireInfo({ expiresAt: roomInfo.expiresAt, messageCount: roomInfo.messageCount });
        } catch { /* 非关键 */ }
        setPhase('gate');
      } catch (e) {
        if (cancelled) return;
        if (e instanceof ApiError && (e.status === 404 || e.status === 403)) setPhase('expired');
        else setPhase('error');
      }
    })();

    return () => {
      cancelled = true;
      cancelledRef.current = true;
      if (reconnectTimer.current !== null) window.clearTimeout(reconnectTimer.current);
      closeWsRef.current?.close();
    };
  }, [inviteId, resolveKey]);

  /** 验证码 + 加入(游客或账号身份) */
  const join = async (useAccount: boolean) => {
    const roomId = roomIdRef.current;
    const key = keyRef.current;
    if (!roomId || !key || joining) return;
    setJoining(true);
    setCodeErr('');
    try {
      const resp = await inviteApi.join(inviteId, {
        code,
        token: useAccount ? session?.token : null,
        anonId: localStorage.getItem('anon:' + roomId) || null, // 携带持久化身份,刷新/重连保持同一编号
      });

      // 持久化密钥(刷新后保留聊天记录)
      localStorage.setItem(KEY_STORE_PREFIX + roomId, sessionKeyToB64url(key));
      localStorage.setItem('anon:' + roomId, resp.anonId);
      anonRef.current = resp.anonId;
      labelFor(resp.anonId); // 注册自己的全局编号
      setDisplayName(resp.displayName);

      // 拉历史并解密
      const hist = await tempApi.history(roomId, 0, 500);
      const decrypted: DecryptedMsg[] = [];
      for (const m of hist.messages) {
        try {
          const text = await decryptMessage(key, { iv: m.iv, ct: m.cipher }, roomId, m.seq, m.ts);
          decrypted.push({ id: m.id, seq: m.seq, sender: m.anonId === resp.anonId ? 'me' : 'other', anonId: m.anonId || undefined, ts: m.ts, text });
        } catch { /* 跳过无法解密 */ }
      }
      decrypted.sort((a, b) => a.seq - b.seq);
      setMessages(decrypted);
      lastSeqRef.current = decrypted.length ? decrypted[decrypted.length - 1].seq : 0;

      // WS 实时通知(断线自动重连;令牌存入 ref,重连时复用避免重复 join 触发限流)
      wsTokenRef.current = resp.wsToken;
      void reconnectWs(0);

      setPhase('chat');
    } catch (e) {
      if (e instanceof ApiError) {
        if (e.status === 401) setCodeErr('验证码错误,请重试');
        else if (e.status === 429) setCodeErr('尝试次数过多,请稍后再试');
        else setCodeErr('加入失败,请重试');
      } else {
        setCodeErr('网络错误,请重试');
      }
    }
    setJoining(false);
  };

  const pullNew = useCallback(async () => {
    const roomId = roomIdRef.current;
    const key = keyRef.current;
    if (!roomId || !key) return;
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
  }, []);

  /** 断线自动重连:优先复用已颁发的短令牌(5 分钟有效期内可重复连接,不再每次重连都 join,
   *  避免重连风暴烧光 join 限流导致 429 锁死);令牌失效(4001)才重新 join
   *  (邀请房间复用已输入的验证码),重连后补收离线消息 */
  const reconnectWs = useCallback(async (attempt: number) => {
    if (cancelledRef.current) return;
    const roomId = roomIdRef.current;
    const key = keyRef.current;
    if (!roomId || !key) return;
    let token = wsTokenRef.current;
    if (!token) {
      try {
        const resp = await inviteApi.join(inviteId, { code, token: session?.token ?? null, anonId: anonRef.current || null });
        anonRef.current = resp.anonId;
        localStorage.setItem('anon:' + roomId, resp.anonId);
        wsTokenRef.current = resp.wsToken;
        token = resp.wsToken;
      } catch {
        if (cancelledRef.current) return;
        const delay = Math.min(1000 * 2 ** attempt, 15000);
        reconnectTimer.current = window.setTimeout(() => reconnectWs(attempt + 1), delay);
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
        reconnectTimer.current = window.setTimeout(() => reconnectWs(attempt + 1), delay);
      },
    });
    closeWsRef.current?.close();
    closeWsRef.current = handle;
  }, [inviteId, code, session?.token, pullNew]);

  useEffect(() => {
    listRef.current?.scrollTo({ top: listRef.current.scrollHeight });
  }, [messages]);

  // 断线兜底:WS 断开期间定时轮询补收,避免断线期间的消息丢失
  useEffect(() => {
    if (phase !== 'chat') return;
    const pollTimer = window.setInterval(() => {
      if (!wsConnectedRef.current && !cancelledRef.current) pullNew();
    }, 15_000);
    return () => window.clearInterval(pollTimer);
  }, [phase, pullNew]);

  const send = async () => {
    const text = input.trim();
    const roomId = roomIdRef.current;
    const key = keyRef.current;
    if (!text || !roomId || !key || sending || phase !== 'chat') return;
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
    } catch {
      setInput(text);
      alert('发送失败,请重试');
    }
    setSending(false);
  };

  const leave = async () => {
    closeWsRef.current?.close();
    nav('/');
  };

  /** 清除本地密钥与记录(服务器密文归档仍保留) */
  const clearLocal = () => {
    localStorage.removeItem(KEY_STORE_PREFIX + roomIdRef.current);
    localStorage.removeItem('anon:' + roomIdRef.current);
    closeWsRef.current?.close();
    nav('/');
  };

  /* ---------- 渲染 ---------- */
  if (phase === 'loading') {
    return <div className="boot"><div className="spinner" /></div>;
  }

  if (phase === 'error' || phase === 'expired') {
    return (
      <div className="card" style={{ marginTop: 60, textAlign: 'center' }}>
        <h2 style={{ fontSize: 18, marginBottom: 12 }}>{phase === 'expired' ? '⏰ 邀请已失效' : '⚠️ 无法进入聊天'}</h2>
        <p className="hint">
          {phase === 'expired'
            ? '邀请码已过期、房间已过期或被管理员封禁。请让创建者重新生成邀请。'
            : '缺少会话密钥:请使用创建者分享的完整链接(包含 #k= 部分)进入。'}
        </p>
        <div style={{ marginTop: 18 }}>
          <Link to="/" className="btn btn-primary">返回首页</Link>
        </div>
      </div>
    );
  }

  if (phase === 'gate') {
    return (
      <div className="card" style={{ maxWidth: 420, margin: '40px auto' }}>
        <h2 style={{ fontSize: 20, marginBottom: 6 }}>🔗 邀请聊天</h2>
        <p className="hint" style={{ marginBottom: 16 }}>
          输入创建者分享给你的验证码即可加入。<br />
          {expireInfo ? `已保存 ${expireInfo.messageCount} 条加密消息 · 房间 1 年内有效` : ''}
        </p>

        <div className="field">
          <label>邀请验证码</label>
          <input
            className="input"
            inputMode="numeric"
            placeholder="6 位验证码"
            value={code}
            maxLength={6}
            autoFocus
            onChange={(e) => { setCode(e.target.value.replace(/\D/g, '')); setCodeErr(''); }}
            onKeyDown={(e) => { if (e.key === 'Enter') join(false); }}
          />
          {codeErr && <div className="error" style={{ marginTop: 6 }}>{codeErr}</div>}
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 8, marginTop: 12 }}>
          <button className="btn btn-primary" style={{ width: '100%' }} onClick={() => join(false)} disabled={joining || !code}>
            {joining ? '加入中…' : '🚶 以游客身份进入(不登录)'}
          </button>
          {session ? (
            <button className="btn" style={{ width: '100%' }} onClick={() => join(true)} disabled={joining || !code}>
              👤 以账号身份进入({session.handle || `用户${session.userId}`})
            </button>
          ) : (
            <Link to={`/login?next=/i/${inviteId}`} className="btn" style={{ width: '100%', textAlign: 'center' }}>
              👤 登录账号后进入
            </Link>
          )}
        </div>

        <p className="hint" style={{ marginTop: 14, textAlign: 'center' }}>
          <Link to="/">← 返回首页</Link>
        </p>
      </div>
    );
  }

  return (
    <div className="chat-page">
      <div className="chat-head">
        <Link to="/" style={{ color: 'var(--text-dim)' }}>←</Link>
        <span className={`presence-dot ${online.length > 0 ? 'online' : ''}`} />
        <div className="title">
          邀请聊天 <span className="sub">#{roomIdRef.current.slice(0, 8)}</span>
        </div>
        <button className="btn btn-small btn-danger" onClick={leave}>退出</button>
      </div>

      <div className="card" style={{ padding: 10, margin: '8px 0', fontSize: 12.5 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
          <span className="hint" style={{ margin: 0, flex: 1 }}>
            👤 {displayName} · {onlineIps} 个IP在线 · 记录已保留(刷新页面不丢失)
          </span>
          <button className="btn btn-small" onClick={clearLocal} title="清除本机密钥与记录(服务器密文归档保留)">清除本机记录</button>
        </div>
      </div>

      <div className="msg-list" ref={listRef}>
        {messages.length === 0 && (
          <div className="msg sys">🔒 已建立端到端加密会话,开始聊天吧(仅持有链接密钥和验证码的人可读)</div>
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
