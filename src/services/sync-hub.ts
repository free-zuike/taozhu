/** 实时同步广播：Durable Object 持有在线 WebSocket 连接，数据变更后向所有客户端推送 {type:'sync'}，
 *  客户端收到后触发增量拉取（pull），实现"一端改动、多端实时同步"。 */

/** 环境捕获：Workers 单实例所有请求共享同一绑定，首请求中间件记录后即可全局使用 */
let hubEnv: { SYNC_HUB: DurableObjectNamespace } | null = null;

export function setHubEnv(env: { SYNC_HUB: DurableObjectNamespace }): void {
  hubEnv = env;
}

/** 广播一次同步通知（变更流已写入后调用；失败静默，不影响主流程） */
export async function notifyClients(): Promise<void> {
  const hub = hubEnv?.SYNC_HUB;
  if (!hub) return;
  try {
    const id = hub.idFromName('global');
    await hub.get(id).fetch(new Request('http://sync-hub/notify', { method: 'POST' }));
  } catch {
    // 广播失败不影响写入主流程（客户端会在下次拉取时拿到变更）
  }
}

/** Durable Object：WebSocket 连接集合 + broadcast */
export class SyncHub {
  private sockets = new Set<WebSocket>();

  async fetch(request: Request): Promise<Response> {
    // 内部通知（notifyClients 调用）：向全部在线连接广播
    if (request.url.includes('/notify')) {
      this.broadcast();
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

  private broadcast(): void {
    const msg = JSON.stringify({ type: 'sync' });
    for (const s of this.sockets) {
      try {
        s.send(msg);
      } catch {
        this.sockets.delete(s);
      }
    }
  }
}
