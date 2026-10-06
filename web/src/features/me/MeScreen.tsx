/**
 * 「我的」Tab —— 账号资料 / 头像 / 昵称 / 实名认证 / 退出登录。
 *
 * 对齐 iOS MeTab + RealNameView:
 *  - 头像:点头像(或「上传/更换头像」行)→ 隐藏 <input type="file" accept="image/*">
 *          → 客户端 canvas 居中裁方到 512×512、输出 JPEG(quality 0.85)→ avatarExt.upload。
 *          压缩后仍 >2MB 提示换图;提供「移除头像」;上传成功后刷新显示。
 *  - 昵称:展示 + 修改(meApi.setNickname,≤24 字,空或超长提示)。
 *  - 账号 ID(handle):只读展示,说明不可修改。
 *  - 实名认证:realnameExt.status 拉状态;**已认证只渲染只读卡**,严禁任何输入框/提交/重核入口;
 *          未认证才显示姓名 + 身份证输入框与「提交认证」。
 *  - ⚠️ 铁律:全 App 只允许这一处「退出登录」(useAuth().logout)。
 *
 * 端点与类型全部来自 ../api-ext.ts(只读契约,禁止修改)。
 */
import { useEffect, useRef, useState, type ChangeEvent } from 'react';
import { useAuth } from '../../auth';
import {
  ApiError,
  avatarExt,
  avatarUrl,
  initialOf,
  meApi,
  realnameExt,
  type MeUser,
  type RealnameStatus,
} from '../api-ext';

/* ---------------- 工具(模块级,避免重复创建) ---------------- */

function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

/** 认证时间(ms)→ 本地时间 yyyy-MM-dd HH:mm */
function formatDate(ms: number): string {
  const d = new Date(ms);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())} ${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** 服务端实名错误码 → 友好提示 */
function friendlyRealnameError(code: string | null): string {
  switch (code) {
    case 'bad_name':
      return '姓名格式不正确(2~20 字,需为中文或字母)';
    case 'bad_idcard':
      return '身份证号不正确,请检查位数与校验位';
    case 'idcard_already_bound':
      return '该身份证已绑定其他账号(一个身份证只能认证一个账号)';
    case 'already_verified':
      return '本账号已完成实名认证,不支持重新核验或换绑';
    case 'too_frequent':
      return '操作过于频繁,请稍后重试';
    case 'daily_limit':
      return '今日核验次数已达上限,请明日再试';
    case 'rate_limited':
      return '请求过于频繁,请稍后再试';
    case 'realname_unavailable':
      return '实名认证服务未开通';
    case 'vendor_error':
    case 'upstream_error':
      return '核验服务暂时不可用,请稍后再试';
    case 'vendor_quota':
      return '核验服务额度不足,请联系管理员';
    case 'vendor_disabled':
      return '核验服务已停用';
    default:
      return '网络异常,请稍后重试';
  }
}

function readFileAsDataURL(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const fr = new FileReader();
    fr.onload = () => resolve(fr.result as string);
    fr.onerror = () => reject(new Error('read_failed'));
    fr.readAsDataURL(file);
  });
}

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error('decode_failed'));
    img.src = src;
  });
}

function canvasToBlob(canvas: HTMLCanvasElement, type: string, quality: number): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('encode_failed'))), type, quality);
  });
}

/**
 * 客户端压缩:居中裁方 → 512×512 → JPEG(0.85)。
 * 压缩后仍 >2MB 抛 'too_large'(正常情况下 512 方图 JPEG 只有几十 KB)。
 */
async function compressToSquareJpeg(file: File): Promise<{ bytes: ArrayBuffer; mime: string }> {
  const dataUrl = await readFileAsDataURL(file);
  const img = await loadImage(dataUrl);
  const side = Math.min(img.naturalWidth, img.naturalHeight);
  if (side <= 0) throw new Error('decode_failed');
  const sx = (img.naturalWidth - side) / 2;
  const sy = (img.naturalHeight - side) / 2;
  const canvas = document.createElement('canvas');
  canvas.width = 512;
  canvas.height = 512;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('canvas_unavailable');
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(img, sx, sy, side, side, 0, 0, 512, 512);
  const blob = await canvasToBlob(canvas, 'image/jpeg', 0.85);
  if (blob.size > 2 * 1024 * 1024) throw new Error('too_large');
  return { bytes: await blob.arrayBuffer(), mime: 'image/jpeg' };
}

