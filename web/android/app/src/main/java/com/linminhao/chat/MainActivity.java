package com.linminhao.chat;

import android.os.Bundle;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        // 注册自定义插件必须在 super.onCreate 之前
        registerPlugin(VoiceRecorderPlugin.class);
        registerPlugin(PnsAuthPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
