/** 实时同步广播：Durable Object 持有在线 WebSocket 连接，数据变更后向所有客户端推送类型化消息，
 *  客户端按 type 分发：sync=实体变更触发增量拉取（pull）；profile_change=资料/头像变更触发 syncMyProfile；
 *  ai_config=AI 配置（服务商/能力绑定）变更触发 AI 设置页重新拉取。
 *  （消息类型化对齐参考架构：sync_change / profile_change / connected 分发模型） */

/** 环境捕获：Workers 单实例所有请求共享同一绑定，首请求中间件记录后即可全局使用 */
let hubEnv: { SYNC_HUB: DurableObjectNamespace } | null = null;

export function setHubEnv(env: { SYNC_HUB: DurableObjectNamespace }): void {
  hubEnv = env;
}

/** 广播一次同步通知（变更流已写入后调用；失败静默，不影响主流程）
 *  type: sync=业务实体变更（默认）/ profile_change=用户资料（显示名/头像）变更 / ai_config=AI 配置变更
 *        theme_config=主题配置变更 / audit=操作审计变更（删除单条）/ devices=设备列表变更（删除设备）
 *        stmt_templates=对账单模板列表变更（App 设计器保存后其他端重新拉取）
 *  data: 可选负载（rounding=carry/digits、theme_config=preset 等）——客户端收到后**直接应用，不再 GET 回读**（ws 也是推送） */
export async function notifyClients(
  type: 'sync' | 'profile_change' | 'ai_config' | 'theme_config' | 'rounding' | 'audit' | 'devices' | 'stmt_templates' = 'sync',
  data?: Record<string, unknown>,
): Promise<void> {
  const hub = hubEnv?.SYNC_HUB;
  if (!hub) return;
  try {
    const id = hub.idFromName('global');
    const body = JSON.stringify(data ?? {});
    await hub.get(id).fetch(new Request(`http://sync-hub/notify?type=${type}`, { method: 'POST', body }));
  } catch {
    // 广播失败不影响写入主流程（客户端会在下次拉取时拿到变更）
  }
}

/** Durable Object：WebSocket 连接集合 + broadcast + 服务端主动保活 */
export class SyncHub {
  private sockets = new Set<WebSocket>();
  private heartbeat: ReturnType<typeof setInterval> | null = null;

  /**
   * 每 25s 给所有在线连接发一帧纯文本 'pong'，制造下行流量，避免 Cloudflare 断开空闲 WS。
   * 客户端（含部署前旧版）对非 JSON 文本一律 jsonDecode/JSON.parse 失败后静默忽略，
   * 不广播、不写变更流、不触发页面整页重拉——所以这一帧纯粹是保活，不会变成刷新风暴。
   *
   * 为什么仍要服务端主动发：已打开且未重新导航的页面里跑的是旧前端 JS，没有 25s 客户端心跳；
   * 靠被动回 ping 救不了它。而它一旦空闲断连就会触发重连 → 整页重拉一批 /stats 接口，
   * 这正是「页面挂着不动却持续产生请求」的链条。服务端保活是在不改客户端的前提下掐断它。
   *
   * 定时器只在有在线连接时存在：最后一个连接断开立即停表，DO 回归可休眠状态，
   * 避免无人在线时仍按 duration 空转计费。
   */
  private ensureHeartbeat(): void {
    if (this.heartbeat) return;
    this.heartbeat = setInterval(() => {
      if (this.sockets.size === 0) {
        if (this.heartbeat) clearInterval(this.heartbeat);
        this.heartbeat = null;
        return;
      }
      for (const s of this.sockets) {
        try { s.send('pong'); } catch { this.sockets.delete(s); }
      }
    }, 25_000);
  }

  async fetch(request: Request): Promise<Response> {
    // 内部通知（notifyClients 调用）：向全部在线连接广播（type 透传：sync / profile_change；body 为负载 JSON）
    if (request.url.includes('/notify')) {
      const type = new URL(request.url).searchParams.get('type') || 'sync';
      const data = await request.text().catch(() => '');
      this.broadcast(type, data);
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
    this.ensureHeartbeat();
    server.addEventListener('close', () => this.sockets.delete(server));
    server.addEventListener('error', () => this.sockets.delete(server));
    server.addEventListener('message', (event) => {
      // 新版客户端每 25s 发纯文本 'ping'，回一帧 'pong' 形成双向流量即可。
      // 旧版客户端不发 ping，靠 ensureHeartbeat 的下行帧保活；两条路径互补，
      // 都不广播、不写变更流，客户端也都不会因心跳触发页面刷新。
      if (event.data === 'ping') {
        try { server.send('pong'); } catch { this.sockets.delete(server); }
      }
      // 其它客户端消息忽略；同步始终由服务端通知驱动
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  private broadcast(type: string, dataJson = ''): void {
    // 带负载：{type, ...data} 展开进消息（rounding 带 carry/digits、theme_config 带 preset 等）；
    // 无负载：保持 {type} 不变（业务实体同步等仍走 pull）
    let msg: string;
    try {
      const data = dataJson ? JSON.parse(dataJson) : {};
      msg = JSON.stringify({ type, ...data });
    } catch {
      msg = JSON.stringify({ type });
    }
    for (const s of this.sockets) {
      try {
        s.send(msg);
      } catch {
        this.sockets.delete(s);
      }
    }
  }
}