/* ---------------- 组件 ---------------- */

interface Msg {
  text: string;
  error: boolean;
}

export default function MeScreen() {
  const { session, logout } = useAuth();
  const token = session?.token ?? '';
  const userId = session?.userId ?? 0;

  const [me, setMe] = useState<MeUser | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);

  const [avatarSrc, setAvatarSrc] = useState<string | null>(null);
  const [avatarBusy, setAvatarBusy] = useState(false);
  const [avatarMsg, setAvatarMsg] = useState<Msg | null>(null);

  const [editingName, setEditingName] = useState(false);
  const [nameDraft, setNameDraft] = useState('');
  const [nameBusy, setNameBusy] = useState(false);
  const [nameMsg, setNameMsg] = useState<string | null>(null);

  const [rn, setRn] = useState<RealnameStatus | null>(null);
  const [rnLoading, setRnLoading] = useState(true);
  const [rnName, setRnName] = useState('');
  const [rnIdcard, setRnIdcard] = useState('');
  const [rnSubmitting, setRnSubmitting] = useState(false);
  const [rnResult, setRnResult] = useState<{ title: string; detail: string; isError: boolean } | null>(null);

  const fileInputRef = useRef<HTMLInputElement>(null);

  const hasAvatar = me?.hasAvatar ?? false;
  const displayName = me?.nickname || session?.handle || '—';
  const handle = me?.handle || session?.handle || String(userId);

  /* 初次加载:我的资料 + 实名状态 + 头像 */
  useEffect(() => {
    if (!session) {
      setLoading(false);
      setRnLoading(false);
      return;
    }
    let cancelled = false;
    (async () => {
      try {
        const [meRes, rnRes] = await Promise.all([meApi.me(token), realnameExt.status(token)]);
        if (cancelled) return;
        setMe(meRes.user);
        setRn(rnRes);
        if (meRes.user.hasAvatar) {
          const url = await avatarUrl(userId, meRes.user.avatarUpdatedAt, token);
          if (!cancelled) setAvatarSrc(url);
        }
      } catch {
        if (!cancelled) setLoadError('加载失败,请稍后重试');
      } finally {
        if (!cancelled) {
          setLoading(false);
          setRnLoading(false);
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [session, token, userId]);

  /* 头像:选图 → 压缩 → 上传 → 刷新显示 */
  const openPicker = () => fileInputRef.current?.click();

  const onPickFile = async (file: File) => {
    setAvatarBusy(true);
    setAvatarMsg(null);
    try {
      const { bytes, mime } = await compressToSquareJpeg(file);
      const res = await avatarExt.upload(bytes, mime, token);
      setMe((prev) => (prev ? { ...prev, hasAvatar: true, avatarUpdatedAt: res.avatarUpdatedAt } : prev));
      const url = await avatarUrl(userId, res.avatarUpdatedAt, token);
      setAvatarSrc(url);
      setAvatarMsg({ text: '头像已更新', error: false });
    } catch (e) {
      if (e instanceof ApiError) {
        setAvatarMsg({ text: e.status === 413 ? '图片过大,请换一张' : '图片格式不支持,请换一张', error: true });
      } else if (e instanceof Error && e.message === 'too_large') {
        setAvatarMsg({ text: '图片过大,请换一张', error: true });
      } else {
        setAvatarMsg({ text: '上传失败,请重试', error: true });
      }
    } finally {
      setAvatarBusy(false);
      if (fileInputRef.current) fileInputRef.current.value = '';
    }
  };

  const onFileChange = (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) void onPickFile(file);
  };

  const removeAvatar = async () => {
    setAvatarBusy(true);
    setAvatarMsg(null);
    try {
      await avatarExt.remove(token);
      setMe((prev) => (prev ? { ...prev, hasAvatar: false, avatarUpdatedAt: null } : prev));
      setAvatarSrc(null);
      setAvatarMsg({ text: '头像已移除', error: false });
    } catch {
      setAvatarMsg({ text: '移除失败,请重试', error: true });
    } finally {
      setAvatarBusy(false);
    }
  };

  /* 昵称:修改 */
  const startEditName = () => {
    setNameDraft(me?.nickname ?? '');
    setNameMsg(null);
    setEditingName(true);
  };

  const saveNickname = async () => {
    const name = nameDraft.trim();
    if (!name) {
      setNameMsg('昵称不能为空');
      return;
    }
    if (Array.from(name).length > 24) {
      setNameMsg('昵称最多 24 个字符');
      return;
    }
    if (name === me?.nickname) {
      setEditingName(false);
      return;
    }
    setNameBusy(true);
    setNameMsg(null);
    try {
      const res = await meApi.setNickname(name, token);
      setMe((prev) => (prev ? { ...prev, nickname: res.user.nickname } : prev));
      setEditingName(false);
    } catch {
      setNameMsg('保存失败,请重试');
    } finally {
      setNameBusy(false);
    }
  };

  /* 实名:提交 */
  const submitRealname = async () => {
    const name = rnName.trim();
    const idcard = rnIdcard.trim().toUpperCase();
    if (!name || idcard.length !== 18) return;
    setRnSubmitting(true);
    setRnResult(null);
    try {
      const res = await realnameExt.verify(name, idcard, token);
      if (res.verified) {
        // 注意:verify 成功响应不含 enabled,合并时保留已拉取到的能力状态。
        setRn((prev) => ({ ...res, enabled: prev?.enabled ?? true }));
        setRnName('');
        setRnIdcard('');
        setRnResult({ title: '实名认证通过', detail: '姓名与身份证号一致。', isError: false });
      } else if (res.status === 'no_record') {
        setRnResult({ title: '未查询到该身份证记录', detail: '该号段可能暂不支持核验,请确认号码无误。', isError: true });
      } else {
        setRnResult({ title: '姓名与身份证号不一致', detail: '请核对姓名与身份证号后重试。', isError: true });
      }
    } catch (e) {
      const code = e instanceof ApiError ? e.message : null;
      setRnResult({ title: '核验未完成', detail: friendlyRealnameError(code), isError: true });
    } finally {
      setRnSubmitting(false);
    }
  };

  /* 退出登录:全 App 唯一一处 */
  const doLogout = async () => {
    await logout();
  };

  if (!session) {
    return (
      <div className="mv-page">
        <h2 className="mv-page-title">我的</h2>
        <p className="mv-hint">未登录</p>
      </div>
    );
  }

  return (
    <div className="mv-page">
      <h2 className="mv-page-title">我的</h2>

      {/* 隐藏的选图输入 */}
      <input ref={fileInputRef} type="file" accept="image/*" style={{ display: 'none' }} onChange={onFileChange} />

      {/* 账号区:大头像 + 昵称 + 账号 ID */}
      <div className="mv-card">
        <div className="mv-me-header">
          <button className="mv-me-avatar-btn" onClick={openPicker} disabled={avatarBusy} aria-label="更换头像">
            {avatarSrc ? (
              <img className="mv-avatar mv-avatar-lg" src={avatarSrc} alt="头像" />
            ) : (
              <span className="mv-avatar mv-avatar-lg">{initialOf(displayName)}</span>
            )}
            <span className="mv-me-camera">📷</span>
            {avatarBusy && <span className="mv-me-avatar-mask">上传中</span>}
          </button>
          <div>
            <div className="mv-me-name">{displayName}</div>
            <div className="mv-me-sub">账号 ID {handle} · 不可修改</div>
            <div className="mv-me-sub">点头像可更换</div>
          </div>
        </div>
      </div>

      {loading && <p className="mv-hint">加载中…</p>}
      {loadError && <p className="mv-error">{loadError}</p>}
      {avatarMsg && <p className={avatarMsg.error ? 'mv-error' : 'mv-hint'}>{avatarMsg.text}</p>}

      {/* 账号:昵称修改 + 账号 ID */}
      <div className="mv-card">
        <button className="mv-row" onClick={startEditName}>
          <span className="mv-row-icon">✏️</span>
          <span className="mv-row-main">
            <span className="mv-row-title">修改账号名称</span>
            <span className="mv-row-sub">最多 24 个字符,可随时修改</span>
          </span>
          <span className="mv-row-value">{displayName}</span>
          <span className="mv-row-chev">›</span>
        </button>

        <div className="mv-row mv-row-static">
          <span className="mv-row-icon">🆔</span>
          <span className="mv-row-main">
            <span className="mv-row-title">账号 ID</span>
            <span className="mv-row-sub">由系统按注册时间自动生成,全网唯一,不可修改</span>
          </span>
          <span className="mv-row-value">{handle}</span>
        </div>
      </div>

      {/* 昵称编辑 */}
      {editingName && (
        <div className="mv-card mv-me-editor">
          <input
            className="mv-input"
            value={nameDraft}
            onChange={(e) => setNameDraft(e.target.value)}
            placeholder="输入新的账号名称"
            autoFocus
          />
          {nameMsg && <p className="mv-error">{nameMsg}</p>}
          <div className="mv-me-actions">
            <button className="mv-btn" onClick={() => void saveNickname()} disabled={nameBusy}>
              {nameBusy ? '保存中…' : '保存'}
            </button>
            <button className="mv-btn mv-btn-ghost" onClick={() => setEditingName(false)} disabled={nameBusy}>
              取消
            </button>
          </div>
        </div>
      )}

      {/* 头像操作 */}
      <div className="mv-card">
        <button className="mv-row" onClick={openPicker} disabled={avatarBusy}>
          <span className="mv-row-icon">🖼️</span>
          <span className="mv-row-main">
            <span className="mv-row-title">{hasAvatar ? '更换头像' : '上传头像'}</span>
            <span className="mv-row-sub">将裁剪为 512×512 方图后上传</span>
          </span>
          <span className="mv-row-chev">›</span>
        </button>
        {hasAvatar && (
          <button className="mv-row" onClick={() => void removeAvatar()} disabled={avatarBusy}>
            <span className="mv-row-icon">🗑️</span>
            <span className="mv-row-main">
              <span className="mv-row-title" style={{ color: '#ff3b30' }}>移除头像</span>
            </span>
          </button>
        )}
      </div>

      {/* 实名认证:已认证只读 / 未认证表单 / 服务未开通 */}
      <div className="mv-card">
        <div className="mv-me-card-body">
          {rnLoading ? (
            <p className="mv-hint">检查实名状态…</p>
          ) : rn?.verified ? (
            <div className="mv-me-verified">
              <span className="mv-me-verified-icon">✅</span>
              <div style={{ minWidth: 0, flex: 1 }}>
                <div className="mv-me-row-title">已完成实名认证</div>
                {rn.nameMasked && <div className="mv-me-sub">姓名 {rn.nameMasked}</div>}
                {rn.verifiedAt != null && <div className="mv-me-sub">认证时间 {formatDate(rn.verifiedAt)}</div>}
                <p className="mv-hint" style={{ textAlign: 'left', paddingLeft: 0, paddingRight: 0 }}>
                  实名信息一经通过即与本账号绑定,不可修改、不支持重新核验或换绑其他身份证。
                </p>
              </div>
            </div>
          ) : rn?.enabled === false ? (
            <p className="mv-hint">⚠️ 实名认证服务未开通</p>
          ) : (
            <div>
              <div className="mv-me-field">
                <label htmlFor="rn-name">真实姓名</label>
                <input
                  id="rn-name"
                  className="mv-input"
                  value={rnName}
                  onChange={(e) => setRnName(e.target.value)}
                  placeholder="请输入真实姓名"
                  autoComplete="off"
                />
              </div>
              <div className="mv-me-field">
                <label htmlFor="rn-idcard">身份证号(18 位)</label>
                <input
                  id="rn-idcard"
                  className="mv-input"
                  value={rnIdcard}
                  onChange={(e) => setRnIdcard(e.target.value.toUpperCase().replace(/[^0-9X]/g, '').slice(0, 18))}
                  placeholder="请输入 18 位身份证号"
                  autoComplete="off"
                />
              </div>
              <button
                className="mv-btn"
                style={{ width: '100%' }}
                onClick={() => void submitRealname()}
                disabled={rnSubmitting || !rnName.trim() || rnIdcard.length !== 18}
              >
                {rnSubmitting ? '核验中…' : '提交认证'}
              </button>
              {rnResult && (
                <p className={rnResult.isError ? 'mv-error' : 'mv-hint'} style={{ textAlign: 'left', marginTop: 8 }}>
                  {rnResult.title}
                  {rnResult.detail ? `:${rnResult.detail}` : ''}
                </p>
              )}
            </div>
          )}
        </div>
      </div>

      {/* 退出登录(全 App 唯一) */}
      <button className="mv-btn mv-btn-danger" style={{ width: '100%' }} onClick={() => void doLogout()}>
        退出登录
      </button>

      <p className="mv-hint">版本 1.9.13 · Android 端 · 端到端加密</p>
    </div>
  );
}
