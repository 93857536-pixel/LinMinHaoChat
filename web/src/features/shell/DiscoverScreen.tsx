import { useState } from 'react';
import { useAuth } from '../../auth';
import { tempApi, inviteApi } from '../../api';
import { generateSessionKey, sessionKeyToB64url } from '../../crypto/session';
import { goPath } from '../shell/tabNav';
import { parseDeepLink } from '../../mobile/deeplink';

/** 分享链接的 host:从注入的 API 基址推导(https://chat.linminhao.top/api → https://chat.linminhao.top),
 *  WebView 里 location.origin 是 https://localhost,不能拿去分享。 */
function shareHost(): string {
  const base = (globalThis as unknown as { __LMH_API_BASE__?: string }).__LMH_API_BASE__ || '/api';
  if (base.startsWith('http')) {
    try { return new URL(base).origin; } catch { /* fall through */ }
  }
  return 'https://chat.linminhao.top';
}

/**
 * 发现 Tab(与 iOS DiscoverTab 对齐):临时聊天(发起/粘贴链接加入)、
 * 邀请聊天(创建/粘贴链接加入)+ 加密说明。
 * 目标页通过 tabNav.goPath 打开(移动端壳内),复用 TempChat/InviteChat 既有实现。
 */
export default function DiscoverScreen() {
  const { session } = useAuth();
  const [creatingTemp, setCreatingTemp] = useState(false);
  const [tempErr, setTempErr] = useState('');
  const [joinLink, setJoinLink] = useState('');
  const [joinErr, setJoinErr] = useState('');
  const [creatingInvite, setCreatingInvite] = useState(false);
  const [inviteErr, setInviteErr] = useState('');
  const [invite, setInvite] = useState<{ link: string; code: string } | null>(null);

  /* 发起临时聊天:建房间 → 本地生成密钥 → 进 /t/<id>#k=<密钥>(密钥不经服务器) */
  const startTemp = async () => {
    setCreatingTemp(true);
    setTempErr('');
    try {
      const room = await tempApi.create();
      const key = generateSessionKey();
      goPath(`/t/${room.roomId}#k=${sessionKeyToB64url(key)}`);
    } catch {
      setTempErr('创建失败,请稍后重试');
    }
    setCreatingTemp(false);
  };

  /* 粘贴链接加入(临时或邀请):复用深链解析器,识别 /t/<id> /i/<id>(含 #k= 与 ?roomCode= 等参数) */
  const openPastedLink = () => {
    const raw = joinLink.trim();
    if (!raw) return;
    const p = parseDeepLink(raw);
    if (!p) {
      setJoinErr('无法识别该链接:请粘贴完整的分享链接(需包含 #k= 密钥部分)');
      return;
    }
    setJoinErr('');
    goPath(p);
  };

  /* 创建邀请聊天:建房间 + 6 位验证码,密钥本机持久化(刷新可恢复记录),链接可分享 */
  const startInvite = async () => {
    setCreatingInvite(true);
    setInviteErr('');
    setInvite(null);
    try {
      const inv = await inviteApi.create();
      const key = generateSessionKey();
      const k = sessionKeyToB64url(key);
      const link = `${shareHost()}/i/${inv.inviteId}#k=${k}`;
      localStorage.setItem(`lmh.invite.key.${inv.roomId}`, k);
      setInvite({ link, code: inv.code });
    } catch {
      setInviteErr('创建失败,请稍后重试');
    }
    setCreatingInvite(false);
  };

  const copyInvite = async () => {
    if (!invite) return;
    const text = `【LinMinHao Chat 邀请】\n链接:${invite.link}\n验证码:${invite.code}\n(打开链接后输入验证码即可进入聊天,记录长期保留)`;
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      window.prompt('请复制以下内容:', text);
    }
  };

  return (
    <div className="mv-page">
      <h2 className="mv-page-title">发现</h2>

      {/* 临时聊天 */}
      <div className="mv-card">
        <button
          className="mv-row"
          onClick={startTemp}
          disabled={creatingTemp}
        >
          <span className="mv-row-icon">⚡</span>
          <span className="mv-row-main">
            <span className="mv-row-title">发起临时聊天</span>
            <span className="mv-row-sub">刷新即焚,无需登录,密钥藏在分享链接里</span>
          </span>
          <span className="mv-row-chev">›</span>
        </button>
        {tempErr && <p className="mv-error">{tempErr}</p>}
      </div>

      {/* 邀请聊天 */}
      <div className="mv-card">
        <button
          className="mv-row"
          onClick={startInvite}
          disabled={creatingInvite}
        >
          <span className="mv-row-icon">🔗</span>
          <span className="mv-row-main">
            <span className="mv-row-title">创建邀请聊天</span>
            <span className="mv-row-sub">生成链接 + 6 位验证码,记录长期保留(1 年)</span>
          </span>
          <span className="mv-row-chev">›</span>
        </button>
        {creatingInvite && <p className="mv-hint">正在创建邀请…</p>}
        {inviteErr && <p className="mv-error">{inviteErr}</p>}
        {invite && (
          <div className="mv-discover-box">
            <div className="mv-discover-label">邀请链接(含密钥)</div>
            <div className="mv-discover-link">{invite.link}</div>
            <div className="mv-discover-label" style={{ marginTop: 8 }}>验证码</div>
            <div className="mv-discover-code">{invite.code}</div>
            <button className="mv-btn mv-btn-block" style={{ marginTop: 10 }} onClick={copyInvite}>
              复制链接与验证码
            </button>
            <p className="mv-hint" style={{ textAlign: 'center', marginTop: 8 }}>
              请通过安全渠道发送;创建者本机已保存密钥,重进可恢复记录
            </p>
          </div>
        )}
      </div>

      {/* 粘贴链接加入 */}
      <div className="mv-card">
        <div className="mv-discover-label">加入聊天(粘贴分享链接)</div>
        <textarea
          className="mv-input"
          style={{ marginTop: 6 }}
          rows={2}
          placeholder="https://chat.linminhao.top/t/…#k=… 或 /i/…(支持 lmhchat:// 与网页链接)"
          value={joinLink}
          onChange={(e) => { setJoinLink(e.target.value); setJoinErr(''); }}
        />
        {joinErr && <p className="mv-error">{joinErr}</p>}
        <button
          className="mv-btn mv-btn-block"
          style={{ marginTop: 8 }}
          disabled={joinLink.trim().length === 0}
          onClick={openPastedLink}
        >
          加入
        </button>
      </div>

      {/* 其他 */}
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

      <p className="mv-hint">版本 1.9.15 · Android 端</p>
    </div>
  );
}
