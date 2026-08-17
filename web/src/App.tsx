import { Routes, Route, Navigate, Link, useLocation } from 'react-router-dom';
import Home from './pages/Home';
import TempChat from './pages/TempChat';
import InviteChat from './pages/InviteChat';
import Login from './pages/Login';
import Chat from './pages/Chat';
import Admin from './pages/Admin';
import About from './pages/About';
import { useAuth } from './auth';

export default function App() {
  const { session, loading } = useAuth();
  const loc = useLocation();

  if (loading) {
    return <div className="boot"><div className="spinner" /></div>;
  }

  // /t/:id 临时聊天与 /i/:id 邀请聊天路由必须最先匹配(与登录态无关)
  if (loc.pathname.startsWith('/t/')) return <TempChat />;
  if (loc.pathname.startsWith('/i/')) return <InviteChat />;

  return (
    <div className="app">
      <header className="topbar">
        <Link to="/" className="brand">LinMinHao Chat</Link>
        <nav>
          <Link to="/about">关于加密</Link>
          {session ? (
            <>
              <Link to="/chat">聊天</Link>
              <Link to="/admin">管理</Link>
            </>
          ) : (
            <Link to="/login" className="btn btn-small">登录</Link>
          )}
        </nav>
      </header>
      <main className="main">
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/login" element={<Login />} />
          <Route path="/chat" element={session ? <Chat /> : <Navigate to="/login" replace />} />
          <Route path="/admin" element={<Admin />} />
          <Route path="/about" element={<About />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
    </div>
  );
}
