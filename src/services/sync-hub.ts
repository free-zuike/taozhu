/** 实时同步广播：Durable Object 持有在线 WebSocket 连接，数据变更后向所有客户端推送类型化消息，
 *  客户端按 type 分发：sync=实体变更触发增量拉取（pull）；profile_change=资料/头像变更触发 syncMyProfile。
 *  （消息类型化对齐参考架构：sync_change / profile_change / connected 分发模型） */

/** 环境捕获：Workers 单实例所有请求共享同一绑定，首请求中间件记录后即可全局使用 */
let hubEnv: { SYNC_HUB: DurableObjectNamespace } | null = null;

export function setHubEnv(env: { SYNC_HUB: DurableObjectNamespace }): void {
  hubEnv = env;
}

/** 广播一次同步通知（变更流已写入后调用；失败静默，不影响主流程）
 *  type: sync=业务实体变更（默认）/ profile_change=用户资料（显示名/头像）变更 */
export async function notifyClients(type: 'sync' | 'profile_change' = 'sync'): Promise<void> {
  const hub = hubEnv?.SYNC_HUB;
  if (!hub) return;
  try {
    const id = hub.idFromName('global');
    await hub.get(id).fetch(new Request(`http://sync-hub/notify?type=${type}`, { method: 'POST' }));
  } catch {
    // 广播失败不影响写入主流程（客户端会在下次拉取时拿到变更）
  }
}

/** Durable Object：WebSocket 连接集合 + broadcast */
export class SyncHub {
  private sockets = new Set<WebSocket>();

  async fetch(request: Request): Promise<Response> {
    // 内部通知（notifyClients 调用）：向全部在线连接广播（type 透传：sync / profile_change）
    if (request.url.includes('/notify')) {
      const type = new URL(request.url).searchParams.get('type') || 'sync';
      this.broadcast(type);
      return new Response('ok');
    }
    // WebSocket 升级（客户端连接，token 已在路由层校验）
    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('not found', { status: 404 });
    }
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.sockets.add(server);
    server.accept();
    server.addEventListener('close', () => this.sockets.delete(server));
    server.addEventListener('error', () => this.sockets.delete(server));
    server.addEventListener('message', () => {
      // 客户端消息（心跳等）忽略；同步由服务端通知驱动
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  private broadcast(type: string): void {
    const msg = JSON.stringify({ type });
    for (const s of this.sockets) {
      try {
        s.send(msg);
      } catch {
        this.sockets.delete(s);
      }
    }
  }
}
