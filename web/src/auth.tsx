/** 认证状态(React Context + localStorage 持久化 token) */
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import { authApi } from './api';
import { ensureIdentityKeys, hasIdentity, type IdentityKeys } from './crypto/keys';

interface Session {
  token: string;
  sessionId: string;
  userId: number;
  handle?: string;
  deviceId: string;
}

interface AuthState {
  session: Session | null;
  identity: IdentityKeys | null;
  loading: boolean;
  login: (s: Session) => void;
  logout: () => Promise<void>;
  refreshIdentity: () => Promise<void>;
}

const Ctx = createContext<AuthState>({
  session: null, identity: null, loading: true,
  login: () => {}, logout: async () => {}, refreshIdentity: async () => {},
});

export function useAuth() {
  return useContext(Ctx);
}

const SESSION_KEY = 'lmh.session';

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [identity, setIdentity] = useState<IdentityKeys | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      try {
        const raw = localStorage.getItem(SESSION_KEY);
        if (raw) setSession(JSON.parse(raw) as Session);
        if (await hasIdentity()) setIdentity(await ensureIdentityKeys());
      } catch { /* ignore */ }
      setLoading(false);
    })();
  }, []);

  const login = (s: Session) => {
    setSession(s);
    localStorage.setItem(SESSION_KEY, JSON.stringify(s));
  };

  const logout = async () => {
    if (session) {
      try { await authApi.logout(session.sessionId); } catch { /* ignore */ }
    }
    setSession(null);
    localStorage.removeItem(SESSION_KEY);
  };

  const refreshIdentity = async () => {
    setIdentity(await ensureIdentityKeys());
  };

  return (
    <Ctx.Provider value={{ session, identity, loading, login, logout, refreshIdentity }}>
      {children}
    </Ctx.Provider>
  );
}
