/**
 * 转发消息。
 *
 * E2EE 关键:每个房间的会话密钥不同,源房间的密文不能直接搬到目标房间(对方解不开)。
 * 必须:用源房间会话密钥解出原文 → 用「目标房间」会话密钥重新加密 → 发送。
 *
 * ⚠️ 已知阻塞(见汇报):
 *   1. `forwardTo` 的 verbatim 签名只有 `(token, targetRoomId, payload)`,但解密原文需要
 *      源消息的 roomId/seq/ts(AAD = `${roomId}:${seq}:${ts}`)。故追加可选第 4 参 `source`,
 *      缺省时抛错。主会话集成时需从 Chat 侧把源消息的 seq/ts 一并传进来。
 *   2. `msgExt.forward` 落盘的 body 字段是 `{ targetRoomId, msgId, iv, cipher, kind, meta }`,
 *      但 server 端 `/chat/rooms/:id/forward` 实际读取 `{ sourceMsgId, srcRoomId, cipher,
 *      iv, kind, meta, ts }` —— 字段名与缺失项(源房间 id、时间戳)对不上,且转发接口会在
 *      服务端按目标房间重算 seq,客户端这里用 lastSeq+1 预估,存在并发竞态(见汇报)。
 */
import { chatApi } from '../../api';
import { msgExt } from '../api-ext';
import { decryptMessage, encryptMessage } from '../../crypto/message';
import { unwrapSessionKey, type Bytes } from '../../crypto/session';
import { ensureIdentityKeys } from '../../crypto/keys';

/** 解密原文所需的源消息最小上下文 */
export interface ForwardSource {
  roomId: string;
  seq: number;
  ts: number;
  /** 源消息在服务端的 id(服务端要求 sourceMsgId) */
  msgId: string;
}

async function getRoomSessionKey(roomId: string, deviceId: string, token: string): Promise<Bytes> {
  const wrapped = await chatApi.keys(roomId, deviceId, token);
  for (const w of wrapped.keys) {
    try {
      return await unwrapSessionKey(w);
    } catch {
      /* 尝试下一个 wrapped key */
    }
  }
  throw new Error(`无法解包房间 ${roomId.slice(0, 8)} 的会话密钥:你可能不是该房间的授权成员`);
}

/**
 * 把一条消息转发到目标房间(解出原文 → 用目标房间密钥重加密 → 发送)。
 * @param source 源消息的 roomId/seq/ts(解密原文必需);缺省时抛错。
 */
export async function forwardTo(
  token: string,
  targetRoomId: string,
  payload: { iv: string; cipher: string; kind: string; meta?: string },
  source?: ForwardSource,
): Promise<void> {
  if (!source) {
    throw new Error('转发缺少源消息上下文(roomId/seq/ts),无法解密原文');
  }

  const { deviceId } = await ensureIdentityKeys();

  // 1. 源房间会话密钥 → 解出原文(JSON 字符串,{"t":...} / {"f":...})
  const srcKey = await getRoomSessionKey(source.roomId, deviceId, token);
  const plaintext = await decryptMessage(
    srcKey,
    { iv: payload.iv, ct: payload.cipher },
    source.roomId,
    source.seq,
    source.ts,
  );

  // 2. 目标房间会话密钥 + 下一个 seq → 重新加密
  const tgtKey = await getRoomSessionKey(targetRoomId, deviceId, token);
  const rooms = await chatApi.rooms(token);
  const tgt = rooms.rooms.find((r) => r.id === targetRoomId);
  const nextSeq = (tgt?.lastSeq ?? 0) + 1;
  const ts = Date.now();
  const enc = await encryptMessage(tgtKey, plaintext, targetRoomId, nextSeq, ts);

  // 3. 发送(服务器只存密文;字段名严格对齐 /rooms/:id/forward 契约)
  await msgExt.forward(
    targetRoomId,
    {
      sourceMsgId: source.msgId,
      srcRoomId: source.roomId,
      cipher: enc.ct,
      iv: enc.iv,
      kind: payload.kind,
      meta: payload.meta,
      ts,
    },
    token,
  );
}
