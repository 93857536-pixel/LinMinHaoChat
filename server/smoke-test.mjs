#!/usr/bin/env node
/* 本地冒烟测试:验证码 → 注册 → 临时聊天 → 密文检查 */
import fs from 'node:fs';

const BASE = 'http://127.0.0.1:3100';
const DATA = '/tmp/lmh-test';
const log = (...a) => console.log(...a);
let pass = 0, fail = 0;
// 清空上轮 dev-otp 日志,保证验证码可重复测试
try { fs.unlinkSync(`${DATA}/logs/dev-otp.log`); } catch { /* first run */ }
const check = (name, cond, extra = '') => {
  if (cond) { pass++; log(`  ✅ ${name}`); }
  else { fail++; log(`  ❌ ${name} ${extra}`); }
};

async function api(path, opts = {}) {
  const r = await fetch(BASE + path, {
    headers: { 'Content-Type': 'application/json', ...(opts.token ? { Authorization: `Bearer ${opts.token}` } : {}) },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
    method: opts.method || (opts.body ? 'POST' : 'GET'),
  });
  const j = await r.json().catch(() => ({}));
  return { status: r.status, ...j };
}

// 1. 发送验证码(邮箱)
log('\n[1] 验证码');
const codeResp = await api('/api/auth/send-code', { body: { type: 'email', target: 'alice@example.com' } });
check('发送验证码 ok', codeResp.ok === true);
// 从 dev-otp.log 读取验证码(模拟真实用户查收)
const otpLines = fs.readFileSync(`${DATA}/logs/dev-otp.log`, 'utf8').trim().split('\n');
const lastCode = otpLines[otpLines.length - 1].match(/code=(\d{6})/)[1];
check('验证码 6 位数字', /^\d{6}$/.test(lastCode), lastCode);
const otpRaw = fs.readFileSync(`${DATA}/logs/dev-otp.log`, 'utf8');
check('日志中目标脱敏(不出现完整邮箱)', !otpRaw.includes('alice@example.com'));

// 2. 注册 A
log('\n[2] 注册用户 A');
const regA = await api('/api/auth/register', { body: {
  type: 'email', target: 'alice@example.com', code: lastCode, handle: 'Alice',
  deviceId: 'dev-a', ed25519Pub: 'pubA_ed', ecdhPub: 'pubA_ecdh',
} });
check('注册 A ok', regA.ok === true && regA.token, JSON.stringify(regA).slice(0, 120));
const tokenA = regA.token;

// 3. 错误验证码
const badCode = String((Number(lastCode) + 1) % 1000000).padStart(6, '0');
const badReg = await api('/api/auth/register', { body: { type: 'email', target: 'bob@example.com', code: badCode } });
check('错误验证码被拒', badReg.status === 401, badReg.status);

// 4. 注册 B
log('\n[3] 注册用户 B');
const sendB = await api('/api/auth/send-code', { body: { type: 'email', target: 'bob@example.com' } });
const otpLines2 = fs.readFileSync(`${DATA}/logs/dev-otp.log`, 'utf8').trim().split('\n');
const codeB = otpLines2[otpLines2.length - 1].match(/code=(\d{6})/)[1];
const regB = await api('/api/auth/register', { body: {
  type: 'email', target: 'bob@example.com', code: codeB, handle: 'Bob',
  deviceId: 'dev-b', ed25519Pub: 'pubB_ed', ecdhPub: 'pubB_ecdh',
} });
check('注册 B ok', regB.ok === true);
const tokenB = regB.token;

// 5. 验证码一次性:同一验证码再注册应失败
const regA2 = await api('/api/auth/register', { body: { type: 'email', target: 'charlie@example.com', code: lastCode } });
check('验证码用后即失效', regA2.status === 401, regA2.status);

// 6. 临时聊天
log('\n[4] 临时聊天');
const room = await api('/api/temp/rooms', { method: 'POST' });
check('创建临时房间', room.ok === true && room.roomId?.startsWith('t_'), room.roomId);
const roomId = room.roomId;

const joinA = await api(`/api/temp/rooms/${roomId}/join`, { method: 'POST' });
check('加入房间拿 WS 令牌', joinA.ok === true && joinA.wsToken);

const msgPlain = '这是一条绝密消息,服务器绝不能看到!';
const sendMsg = await api(`/api/temp/rooms/${roomId}/messages`, { method: 'POST', body: { iv: 'iv123456789012', cipher: Buffer.from(msgPlain, 'utf8').toString('base64'), seq: 1 } });
check('发送密文消息', sendMsg.ok === true && sendMsg.seq === 1, JSON.stringify(sendMsg));

// seq 冲突:错误 seq 应 409
const badSeq = await api(`/api/temp/rooms/${roomId}/messages`, { method: 'POST', body: { iv: 'iv123456789012', cipher: Buffer.from('some-conflicting-payload-xxxxxx', 'utf8').toString('base64'), seq: 5 } });
check('seq 冲突返回 409', badSeq.status === 409, badSeq.status);

const history = await api(`/api/temp/rooms/${roomId}/messages`, {});
check('拉取历史密文', history.ok === true && history.messages.length === 1);
check('返回的是密文(非明文)', !JSON.stringify(history.messages).includes(msgPlain));

