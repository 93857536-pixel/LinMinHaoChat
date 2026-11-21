/** WebSocket 客户端(账号聊天 / 临时聊天共用) */

export type WsMsg =
  | { type: 'msg'; roomId: string; seq: number; id: string; senderId?: number; anonId?: string; ts: number; kind?: string }
  | { type: 'read'; roomId: string; userId: number; lastSeq: number }
  | { type: 'presence'; roomId: string; online: (number | string)[] }
  | { type: 'typing'; roomId: string; userId: number; ts: number }
  | { type: 'subscribed'; roomId: string }
  | { type: 'pong'; t: number }
  | { type: 'hello'; serverTime: number }
  | { type: 'error'; error: string };

export interface WsClientOptions {
  onMessage: (m: WsMsg) => void;
  onOpen?: () => void;
  onClose?: (e?: CloseEvent) => void;
  onError?: (e: unknown) => void;
}

export interface WsHandle {
  close: () => void;
  send: (data: unknown) => void;
}

export function connectWs(token: string, opts: WsClientOptions): WsHandle {
  // 运行时基址覆盖:Web 端走同源(location);移动端(WebView 壳)由 boot 注入 wss:// 绝对地址。
  const override = (globalThis as unknown as { __LMH_WS_BASE__?: string }).__LMH_WS_BASE__;
  const proto = override
    ? (override.startsWith('wss') ? 'wss' : 'ws')
    : (location.protocol === 'https:' ? 'wss' : 'ws');
  const host = override ? override.replace(/^wss?:\/\//, '') : location.host;
  const ws = new WebSocket(`${proto}://${host}/ws?token=${encodeURIComponent(token)}`);
  let closed = false;
  /**
   * 连接建立前(readyState=CONNECTING)发出的帧不能直接丢:调用方(openRoom)在
   * connectWs 返回后立刻 send({type:'subscribe'}),此时握手尚未完成,旧实现会静默
   * 丢包 → 服务端 never 收到 subscribe → 该连接收不到 msg/typing/presence 广播,
   * 实时链路退化为「只有 15s 轮询兜底」。改为先入队,onopen 后按序冲刷。
   */
  const pending: string[] = [];

  ws.onopen = () => {
    while (pending.length) {
      const data = pending.shift() as string;
      try { ws.send(data); } catch { /* ignore */ }
    }
    opts.onOpen?.();
  };
  ws.onmessage = (e) => {
    try {
      opts.onMessage(JSON.parse(String(e.data)) as WsMsg);
    } catch { /* ignore bad frames */ }
  };
  ws.onclose = (e) => { if (!closed) opts.onClose?.(e); };
  ws.onerror = (e) => opts.onError?.(e);

  // 心跳保活
  const hb = setInterval(() => {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: 'ping' }));
  }, 25_000);

  return {
    send: (data) => {
      const payload = JSON.stringify(data);
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(payload);
      } else if (ws.readyState === WebSocket.CONNECTING && !closed) {
        // 握手未完成:入队,onopen 后统一冲刷(最多保留 32 条,防内存泄漏)
        if (pending.length < 32) pending.push(payload);
      }
    },
    close: () => {
      closed = true;
      pending.length = 0;
      clearInterval(hb);
      try { ws.close(); } catch { /* ignore */ }
    },
  };
}
