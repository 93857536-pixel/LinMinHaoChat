/**
 * 管理员后台:统计 / 用户管理 / 临时房间管理 / 日志
 * 注意:管理员只能看到元数据与统计,看不到任何消息明文(E2EE 设计使然)。
 */
import { useEffect, useState } from 'react';
import { adminApi } from '../api';

interface AdminState {
  token: string | null;
  stats: Record<string, any> | null;
  users: Record<string, any>[];
  tempRooms: Record<string, any>[];
  logs: string[];
  userPage: number;
  roomPage: number;
  totalUsers: number;
  totalRooms: number;
  err: string;
  busy: boolean;
}

export default function Admin() {
  const [u, setU] = useState('');
  const [p, setP] = useState('');
  const [state, setState] = useState<AdminState>({
    token: localStorage.getItem('lmh.admin') || null,
    stats: null, users: [], tempRooms: [], logs: [], userPage: 1, roomPage: 1, totalUsers: 0, totalRooms: 0, err: '', busy: false,
  });

  const set = (patch: Partial<AdminState>) => setState((s) => ({ ...s, ...patch }));

  const login = async () => {
    set({ busy: true, err: '' });
    try {
      const r = await adminApi.login(u, p);
      localStorage.setItem('lmh.admin', r.token);
      set({ token: r.token, busy: false });
      await loadAll(r.token);
    } catch {
      set({ err: '管理员账号或密码错误', busy: false });
    }
  };

  const loadAll = async (token: string) => {
    try {
      const [stats, users, rooms, logs] = await Promise.all([
        adminApi.stats(token), adminApi.users(token, 1), adminApi.tempRooms(token, 1), adminApi.logs(token, 200),
      ]);
      set({ stats: stats.stats, users: users.users, tempRooms: rooms.rooms, logs: logs.logs, totalUsers: users.total, totalRooms: rooms.total, userPage: 1, roomPage: 1 });
    } catch (e) {
      set({ err: '加载失败:' + (e as Error).message });
    }
  };

  useEffect(() => {
    if (state.token) loadAll(state.token).catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const fmt = (n: unknown) => (typeof n === 'number' ? n.toLocaleString() : String(n ?? '-'));
  const fmtTime = (t: number) => new Date(t).toLocaleString('zh-CN', { hour12: false });

  const stat = (label: string, value: unknown) => (
    <div className="stat"><div className="num">{fmt(value)}</div><div className="label">{label}</div></div>
  );

  if (!state.token) {
    return (
      <div className="card" style={{ maxWidth: 380, margin: '60px auto' }}>
        <h2 style={{ fontSize: 18, marginBottom: 14 }}>管理员登录</h2>
        <div className="field">
          <label>账号</label>
          <input className="input" value={u} onChange={(e) => setU(e.target.value)} />
        </div>
        <div className="field">
          <label>密码</label>
          <input className="input" type="password" value={p} onChange={(e) => setP(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && login()} />
        </div>
        {state.err && <div className="error">{state.err}</div>}
        <button className="btn btn-primary" style={{ width: '100%' }} onClick={login} disabled={state.busy}>登录</button>
        <p className="hint" style={{ marginTop: 10 }}>凭据在服务器 data/config/env.json 或 admin.cred 中配置</p>
      </div>
    );
  }

  const banUser = async (id: number, banned: boolean) => {
    if (!confirm(`确定要${banned ? '解封' : '封禁'}用户 #${id} 吗?`)) return;
    await adminApi.banUser(id, !banned, state.token!);
    await loadAll(state.token!);
  };
  const delUser = async (id: number) => {
    if (!confirm(`⚠️ 确定删除用户 #${id} 及其全部私聊密文?此操作不可恢复!`)) return;
    await adminApi.deleteUser(id, state.token!);
    await loadAll(state.token!);
  };
  const banRoom = async (id: string, banned: boolean) => {
    if (!confirm(`确定要${banned ? '恢复' : '封禁'}临时房间 ${id} 吗?`)) return;
    await adminApi.banTempRoom(id, !banned, state.token!);
    await loadAll(state.token!);
  };
  const delRoom = async (id: string) => {
    if (!confirm(`⚠️ 确定删除临时房间 ${id} 的全部密文归档?此操作不可恢复!`)) return;
    await adminApi.deleteTempRoom(id, state.token!);
    await loadAll(state.token!);
  };

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14 }}>
        <h2 style={{ fontSize: 18 }}>管理后台</h2>
        <div style={{ display: 'flex', gap: 8 }}>
          <button className="btn btn-small" onClick={() => loadAll(state.token!)}>刷新</button>
          <button className="btn btn-small btn-danger" onClick={() => { localStorage.removeItem('lmh.admin'); set({ token: null }); }}>退出</button>
        </div>
      </div>
      {state.err && <div className="error">{state.err}</div>}

      <h3 style={{ fontSize: 14, color: 'var(--text-dim)', margin: '10px 0 8px' }}>系统状态</h3>
      <div className="admin-grid">
        {state.stats && <>
          {stat('用户数', state.stats.users)}
          {stat('封禁用户', state.stats.bannedUsers)}
          {stat('当前在线', state.stats.online)}
          {stat('临时房间', state.stats.tempRooms)}
          {stat('有效临时房', state.stats.activeTempRooms)}
          {stat('账号会话', state.stats.rooms)}
          {stat('消息密文数', state.stats.messages)}
          {stat('会话数', state.stats.sessions)}
          {stat('运行时长', state.stats.uptimeSec ? Math.round((state.stats.uptimeSec as number) / 60) + ' 分钟' : '-' )}
          {stat('内存 RSS', state.stats.memUsedMB ? state.stats.memUsedMB + ' MB' : '-')}
          {stat('密文磁盘', state.stats.disk?.total ? Math.round((state.stats.disk.total as number) / 1024) + ' KB' : '-')}
          {stat('数据库', state.stats.dbOk ? '正常' : '异常')}
        </>}
      </div>

      <h3 style={{ fontSize: 14, color: 'var(--text-dim)', margin: '18px 0 8px' }}>用户管理</h3>
      <table className="list">
        <thead><tr><th>ID</th><th>昵称</th><th>手机</th><th>邮箱</th><th>注册时间</th><th>状态</th><th>操作</th></tr></thead>
        <tbody>
          {state.users.map((x) => (
            <tr key={String(x.id)}>
              <td>#{x.id}</td>
              <td>{x.handle || '-'}</td>
              <td>{x.phone_masked || '-'}</td>
              <td>{x.email_masked || '-'}</td>
              <td>{fmtTime(Number(x.created_at))}</td>
              <td>{x.banned ? <span style={{ color: 'var(--danger)' }}>封禁</span> : '正常'}</td>
              <td style={{ whiteSpace: 'nowrap' }}>
                <button className="btn btn-small" onClick={() => banUser(Number(x.id), !!x.banned)}>{x.banned ? '解封' : '封禁'}</button>{' '}
                <button className="btn btn-small btn-danger" onClick={() => delUser(Number(x.id))}>删除</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="hint">共 {state.totalUsers} 人</p>

      <h3 style={{ fontSize: 14, color: 'var(--text-dim)', margin: '18px 0 8px' }}>临时房间(密文归档元数据)</h3>
      <table className="list">
        <thead><tr><th>房间 ID</th><th>创建时间</th><th>过期时间</th><th>消息数</th><th>状态</th><th>操作</th></tr></thead>
        <tbody>
          {state.tempRooms.map((x) => (
            <tr key={String(x.id)}>
              <td className="mono" style={{ fontSize: 11 }}>{String(x.id).slice(0, 18)}</td>
              <td>{fmtTime(Number(x.created_at))}</td>
              <td>{fmtTime(Number(x.expires_at))}</td>
              <td>{x.msg_count}</td>
              <td>{x.status}</td>
              <td style={{ whiteSpace: 'nowrap' }}>
                <button className="btn btn-small" onClick={() => banRoom(String(x.id), x.status === 'banned')}>{x.status === 'banned' ? '恢复' : '封禁'}</button>{' '}
                <button className="btn btn-small btn-danger" onClick={() => delRoom(String(x.id))}>删除密文</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="hint">共 {state.totalRooms} 个临时房间 · 管理员可见元数据与密文文件,但无法解密任何消息(E2EE)</p>

      <h3 style={{ fontSize: 14, color: 'var(--text-dim)', margin: '18px 0 8px' }}>错误日志</h3>
      <div className="mono-block" style={{ maxHeight: 220, overflowY: 'auto' }}>
        {state.logs.length ? state.logs.join('\n') : '(无)'}
      </div>
    </div>
  );
}
