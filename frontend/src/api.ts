/** API 封装：axios 实例 + token 注入 + 401 处理 */
import axios from 'axios';

const TOKEN_KEY = 'taozhu_token';
const USER_KEY = 'taozhu_user';

// Web（同源相对路径）走 ''；Android App（Capacitor）构建时注入 VITE_API_BASE 指向生产域名
const API_BASE = (import.meta.env.VITE_API_BASE as string | undefined ?? '').replace(/\/+$/, '');

export const api = axios.create({ baseURL: `${API_BASE}/api/v1` });

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}

export function getStoredUser(): { id: string; username: string; role: 'admin' | 'staff' } | null {
  const raw = localStorage.getItem(USER_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

export function setSession(token: string, user: { id: string; username: string; role: 'admin' | 'staff' }) {
  localStorage.setItem(TOKEN_KEY, token);
  localStorage.setItem(USER_KEY, JSON.stringify(user));
}

export function clearSession() {
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(USER_KEY);
}

api.interceptors.request.use((config) => {
  const token = getToken();
  if (token) config.headers.Authorization = `Bearer ${token}`;
  return config;
});

api.interceptors.response.use(
  (resp) => resp,
  (error) => {
    if (error.response?.status === 401) {
      clearSession();
      if (!location.pathname.startsWith('/login')) location.href = '/login';
    }
    return Promise.reject(error);
  },
);

/** 统一错误消息提取 */
export function errMsg(error: unknown, fallback = '操作失败'): string {
  if (axios.isAxiosError(error)) {
    const data = error.response?.data as { error?: string } | undefined;
    if (data?.error) return data.error;
    if (error.response?.status === 401) return '登录已过期，请重新登录';
  }
  return fallback;
}