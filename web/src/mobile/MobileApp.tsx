import { useEffect, useState } from 'react';
import { useAuth } from '../auth';
import Login from '../pages/Login';
import ChatsScreen from '../features/chat/ChatsScreen';
import ContactsScreen from '../features/contacts/ContactsScreen';
import MeScreen from '../features/me/MeScreen';
import DiscoverScreen from '../features/shell/DiscoverScreen';
import PrivacyGate from './PrivacyGate';
import { registerTabSetter } from '../features/shell/tabNav';
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
