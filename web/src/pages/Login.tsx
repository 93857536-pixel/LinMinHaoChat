import { useEffect, useState } from 'react';
import { useNavigate, Link, useSearchParams } from 'react-router-dom';
import { authApi } from '../api';
import { pnsExt } from '../features/api-ext';
import { useAuth } from '../auth';
import { ensureIdentityKeys } from '../crypto/keys';
import { pnsAvailable, pnsNativeShell, pnsGetLoginToken } from '../mobile/pns-auth';

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
  const [submitIntent, setSubmitIntent] = useState<null | 'login' | 'register'>(null);
  const submitting = submitIntent !== null;
  const [pnsOk, setPnsOk] = useState(false); // 本端是否可用一键登录(原生壳 + SDK 可用)
  const [oneKeyBusy, setOneKeyBusy] = useState(false);

  useEffect(() => {
    if (!pnsNativeShell()) return;
    let alive = true;
    pnsAvailable().then((a) => { if (alive) setPnsOk(a); });
    return () => { alive = false; };
  }, []);

  /** 本机号码一键登录:原生 SDK 授权页 → spToken → 服务端 GetMobile 换号 → 登录/自动注册 */
  const oneKeyLogin = async () => {
    setErr('');
    setOneKeyBusy(true);
    try {
      const identity = await ensureIdentityKeys();
      const { token: spToken } = await pnsGetLoginToken();
      const resp = await pnsExt.phoneCheck({
        spToken,
        deviceId: identity.deviceId,
        ed25519Pub: identity.ed25519Pub,
        ecdhPub: identity.ecdhPub,
      });
      login({ token: resp.token, sessionId: resp.sessionId, userId: resp.user.id, handle: resp.user.handle ?? undefined, deviceId: identity.deviceId });
      await refreshIdentity();
      nav(next);
    } catch (e) {
      const msg = (e as Error).message || '';
      setErr(msg === 'pns_upstream_error' ? '一键登录暂时不可用,请用下方验证码登录'
        : msg === 'token_invalid' ? '号码验证失败,请用下方验证码登录'
        : msg === 'banned' ? '账号已被封禁'
        : msg ? `一键登录失败: ${msg}` : '一键登录失败');
    } finally {
      setOneKeyBusy(false);
    }
  };

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

  const submit = (intent: 'login' | 'register') => {
    setErr('');
    if (!/^\d{6}$/.test(code)) { setErr('请输入 6 位验证码'); return; }
    setSubmitIntent(intent);
    (async () => {
      try {
        // 确保本设备身份密钥存在,并随注册/登录上传公钥
        const identity = await ensureIdentityKeys();
        const base = { type: mode, target: mode === 'email' ? target.trim().toLowerCase() : target.trim(), code,
                       deviceId: identity.deviceId, ed25519Pub: identity.ed25519Pub, ecdhPub: identity.ecdhPub };
        const resp = intent === 'register'
          ? await authApi.register({ ...base, handle: handle.trim() || undefined })
          : await authApi.login(base);
        login({ token: resp.token, sessionId: resp.sessionId, userId: resp.user.id, handle: resp.user.handle, deviceId: identity.deviceId });
        await refreshIdentity();
        nav(next);
      } catch (e) {
        const msg = (e as Error).message;
        if (intent === 'login' && msg === 'invalid_code') {
          setErr('登录失败:账号不存在或验证码错误(新账号请点「注册」)');
        } else {
          setErr(msg === 'invalid_code' ? '验证码错误' : msg === 'too_many_attempts' ? '尝试次数过多,请重新获取' : intent === 'register' ? '注册失败,请稍后重试' : '登录失败,请稍后重试');
        }
      } finally {
        setSubmitIntent(null);
      }
    })();
  };

  return (
    <div className="card" style={{ maxWidth: 420, margin: '40px auto' }}>
      <h2 style={{ fontSize: 20, marginBottom: 6 }}>登录 / 注册</h2>
      <p className="hint" style={{ marginBottom: 16 }}>验证码验证,无需记忆密码。已有账号点「登录」,首次使用点「注册」。</p>

      <div className="tabs">
        <button className={`tab ${mode === 'sms' ? 'active' : ''}`} onClick={() => { setMode('sms'); setErr(''); }}>手机号</button>
        <button className={`tab ${mode === 'email' ? 'active' : ''}`} onClick={() => { setMode('email'); setErr(''); }}>邮箱</button>
      </div>

      <div className="field">
        {mode === 'sms' && pnsOk && (
          <>
            <label>本机号码</label>
            <button
              className="btn btn-primary"
              style={{ width: '100%', marginBottom: 10 }}
              onClick={oneKeyLogin}
              disabled={oneKeyBusy || submitting}
            >
              {oneKeyBusy ? '正在唤起授权页…' : '本机号码一键登录'}
            </button>
            <p className="hint" style={{ marginTop: -6, marginBottom: 10 }}>
              需插 SIM 卡 + 开启蜂窝网络；运营商授权页确认后自动登录，无需记忆验证码。
            </p>
          </>
        )}
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

      <div style={{ display: 'flex', gap: 10, marginTop: 10 }}>
        <button
          className="btn btn-primary"
          style={{ flex: 1 }}
          onClick={() => submit('login')}
          disabled={submitting}
        >
          {submitIntent === 'login' ? '登录中…' : '登录'}
        </button>
        <button
          className="btn btn-ghost"
          style={{ flex: 1 }}
          onClick={() => submit('register')}
          disabled={submitting}
        >
          {submitIntent === 'register' ? '注册中…' : '注册'}
        </button>
      </div>

      <p className="hint" style={{ marginTop: 14, textAlign: 'center' }}>
        <Link to="/">← 返回首页</Link>
      </p>
    </div>
  );
}
