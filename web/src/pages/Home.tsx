import { useState } from 'react';
import { useNavigate, Link } from 'react-router-dom';
import { tempApi, inviteApi } from '../api';
import { generateSessionKey, buildTempShareUrl, sessionKeyToB64url } from '../crypto/session';
import { useAuth } from '../auth';

export default function Home() {
  const nav = useNavigate();
  const { session } = useAuth();
  const [inviteBox, setInviteBox] = useState<{ link: string; code: string } | null>(null);

  const startTemp = async () => {
    try {
      const room = await tempApi.create();
      const key = generateSessionKey();
      const url = buildTempShareUrl(room.roomId, key);
      // 通过 sessionStorage 传递密钥给 /t/:id 页面(仅本标签页会话级)
      sessionStorage.setItem('lmh.temp.new', JSON.stringify({ roomId: room.roomId, key: url.split('#k=')[1], expiresAt: room.expiresAt }));
      nav(`/t/${room.roomId}#k=${url.split('#k=')[1]}`);
    } catch (e) {
      alert('创建失败,请稍后重试');
      console.error(e);
    }
  };

  /** 创建邀请聊天:生成房间 + 验证码,弹窗展示链接与验证码 */
  const startInvite = async () => {
    try {
      const inv = await inviteApi.create();
      const key = generateSessionKey();
      // 分享链接:含密钥 fragment(创建者自己保留密钥,刷新后可恢复记录)
      const link = `${location.origin}/i/${inv.inviteId}#k=${sessionKeyToB64url(key)}`;
      // 本机持久化密钥(创建者刷新后仍能进入并保留记录)
      localStorage.setItem(`lmh.invite.key.${inv.roomId}`, sessionKeyToB64url(key));
      setInviteBox({ link, code: inv.code });
    } catch (e) {
      alert('创建失败,请稍后重试');
      console.error(e);
    }
  };

  const copyInvite = async () => {
    if (!inviteBox) return;
    const text = `【LinMinHao Chat 邀请】\n链接:${inviteBox.link}\n验证码:${inviteBox.code}\n(打开链接后输入验证码即可进入聊天,记录长期保留)`;
    try {
      await navigator.clipboard.writeText(text);
      alert('链接与验证码已复制,请通过安全渠道发送给朋友');
    } catch {
      prompt('请复制以下内容:', text);
    }
  };

  return (
    <div>
      <div className="hero">
        <h1>LinMinHao Chat</h1>
        <p>
          端到端加密通讯<br />
          你的消息在发送前会在设备上加密<br />
          服务器只保存加密后的数据
        </p>
        <span className="e2ee-badge">🔒 E2EE · AES-256-GCM</span>
      </div>

      <div className="actions">
        <button className="btn btn-primary" onClick={startTemp}>⚡ 开始临时聊天</button>
        <button className="btn btn-accent" onClick={startInvite}>🔗 创建邀请聊天</button>
        <Link to={session ? '/chat' : '/login'} className="btn">
          {session ? '进入我的聊天' : '登录 / 注册'}
        </Link>
      </div>

      <div className="features">
        <div className="feature">
          <h3>临时聊天</h3>
          <p>无需注册,生成分享链接即可开始私密对话。刷新页面后本地密钥立即清除,服务器仅保留加密归档。</p>
        </div>
        <div className="feature">
          <h3>邀请聊天</h3>
          <p>生成链接 + 验证码,发给朋友,输入验证码即可加入。可选登录或游客身份,聊天记录长期保留。</p>
        </div>
        <div className="feature">
          <h3>端到端加密</h3>
          <p>基于 Web Crypto 标准实现:ECDH P-256 密钥交换 + AES-256-GCM 认证加密,每条消息独立随机 IV,防篡改防重放。</p>
        </div>
      </div>

      {inviteBox && (
        <div className="modal-backdrop" onClick={() => setInviteBox(null)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <h2 style={{ fontSize: 18, marginBottom: 8 }}>🔗 邀请已创建</h2>
            <p className="hint" style={{ marginBottom: 12 }}>
              把链接和验证码一起发给朋友。朋友打开链接、输入验证码即可进入聊天。房间 1 年有效,聊天记录长期保留。
            </p>
            <div className="field">
              <label>邀请链接(含密钥)</label>
              <div className="invite-line">
                <code className="invite-code" style={{ wordBreak: 'break-all' }}>{inviteBox.link}</code>
              </div>
            </div>
            <div className="field">
              <label>验证码</label>
              <div className="invite-line">
                <code className="invite-code invite-code-big">{inviteBox.code}</code>
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8, marginTop: 12, flexWrap: 'wrap' }}>
              <button className="btn btn-primary" style={{ flex: 1 }} onClick={copyInvite}>📋 复制链接 + 验证码</button>
              <button className="btn" style={{ flex: 1 }} onClick={() => { setInviteBox(null); nav('/'); }}>
                我记住了
              </button>
            </div>
            <p className="hint" style={{ marginTop: 10, textAlign: 'center', fontSize: 12 }}>
              提示:创建者本机已保存密钥,回到首页点开链接即可继续查看聊天记录。
            </p>
          </div>
        </div>
      )}
    </div>
  );
}
