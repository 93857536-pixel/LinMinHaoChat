import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

export interface AppConfig {
  nodeEnv: 'development' | 'production';
  port: number;
  dataRoot: string;
  /** HTTPS 由 nginx 终止,Node 只监听内网 */
  bindHost: string;
  jwtSecret: string;
  otpPepper: string;
  adminUser: string;
  adminPasswordHash: string; // scrypt: salt:hash
  adminPasswordPlain?: string; // 仅首次自动生成时短暂存在(写文件后清除)
  corsOrigin: string;
  verifyChannel: 'dev' | 'alibaba';
  /** 邮件通道:smtp(通用 SMTP,如 foxmail/QQ) | directmail(阿里云) | dev(本地日志) */
  mailChannel: 'smtp' | 'directmail' | 'dev';
  // Alibaba Cloud
  alibabaKeyId?: string;
  alibabaKeySecret?: string;
  smsSignName?: string;
  smsTemplateCode?: string;
  dmAccountName?: string;   // DirectMail 发信地址
  dmFromAlias?: string;
  // SMTP(邮件验证码)
  smtpHost?: string;
  smtpPort?: number;
  smtpUser?: string;
  smtpPass?: string;
  smtpFromName?: string;
  // limits
  maxBodyBytes: number;       // 普通 API
  maxAttachmentBytes: number; // 加密附件
  tempRoomTtlMs: number;      // 临时房间过期
  tempRoomMaxMessages: number;
  inviteRoomTtlMs: number;    // 邀请房间过期(长效,保留聊天记录)
  inviteCodeTtlMs: number;    // 邀请码有效期
  inviteMaxAttempts: number;  // 验证码最大尝试次数
  wsMaxPayloadBytes: number;
}

function loadEnvFile(): Record<string, string> {
  // 支持 config/env.json(服务器本机,chmod 600)或真实环境变量。env 变量优先。
  // 候选位置:① cwd/config/env.json(随 start 脚本 WorkingDirectory)② DATA_ROOT/config/env.json(运维约定位置)
  const candidates = [
    path.join(process.cwd(), 'config', 'env.json'),
    path.join(process.env.DATA_ROOT || defaultDataRoot(), 'config', 'env.json'),
  ];
  let file: Record<string, string> = {};
  for (const envPath of candidates) {
    try {
      if (fs.existsSync(envPath)) {
        // 兼容 PowerShell 写出的 UTF-8 BOM 文件(JSON.parse 遇 BOM 直接失败)
        file = JSON.parse(fs.readFileSync(envPath, 'utf8').replace(/^\uFEFF/, ''));
        break;
      }
    } catch (e) {
      console.error('[config] failed to read', envPath, ':', (e as Error).message);
    }
  }
  return file;
}

function getSecretFile(relPath: string): string {
  // 从 data/config/<name> 读取或生成随机 secret(持久化,权限最小化)
  const file = path.join(process.env.DATA_ROOT || defaultDataRoot(), 'config', relPath);
  if (fs.existsSync(file)) {
    return fs.readFileSync(file, 'utf8').trim();
  }
  const secret = crypto.randomBytes(32).toString('base64url');
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, secret, { mode: 0o600 });
  return secret;
}

function defaultDataRoot(): string {
  return process.platform === 'win32' ? 'C:\\opt\\linminhao' : '/opt/linminhao';
}

function scryptHash(pw: string): string {
  const salt = crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(pw, salt, 64).toString('hex');
  return `${salt}:${hash}`;
}

export function loadConfig(): AppConfig {
  const env = { ...loadEnvFile(), ...process.env };

  const dataRoot = env.DATA_ROOT || defaultDataRoot();
  const nodeEnv: AppConfig['nodeEnv'] = env.NODE_ENV === 'production' ? 'production' : 'development';

  // 管理员:优先环境变量;否则自动生成随机密码(写入 data/config/admin.cred,chmod 600)
  let adminUser = env.ADMIN_USER || '';
  let adminPasswordHash = '';
  let adminPasswordPlain: string | undefined;
  if (adminUser && env.ADMIN_PASSWORD) {
    adminPasswordHash = scryptHash(env.ADMIN_PASSWORD);
  } else {
    adminUser = 'admin';
    adminPasswordPlain = crypto.randomBytes(9).toString('base64url').slice(0, 12);
    adminPasswordHash = scryptHash(adminPasswordPlain);
    const credPath = path.join(dataRoot, 'config', 'admin.cred');
    fs.mkdirSync(path.dirname(credPath), { recursive: true, mode: 0o700 });
    try {
      fs.writeFileSync(credPath, `admin:${adminPasswordPlain}\n`, { mode: 0o600 });
    } catch { /* non-fatal */ }
  }

  return {
    nodeEnv,
    port: parseInt(env.PORT || '3000', 10),
    dataRoot,
    bindHost: env.BIND_HOST || '127.0.0.1',
    jwtSecret: env.JWT_SECRET || getSecretFile('jwt.secret'),
    otpPepper: env.OTP_PEPPER || getSecretFile('otp.pepper'),
    adminUser,
    adminPasswordHash,
    adminPasswordPlain,
    corsOrigin: env.CORS_ORIGIN || 'http://localhost:5173', // 生产必须设置 CORS_ORIGIN 为你的站点源
    verifyChannel: env.VERIFY_CHANNEL === 'alibaba' ? 'alibaba' : 'dev',
    mailChannel: env.MAIL_CHANNEL === 'directmail' ? 'directmail' : env.MAIL_CHANNEL === 'smtp' ? 'smtp' : 'dev',
    alibabaKeyId: env.ALIBABA_ACCESS_KEY_ID,
    alibabaKeySecret: env.ALIBABA_ACCESS_KEY_SECRET,
    smsSignName: env.SMS_SIGN_NAME,
    smsTemplateCode: env.SMS_TEMPLATE_CODE,
    dmAccountName: env.DM_ACCOUNT_NAME,
    dmFromAlias: env.DM_FROM_ALIAS,
    smtpHost: env.MAIL_SMTP_HOST,
    smtpPort: parseInt(env.MAIL_SMTP_PORT || '465', 10),
    smtpUser: env.MAIL_USER,
    smtpPass: env.MAIL_PASS,
    smtpFromName: env.MAIL_FROM_NAME || 'LinMinHao Chat',
    maxBodyBytes: 128 * 1024,
    maxAttachmentBytes: 10 * 1024 * 1024,
    tempRoomTtlMs: 7 * 24 * 3600 * 1000,
    tempRoomMaxMessages: 2000,
    inviteRoomTtlMs: 365 * 24 * 3600 * 1000,  // 邀请房间 1 年(保留聊天记录)
    inviteCodeTtlMs: 30 * 24 * 3600 * 1000,   // 邀请码 30 天有效
    inviteMaxAttempts: 10,                    // 验证码尝试 10 次封禁
    wsMaxPayloadBytes: 128 * 1024,
  };
}

export const config: AppConfig = loadConfig();
