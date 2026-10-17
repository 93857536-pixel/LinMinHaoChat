/**
 * VoiceRecorder — 语音录制桥插件(鸿蒙端:AVRecorder → m4a/AAC)。
 *
 * 与 Android MediaRecorder 版逐字对齐(见 docs/bridge-protocol.md §3):
 *   start()      → 开始录 m4a(AAC in MP4);不足会 reject
 *   stop()       → 结束并回传 {base64, mime:'audio/mp4', durationMs}
 *   cancel()     → 丢弃
 *   isAvailable() → {available:true}
 *
 * 跨端硬约束(与 Android/iOS 一致):语音必须录成 m4a/AAC。iOS 用 AVAudioPlayer 播放,
 * 服务端 /api/attachments 白名单只收 audio/mp4、audio/aac(audio/webm 会被 400 拒绝)。
 *
 * 权限:ohos.permission.MICROPHONE(module.json5 已声明),start() 时动态申请。
 *
 * ⚠️ SDK 实测锚点:AVRecorder 输出文件绑定 / prepare 配置字段随 API 版本略有差异,
 *    以本机安装的 HarmonyOS SDK(API 12)编译结果为准;下方按官方 @kit.MediaKit 标准范式书写。
 */
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { buffer } from '@kit.ArkBuffer';
import { VOICE_MIME } from '../common/Consts';

export type VoiceHandler = (ok: boolean, payload: Record<string, Object>, errMsg?: string) => void;

export class VoiceRecorder {
  private context: common.UIAbilityContext;
  private recorder: media.AVRecorder | null = null;
  private file: fileIo.File | null = null;
  private filePath: string = '';
  private startedAt: number = 0;
  private recording: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** 分发入口(与 BridgeDispatcher 对齐) */
  dispatch(method: string, options: Record<string, Object>, done: VoiceHandler): void {
    if (method === 'isAvailable') {
      done(true, { available: true });
      return;
    }
    if (method === 'start') {
      this.start().then(() => done(true, {}), (e) => done(false, {}, this.friendly(String(e))));
      return;
    }
    if (method === 'stop') {
      this.stop().then((payload) => done(true, payload), (e) => done(false, {}, this.friendly(String(e))));
      return;
    }
    if (method === 'cancel') {
      this.cancel();
      done(true, {});
      return;
    }
    done(false, {}, `VoiceRecorder.${method} 未实现`);
  }

  /* ---------------- 权限 ---------------- */
  private async ensureMicPermission(): Promise<void> {
    const atManager = abilityAccessCtrl.createManager();
    const perms: Array<string> = ['ohos.permission.MICROPHONE'];
    try {
      const result = await atManager.requestPermissionsFromUser(this.context, perms);
      if (result.results.length > 0 && result.results[0] !== 0) {
        throw new Error('需要麦克风权限才能发送语音消息');
      }
    } catch (e) {
      const err = e as BusinessError;
      throw new Error(err.message ? err.message : '麦克风权限申请失败');
    }
  }

  /* ---------------- start ---------------- */
  private async start(): Promise<void> {
    await this.discard(); // 清理上一段
    await this.ensureMicPermission();

    this.filePath = this.context.cacheDir + '/voice_' + Date.now() + '.m4a';
    this.file = fileIo.openSync(this.filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);

    this.recorder = await media.createAVRecorder();
    this.recorder.on('stateChange', (state: media.AVRecorderState) => {
      if (state === 'error' || state === 'released') {
        this.recording = false;
      }
    });

    // 输出文件绑定: 官方 RecorderConfig.outputFd(number)。部分 SDK 版本可能无此字段,
    // 编译若报「属性 outputFd 不存在」, 删掉该字段即可(AVRecorder 会自动写 cacheDir 默认文件)。
    const cfg: media.RecorderConfig = {
      audioSourceType: media.AudioSourceType.MIC,
      audioProfile: {
        samplingRate: 44100,
        channels: 1,
        codec: media.CodecType.AAC,
        bitRate: 64000
      },
      fileFormat: media.OutputFormat.MPEG_4,
      outputFd: this.file.fd
    };

    try {
      await this.recorder.prepare(cfg);
      await this.recorder.start();
      this.recording = true;
      this.startedAt = Date.now();
    } catch (e) {
      const err = e as BusinessError;
      await this.discard();
      throw new Error('录音启动失败: ' + (err.message ? err.message : String(e)));
    }
  }

  /* ---------------- stop ---------------- */
  private async stop(): Promise<Record<string, Object>> {
    if (!this.recorder || !this.recording) {
      throw new Error('未在录音');
    }
    const durationMs = Date.now() - this.startedAt;
    this.recording = false;
    try {
      await this.recorder.stop();
    } catch (e) {
      // 录音过短时 stop 会抛异常,按「文件为空」处理(与 Android 同款)
    }
    try {
      await this.recorder.release();
    } catch (e) { /* ignore */ }
    this.recorder = null;

    if (!this.file || !this.filePath) {
      await this.discard();
      throw new Error('录音太短或失败,请按住多说一会儿');
    }
    // 读文件校验非空
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
    const base64 = buffer.from(new Uint8Array(buf)).toString('base64');
    await this.discard(); // 删临时文件(音频已回传 JS)
    return {
      base64: base64,
      mime: VOICE_MIME, // 'audio/mp4'(与 Android/iOS 的 declaredMime 口径一致,服务端白名单内)
      durationMs: durationMs
    };
  }

  /* ---------------- cancel / 清理 ---------------- */
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
