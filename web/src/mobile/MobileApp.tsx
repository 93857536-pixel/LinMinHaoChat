import { useCallback, useEffect, useState } from 'react';
import { useLocation } from 'react-router-dom';
import { useAuth } from '../auth';
import Login from '../pages/Login';
import ChatsScreen from '../features/chat/ChatsScreen';
import ContactsScreen from '../features/contacts/ContactsScreen';
import MeScreen from '../features/me/MeScreen';
import DiscoverScreen from '../features/shell/DiscoverScreen';
import PrivacyGate from './PrivacyGate';
import { registerTabSetter, registerPathSetter } from '../features/shell/tabNav';
import { parseDeepLink, isDeepLinkPath } from './deeplink';
import InviteChat from '../pages/InviteChat';
import TempChat from '../pages/TempChat';
import './mobile.css';

export type TabKey = 'chats' | 'contacts' | 'discover' | 'me';

const TABS: { key: TabKey; label: string; icon: string }[] = [
  { key: 'chats', label: '聊天', icon: '💬' },
  { key: 'contacts', label: '通讯录', icon: '👥' },
  { key: 'discover', label: '发现', icon: '🧭' },
  { key: 'me', label: '我的', icon: '👤' },
];

/**
 * Android 移动端根组件(Capacitor WebView 内)。
 * - 未登录:复用现有登录页
 * - 已登录:四 Tab 壳(聊天/通讯录/发现/我的),与 iOS 版结构一致
 * - 隐私模式:切后台自动模糊(与 iOS PrivacyMode 对应)
 */
export default function MobileApp() {
  const { session } = useAuth();
  const [tab, setTab] = useState<TabKey>('chats');
  const loc = useLocation();

  useEffect(() => {
    document.documentElement.classList.add('mv-native');
    return () => document.documentElement.classList.remove('mv-native');
  }, []);

  // 让功能屏(通讯录等)能请求切换 Tab
  useEffect(() => {
    registerTabSetter(setTab);
    return () => registerTabSetter(null);
  }, []);

  // 内部路径导航(发现页发起/加入临时·邀请聊天):pushState + 派发 popstate,
  // 让 BrowserRouter 同步路由位置,页面内「返回首页」(nav('/'))才生效。
  const openPath = useCallback((p: string) => {
    window.history.pushState({}, '', p);
    window.dispatchEvent(new PopStateEvent('popstate'));
  }, []);
  /** 返回键:replace(不堆积 history)+ 同步路由 */
  const closePath = useCallback(() => {
    window.history.replaceState({}, '', '/');
    window.dispatchEvent(new PopStateEvent('popstate'));
  }, []);
  useEffect(() => {
    registerPathSetter(openPath);
    return () => registerPathSetter(null);
  }, [openPath]);

  // 深链(Capacitor 冷启动/热启动的 lmhchat:// 与官方网页链接):解析后推入路由
  useEffect(() => {
    let sub: { remove: () => void } | undefined;
    let cancelled = false;
    (async () => {
      try {
        const { App: CapApp } = await import('@capacitor/app');
        const handle = (raw?: string | null) => {
          if (!raw || cancelled) return;
          const p = parseDeepLink(raw);
          if (p) openPath(p);
        };
        const launch = await CapApp.getLaunchUrl();
        handle(launch?.url ?? null);
        sub = await CapApp.addListener('appUrlOpen', (e) => handle(e.url));
      } catch {
        // 非原生环境(浏览器直开):深链由 location 自然处理,无需接管
      }
    })();
    return () => {
      cancelled = true;
      sub?.remove();
    };
  }, [openPath]);

  // 深链页面优先于登录态判定:邀请聊天/临时聊天本身支持未登录进入。
  // 以路由 location 为唯一真源(TempChat/InviteChat 的「退出」走 nav('/'),自动同步)。
  const deep = isDeepLinkPath(loc.pathname + loc.search + loc.hash);
  if (deep) {
    return (
      <PrivacyGate>
        <div className="mv-shell">
          <div className="mv-deeplink-bar">
            <button className="mv-back" onClick={closePath}>← 返回</button>
          </div>
          <div className="mv-body">
            {loc.pathname.startsWith('/i/') ? <InviteChat /> : <TempChat />}
          </div>
        </div>
      </PrivacyGate>
    );
  }

  if (!session) return <Login />;

  return (
    <PrivacyGate>
      <div className="mv-shell">
        <div className="mv-body">
          {tab === 'chats' && <ChatsScreen />}
          {tab === 'contacts' && <ContactsScreen />}
          {tab === 'discover' && <DiscoverScreen />}
          {tab === 'me' && <MeScreen />}
        </div>
        <nav className="mv-tabbar">
          {TABS.map((t) => (
            <button
              key={t.key}
              className={`mv-tab${tab === t.key ? ' mv-tab-active' : ''}`}
              onClick={() => setTab(t.key)}
              aria-label={t.label}
            >
              <span className="mv-tab-icon">{t.icon}</span>
              <span className="mv-tab-label">{t.label}</span>
            </button>
          ))}
        </nav>
      </div>
    </PrivacyGate>
  );
}
