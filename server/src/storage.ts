import fs from 'node:fs';
import path from 'node:path';
import { config } from './config.js';
import { logger } from './logger.js';

/**
 * 密文存储层。
 * 数据目录结构(与站点代码完全分离,禁止通过 nginx 访问):
 *   <dataRoot>/
 *     messages/YYYY/MM/DD/<room>_<seq>.enc
 *     attachments/YYYY/MM/DD/<attId>.enc
 *     users/         (保留:用户相关文件)
 *     sessions/
 *     logs/
 *     config/        (密钥文件,chmod 600)
 *     backups/
 *
 * 这里只保存加密后的字节,服务器永远不接触明文。
 */
export class CipherStore {
  readonly messagesDir: string;
  readonly attachmentsDir: string;
  readonly avatarsDir: string;
  readonly usersDir: string;
  readonly sessionsDir: string;
  readonly backupsDir: string;
  readonly configDir: string;

  constructor() {
    const root = config.dataRoot;
    this.messagesDir = path.join(root, 'messages');
    this.attachmentsDir = path.join(root, 'attachments');
    this.avatarsDir = path.join(root, 'avatars');
    this.usersDir = path.join(root, 'users');
    this.sessionsDir = path.join(root, 'sessions');
    this.backupsDir = path.join(root, 'backups');
    this.configDir = path.join(root, 'config');
    for (const d of [root, this.messagesDir, this.attachmentsDir, this.avatarsDir, this.usersDir, this.sessionsDir, this.backupsDir, this.configDir, path.join(root, 'logs')]) {
      fs.mkdirSync(d, { recursive: true, mode: 0o700 });
    }
  }

  private dayDir(base: string): string {
    const d = new Date();
    const p = path.join(base, String(d.getFullYear()), String(d.getMonth() + 1).padStart(2, '0'), String(d.getDate()).padStart(2, '0'));
    fs.mkdirSync(p, { recursive: true, mode: 0o700 });
    return p;
  }

  /** 保存一条消息密文,返回相对路径(如 messages/2026/08/17/room_1.enc) */
  saveMessageCipher(roomId: string, seq: number, payload: Buffer): string {
    const dir = this.dayDir(this.messagesDir);
    // roomId/seq 均由服务器生成并校验格式,杜绝路径遍历
    const safeRoom = roomId.replace(/[^A-Za-z0-9_-]/g, '');
    const filename = `${safeRoom}_${seq}.enc`;
    fs.writeFileSync(path.join(dir, filename), payload, { mode: 0o600 });
    const rel = path.relative(this.messagesDir, path.join(dir, filename)).replace(/\\/g, '/');
    return `messages/${rel}`;
  }

  saveAttachmentCipher(attId: string, payload: Buffer): string {
    const dir = this.dayDir(this.attachmentsDir);
    const safeId = attId.replace(/[^A-Za-z0-9_-]/g, '');
    const filename = `${safeId}.enc`;
    fs.writeFileSync(path.join(dir, filename), payload, { mode: 0o600 });
    const rel = path.relative(this.attachmentsDir, path.join(dir, filename)).replace(/\\/g, '/');
    return `attachments/${rel}`;
  }

  /** 读取密文文件(只允许 dataRoot 内 messages/attachments 两个子目录,防目录遍历) */
  readCipher(relPath: string): Buffer {
    const normalized = path.normalize(relPath).replace(/\\/g, '/');
    if (!normalized.startsWith('messages/') && !normalized.startsWith('attachments/')) {
      throw new Error('bad cipher path');
    }
    const abs = path.join(config.dataRoot, normalized);
    const root = path.resolve(config.dataRoot);
    if (!abs.startsWith(root + path.sep)) throw new Error('path escape');
    return fs.readFileSync(abs);
  }

  deleteCipher(relPath: string): void {
    const normalized = path.normalize(relPath).replace(/\\/g, '/');
    if (!normalized.startsWith('messages/') && !normalized.startsWith('attachments/')) return;
    const abs = path.join(config.dataRoot, normalized);
    const root = path.resolve(config.dataRoot);
    if (!abs.startsWith(root + path.sep)) return;
    try { fs.unlinkSync(abs); logger.info('cipher deleted', { relPath }); } catch { /* ignore */ }
  }

  /**
   * 头像(用户自主上传的明文图片,非密文):
   *   <dataRoot>/avatars/<userId>.<ext>   —— 每个用户至多一份,换头像即覆盖
   * 只允许 dataRoot/avatars 内、纯数字 userId + 白名单扩展名,杜绝路径遍历。
   */
  saveAvatar(userId: number, ext: string, payload: Buffer): string {
    const safeId = String(userId).replace(/[^0-9]/g, '');
    const safeExt = ['jpg', 'png', 'webp'].includes(ext) ? ext : 'jpg';
    // 换头像:先清掉该用户其它扩展名的旧文件,避免残留
    for (const e of ['jpg', 'png', 'webp']) {
      if (e === safeExt) continue;
      try { fs.unlinkSync(path.join(this.avatarsDir, `${safeId}.${e}`)); } catch { /* ignore */ }
    }
    const file = path.join(this.avatarsDir, `${safeId}.${safeExt}`);
    fs.writeFileSync(file, payload, { mode: 0o600 });
    return `avatars/${safeId}.${safeExt}`;
  }

  readAvatar(relPath: string): Buffer | null {
    const normalized = path.normalize(relPath).replace(/\\/g, '/');
    if (!/^avatars\/[0-9]+\.(jpg|png|webp)$/.test(normalized)) return null;
    const abs = path.join(config.dataRoot, normalized);
    const root = path.resolve(config.dataRoot);
    if (!abs.startsWith(root + path.sep)) return null;
    try { return fs.readFileSync(abs); } catch { return null; }
  }

  deleteAvatar(relPath: string): void {
    const normalized = path.normalize(relPath).replace(/\\/g, '/');
    if (!/^avatars\/[0-9]+\.(jpg|png|webp)$/.test(normalized)) return;
    const abs = path.join(config.dataRoot, normalized);
    const root = path.resolve(config.dataRoot);
    if (!abs.startsWith(root + path.sep)) return;
    try { fs.unlinkSync(abs); } catch { /* ignore */ }
  }

  diskUsageBytes(): { messages: number; attachments: number; total: number } {
    const walk = (d: string): number => {
      let sum = 0;
      try {
        for (const e of fs.readdirSync(d, { withFileTypes: true })) {
          const p = path.join(d, e.name);
          if (e.isDirectory()) sum += walk(p);
          else if (e.isFile()) sum += fs.statSync(p).size;
        }
      } catch { /* ignore */ }
      return sum;
    };
    const messages = walk(this.messagesDir);
    const attachments = walk(this.attachmentsDir);
    return { messages, attachments, total: messages + attachments };
  }
}

export const store = new CipherStore();
