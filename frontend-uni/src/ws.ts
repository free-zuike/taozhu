/**
 * 小程序实时同步（WebSocket）：连接服务器 SyncHub，收到类型化消息后通知各页面刷新。
 * 与 App 端 RealtimeSync 对齐：sync=业务变更 / theme_config=主题 / audit=审计 / devices=设备等。
 * 页面 onShow 时注册自己的刷新回调，onHide 注销——只刷新当前可见页，不全局重载。
 */
import { getToken, getApiBase } from './api';

type WsHandler = () => void;
const handlers: Record<string, Set<WsHandler>> = {};

let socket: UniApp.SocketTask | null = null;
let closed = true;
let retryTimer: ReturnType<typeof setTimeout> | null = null;
let failCount = 0;

/** 注册页面级刷新回调（onShow 调用；type 见消息类型） */
export function onWs(type: string, fn: WsHandler) {
  (handlers[type] ??= new Set()).add(fn);
}

/** 注销页面级刷新回调（onHide 调用） */
export function offWs(type: string, fn: WsHandler) {
  handlers[type]?.delete(fn);
}

/** 登录后启动 WS（全局只连一条；页面通过 onWs 订阅） */
export function startWs() {
  closed = false;
  // 立即重连（不等退避）：onShow/回前台时调用——退避在 8/20/60s 大间隔时跨端刷新
  // 要等很多秒（用户"备注修改跨端很多秒才刷新"）；已连接时重复调用无副作用（connect 幂等 close 旧连）
  if (socket) {
    try { socket.close({}); } catch (_) {}
    socket = null;
  }
  if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
  failCount = 0;
  connect();
}

/** 退出登录时断开 */
export function stopWs() {
  closed = true;
  if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
  socket?.close({});
  socket = null;
}

function connect() {
  if (closed) return;
  const token = getToken();
  const base = getApiBase();
  if (!token || !base) { scheduleRetry(); return; }
  const wsBase = base.replace('https://', 'wss://').replace('http://', 'ws://');
  try {
    socket = uni.connectSocket({
      url: `${wsBase}/api/v1/sync/ws?token=${token}`,
      complete: () => {},
    });
    socket.onOpen(() => {
      failCount = 0;
      // 连接建立（首连/断线重连）：通知页面重拉——否则断线期间服务端变更不会在重连后自动刷新，
      // 页面停留旧数据直到手动刷新（对齐 App RealtimeSync onOpen → autoSync 语义）
      fire('sync');
      fire('*');
    });
    socket.onMessage((res) => {
      try {
        const d = JSON.parse(res.data as string);
        if (typeof d === 'object' && d && typeof (d as Record<string, unknown>).type === 'string') {
          const type = (d as { type: string }).type;
          // 金额舍入配置变更广播：直接应用 payload（carry/digits，ws 也是推送，不再 GET 回读兜底）
          if (type === 'rounding') {
            const carry = Number((d as Record<string, unknown>).carry);
            const digits = Number((d as Record<string, unknown>).digits);
            if (carry > 0 && carry <= 1 && [0, 1, 2].includes(digits)) {
              void import('./utils/money').then(async (m) => { m.applyRounding(carry, digits); fire(type); fire('*'); });
            } else {
              // 旧服务器广播无 payload：回退原逻辑（拉一次服务器）
              void import('./utils/money').then(async (m) => { await m.initRounding(); fire(type); fire('*'); });
            }
            return;
          }
          // 主题配置变更广播：直接应用 payload（preset/skin/bg/mode，不再 GET 回读）
          if (type === 'theme_config') {
            void import('./theme').then((t) => {
              const p = d as Record<string, unknown>;
              t.applyThemePayload({
                preset: (p.preset_id as string) || '',
                skin: (p.skin_id as string) || '',
                bg: p.bg_enabled !== false,
                mode: (p.theme_mode as string) || '',
              });
              fire(type); fire('*');
            });
            return;
          }
          fire(type);
          fire('*'); // 兜底：未知类型也通知（业务数据变更）
        }
      } catch (_) {}
    });
    socket.onClose(() => { scheduleRetry(); });
    socket.onError(() => { scheduleRetry(); });
  } catch (_) {
    scheduleRetry();
  }
}

function fire(type: string) {
  const set = handlers[type];
  if (!set) return;
  for (const fn of [...set]) {
    try { fn(); } catch (_) {}
  }
}

function scheduleRetry() {
  if (closed) return;
  if (retryTimer) clearTimeout(retryTimer);
  failCount++;
  const delay = [1, 3, 8, 20, 60][Math.min(failCount, 5) - 1] * 1000;
  retryTimer = setTimeout(() => connect(), delay);
}