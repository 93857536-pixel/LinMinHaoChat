import { useAuth } from '../../auth';

/**
 * 发现 Tab(与 iOS DiscoverTab 对应):临时聊天 / 邀请聊天入口 + 关于。
 * 临时聊天与邀请聊天沿用 Web 端既有页面路由。
 */
export default function DiscoverScreen() {
  const { session } = useAuth();

  const open = (path: string) => {
    window.location.hash = '';
    window.history.pushState({}, '', path);
    window.dispatchEvent(new PopStateEvent('popstate'));
  };

  return (
    <div className="mv-page">
      <h2 className="mv-page-title">发现</h2>

      <div className="mv-card">
        <button className="mv-row" onClick={() => open('/')}>
          <span className="mv-row-icon">⚡</span>
          <span className="mv-row-main">
            <span className="mv-row-title">临时聊天</span>
            <span className="mv-row-sub">无需注册,链接分享即可开聊</span>
          </span>
          <span className="mv-row-chev">›</span>
        </button>

        <button className="mv-row" onClick={() => open('/')}>
          <span className="mv-row-icon">🔗</span>
          <span className="mv-row-main">
            <span className="mv-row-title">邀请聊天</span>
            <span className="mv-row-sub">生成链接 + 验证码,记录长期保留</span>
          </span>
          <span className="mv-row-chev">›</span>
        </button>
      </div>

      <div className="mv-card">
        <div className="mv-row mv-row-static">
          <span className="mv-row-icon">🔒</span>
          <span className="mv-row-main">
            <span className="mv-row-title">端到端加密</span>
            <span className="mv-row-sub">ECDH P-256 + AES-256-GCM,服务器只存密文</span>
          </span>
        </div>
        <div className="mv-row mv-row-static">
          <span className="mv-row-icon">📱</span>
          <span className="mv-row-main">
            <span className="mv-row-title">当前设备</span>
            <span className="mv-row-sub">{session ? `账号 ID ${session.handle || session.userId}` : '未登录'}</span>
          </span>
        </div>
      </div>

      <p className="mv-hint">版本 1.9.13 · Android 端</p>
    </div>
  );
}
