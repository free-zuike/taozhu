/**
 * uni-app 版 API 封装：uni.request 统一请求 + 服务器地址可手动设置 + token + 401 处理。
 * 小程序/App/H5 三端通用（uni 跨端 API）。
 */
import { APP_VERSION } from './version';

const TOKEN_KEY = 'taozhu_token';
const BASE_KEY = 'taozhu_api_base';
const ROLE_KEY = 'taozhu_role';
const REFRESH_KEY = 'taozhu_refresh_token';

export function getToken(): string | null {
  return (uni.getStorageSync(TOKEN_KEY) as string) || null;
}
export function setToken(t: string) {
  uni.setStorageSync(TOKEN_KEY, t);
}
export function clearToken() {
  uni.removeStorageSync(TOKEN_KEY);
  uni.removeStorageSync(ROLE_KEY);
  uni.removeStorageSync(REFRESH_KEY);
}

/** 双 token：refresh_token（access 过期后静默刷新用；旧版单 token 会话无此值） */
export function getRefreshToken(): string {
  return (uni.getStorageSync(REFRESH_KEY) as string) || '';
}
export function setRefreshToken(rt: string) {
  uni.setStorageSync(REFRESH_KEY, rt);
}

/** 双 token 静默刷新（单例防并发）：同一时刻多个请求 401 只刷一次，其余 await 同一 Promise。
 *  成功返回 true 并写新 token/refresh_token；无 refresh_token 或刷新失败返回 false。 */
let refreshing: Promise<boolean> | null = null;
export function tryRefreshToken(): Promise<boolean> {
  if (refreshing) return refreshing;
  const p = (async () => {
    const rt = getRefreshToken();
    if (!rt) return false;
    try {
      const r = await new Promise<{ statusCode: number; data?: unknown }>((res2, rej2) => {
        uni.request({
          url: `${getApiBase()}/api/v1/auth/refresh`,
          method: 'POST',
          data: { refresh_token: rt },
          header: { 'Content-Type': 'application/json' },
          success: (res) => res2({ statusCode: res.statusCode, data: res.data }),
          fail: (err) => rej2(err),
        });
      });
      if (r.statusCode !== 200) return false;
      const d = r.data as { token?: string; refresh_token?: string } | undefined;
      if (!d?.token) return false;
      setToken(d.token);
      if (d.refresh_token) setRefreshToken(d.refresh_token);
      return true;
    } catch (_) {
      return false;
    }
  })();
  refreshing = p;
  p.finally(() => {
    refreshing = null;
  }).catch(() => {});
  return p;
}

/** 当前账号角色（admin=老板 / staff=店员）：登录时存，用于页面按角色隐藏入口（对齐 App：员工看不到老板专属页面） */
export function getRole(): string {
  return (uni.getStorageSync(ROLE_KEY) as string) || '';
}
export function setRole(r: string) {
  uni.setStorageSync(ROLE_KEY, r);
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
/** uni.request 接受的 method（PATCH 运行时可用但类型未列——调用处已有 as 转换） */
type UniMethod = 'GET' | 'POST' | 'PUT' | 'DELETE' | 'PATCH' | 'OPTIONS' | 'HEAD' | 'TRACE' | 'CONNECT';

/** 设备标识：首次生成随机 id（每台设备独立自报；服务器设备列表按此归并） */
const DEVICE_KEY = 'taozhu_device_id';
export function getDeviceId(): string {
  let id = (uni.getStorageSync(DEVICE_KEY) as string) || '';
  if (!id) {
    id = `dev-${Date.now().toString(16)}-${Math.random().toString(16).slice(2, 10)}`;
    uni.setStorageSync(DEVICE_KEY, id);
  }
  return id;
}

/** 通用请求：成功返回 data；失败 reject Error（message 为后端 error 字段或通用文案）。
 *  access 过期（401）→ 静默刷新换新 token 重放一次（单例防并发；刷新失败才跳登录页） */
export function request<T = any>(path: string, method: UniMethod = 'GET', data?: Record<string, unknown> | string | ArrayBuffer): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const fail401 = () => {
      clearToken();
      uni.reLaunch({ url: '/pages/login/login' });
      reject(new Error('登录已过期，请重新登录'));
    };
    const send = (auth: string | null, replayed = false): void => {
      uni.request({
        url: `${getApiBase()}/api/v1${path}`,
        method: method as never, // PATCH 运行时支持但 uni 类型未列，绕过类型检查
        data,
        header: {
          'Content-Type': 'application/json',
          'x-app-version': APP_VERSION,
          'x-device-id': getDeviceId(),
          ...(auth ? { Authorization: `Bearer ${auth}` } : {}),
        },
        success: (res) => {
          const status = res.statusCode;
          if (status >= 200 && status < 300) {
            resolve(res.data as T);
            return;
          }
          if (status === 401) {
            // 仅重放一次（防循环）：刷新成功带新 token 重发；失败才判定登录过期
            if (!replayed) {
              tryRefreshToken()
                .then((ok) => {
                  if (ok) send(getToken(), true);
                  else fail401();
                })
                .catch(() => fail401());
            } else {
              fail401();
            }
            return;
          }
          const d = res.data as { error?: string } | undefined;
          reject(new Error(d?.error || `请求失败(${status})`));
        },
        fail: (err) => {
          reject(new Error((err && (err as { errMsg?: string }).errMsg) || '网络错误，请检查服务器地址'));
        },
      });
    };
    send(getToken(), false);
  });
}

