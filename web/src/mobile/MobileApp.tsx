import { useEffect, useState } from 'react';
import { useAuth } from '../auth';
import Login from '../pages/Login';
import ChatsScreen from '../features/chat/ChatsScreen';
import ContactsScreen from '../features/contacts/ContactsScreen';
import MeScreen from '../features/me/MeScreen';
import DiscoverScreen from '../features/shell/DiscoverScreen';
import PrivacyGate from './PrivacyGate';
import { registerTabSetter } from '../features/shell/tabNav';
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

  useEffect(() => {
    document.documentElement.classList.add('mv-native');
    return () => document.documentElement.classList.remove('mv-native');
  }, []);

  // 让功能屏(通讯录等)能请求切换 Tab
  useEffect(() => {
    registerTabSetter(setTab);
    return () => registerTabSetter(null);
  }, []);

  // 深链:lmhchat://invite/<id> / https://chat.linminhao.top/i/<id>(邀请与临时聊天无需登录)
  const [deepPath, setDeepPath] = useState<string | null>(null);
  useEffect(() => {
    let sub: { remove: () => void } | undefined;
    let cancelled = false;
    (async () => {
      try {
        const { App: CapApp } = await import('@capacitor/app');
        const handle = (raw?: string | null) => {
          if (!raw || cancelled) return;
          const p = parseDeepLink(raw);
          if (p) {
            window.history.pushState({}, '', p);
            setDeepPath(p);
          }
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
  }, []);

  const closeDeep = () => {
    window.history.replaceState({}, '', '/');
    setDeepPath(null);
  };

  // 深链页面优先于登录态判定:邀请聊天/临时聊天本身支持未登录进入
  if (isDeepLinkPath(deepPath)) {
    return (
      <PrivacyGate>
        <div className="mv-shell">
          <div className="mv-deeplink-bar">
            <button className="mv-back" onClick={closeDeep}>← 返回</button>
          </div>
          <div className="mv-body">
            {deepPath!.startsWith('/i/') ? <InviteChat /> : <TempChat />}
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
