/** API 封装：axios 实例 + 服务器地址可手动设置（App/自托管各端） + token 注入 + 401 处理 */
import axios from 'axios';

const TOKEN_KEY = 'taozhu_token';
const USER_KEY = 'taozhu_user';
const API_BASE_KEY = 'taozhu_api_base';

// 服务器地址：登录页可手动填（存 localStorage，App/小程序/换域名均可改）；未填时 Web 走同源相对路径，App 用构建变量
function getStoredApiBase(): string {
  return (localStorage.getItem(API_BASE_KEY) ?? (import.meta.env.VITE_API_BASE as string | undefined ?? '')).replace(/\/+$/, '');
}
let apiBase = getStoredApiBase();

export function getApiBase(): string {
  return apiBase;
}

/** 手动设置服务器地址（登录页填写时调用；留空=同源相对路径） */
export function setApiBase(url: string) {
  apiBase = url.trim().replace(/\/+$/, '');
  if (apiBase) localStorage.setItem(API_BASE_KEY, apiBase);
  else localStorage.removeItem(API_BASE_KEY);
}

export const api = axios.create({ baseURL: '' });

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
  // 动态 base（在拦截器里设置，登录前改地址即可生效）
  config.baseURL = `${getApiBase()}/api/v1`;
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