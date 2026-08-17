/**
 * 账号聊天页:会话列表 + 聊天窗(移动端优先,桌面并排)
 * - 会话密钥:打开会话时从服务器拉取 wrapped keys,用本设备私钥解包(内存缓存)
 * - 消息:AES-GCM 加密上传;WS 事件通知 + REST 拉取密文
 * - 已读:元数据回执;附件:加密后上传,下载后解密渲染
 */
import { useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { chatApi, keysApi, attachmentApi, ApiError, type RoomMeta, type ChatMsg } from '../api';
import { useAuth } from '../auth';
import { ensureIdentityKeys, exportEncryptedPackage, importEncryptedPackage } from '../crypto/keys';
import { generateSessionKey, wrapSessionKey, unwrapSessionKey, type Bytes } from '../crypto/session';
import { encryptMessage, decryptMessage, encryptAttachment, decryptAttachment, encodeMessageBody, decodeMessageBody } from '../crypto/message';
import { connectWs, type WsMsg } from '../ws';

interface DecryptedMsg {
  id: string;
  seq: number;
  mine: boolean;
  senderId: number | null;
  ts: number;
  kind: 'msg' | 'attachment';
  text: string;
  att?: { attId: string; name: string; size: number; mime: string };
  read?: boolean;
}

export default function Chat() {
  const { session, logout, identity, refreshIdentity } = useAuth();
  const nav = useNavigate();
  const token = session?.token || '';

  const [rooms, setRooms] = useState<RoomMeta[]>([]);
  const [active, setActive] = useState<RoomMeta | null>(null);
  const [messages, setMessages] = useState<DecryptedMsg[]>([]);
  const [online, setOnline] = useState<number[]>([]);
  const [onlineIps, setOnlineIps] = useState(0);
  const [input, setInput] = useState('');
  const [sending, setSending] = useState(false);
  const [showCreate, setShowCreate] = useState(false);
  const [showSettings, setShowSettings] = useState(false);
  const [peerIdInput, setPeerIdInput] = useState('');
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);

  const keyCache = useRef(new Map<string, Bytes>());
  const lastSeqRef = useRef(0);
  const myIdRef = useRef(session?.userId || 0);
  const deviceRef = useRef(identity?.deviceId || 'default');
  const closeWsRef = useRef<(() => void) | null>(null);
  const reconnectTimer = useRef<number | null>(null);
  const closedRef = useRef(false);
  const listRef = useRef<HTMLDivElement>(null);

  const refreshRooms = useCallback(async () => {
    try {
      const r = await chatApi.rooms(token);
      setRooms(r.rooms);
    } catch { /* ignore */ }
  }, [token]);

  useEffect(() => {
    refreshRooms();
    return () => {
      closedRef.current = true;
      if (reconnectTimer.current !== null) window.clearTimeout(reconnectTimer.current);
      closeWsRef.current?.();
    };
  }, [token, refreshRooms]);

  useEffect(() => {
    myIdRef.current = session?.userId || 0;
    deviceRef.current = identity?.deviceId || 'default';
  }, [session, identity]);

  /** 打开会话:解包密钥 + 拉历史 + 订阅 WS */
  const openRoom = useCallback(async (room: RoomMeta) => {
    setActive(room);
    setMessages([]);
    setErr('');
    closeWsRef.current?.();
    if (reconnectTimer.current !== null) window.clearTimeout(reconnectTimer.current);
    reconnectTimer.current = null;

    // 1. 解包会话密钥(内存缓存)
    let key = keyCache.current.get(room.id);
    if (!key) {
      const wrapped = await chatApi.keys(room.id, deviceRef.current, token);
      for (const w of wrapped.keys) {
        try {
          key = await unwrapSessionKey(w);
          keyCache.current.set(room.id, key);
          break;
        } catch { /* try next */ }
      }
      if (!key) {
        setErr('无法解包会话密钥:你可能不是本设备的授权成员,或需要从其他设备导入身份密钥。');
        return;
      }
    }

    // 2. 拉历史
    const hist = await chatApi.history(room.id, token, 0, 300);
    const dec: DecryptedMsg[] = [];
    for (const m of hist.messages) {
      try {
        dec.push(await decodeChatMsg(key, m, room.id, myIdRef.current));
      } catch { /* skip */ }
    }
    dec.sort((a, b) => a.seq - b.seq);
    setMessages(dec);
    lastSeqRef.current = dec.length ? dec[dec.length - 1].seq : 0;
    if (lastSeqRef.current > 0) chatApi.read(room.id, lastSeqRef.current, token).catch(() => {});

    // 3. WS 订阅(断线自动重连,JWT 可复用,无需重新鉴权)
    let retries = 0;
    const connect = () => {
      const handle = connectWs(token, {
        onMessage: (m: WsMsg) => {
          if (m.type === 'presence' && m.roomId === room.id) {
            setOnline(Array.isArray(m.online) ? m.online.map(Number) : []);
            if (typeof m.onlineIps === 'number') setOnlineIps(m.onlineIps);
          }
          if (m.type === 'msg' && m.roomId === room.id && m.seq > lastSeqRef.current) {
            pullNew(room.id, key as Bytes);
          }
          if (m.type === 'read' && m.roomId === room.id && m.userId !== myIdRef.current) {
            setMessages((prev) => prev.map((p) => (p.seq <= m.lastSeq ? { ...p, read: true } : p)));
          }
        },
        onClose: () => {
          if (closedRef.current) return;
          const delay = Math.min(1000 * 2 ** retries, 15000);
          retries += 1;
          reconnectTimer.current = window.setTimeout(connect, delay);
        },
      });
      closeWsRef.current?.();
      closeWsRef.current = handle.close;
      handle.send({ type: 'subscribe', roomId: room.id });
      pullNew(room.id, key as Bytes); // 补收断线期间的消息
    };
    connect();
  }, [token]);

  const pullNew = useCallback(async (roomId: string, key: Bytes) => {
    try {
      const hist = await chatApi.history(roomId, token, lastSeqRef.current, 200);
      const dec: DecryptedMsg[] = [];
      for (const m of hist.messages) {
        if (m.seq <= lastSeqRef.current) continue;
        try {
          const d = await decodeChatMsg(key, m, roomId, myIdRef.current);
          if (d.mine) d.read = true;
          dec.push(d);
        } catch { /* skip */ }
      }
      if (dec.length) {
        lastSeqRef.current = Math.max(lastSeqRef.current, ...dec.map((d) => d.seq));
        setMessages((prev) => {
          const seen = new Set(prev.map((p) => p.seq));
          return [...prev, ...dec.filter((d) => !seen.has(d.seq))].sort((a, b) => a.seq - b.seq);
        });
        chatApi.read(roomId, lastSeqRef.current, token).catch(() => {});
      }
    } catch { /* ignore */ }
  }, [token]);

  const decodeChatMsg = async (key: Bytes, m: ChatMsg, roomId: string, myId: number): Promise<DecryptedMsg> => {
    const raw = await decryptMessage(key, { iv: m.iv, ct: m.cipher }, roomId, m.seq, m.ts);
    const body = decodeMessageBody(raw);
    const base: DecryptedMsg = {
      id: m.id, seq: m.seq, mine: m.senderId === myId, senderId: m.senderId, ts: m.ts,
      kind: m.kind === 'attachment' ? 'attachment' : 'msg',
      text: body.t || '',
      read: m.senderId !== myId ? true : undefined,
    };
    if (body.f) base.att = { attId: body.f.attId || '', name: body.f.name, size: body.f.size, mime: body.f.mime };
    return base;
  };

  useEffect(() => {
    listRef.current?.scrollTo({ top: listRef.current.scrollHeight });
  }, [messages, active]);

  /** 创建私聊 */
  const createDm = async () => {
    const peerId = Number(peerIdInput.trim());
    if (!Number.isInteger(peerId) || peerId <= 0) { setErr('请输入对方的用户 ID(数字)'); return; }
    if (peerId === myIdRef.current) { setErr('不能和自己创建私聊'); return; }
    setBusy(true);
    setErr('');
    try {
      const me = await ensureIdentityKeys();
      const peerKeys = await keysApi.getUserKeys(peerId, token);
      if (!peerKeys.devices.length) { setErr('对方还没有上传公钥(对方需先登录一次)'); return; }
      const key = generateSessionKey();
      const wrappedKeys: { userId: number; deviceId: string; wrappedKey: string }[] = [];
      // 包装给自己(当前设备)
      wrappedKeys.push({ userId: myIdRef.current, deviceId: me.deviceId, wrappedKey: await wrapSessionKey(key, me.ecdhPub) });
      // 包装给对方所有设备
      for (const d of peerKeys.devices) {
        wrappedKeys.push({ userId: peerId, deviceId: d.device_id, wrappedKey: await wrapSessionKey(key, d.ecdh_pub) });
      }
      const resp = await chatApi.createRoom({ type: 'dm', memberIds: [peerId], wrappedKeys }, token);
      keyCache.current.set(resp.room.id, key);
      setShowCreate(false);
      setPeerIdInput('');
      setActive(resp.room);
      await refreshRooms();
      await openRoom(resp.room);
    } catch (e) {
      setErr((e as Error).message === 'not_found' ? '用户不存在' : '创建失败,请稍后重试');
    }
    setBusy(false);
  };

  const send = async () => {
    const text = input.trim();
    if (!text || !active || sending) return;
    const key = keyCache.current.get(active.id);
    if (!key) return;
    setSending(true);
    setInput('');
    try {
      for (let attempt = 0; attempt < 3; attempt++) {
        const targetSeq = lastSeqRef.current + 1;
        const ts = Date.now();
        const enc = await encryptMessage(key, encodeMessageBody(text), active.id, targetSeq, ts);
        try {
          const resp = await chatApi.send(active.id, { iv: enc.iv, cipher: enc.ct, seq: targetSeq, ts }, token);
          lastSeqRef.current = resp.seq;
          setMessages((prev) => {
            const seen = new Set(prev.map((p) => p.seq));
            const mine: DecryptedMsg = { id: resp.id, seq: resp.seq, mine: true, senderId: myIdRef.current, ts: resp.ts, kind: 'msg', text, read: true };
            return seen.has(resp.seq) ? prev : [...prev, mine].sort((a, b) => a.seq - b.seq);
          });
          chatApi.read(active.id, resp.seq, token).catch(() => {});
          refreshRooms();
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
      alert('发送失败');
    }
    setSending(false);
  };

  /** 发送附件 */
  const sendAttachment = async (file: File) => {
    if (!active) return;
    const key = keyCache.current.get(active.id);
    if (!key) return;
    const SAFE = ['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif', 'audio/mpeg', 'audio/ogg', 'audio/wav', 'video/mp4', 'video/webm', 'text/plain', 'application/pdf', 'application/json', 'application/zip'];
    if (!SAFE.includes(file.type)) { alert('不支持的文件类型'); return; }
    if (file.size > 10 * 1024 * 1024) { alert('文件不能超过 10MB'); return; }
    setSending(true);
    try {
      const buf = await file.arrayBuffer();
      const ts = Date.now();
      const enc = await encryptAttachment(key, buf, active.id, ts);
      const up = await attachmentApi.upload(active.id, file.type, enc, token);
      // 附件消息:cipher 加密元数据,meta 明文(仅 UI 提示)
      const body = JSON.stringify({ f: { attId: up.attId, name: file.name, size: file.size, mime: file.type } });
      const meta = JSON.stringify({ attId: up.attId, mime: file.type, size: file.size });
      for (let attempt = 0; attempt < 3; attempt++) {
        const targetSeq = lastSeqRef.current + 1;
        const encMeta = await encryptMessage(key, body, active.id, targetSeq, ts);
        try {
          const resp = await chatApi.send(active.id, { iv: encMeta.iv, cipher: encMeta.ct, kind: 'attachment', meta, seq: targetSeq, ts }, token);
          lastSeqRef.current = resp.seq;
          const mine: DecryptedMsg = { id: resp.id, seq: resp.seq, mine: true, senderId: myIdRef.current, ts: resp.ts, kind: 'attachment', text: file.name, att: { attId: up.attId, name: file.name, size: file.size, mime: file.type }, read: true };
          setMessages((prev) => [...prev, mine].sort((a, b) => a.seq - b.seq));
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
      alert('附件发送失败:' + (e as Error).message);
    }
    setSending(false);
  };

  /** 下载并解密附件 */
  const downloadAttachment = async (att: { attId: string; name: string; mime: string }) => {
    if (!active) return;
    const key = keyCache.current.get(active.id);
    if (!key) return;
    try {
      const encBuf = await attachmentApi.download(att.attId, token);
      const m = messages.find((x) => x.att?.attId === att.attId);
      const ts = m?.ts || Date.now();
      const plain = await decryptAttachment(key, encBuf, active.id, ts);
      const blob = new Blob([plain], { type: att.mime.startsWith('image/') ? att.mime : 'application/octet-stream' });
      const url = URL.createObjectURL(blob);
      if (att.mime.startsWith('image/')) {
        window.open(url, '_blank');
      } else {
        const a = document.createElement('a');
        a.href = url;
        a.download = att.name;
        a.click();
      }
      setTimeout(() => URL.revokeObjectURL(url), 60_000);
    } catch {
      alert('附件解密失败(密钥不匹配或数据损坏)');
    }
  };

  /** 导出密钥包 */
  const doExport = async () => {
    const pin = prompt('设置一个导出口令(至少 8 位,请牢记;丢失无法找回):');
    if (!pin || pin.length < 8) { alert('口令至少 8 位'); return; }
    try {
      const pkg = await exportEncryptedPackage(pin);
      await keysApi.saveExportPackage(pkg, deviceRef.current, token);
      const blob = new Blob([pkg], { type: 'application/json' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = `lmh-keys-backup-${new Date().toISOString().slice(0, 10)}.json`;
      a.click();
      alert('密钥包已导出并备份到服务器。请妥善保管文件与口令。');
    } catch (e) {
      alert('导出失败:' + (e as Error).message);
    }
  };

  /** 导入密钥包(新设备恢复) */
  const doImport = async () => {
    const fileInput = document.createElement('input');
    fileInput.type = 'file';
    fileInput.accept = '.json,application/json';
    fileInput.onchange = async () => {
      const f = fileInput.files?.[0];
      if (!f) return;
      const pin = prompt('输入该密钥包的导出口令:');
      if (!pin) return;
      try {
        const pkg = await f.text();
        const identity2 = await importEncryptedPackage(pkg, pin);
        alert(`导入成功!设备 ID: ${identity2.deviceId}\n请重新登录以使用此身份。`);
        await refreshIdentity();
      } catch (e) {
        alert('导入失败:' + (e as Error).message);
      }
    };
    fileInput.click();
  };

  /* ---------- 渲染 ---------- */
  if (!session) return null;

  const roomName = (r: RoomMeta) => {
    if (r.nameEnc) return '群聊';
    const other = r.memberIds.find((id) => id !== myIdRef.current);
    return other ? `用户 #${other}` : '会话';
  };

  return (
    <div className="chat-page">
      {/* 会话列表 */}
      <div style={{ display: 'flex', gap: 10, marginBottom: 10 }}>
        <div style={{ flex: 1, display: 'flex', gap: 8 }}>
          <button className="btn btn-small" onClick={() => { setShowCreate(true); setErr(''); }}>+ 新建私聊</button>
          <button className="btn btn-small" onClick={refreshRooms}>刷新</button>
        </div>
        <button className="btn btn-small" onClick={() => setShowSettings(true)}>设备</button>
        <button className="btn btn-small btn-danger" onClick={async () => { await logout(); nav('/'); }}>退出</button>
      </div>

      {!active ? (
        <>
          {rooms.length === 0 && (
            <div className="msg sys" style={{ padding: 40, textAlign: 'center' }}>
              还没有会话<br />输入对方用户 ID 发起私聊(对方 ID 显示在自己账号信息中)
            </div>
          )}
          <div className="rooms">
            {rooms.map((r) => (
              <div key={r.id} className="room-item" onClick={() => openRoom(r)}>
                <div className="avatar">{r.type === 'group' ? '群' : '私'}</div>
                <div className="name">{roomName(r)}</div>
                {r.unread > 0 && <span className="badge">{r.unread}</span>}
              </div>
            ))}
          </div>
        </>
      ) : (
        <>
          <div className="chat-head">
            <button className="btn btn-small" style={{ padding: '4px 10px' }} onClick={() => { setActive(null); closeWsRef.current?.(); }}>←</button>
            <span className={`presence-dot ${online.length > 1 ? 'online' : ''}`} />
            <div className="title">{roomName(active)} <span className="sub">#{active.id.slice(0, 8)}</span></div>
            <span className="sub">{onlineIps ? `${onlineIps} 个IP在线` : ''}</span>
          </div>
          {err && <div className="error" style={{ padding: '8px 0' }}>{err}</div>}
          <div className="msg-list" ref={listRef}>
            {messages.length === 0 && !err && <div className="msg sys">🔒 端到端加密会话已建立</div>}
            {messages.map((m) => (
              <div key={m.id} className={`msg ${m.mine ? 'own' : 'other'} ${m.kind === 'attachment' ? 'attachment' : ''}`}>
                {!m.mine && <div className="sender">用户 #{m.senderId}</div>}
                {m.kind === 'attachment' && m.att ? (
                  <div className="bubble">
                    <div className="attach-chip">📎 {m.att.name} ({Math.round(m.att.size / 1024)} KB)</div>
                    {m.att.mime.startsWith('image/') && (
                      <button className="btn btn-small" onClick={() => downloadAttachment(m.att!)}>查看图片</button>
                    )}
                    {!m.att.mime.startsWith('image/') && (
                      <button className="btn btn-small" onClick={() => downloadAttachment(m.att!)}>下载</button>
                    )}
                  </div>
                ) : (
                  <div className="bubble">{m.text}</div>
                )}
                <div className="meta">
                  <span>{new Date(m.ts).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}</span>
                  {m.mine && <span className="read">{m.read ? '已读' : '已发送'}</span>}
                </div>
              </div>
            ))}
          </div>
          <div className="input-row">
            <button className="btn btn-small" style={{ flex: 'none' }} onClick={() => {
              const fi = document.createElement('input');
              fi.type = 'file';
              fi.onchange = () => { const f = fi.files?.[0]; if (f) sendAttachment(f); };
              fi.click();
            }} title="发送附件(加密)">📎</button>
            <textarea
              placeholder="输入消息…(端到端加密)"
              value={input}
              maxLength={4000}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send(); } }}
            />
            <button className="btn btn-primary send" onClick={send} disabled={sending || !input.trim()}>➤</button>
          </div>
        </>
      )}

      {/* 新建私聊弹窗 */}
      {showCreate && (
        <div className="modal-backdrop" onClick={() => setShowCreate(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h3 style={{ marginBottom: 12 }}>新建私聊</h3>
            <div className="field">
              <label>对方用户 ID</label>
              <input className="input" inputMode="numeric" placeholder="例如 1002" value={peerIdInput} onChange={(e) => setPeerIdInput(e.target.value)} />
            </div>
            <p className="hint" style={{ marginBottom: 12 }}>提示:对方需要在「登录」后,在地址栏访问 /chat 页面并在设备菜单中查看自己的 ID。</p>
            {err && <div className="error">{err}</div>}
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button className="btn btn-small btn-ghost" onClick={() => setShowCreate(false)}>取消</button>
              <button className="btn btn-small btn-primary" onClick={createDm} disabled={busy}>创建</button>
            </div>
          </div>
        </div>
      )}

      {/* 设备设置弹窗 */}
      {showSettings && (
        <div className="modal-backdrop" onClick={() => setShowSettings(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h3 style={{ marginBottom: 12 }}>设备与密钥</h3>
            <p className="hint" style={{ marginBottom: 14 }}>
              设备 ID:<span className="mono">{identity?.deviceId || '…'}</span><br />
              用户 ID:<span className="mono">#{session.userId}</span>
            </p>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              <button className="btn btn-small" onClick={doExport}>导出密钥包(备份/迁移)</button>
              <button className="btn btn-small" onClick={doImport}>从密钥包导入(新设备)</button>
              <button className="btn btn-small btn-ghost" onClick={() => setShowSettings(false)}>关闭</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
