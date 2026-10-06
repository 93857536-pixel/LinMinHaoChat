import Chat from '../../pages/Chat';
import StarredScreen from './StarredScreen';
import { useState } from 'react';
import { useAuth } from '../../auth';

/**
 * 聊天 Tab:会话列表 + 聊天窗复用现有 Web 端实现(Chat.tsx 已含 E2EE/附件/已读全链路)。
 * 顶部提供「收藏」入口(对应 iOS StarredListView)。
 */
export default function ChatsScreen() {
  const { session } = useAuth();
  const [showStarred, setShowStarred] = useState(false);

  if (!session) return null;

  if (showStarred) return <StarredScreen onBack={() => setShowStarred(false)} />;

  return (
    <div className="mv-chats">
      <div className="mv-chats-bar">
        <span className="mv-chats-title">聊天</span>
        <button className="mv-link-btn" onClick={() => setShowStarred(true)}>
          ⭐ 收藏
        </button>
      </div>
      <div className="mv-chats-body">
        <Chat />
      </div>
    </div>
  );
}
