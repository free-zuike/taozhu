/** 备份打包 Durable Object：云端备份/恢复的"重活"在这里执行（每次请求 30s CPU 预算，绕开
 *  Worker 10ms CPU 限制——对齐 beecount backup-pack DO）。
 *  操作：
 *   - POST /backup         生成 ZIP 归档包（meta.json + db.json + attachments/ 附件原始文件）写存储端
 *   - POST /restore?key=   从存储端读归档包 → db.json 合并导入 D1 + attachments/* 写回存储端
 *  Worker 路由（POST /backup/now、定时、恢复）只做鉴权与转发，不直接打包。 */
import { BACKUP_PREFIX, bjStamp, buildBackupArchive, importBackupData, restoreBackupArchive } from './backup-core';
import { createStorage } from './storage';
import type { Env } from '../types';

export class BackupPack {
  private env: Env;

  /** DO 的环境绑定经构造函数注入（this.env 不会自动赋值——缺失则 createStorage(undefined) 崩） */
  constructor(_ctx: DurableObjectState, env: Env) {
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const env = this.env;
    const url = new URL(request.url);
    const store = createStorage(env);
    try {
      if (url.pathname === '/backup') {
        return await this.runBackup(env.DB, store);
      }
      if (url.pathname === '/restore') {
        const key = url.searchParams.get('key') ?? '';
        if (!key || key.includes('/') || key.startsWith('.') || key.startsWith('..')) {
          return Response.json({ ok: false, error: '非法备份标识' }, { status: 400 });
        }
        const obj = await store.get(`${BACKUP_PREFIX}${key}`);
        if (!obj) return Response.json({ ok: false, error: '备份不存在或已被清理' }, { status: 404 });
        const bytes = new Uint8Array(await new Response(obj.body).arrayBuffer());
        // 新版 ZIP 归档包 → 解包恢复（db.json + attachments/*）；旧版 JSON 备份 → 直接合并导入
        if (key.endsWith('.zip')) {
          const r = await restoreBackupArchive(env.DB, store, bytes);
          return Response.json({ ...r });
        }
        let data: Record<string, Record<string, unknown>[]> | null = null;
        try {
          const parsed = JSON.parse(new TextDecoder().decode(bytes)) as { data?: Record<string, Record<string, unknown>[]> };
          data = parsed.data ?? null;
        } catch {
          data = null;
        }
        if (!data || typeof data !== 'object' || Array.isArray(data)) {
          return Response.json({ ok: false, error: '备份文件内容损坏' }, { status: 400 });
        }
        const { report, total_inserted } = await importBackupData(env.DB, data, env);
        return Response.json({ ok: true, report, total_inserted, key });
      }
      return Response.json({ ok: false, error: '未知操作' }, { status: 404 });
    } catch (e) {
      return Response.json({ ok: false, error: `备份执行失败：${(e as Error).message}` }, { status: 500 });
    }
  }

  /// 执行一次云备份：先建 backup_runs 记录（running），打包过程逐步写日志，完成/失败收尾。
  /// 日志实时落库——App 备份页可查"进行中/成功/失败"状态与日志（对齐参考项目备份运行状态机制）。
  private async runBackup(db: D1Database, store: ReturnType<typeof createStorage>): Promise<Response> {
    const runId = bjStamp(new Date());
    const started = new Date().toISOString();
    try {
      await db.prepare(
        "INSERT INTO backup_runs (id, status, started_at, message, log_text) VALUES (?, 'running', ?, ?, '')",
      ).bind(runId, started, '开始备份…').run();
    } catch (e) {
      return Response.json({ ok: false, status: 'failed', message: `备份状态记录失败：${(e as Error).message}` }, { status: 500 });
    }
    const logLines: string[] = [];
    const onLog = (line: string) => {
      logLines.push(`[${new Date().toISOString()}] ${line}`);
      // 实时落库（best-effort；截断 64KB 防超大日志）
      try {
        db.prepare('UPDATE backup_runs SET log_text = ? WHERE id = ?')
          .bind(logLines.join('\n').slice(0, 65536), runId).run();
      } catch (_) {}
    };
    try {
      const r = await buildBackupArchive(db, store, { runId, onLog });
      return Response.json({ ok: true, runId, ...r });
    } catch (e) {
      const message = `备份执行异常：${(e as Error).message}`;
      try {
        await db.prepare(
          "UPDATE backup_runs SET status = 'failed', message = ?, finished_at = ? WHERE id = ?",
        ).bind(message, new Date().toISOString(), runId).run();
      } catch (_) {}
      return Response.json({ ok: false, status: 'failed', runId, message }, { status: 500 });
    }
  }
}
