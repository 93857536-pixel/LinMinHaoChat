import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'com.linminhao.chat',
  appName: 'LinMinHao Chat',
  webDir: 'dist',
  // ⚠️ 必须 https:WebCrypto(crypto.subtle)仅在安全上下文可用,而 E2EE 完全依赖它。
  // 用 http 会让 Android 端连密钥都生成不了。
  server: { androidScheme: 'https' },
  android: { allowMixedContent: false },
};

export default config;