// 便捷方法
export const get = <T = any>(path: string) => request<T>(path, 'GET');
export const post = <T = any>(path: string, data?: Record<string, unknown> | string | ArrayBuffer) => request<T>(path, 'POST', data);
export const put = <T = any>(path: string, data?: Record<string, unknown> | string | ArrayBuffer) => request<T>(path, 'PUT', data);
export const patch = <T = any>(path: string, data?: Record<string, unknown> | string | ArrayBuffer) => request<T>(path, 'PATCH', data);
export const del = <T = any>(path: string) => request<T>(path, 'DELETE');

/** 附件列表：GET /attachments?entity=&id= → { attachments: [{key,url,size}] } */
export function getAttachments(entity: string, id: string): Promise<{ attachments: Array<{ key: string; url: string; size: number }> }> {
  return request(`/attachments?entity=${entity}&id=${encodeURIComponent(id)}`, 'GET');
}

/** 附件代理读取 URL（需带 token；小程序 image 组件需拼接 token 参数） */
export function attachmentUrl(key: string): string {
  return `${getApiBase()}/api/v1/attachments/${key}?token=${encodeURIComponent(getToken() || '')}`;
}

/** 上传附件：uni.uploadFile 走 multipart，成功返回 {key,url} */
export function uploadAttachment(entity: string, id: string, filePath: string): Promise<{ key: string; url: string }> {
  return new Promise((resolve, reject) => {
    uni.uploadFile({
      url: `${getApiBase()}/api/v1/attachments?entity=${entity}&id=${encodeURIComponent(id)}`,
      filePath,
      name: 'photo',
      header: getToken() ? { Authorization: `Bearer ${getToken()}` } : {},
      success: (res) => {
        try {
          const d = JSON.parse(res.data) as { key?: string; url?: string; error?: string };
          if (res.statusCode >= 200 && res.statusCode < 300 && d.key) {
            resolve(d as { key: string; url: string });
          } else {
            reject(new Error(d?.error || `上传失败(${res.statusCode})`));
          }
        } catch (e) {
          reject(new Error('上传响应解析失败'));
        }
      },
      fail: (err) => reject(new Error((err && (err as { errMsg?: string }).errMsg) || '上传失败')),
    });
  });
}

/** 删除附件：DELETE /attachments?key= */
export function deleteAttachment(key: string): Promise<unknown> {
  return request(`/attachments?key=${encodeURIComponent(key)}`, 'DELETE');
}

/** AI 识别上传（uni.uploadFile multipart）：field=photo|audio，返回后端解析结果 {ok,items,...} */
export function uploadAi<T = any>(path: string, field: string, filePath: string): Promise<T> {
  return new Promise((resolve, reject) => {
    uni.uploadFile({
      url: `${getApiBase()}/api/v1${path}`,
      filePath,
      name: field,
      header: getToken() ? { Authorization: `Bearer ${getToken()}` } : {},
      success: (res) => {
        try {
          const d = JSON.parse(res.data) as { error?: string } | undefined;
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve(res.data as T);
          } else {
            reject(new Error(d?.error || `识别失败(${res.statusCode})`));
          }
        } catch (e) {
          reject(new Error('识别响应解析失败'));
        }
      },
      fail: (err) => reject(new Error((err && (err as { errMsg?: string }).errMsg) || '上传失败')),
    });
  });
}