/**
 * 小程序实时同步（WebSocket）：连接服务器 SyncHub，收到类型化消息后通知各页面刷新。
 * 与 App 端 RealtimeSync 对齐：sync=业务变更 / theme_config=主题 / audit=审计 / devices=设备等。
 * 页面 onShow 时注册自己的刷新回调，onHide 注销——只刷新当前可见页，不全局重载。
 *
 * 心跳保活（v0.17.513）：Cloudflare 会断开长时间无帧流量的 WebSocket。此前两端都无心跳
 * → 页面「挂着不动」也周期性断连 → 重连 → 每次 onOpen 都 fire('sync')+fire('*') 整页重拉
 * （统计页一次 6~7 个 /stats 接口）→ 持续消耗 D1 读取额度。改为客户端每 25s 发一帧
 * keepalive；服务端 SyncHub 忽略消息、不广播。首连不再重复 fire（页面 onShow 已加载过），
 * 重连才补拉且加 10s 节流，避免网络抖动反复整页重拉。
 */
import { getToken, getApiBase } from './api';

type WsHandler = () => void;
const handlers: Record<string, Set<WsHandler>> = {};

let socket: UniApp.SocketTask | null = null;
let closed = true;
let retryTimer: ReturnType<typeof setTimeout> | null = null;
let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
let failCount = 0;
let everConnected = false;
let connected = false;
let lastReload = 0;

/** 注册页面级刷新回调（onShow 调用；type 见消息类型） */
export function onWs(type: string, fn: WsHandler) {
  (handlers[type] ??= new Set()).add(fn);
}

/** 注销页面级刷新回调（onHide 调用） */
export function offWs(type: string, fn: WsHandler) {
  handlers[type]?.delete(fn);
}

function clearHeartbeat() {
  if (heartbeatTimer) { clearInterval(heartbeatTimer); heartbeatTimer = null; }
}

/** 登录后启动 WS（全局只连一条；页面通过 onWs 订阅）
 *  已建立连接时直接返回：App.onShow 在浏览器切标签/回前台会反复调用，
 *  无条件 close 旧连重建会让每次回前台都触发一次整页重拉。 */
export function startWs() {
  closed = false;
  if (connected && socket) return;
  // 立即重连（不等退避）：onShow/回前台时调用——退避在 8/20/60s 大间隔时跨端刷新
  // 要等很多秒（用户"备注修改跨端很多秒才刷新"）
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
  clearHeartbeat();
  if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
  connected = false;
  everConnected = false;
  lastReload = 0;
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
      connected = true;
      // 心跳保活：25s 一帧，避免 Cloudflare 空闲断连（详见文件头注释）
      clearHeartbeat();
      const s = socket;
      heartbeatTimer = setInterval(() => {
        if (closed || socket !== s) return;
        try {
          s?.send({ data: 'ping' });
        } catch (_) {
          // 连接假活（onClose 未触发）：主动断开重连，避免 startWs 幂等判断卡住
          connected = false;
          clearHeartbeat();
          scheduleRetry();
        }
      }, 25000);
      // 首连不重拉：页面 onShow 已自行加载过数据；只有断线重连才需补齐离线期间的变更。
      // 10s 节流：网络抖动导致的高频重连不反复整页重拉。
      if (everConnected) {
        const now = Date.now();
        if (now - lastReload >= 10_000) {
          lastReload = now;
          fire('sync');
          fire('*');
        }
      } else {
        everConnected = true;
      }
    });
    socket.onMessage((res) => {
      try {
        const d = JSON.parse(res.data as string);
        if (typeof d === 'object' && d && typeof (d as Record<string, unknown>).type === 'string') {
          const type = (d as { type: string }).type;
          // 心跳回包：仅保活，绝不触发页面刷新
          if (type === 'ping' || type === 'pong') return;
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
    socket.onClose(() => { connected = false; clearHeartbeat(); scheduleRetry(); });
    socket.onError(() => { connected = false; clearHeartbeat(); scheduleRetry(); });
  } catch (_) {
    connected = false;
    clearHeartbeat();
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
