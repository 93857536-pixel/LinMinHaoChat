import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { AuthProvider } from './auth';
import './styles.css';

/** 是否运行在 Capacitor 原生壳(Android APK)内 */
function isNativeShell(): boolean {
  const c = (globalThis as unknown as { Capacitor?: { isNativePlatform?: () => boolean } }).Capacitor;
  return !!(c && typeof c.isNativePlatform === 'function' && c.isNativePlatform());
}

async function boot(): Promise<void> {
  let Root: React.ComponentType;

  if (isNativeShell()) {
    // 移动壳:WebView 从 https://localhost 加载,相对路径 '/api' 无效 → 注入绝对基址。
    // 必须在 import 业务模块之前设置(api.ts / ws.ts 在模块求值时读取该全局)。
    (globalThis as unknown as { __LMH_API_BASE__?: string }).__LMH_API_BASE__ = 'https://chat.linminhao.top/api';
    (globalThis as unknown as { __LMH_WS_BASE__?: string }).__LMH_WS_BASE__ = 'wss://chat.linminhao.top';
    Root = (await import('./mobile/MobileApp')).default;
  } else {
    Root = (await import('./App')).default;
  }

  ReactDOM.createRoot(document.getElementById('root')!).render(
    <React.StrictMode>
      <BrowserRouter>
        <AuthProvider>
          <Root />
        </AuthProvider>
      </BrowserRouter>
    </React.StrictMode>
  );
}

void boot();
