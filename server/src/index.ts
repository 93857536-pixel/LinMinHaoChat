import http from 'node:http';
import { buildApp } from './app.js';
import { startWs } from './ws.js';
import { config } from './config.js';
import { logger } from './logger.js';
import { db } from './db.js';
import { store } from './storage.js';
import path from 'node:path';
import fs from 'node:fs';

const app = buildApp();
const server = http.createServer(app);
startWs(server);

server.listen(config.port, config.bindHost, () => {
  logger.info('server_started', {
    port: config.port,
    host: config.bindHost,
    nodeEnv: config.nodeEnv,
    dataRoot: config.dataRoot,
    verifyChannel: config.verifyChannel,
  });
  if (config.verifyChannel !== 'alibaba' || config.mailChannel === 'dev') {
    logger.warn('验证码通道未全部启用生产通道:短信=' + (config.verifyChannel === 'alibaba' ? 'alibaba' : 'dev(日志)') + ' 邮件=' + config.mailChannel + ',生产请配置(短信:VERIFY_CHANNEL=alibaba;邮件:MAIL_CHANNEL=smtp|directmail)');
  }
  if (config.adminPasswordPlain) {
    logger.warn('ADMIN 使用自动生成密码,见 ' + path.join(config.dataRoot, 'config', 'admin.cred'));
  }
});

// 优雅退出
function shutdown(sig: string) {
  logger.info('shutdown', { sig });
  server.close(() => {
    db.close();
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 5000).unref();
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

// 未捕获异常:记日志后退出(由进程管理器重启)
process.on('uncaughtException', (e) => {
  logger.error('uncaught_exception', { message: e.message, stack: e.stack?.slice(0, 4000) });
  process.exit(1);
});
process.on('unhandledRejection', (r) => {
  logger.error('unhandled_rejection', { reason: String(r) });
});
