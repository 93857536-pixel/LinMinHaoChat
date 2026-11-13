import { createRequire } from 'node:module';
import { config } from './config.js';
import { logger } from './logger.js';

// 阿里云 SDK 为 CJS 转译产物(exports.default = Client),用 createRequire 运行时加载,
// 规避 NodeNext ESM 解析差异。类型以最小调用面声明。
const require = createRequire(import.meta.url);
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const DysmsapiMod: any = require('@alicloud/dysmsapi20170525');
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const DysmsapiCtor: any = DysmsapiMod.default;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const DmCtor: any = require('@alicloud/dm20151123').default;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const OpenApiConfig: any = require('@alicloud/openapi-client').Config;

interface SendResult { ok: boolean; error?: string }

interface SmsClient {
  sendSms(req: { phoneNumbers: string; signName: string; templateCode: string; templateParam: string }): Promise<{ body?: { code?: string; message?: string } }>;
}
interface MailClient {
  singleSendMail(req: { accountName: string; fromAlias?: string; addressType: number; replyToAddress: boolean; toAddress: string; subject: string; textBody: string }): Promise<{ body?: { requestId?: string } }>;
}

function newSmsClient(): SmsClient {
  return new DysmsapiCtor(new OpenApiConfig({
    accessKeyId: config.alibabaKeyId,
    accessKeySecret: config.alibabaKeySecret,
    endpoint: 'dysmsapi.aliyuncs.com',
  })) as SmsClient;
}

function newMailClient(): MailClient {
  return new DmCtor(new OpenApiConfig({
    accessKeyId: config.alibabaKeyId,
    accessKeySecret: config.alibabaKeySecret,
    endpoint: 'dm.aliyuncs.com',
  })) as MailClient;
}

/**
 * 发送通道:
 * - 短信: 阿里云 Dysmsapi SendSms(签名+模板需审核)
 * - 邮件: 可选 SMTP(通用,如 foxmail/QQ)或阿里云 DirectMail SingleSendMail
 * 凭证仅来自环境变量/config/env.json,绝不进入前端或代码仓库。
 */

export async function sendSmsCode(phone: string, code: string, min: number = 5): Promise<SendResult> {
  if (!config.alibabaKeyId || !config.alibabaKeySecret) {
    logger.error('sms_not_configured', { reason: 'missing access key' });
    return { ok: false, error: 'sms_not_configured' };
  }
  if (!config.smsSignName || !config.smsTemplateCode) {
    logger.error('sms_not_configured', { reason: 'missing sign/template' });
    return { ok: false, error: 'sms_not_configured' };
  }
  try {
    const req = new DysmsapiMod.SendSmsRequest({
      phoneNumbers: phone,
      signName: config.smsSignName,
      templateCode: config.smsTemplateCode,
      templateParam: JSON.stringify({ code, min }) /* min MUST match CODE_TTL_MS (5min) in otp.js; channels.js cannot import otp.js (circular) */,
    });
    const resp = await newSmsClient().sendSms(req);
    if (resp.body?.code === 'OK') {
      return { ok: true };
    }
    logger.error('sms_send_failed', { aliyunCode: resp.body?.code, message: resp.body?.message });
    return { ok: false, error: 'sms_failed' };
  } catch (e) {
    logger.error('sms_send_exception', { message: (e as Error).message });
    return { ok: false, error: 'sms_failed' };
  }
}

/** 邮件发送:按 config.mailChannel 分发 */
export async function sendEmailCode(email: string, code: string): Promise<SendResult> {
  if (config.mailChannel === 'directmail') {
    return sendDirectMail(email, code);
  }
  if (config.mailChannel === 'smtp') {
    return sendSmtpMail(email, code);
  }
  return { ok: false, error: 'mail_channel_not_configured' };
}

/** 阿里云 DirectMail */
async function sendDirectMail(email: string, code: string): Promise<SendResult> {
  if (!config.alibabaKeyId || !config.alibabaKeySecret) {
    logger.error('mail_not_configured', { reason: 'missing access key' });
    return { ok: false, error: 'mail_not_configured' };
  }
  if (!config.dmAccountName) {
    logger.error('mail_not_configured', { reason: 'missing DM_ACCOUNT_NAME' });
    return { ok: false, error: 'mail_not_configured' };
  }
  try {
    const resp = await newMailClient().singleSendMail({
      accountName: config.dmAccountName,
      fromAlias: config.dmFromAlias || 'LinMinHao Chat',
      addressType: 1,
      replyToAddress: false,
      toAddress: email,
      subject: 'LinMinHao Chat 登录验证码',
      textBody: `你的登录验证码是: ${code} ,5 分钟内有效。若非本人操作请忽略。`,
    });
    logger.info('mail_sent', { requestId: resp.body?.requestId });
    return { ok: true };
  } catch (e) {
    logger.error('mail_send_exception', { message: (e as Error).message });
    return { ok: false, error: 'mail_failed' };
  }
}

/** 通用 SMTP(如 smtp.foxmail.com / smtp.qq.com),nodemailer 传输 */
async function sendSmtpMail(email: string, code: string): Promise<SendResult> {
  if (!config.smtpHost || !config.smtpUser || !config.smtpPass) {
    logger.error('smtp_not_configured', { reason: 'missing host/user/pass' });
    return { ok: false, error: 'smtp_not_configured' };
  }
  try {
    // nodemailer 为 CJS,createRequire 加载
    const nodemailer = require('nodemailer');
    const transporter = nodemailer.createTransport({
      host: config.smtpHost,
      port: config.smtpPort || 465,
      secure: (config.smtpPort || 465) === 465,
      auth: { user: config.smtpUser, pass: config.smtpPass },
      connectionTimeout: 15_000,
      socketTimeout: 20_000,
    });
    await transporter.sendMail({
      from: `"${config.smtpFromName || 'LinMinHao Chat'}" <${config.smtpUser}>`,
      to: email,
      subject: 'LinMinHao Chat 登录验证码',
      text: `你的登录验证码是: ${code} ,5 分钟内有效。若非本人操作请忽略。`,
    });
    logger.info('smtp_mail_sent', { to: email });
    return { ok: true };
  } catch (e) {
    logger.error('smtp_mail_exception', { message: (e as Error).message });
    return { ok: false, error: 'mail_failed' };
  }
}
