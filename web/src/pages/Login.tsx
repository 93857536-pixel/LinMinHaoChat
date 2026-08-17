import { useState } from 'react';
import { useNavigate, Link, useSearchParams } from 'react-router-dom';
import { authApi } from '../api';
import { useAuth } from '../auth';
import { ensureIdentityKeys } from '../crypto/keys';

type Mode = 'sms' | 'email';

export default function Login() {
  const nav = useNavigate();
  const [params] = useSearchParams();
  const next = params.get('next') || '/chat';
  const { login, refreshIdentity } = useAuth();
  const [mode, setMode] = useState<Mode>('sms');
  const [target, setTarget] = useState('');
  const [code, setCode] = useState('');
  const [handle, setHandle] = useState('');
  const [countdown, setCountdown] = useState(0);
  const [err, setErr] = useState('');
  const [sending, setSending] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  const sendCode = async () => {
    setErr('');
    if (mode === 'sms' && !/^1[3-9]\d{9}$/.test(target)) { setErr('请输入正确的手机号'); return; }
    if (mode === 'email' && !/^[^@\s]+@[^@\s]+\.[a-zA-Z]{2,}$/.test(target)) { setErr('请输入正确的邮箱'); return; }
    setSending(true);
    try {
      await authApi.sendCode(mode, target.trim());
      setCountdown(60);
      const t = setInterval(() => {
        setCountdown((c) => {
          if (c <= 1) { clearInterval(t); return 0; }
          return c - 1;
        });
      }, 1000);
    } catch (e) {
      setErr((e as Error).message === 'rate_limited' ? '发送太频繁,请稍后再试' : '发送失败,请稍后重试');
    }
    setSending(false);
  };

  const submit = async () => {
    setErr('');
    if (!/^\d{6}$/.test(code)) { setErr('请输入 6 位验证码'); return; }
    setSubmitting(true);
    try {
      // 确保本设备身份密钥存在,并随注册上传公钥
      const identity = await ensureIdentityKeys();
      const resp = mode === 'email'
        ? await authApi.register({ type: 'email', target: target.trim().toLowerCase(), code, handle: handle.trim() || undefined, deviceId: identity.deviceId, ed25519Pub: identity.ed25519Pub, ecdhPub: identity.ecdhPub })
        : await authApi.register({ type: 'sms', target: target.trim(), code, handle: handle.trim() || undefined, deviceId: identity.deviceId, ed25519Pub: identity.ed25519Pub, ecdhPub: identity.ecdhPub });
      login({ token: resp.token, sessionId: resp.sessionId, userId: resp.user.id, handle: resp.user.handle, deviceId: identity.deviceId });
      await refreshIdentity();
      nav(next);
    } catch (e) {
      const msg = (e as Error).message;
      setErr(msg === 'invalid_code' ? '验证码错误' : msg === 'too_many_attempts' ? '尝试次数过多,请重新获取' : '登录失败,请稍后重试');
    }
    setSubmitting(false);
  };

  return (
    <div className="card" style={{ maxWidth: 420, margin: '40px auto' }}>
      <h2 style={{ fontSize: 20, marginBottom: 6 }}>登录 / 注册</h2>
      <p className="hint" style={{ marginBottom: 16 }}>验证码登录,无需记忆密码。首次登录自动创建账号。</p>

      <div className="tabs">
        <button className={`tab ${mode === 'sms' ? 'active' : ''}`} onClick={() => { setMode('sms'); setErr(''); }}>手机号</button>
        <button className={`tab ${mode === 'email' ? 'active' : ''}`} onClick={() => { setMode('email'); setErr(''); }}>邮箱</button>
      </div>

      <div className="field">
        <label>{mode === 'sms' ? '手机号码' : '邮箱地址'}</label>
        <input
          className="input"
          type={mode === 'sms' ? 'tel' : 'email'}
          inputMode={mode === 'sms' ? 'numeric' : 'email'}
          placeholder={mode === 'sms' ? '138****1234' : 'you@example.com'}
          value={target}
          maxLength={64}
          onChange={(e) => setTarget(e.target.value)}
        />
      </div>

      <div className="field">
        <label>验证码</label>
        <div style={{ display: 'flex', gap: 8 }}>
          <input
            className="input"
            inputMode="numeric"
            placeholder="6 位验证码"
            value={code}
            maxLength={6}
            onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))}
          />
          <button
            className="btn btn-small"
            style={{ flex: 'none', minWidth: 96 }}
            onClick={sendCode}
            disabled={countdown > 0 || sending}
          >
            {countdown > 0 ? <span className="countdown">{countdown}s</span> : '获取验证码'}
          </button>
        </div>
        <p className="hint">验证码 5 分钟内有效,每 60 秒可发送一次</p>
      </div>

      <div className="field">
        <label>昵称(可选,注册时使用)</label>
        <input className="input" placeholder="默认自动生成" value={handle} maxLength={32} onChange={(e) => setHandle(e.target.value)} />
      </div>

      {err && <div className="error">{err}</div>}

      <button className="btn btn-primary" style={{ width: '100%', marginTop: 10 }} onClick={submit} disabled={submitting}>
        {submitting ? '登录中…' : '登录 / 注册'}
      </button>

      <p className="hint" style={{ marginTop: 14, textAlign: 'center' }}>
        <Link to="/">← 返回首页</Link>
      </p>
    </div>
  );
}
