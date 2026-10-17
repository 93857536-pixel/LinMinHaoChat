/**
 * 全局常量 — LinMinHaoChat HarmonyOS 壳。
 *
 * ⚠️ 主会话维护:域名 / scheme / rawfile 路径是跨文件契约,业务文件照此引用,勿各自硬编码。
 */

/** 生产站点(ArkWeb 直接加载它 → 同源 /api /ws + https 安全上下文,零 CORS、E2EE 可用) */
export const SITE_ORIGIN: string = 'https://chat.linminhao.top';
export const SITE_HOME: string = 'https://chat.linminhao.top/';
/** 允许 ArkWeb 访问的域名白名单(setWebViewRestriction,防跳转劫持) */
export const ALLOWED_DOMAINS: string[] = ['chat.linminhao.top', 'linminhao.top', '*.linminhao.top'];
/** 自定义深链 scheme(与 iOS/Android 同款) */
export const DEEPLINK_SCHEME: string = 'lmhchat';

/** rawfile 里的桥 JS 路径(javaScriptOnDocumentStart 注入) */
export const BRIDGE_RAWFILE: string = 'bridge/lmh-bridge.js';

/** API/WS 绝对基址(兜底,前端 main.tsx 会再设一次;同源站点下与 location.host 一致) */
export const API_BASE: string = 'https://chat.linminhao.top/api';
export const WS_BASE: string = 'wss://chat.linminhao.top';

/** AppStorage key:冷启动深链 uri(供 App.getLaunchUrl 读) */
export const K_LAUNCH_URL: string = 'lmh.launchUrl';
/** AppStorage key:热启动待转发的深链 uri(Index 订阅 → emitEvent appUrlOpen) */
export const K_PENDING_DEEPLINK: string = 'lmh.pendingDeeplink';
/** 版本号(与 Android/iOS 对齐口径,展示在「发现/关于」) */
export const APP_VERSION: string = '1.9.16';

/** 语音:与 Android/iOS 端一致的固定文件名与 MIME(服务端附件白名单内) */
export const VOICE_FILE_NAME: string = 'voice.m4a';
export const VOICE_MIME: string = 'audio/mp4';
