/**
 * 原生能力桥(主会话维护)—— 语音录制。
 *
 * ⚠️ 跨端硬约束:语音必须录成 **m4a/AAC**,因为 iOS 端用 AVAudioPlayer 播放,
 *    不认识 webm/opus。服务端 /api/attachments 的白名单也只允许 audio/mp4、audio/aac 等
 *    (audio/webm 音频**不在**白名单,传了会 400 unsafe_mime)。
 *
 * 优先级:
 *   1. Capacitor 原生插件 VoiceRecorder(Android:MediaRecorder MPEG_4/AAC → 真 m4a)← 生产路径
 *   2. MediaRecorder('audio/mp4')(部分 WebView/Safari 支持)
 *   3. 不支持 → voiceSupported() 返回 false,UI 应禁用语音按钮并提示
 */
import { registerPlugin } from '@capacitor/core';

interface VoiceRecorderPlugin {
  start(): Promise<void>;
  stop(): Promise<{ base64: string; mime: string; durationMs: number }>;
  cancel(): Promise<void>;
  isAvailable?(): Promise<{ available: boolean }>;
}

const VoiceRecorder = registerPlugin<VoiceRecorderPlugin>('VoiceRecorder');

export interface VoiceClip {
  blob: Blob;
  /** 上传时作为 declaredMime(必须是服务端白名单内的值) */
  mime: string;
  durationMs: number;
  /** 固定文件名,与 iOS 端一致 */
  name: string;
}

function isNativeShell(): boolean {
  const c = (globalThis as unknown as { Capacitor?: { isNativePlatform?: () => boolean } }).Capacitor;
  return !!(c && typeof c.isNativePlatform === 'function' && c.isNativePlatform());
}

/* ---------------- 路径 2:浏览器 MediaRecorder ---------------- */

let mediaRecorder: MediaRecorder | null = null;
let chunks: Blob[] = [];
let startedAt = 0;
let usingNative = false;

function pickBrowserMime(): string | null {
  if (typeof MediaRecorder === 'undefined') return null;
  const candidates = ['audio/mp4', 'audio/mp4;codecs=mp4a.40.2', 'audio/aac'];
  for (const c of candidates) {
    try {
      if (MediaRecorder.isTypeSupported(c)) return c;
    } catch { /* ignore */ }
  }
  return null;
}

/** 本机是否具备可用的录音能力 */
export function voiceSupported(): boolean {
  if (isNativeShell()) return true; // 原生插件始终可用
  return pickBrowserMime() !== null;
}

/** 开始录音 */
export async function startVoiceRecording(): Promise<void> {
  if (isNativeShell()) {
    await VoiceRecorder.start();
    usingNative = true;
    startedAt = Date.now();
    return;
  }
  const mime = pickBrowserMime();
  if (!mime) throw new Error('当前环境不支持语音录制');
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  chunks = [];
  mediaRecorder = new MediaRecorder(stream, { mimeType: mime });
  mediaRecorder.ondataavailable = (e) => {
    if (e.data && e.data.size > 0) chunks.push(e.data);
  };
  mediaRecorder.start();
  usingNative = false;
  startedAt = Date.now();
}

/** 结束录音并返回可上传的音频片段 */
export async function stopVoiceRecording(): Promise<VoiceClip> {
  const fallbackDuration = Math.max(0, Date.now() - startedAt);

  if (usingNative) {
    const r = await VoiceRecorder.stop();
    const bin = atob(r.base64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return {
      blob: new Blob([bytes], { type: 'audio/mp4' }),
      mime: 'audio/aac', // 与 iOS 端 declaredMime 一致(服务端白名单内)
      durationMs: r.durationMs || fallbackDuration,
      name: 'voice.m4a',
    };
  }

  const rec = mediaRecorder;
  if (!rec) throw new Error('未在录音');
  const done = new Promise<Blob>((resolve) => {
    rec.onstop = () => resolve(new Blob(chunks, { type: rec.mimeType || 'audio/mp4' }));
  });
  rec.stop();
  rec.stream.getTracks().forEach((t) => t.stop());
  const blob = await done;
  mediaRecorder = null;
  return { blob, mime: 'audio/aac', durationMs: fallbackDuration, name: 'voice.m4a' };
}

/** 取消录音(丢弃) */
export function cancelVoiceRecording(): void {
  if (usingNative) {
    void VoiceRecorder.cancel().catch(() => {});
    usingNative = false;
    return;
  }
  try {
    mediaRecorder?.stream.getTracks().forEach((t) => t.stop());
    mediaRecorder?.stop();
  } catch { /* ignore */ }
  mediaRecorder = null;
  chunks = [];
}

/** 把 Blob 读成 ArrayBuffer(上传用) */
export function blobToArrayBuffer(blob: Blob): Promise<ArrayBuffer> {
  return blob.arrayBuffer();
}
