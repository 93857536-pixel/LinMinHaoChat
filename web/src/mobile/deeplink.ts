/**
 * 深链解析 → 应用内路径(主会话维护)。
 *
 * 与 iOS InviteLinkParser 对齐,支持:
 *   lmhchat://invite/<id>#k=<b64url>          (自定义 scheme,Android manifest 注册)
 *   lmhchat://i/<id>#k=... / lmhchat://t/<id>#k=...
 *   https://chat.linminhao.top/i/<id>#k=...   (官方网页链接,Android 会交给本 App)
 *   https://chat.linminhao.top/t/<id>#k=...   (临时聊天)
 *   短链 https://linminhao.top/t/<id>#k=...
 *
 * 返回值用于 history.pushState(保留 fragment,密钥不经服务器);无法识别返回 null。
 */
export function parseDeepLink(rawUrl: string): string | null {
  let u: URL;
  try {
    u = new URL(rawUrl);
  } catch {
    return null;
  }
  const frag = u.hash || '';
  // ⚠️ 必须保留 query:?account=1(账号模式)与 roomCode=<6位码>(凭码直接进房间)都是功能参数,
  //    丢掉会导致这类邀请链接进入后行为错误(iOS InviteLinkParser 同样解析这两项)。
  const search = u.search || '';
  const parts = u.pathname.split('/').filter(Boolean);
  let kind: 'i' | 't' | null = null;
  let id: string | null = null;

  if (u.protocol === 'lmhchat:') {
    // lmhchat://invite/<id> → host='invite', path='/<id>'
    // lmhchat:///invite/<id> → host='', path='/invite/<id>'
    const seg = [u.host, ...parts].filter(Boolean);
    const head = seg[0];
    if (head === 'invite' || head === 'i') {
      kind = 'i';
      id = seg[1] ?? null;
    } else if (head === 't' || head === 'temp') {
      kind = 't';
      id = seg[1] ?? null;
    }
  } else if (u.protocol === 'https:' || u.protocol === 'http:') {
    const host = u.host.replace(/^www\./, '');
    const isOurHost = host === 'chat.linminhao.top' || host === 'linminhao.top' || host.endsWith('.linminhao.top');
    if (isOurHost && (parts[0] === 'i' || parts[0] === 't') && parts[1]) {
      kind = parts[0];
      id = parts[1];
    }
  }

  if (!kind || !id) return null;
  return `/${kind}/${id}${search}${frag}`;
}

/** 该路径是否是深链页面(邀请/临时聊天) */
export function isDeepLinkPath(p: string | null): boolean {
  return !!p && (p.startsWith('/i/') || p.startsWith('/t/'));
}
