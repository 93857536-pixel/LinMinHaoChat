/**
 * 转发消息。
 *
 * E2EE 关键:每个房间的会话密钥不同,源房间的密文不能直接搬到目标房间(对方解不开)。
 * 必须:用源房间会话密钥解出原文 → 用「目标房间」会话密钥重新加密 → 发送。
 *
 * 契约:请求体字段与 server `/chat/rooms/:id/forward`(:id = 目标房间)逐字对齐
 * ({ sourceMsgId, srcRoomId, cipher, iv, kind, meta, ts }),客户端用目标房间
 * 最后 seq + 1 预估加密 AAD,服务端落库时按目标房间 MAX(seq)+1 生成最终 seq。
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
