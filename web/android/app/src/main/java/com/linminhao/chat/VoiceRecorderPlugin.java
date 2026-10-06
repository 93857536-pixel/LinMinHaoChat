package com.linminhao.chat;

import android.Manifest;
import android.media.MediaRecorder;
import android.util.Base64;

import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;

/**
 * 语音录制原生插件。
 *
 * 为什么必须用原生实现:跨端要求语音为 **m4a(AAC in MP4)**,因为 iOS 端用 AVAudioPlayer 播放,
 * 只能解 AAC/MP4;WebView 的 MediaRecorder 在 Android 上通常只给 webm/opus,而服务端附件白名单
 * 也不接受 audio/webm 音频。故此处用 android.media.MediaRecorder 直出 MPEG_4/AAC。
 *
 * 前端调用见 web/src/mobile/native.ts(registerPlugin('VoiceRecorder'))。
 */
@CapacitorPlugin(
        name = "VoiceRecorder",
        permissions = @Permission(alias = "microphone", strings = {Manifest.permission.RECORD_AUDIO})
)
public class VoiceRecorderPlugin extends Plugin {

    private MediaRecorder recorder;
    private File outputFile;
    private long startedAt;

    private boolean micGranted() {
        return getPermissionState("microphone") == PermissionState.GRANTED;
    }

    @PluginMethod
    public void start(PluginCall call) {
        if (!micGranted()) {
            requestPermissionForAlias("microphone", call, "micPermsCallback");
            return;
        }
        startInternal(call);
    }

    @PermissionCallback
    private void micPermsCallback(PluginCall call) {
        if (!micGranted()) {
            call.reject("需要麦克风权限才能发送语音消息");
            return;
        }
        startInternal(call);
    }

    private void startInternal(PluginCall call) {
        try {
            discard();
            outputFile = new File(getContext().getCacheDir(), "voice_" + System.currentTimeMillis() + ".m4a");
            recorder = new MediaRecorder();
            recorder.setAudioSource(MediaRecorder.AudioSource.MIC);
            recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            recorder.setAudioEncodingBitRate(64000);
            recorder.setAudioSamplingRate(44100);
            recorder.setOutputFile(outputFile.getAbsolutePath());
            recorder.prepare();
            recorder.start();
            startedAt = System.currentTimeMillis();
            call.resolve();
        } catch (Exception e) {
            discard();
            call.reject("录音启动失败: " + e.getMessage());
        }
    }

    @PluginMethod
    public void stop(PluginCall call) {
        if (recorder == null) {
            call.reject("未在录音");
            return;
        }
        long durationMs = System.currentTimeMillis() - startedAt;
        try {
            recorder.stop();
        } catch (Exception ignored) {
            // 录音时间过短时 stop() 会抛异常,下面按"文件为空"处理
        }
        try {
            recorder.release();
        } catch (Exception ignored) {
        }
        recorder = null;

        if (outputFile == null || !outputFile.exists() || outputFile.length() == 0) {
            discard();
            call.reject("录音太短或失败,请按住多说一会儿");
            return;
        }
        try {
            byte[] bytes = new byte[(int) outputFile.length()];
            FileInputStream in = new FileInputStream(outputFile);
            int off = 0;
            int r;
            while (off < bytes.length && (r = in.read(bytes, off, bytes.length - off)) > 0) {
                off += r;
            }
            in.close();
            JSObject ret = new JSObject();
            ret.put("base64", Base64.encodeToString(bytes, Base64.NO_WRAP));
            ret.put("mime", "audio/mp4");
            ret.put("durationMs", durationMs);
            outputFile.delete();
            outputFile = null;
            call.resolve(ret);
        } catch (IOException e) {
            discard();
            call.reject("读取录音失败: " + e.getMessage());
        }
    }

    @PluginMethod
    public void cancel(PluginCall call) {
        discard();
        call.resolve();
    }

    @PluginMethod
    public void isAvailable(PluginCall call) {
        JSObject ret = new JSObject();
        ret.put("available", true);
        call.resolve(ret);
    }

    private void discard() {
        if (recorder != null) {
            try {
                recorder.stop();
            } catch (Exception ignored) {
            }
            try {
                recorder.release();
            } catch (Exception ignored) {
            }
            recorder = null;
        }
        if (outputFile != null && outputFile.exists()) {
            //noinspection ResultOfMethodCallIgnored
            outputFile.delete();
        }
        outputFile = null;
    }
}
