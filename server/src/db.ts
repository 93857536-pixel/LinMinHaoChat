import Database from 'better-sqlite3';
import path from 'node:path';
import fs from 'node:fs';
import { config } from './config.js';

const dbDir = path.join(config.dataRoot, 'db');
fs.mkdirSync(dbDir, { recursive: true, mode: 0o700 });

export const db = new Database(path.join(dbDir, 'chat.db'));
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');
db.pragma('synchronous = NORMAL');
db.pragma('busy_timeout = 5000');

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  phone_hash    TEXT UNIQUE,
  email_hash    TEXT UNIQUE,
  phone_masked  TEXT,
  email_masked  TEXT,
  handle        TEXT,
  created_at    INTEGER NOT NULL,
  banned        INTEGER NOT NULL DEFAULT 0,
  ban_reason    TEXT,
  last_login_at INTEGER
);
CREATE TABLE IF NOT EXISTS user_keys (
  user_id    INTEGER NOT NULL REFERENCES users(id),
  device_id  TEXT NOT NULL,
  ed25519_pub TEXT NOT NULL,
  ecdh_pub   TEXT NOT NULL,
  export_pkg TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, device_id)
);
CREATE TABLE IF NOT EXISTS rooms (
  id         TEXT PRIMARY KEY,
  type       TEXT NOT NULL CHECK (type IN ('dm','group')),
  name_enc   TEXT,
  created_by INTEGER,
  created_at INTEGER NOT NULL,
  archived   INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS room_members (
  room_id      TEXT NOT NULL REFERENCES rooms(id),
  user_id      INTEGER NOT NULL REFERENCES users(id),
  joined_at    INTEGER NOT NULL,
  last_read_seq INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (room_id, user_id)
);
CREATE TABLE IF NOT EXISTS room_keys (
  room_id       TEXT NOT NULL REFERENCES rooms(id),
  member_user_id INTEGER NOT NULL,
  device_id     TEXT NOT NULL,
  wrapped_key   TEXT NOT NULL,
  PRIMARY KEY (room_id, member_user_id, device_id)
);
CREATE TABLE IF NOT EXISTS temp_rooms (
  id            TEXT PRIMARY KEY,
  created_at    INTEGER NOT NULL,
  expires_at    INTEGER NOT NULL,
  last_activity INTEGER NOT NULL,
  msg_count     INTEGER NOT NULL DEFAULT 0,
  status        TEXT NOT NULL DEFAULT 'active',
  kind          TEXT NOT NULL DEFAULT 'temp'
);
CREATE TABLE IF NOT EXISTS invite_rooms (
  id          TEXT PRIMARY KEY,
  room_id     TEXT NOT NULL REFERENCES temp_rooms(id),
  code_hash   TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL,
  attempts    INTEGER NOT NULL DEFAULT 0,
  used        INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_invite_room ON invite_rooms(room_id);
CREATE TABLE IF NOT EXISTS messages (
  id             TEXT PRIMARY KEY,
  room_id        TEXT NOT NULL,
  kind           TEXT NOT NULL DEFAULT 'msg',
  seq            INTEGER NOT NULL,
  sender_user_id INTEGER,
  sender_anon    TEXT,
  cipher_path    TEXT NOT NULL,
  iv             TEXT NOT NULL,
  aad            TEXT NOT NULL,
  meta_enc       TEXT,
  ts             INTEGER NOT NULL,
  read_by        TEXT NOT NULL DEFAULT '[]',
  UNIQUE (room_id, seq)
);
CREATE INDEX IF NOT EXISTS idx_messages_room_seq ON messages(room_id, seq);
CREATE TABLE IF NOT EXISTS otp_codes (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  target_hash TEXT NOT NULL,
  type       TEXT NOT NULL,
  code_hash  TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  attempts   INTEGER NOT NULL DEFAULT 0,
  used       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_otp_target ON otp_codes(target_hash, type, created_at);
CREATE TABLE IF NOT EXISTS sessions (
  id         TEXT PRIMARY KEY,
  user_id    INTEGER NOT NULL,
  token_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  device     TEXT
);
CREATE TABLE IF NOT EXISTS admin_audit (
  id     INTEGER PRIMARY KEY AUTOINCREMENT,
  ts     INTEGER NOT NULL,
  actor  TEXT NOT NULL,
  action TEXT NOT NULL,
  detail TEXT
);
`);

/** 服务器重启后校验数据目录可写(快速自检) */
export function healthCheckDb(): boolean {
  try {
    db.prepare('SELECT 1').get();
    return true;
  } catch {
    return false;
  }
}

/**
 * 轻量迁移:为旧库补齐新增列。
 * CREATE TABLE IF NOT EXISTS 不会修改已存在的表,所以这里显式 ALTER。
 */
function migrate(): void {
  const cols = db.prepare('PRAGMA table_info(temp_rooms)').all() as { name: string }[];
  if (!cols.some((c) => c.name === 'kind')) {
    db.exec("ALTER TABLE temp_rooms ADD COLUMN kind TEXT NOT NULL DEFAULT 'temp'");
    console.log('[db] migrated: temp_rooms.kind');
  }
  if (!cols.some((c) => c.name === 'guest_count')) {
    db.exec('ALTER TABLE temp_rooms ADD COLUMN guest_count INTEGER NOT NULL DEFAULT 0');
    console.log('[db] migrated: temp_rooms.guest_count');
  }
}
migrate();
