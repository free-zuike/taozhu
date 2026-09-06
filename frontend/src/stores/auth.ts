/** 认证状态 */
import { defineStore } from 'pinia';
import { api, clearSession, getStoredUser, getToken, setSession } from '../api';

export interface UserInfo {
  id: string;
  username: string;
  role: 'admin' | 'staff';
}

export const useAuthStore = defineStore('auth', {
  state: () => ({
    token: getToken() as string | null,
    user: getStoredUser() as UserInfo | null,
  }),
  getters: {
    isAdmin: (s) => s.user?.role === 'admin',
    loggedIn: (s) => Boolean(s.token),
  },
  actions: {
    async bootstrap(username: string, password: string) {
      const { data } = await api.post('/auth/bootstrap', { username, password });
      setSession(data.token, data.user);
      this.token = data.token;
      this.user = data.user;
    },
    async login(username: string, password: string) {
      const { data } = await api.post('/auth/login', { username, password });
      setSession(data.token, data.user);
      this.token = data.token;
      this.user = data.user;
    },
    async initStatus(): Promise<boolean> {
      const { data } = await api.get('/auth/bootstrap/status');
      return data.initialized;
    },
    logout() {
      clearSession();
      this.token = null;
      this.user = null;
      location.href = '/login';
    },
  },
});