// 7. 关键验收:服务器文件系统里找不到明文
log('\n[5] E2EE 核心验收:抓取服务器密文文件');
let foundPlain = false, encFiles = [];
const walk = (d) => {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = `${d}/${e.name}`;
    if (e.isDirectory()) walk(p);
    else if (e.name.endsWith('.enc')) encFiles.push(p);
  }
};
walk(`${DATA}/messages`);
for (const f of encFiles) {
  const content = fs.readFileSync(f, 'utf8');
  if (content.includes(msgPlain)) { foundPlain = true; log(`  ⚠️ 明文泄漏于 ${f}`); }
}
check('存在密文文件', encFiles.length >= 1, `files=${encFiles.length}`);
check('密文文件中无明文', !foundPlain, JSON.stringify(encFiles));
check('文件名按 YYYY/MM/DD 组织', encFiles[0]?.includes('/messages/2026/'), encFiles[0]);

// 8. 数据库检查:消息表只有密文索引,无明文
const dbFile = `${DATA}/db/chat.db`;
const { execSync } = await import('node:child_process');
const dbDump = execSync(`strings "${dbFile}"`).toString();
check('SQLite 中无明文消息', !dbDump.includes(msgPlain));

// 9. 限流:1 分钟内重复发码应 429
const rl = await api('/api/auth/send-code', { body: { type: 'email', target: 'alice@example.com' } });
check('验证码频率限制(60s)', rl.status === 429, `${rl.status} ${JSON.stringify(rl)}`);

// 10. 认证保护
const noAuth = await api('/api/chat/rooms');
check('无 token 访问被拒', noAuth.status === 401);
const adminNoAuth = await api('/api/admin/stats');
check('管理员接口未认证被拒', adminNoAuth.status === 401);

// 11. 账号聊天:创建私聊 + 发送 + 读取
log('\n[6] 账号聊天');
const dm = await api('/api/chat/rooms', { token: tokenA, body: {
  type: 'dm', memberIds: [2], wrappedKeys: [{ userId: 2, deviceId: 'dev-b', wrappedKey: 'wrapped-secret-key-material' }],
} });
check('创建私聊', dm.ok === true && dm.room?.id?.startsWith('r_'), JSON.stringify(dm));
const dmRoomId = dm.room?.id;

const dmMsg = await api(`/api/chat/rooms/${dmRoomId}/messages`, { token: tokenA, body: { iv: 'iv-16bytes-0001', cipher: Buffer.from('账号聊天也是密文').toString('base64'), seq: 1 } });
check('私聊发送', dmMsg.ok === true && dmMsg.seq === 1, JSON.stringify(dmMsg));

const dmRead = await api(`/api/chat/rooms/${dmRoomId}/messages`, { token: tokenB });
check('B 能读到 A 的密文', dmRead.ok === true && dmRead.messages.length === 1);
check('私聊密文非明文', !JSON.stringify(dmRead.messages).includes('账号聊天也是密文'));

// 12. 密钥包
const pkg = await api('/api/keys/export-package', { token: tokenA, body: { pkg: 'ENCRYPTED_EXPORT_PACKAGE_TEST', deviceId: 'dev-a' } });
check('保存加密导出包', pkg.ok === true);
const pkgGet = await api('/api/keys/export-package?deviceId=dev-a', { token: tokenA });
check('拉取加密导出包', pkgGet.ok === true && pkgGet.pkg === 'ENCRYPTED_EXPORT_PACKAGE_TEST');

// 13. 路径遍历防护
const trav = await fetch(`${BASE}/api/temp/rooms/xxx/messages?afterSeq=../../../../etc/passwd`).then(r => r.status);
check('路径遍历被拒(404/400)', trav === 400 || trav === 404, trav);

// 14. 大 payload 拒绝
const big = await fetch(`${BASE}/api/temp/rooms/${roomId}/messages`, {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ iv: 'x', cipher: 'x'.repeat(200 * 1024) }),
});
check('超大消息被拒', big.status === 413 || big.status === 400, big.status);

// 15. 管理后台登录(自动生成凭据)
log('\n[7] 管理后台');
const cred = fs.readFileSync(`${DATA}/config/admin.cred`, 'utf8').trim().split(':');
const adminLogin = await api('/api/admin/login', { method: 'POST', body: { username: cred[0], password: cred[1] } });
check('管理员登录', adminLogin.ok === true && adminLogin.token, JSON.stringify(adminLogin).slice(0, 100));
const adminToken = adminLogin.token;
const adminStats = await api('/api/admin/stats', { token: adminToken });
check('管理员看统计', adminStats.ok === true && adminStats.stats?.users >= 2, JSON.stringify(adminStats.stats));
check('管理员接口不含消息明文', !JSON.stringify(adminStats).includes(msgPlain));
const adminWrong = await api('/api/admin/login', { method: 'POST', body: { username: 'admin', password: 'wrong-password' } });
check('错误管理员密码被拒', adminWrong.status === 401);

log(`\n===== 冒烟结果: ${pass} 通过 / ${fail} 失败 =====`);
process.exit(fail > 0 ? 1 : 0);
