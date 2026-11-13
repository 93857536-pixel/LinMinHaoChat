/**
 * VoiceRecorder — 语音录制桥插件(鸿蒙端:AVRecorder → m4a/AAC)。
 */
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { VOICE_MIME } from '../common/Consts';
import type { Permissions } from 'permissions';

interface VoicePayload {
  base64?: string;
  mime?: string;
  durationMs?: number;
  available?: boolean;
}

export class VoiceHandler {
  private handler: (ok: boolean, payload: VoicePayload, errMsg?: string) => void;
  constructor(handler: (ok: boolean, payload: VoicePayload, errMsg?: string) => void) {
    this.handler = handler;
  }
  invoke(ok: boolean, payload: VoicePayload, errMsg?: string): void {
    this.handler(ok, payload, errMsg);
  }
}

const base64Helper = new util.Base64Helper();

export class VoiceRecorder {
  context: common.UIAbilityContext;
  recorder: media.AVRecorder | null = null;
  file: fileIo.File | null = null;
  filePath: string = '';
  startedAt: number = 0;
  recording: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  dispatch(method: string, options: Record<string, Object>, done: VoiceHandler): void {
    if (method === 'isAvailable') {
      done.invoke(true, { available: true });
      return;
    }
    if (method === 'start') {
      this.start().then(() => done.invoke(true, {}), (e: Error) => done.invoke(false, {}, this.friendly(e.toString())));
      return;
    }
    if (method === 'stop') {
      this.stop().then((payload: VoicePayload) => done.invoke(true, payload), (e: Error) => done.invoke(false, {}, this.friendly(e.toString())));
      return;
    }
    if (method === 'cancel') {
      this.cancel();
      done.invoke(true, {});
      return;
    }
    done.invoke(false, {}, `VoiceRecorder.${method} 未实现`);
  }

  private async ensureMicPermission(): Promise<void> {
    const atManager = abilityAccessCtrl.createAtManager();
    const perms: Array<Permissions> = ['ohos.permission.MICROPHONE'] as Array<Permissions>;
    try {
      await atManager.requestPermissionsFromUser(this.context, perms);
    } catch (e) {
      const err = e as BusinessError;
      throw new Error(err.message ? err.message : '麦克风权限申请失败');
    }
  }

  private async start(): Promise<void> {
    await this.discard();
    await this.ensureMicPermission();

    this.filePath = this.context.cacheDir + '/voice_' + Date.now() + '.m4a';
    this.file = fileIo.openSync(this.filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);

    this.recorder = await media.createAVRecorder();
    this.recorder.on('stateChange', (state: media.AVRecorderState) => {
      if (state === 'error' || state === 'released') {
        this.recording = false;
      }
    });

    const profile: media.AVRecorderProfile = {
      audioBitrate: 64000,
      audioChannels: 1,
      audioCodec: media.CodecMimeType.AUDIO_AAC,
      fileFormat: media.ContainerFormatType.CFT_MPEG_4
    };

    const cfg: media.AVRecorderConfig = {
      audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
      profile: profile,
      url: 'fd://' + this.file.fd
    };

    try {
      await this.recorder.prepare(cfg);
      await this.recorder.start();
      this.recording = true;
      this.startedAt = Date.now();
    } catch (e) {
      const err = e as BusinessError;
      await this.discard();
      throw new Error('录音启动失败: ' + (err.message ? err.message : e.toString()));
    }
  }

  private async stop(): Promise<VoicePayload> {
    if (!this.recorder || !this.recording) {
      throw new Error('未在录音');
    }
    const durationMs = Date.now() - this.startedAt;
    this.recording = false;
    try {
      await this.recorder.stop();
    } catch (e) { /* ignore */ }
    try {
      await this.recorder.release();
    } catch (e) { /* ignore */ }
    this.recorder = null;

    if (!this.file || !this.filePath) {
      await this.discard();
      throw new Error('录音太短或失败,请按住多说一会儿');
    }
    const stat = fileIo.statSync(this.filePath);
    if (stat.size <= 0) {
      await this.discard();
      throw new Error('录音太短或失败,请按住多说一会儿');
    }
    const buf = new ArrayBuffer(stat.size);
    const read = fileIo.readSync(this.file.fd, buf);
    if (read < stat.size) {
      await this.discard();
      throw new Error('读取录音失败');
    }
    const bytes = new Uint8Array(buf);
    const base64 = base64Helper.encodeToStringSync(bytes);
    await this.discard();
    return {
      base64: base64,
      mime: VOICE_MIME,
      durationMs: durationMs
    };
  }

  private cancel(): void {
    void this.discard();
  }

  private async discard(): Promise<void> {
    if (this.recorder) {
      try { await this.recorder.stop(); } catch (e) { /* ignore */ }
      try { await this.recorder.release(); } catch (e) { /* ignore */ }
      this.recorder = null;
    }
    if (this.file) {
      try { fileIo.closeSync(this.file); } catch (e) { /* ignore */ }
      this.file = null;
    }
    if (this.filePath) {
      try { fileIo.unlinkSync(this.filePath); } catch (e) { /* ignore */ }
      this.filePath = '';
    }
  }

  private friendly(e: string): string {
    if (e.includes('麦克风') || e.includes('MICROPHONE') || e.includes('permission')) {
      return '需要麦克风权限才能发送语音消息';
    }
    return e;
  }
}
