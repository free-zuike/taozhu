/**
 * uni-app 版 API 封装：uni.request 统一请求 + 服务器地址可手动设置 + token + 401 处理。
 * 小程序/App/H5 三端通用（uni 跨端 API）。
 */

const TOKEN_KEY = 'taozhu_token';
const BASE_KEY = 'taozhu_api_base';

export function getToken(): string | null {
  return (uni.getStorageSync(TOKEN_KEY) as string) || null;
}
export function setToken(t: string) {
  uni.setStorageSync(TOKEN_KEY, t);
}
export function clearToken() {
  uni.removeStorageSync(TOKEN_KEY);
}

/** 服务器地址：登录页可手动填；留空则用当前（H5 同源 / 小程序需填） */
export function getApiBase(): string {
  return ((uni.getStorageSync(BASE_KEY) as string) || '').replace(/\/+$/, '');
}
export function setApiBase(url: string) {
  const u = url.trim().replace(/\/+$/, '');
  if (u) uni.setStorageSync(BASE_KEY, u);
  else uni.removeStorageSync(BASE_KEY);
}

type Method = 'GET' | 'POST' | 'PUT' | 'DELETE' | 'PATCH';

/** 通用请求：成功返回 data；失败 reject Error（message 为后端 error 字段或通用文案） */
export function request<T = any>(path: string, method: Method = 'GET', data?: unknown): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    uni.request({
      url: `${getApiBase()}/api/v1${path}`,
      method,
      data,
      header: {
        'Content-Type': 'application/json',
        ...(getToken() ? { Authorization: `Bearer ${getToken()}` } : {}),
      },
      success: (res) => {
        const status = res.statusCode;
        if (status >= 200 && status < 300) {
          resolve(res.data as T);
          return;
        }
        if (status === 401) {
          clearToken();
          uni.reLaunch({ url: '/pages/login/login' });
          reject(new Error('登录已过期，请重新登录'));
          return;
        }
        const d = res.data as { error?: string } | undefined;
        reject(new Error(d?.error || `请求失败(${status})`));
      },
      fail: (err) => {
        reject(new Error((err && (err as { errMsg?: string }).errMsg) || '网络错误，请检查服务器地址'));
      },
    });
  });
}

// 便捷方法
export const get = <T = any>(path: string) => request<T>(path, 'GET');
export const post = <T = any>(path: string, data?: unknown) => request<T>(path, 'POST', data);
export const put = <T = any>(path: string, data?: unknown) => request<T>(path, 'PUT', data);
export const patch = <T = any>(path: string, data?: unknown) => request<T>(path, 'PATCH', data);
export const del = <T = any>(path: string) => request<T>(path, 'DELETE');