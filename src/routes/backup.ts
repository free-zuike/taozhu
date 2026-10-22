/** 全库备份路由（仅老板）：手动导出/导入 JSON、立即云备份（ZIP 归档包）、历史列表、恢复。
 *  云备份/恢复的"重活"在 BackupPack Durable Object（30s CPU 预算）执行——附件以原始文件
 *  流式打入 ZIP 归档包（对齐 beecount），无 base64 内嵌 JSON 的大小上限/503 问题；
 *  GET /backup 手动导出 JSON（轻量存档/对账）仍保留，附件 ≤ 上限时内嵌 base64。 */
import { Hono } from 'hono';
import { adminOnly, authMiddleware } from '../middleware/auth';
import { recordAudit } from './audit';
import { createStorage } from '../services/storage';
import {
  BACKUP_PREFIX, exportAllData, formatBackupName, importBackupData,
} from '../services/backup-core';
import type { AuthUser, Env } from '../types';

type V = { user: AuthUser };
export const backupRouter = new Hono<{ Bindings: Env; Variables: V }>();
backupRouter.use('*', authMiddleware(), adminOnly());

// 自动备份时间（settings 表 key）：用户可配置，格式 HH:MM（北京时间）；空=未设置
const KEY_BACKUP_TIME = 'backup_time';
export const DEFAULT_BACKUP_TIME = '03:05';

export async function getBackupTime(db: D1Database): Promise<string> {
  const row = await db.prepare('SELECT value FROM settings WHERE key = ?').bind(KEY_BACKUP_TIME).first<{ value: string }>();
  const v = (row?.value ?? '').trim();
  return /^\d{2}:\d{2}$/.test(v) ? v : DEFAULT_BACKUP_TIME;
}

/// 是否命中备份时刻：当前北京时间 HH:MM == 配置时间（精确到分钟，一天恰好命中一次）
export function isBackupTime(nowUtc: Date, configured: string): boolean {
  const bj = new Date(nowUtc.getTime() + 8 * 3600 * 1000);
  const hh = String(bj.getUTCHours()).padStart(2, '0');
  const mm = String(bj.getUTCMinutes()).padStart(2, '0');
  return `${hh}:${mm}` === configured;
}

/// 在备份打包 DO 内执行（30s CPU 预算打包 zip/解包恢复；Worker 只做鉴权转发）
async function runBackupPack(env: Env, path: string): Promise<Record<string, unknown>> {
  if (!env.BACKUP_PACK) throw new Error('备份服务未启用（BACKUP_PACK 未绑定）');
  const stub = env.BACKUP_PACK.get(env.BACKUP_PACK.idFromName('global'));
  const res = await stub.fetch(`http://backup-pack${path}`, { method: 'POST' });
  return res.json() as Promise<Record<string, unknown>>;
}

/// 定时自动备份入口（scheduledBackup 用）：调 BackupPack DO 生成 ZIP 归档包
export async function performBackup(env: Env): Promise<Record<string, unknown>> {
  return runBackupPack(env, '/backup');
}

// GET /backup/auto — 自动备份设置（当前生效值：时间 + 保留份数）
backupRouter.get('/auto', async (c) => {
  const timeRow = await c.env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind(KEY_BACKUP_TIME).first<{ value: string }>();
  const keepRow = await c.env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind('backup_keep').first<{ value: string }>();
  return c.json({
    time: (timeRow?.value ?? '').trim() || DEFAULT_BACKUP_TIME,
    configured: (timeRow?.value ?? '').trim() !== '',
    keep: Number((keepRow?.value ?? '').trim()) || 14,
  });
});

// PUT /backup/auto — 设置自动备份（body: { time?: 'HH:MM', keep?: number }；北京时间每日一次；保留份数 1-90）
backupRouter.put('/auto', async (c) => {
  const body = await c.req.json().catch(() => null) as { time?: string; keep?: number } | null;
  const upsert = async (key: string, value: string) => {
    await c.env.DB.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
      .bind(key, value).run();
  };
  if (body?.time !== undefined) {
    const time = (body.time ?? '').trim();
    if (!/^\d{2}:\d{2}$/.test(time)) return c.json({ error: '时间格式应为 HH:MM（如 03:05）' }, 400);
    const hh = Number(time.slice(0, 2));
    const mm = Number(time.slice(3, 5));
    if (hh > 23 || mm > 59) return c.json({ error: '时间超出范围' }, 400);
    await upsert(KEY_BACKUP_TIME, time);
  }
  if (body?.keep !== undefined) {
    const keep = Number(body.keep);
    if (!Number.isInteger(keep) || keep < 1 || keep > 90) return c.json({ error: '保留份数应为 1-90' }, 400);
    await upsert('backup_keep', String(keep));
  }
  const timeRow = await c.env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind(KEY_BACKUP_TIME).first<{ value: string }>();
  const keepRow = await c.env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind('backup_keep').first<{ value: string }>();
  return c.json({
    time: (timeRow?.value ?? '').trim() || DEFAULT_BACKUP_TIME,
    keep: Number((keepRow?.value ?? '').trim()) || 14,
  });
});

// GET /backup — 全部数据 JSON（轻量手动导出/对账）。默认内嵌附件本体 base64（≤12MB 上限，超限仅引用清单）；
// ?attachments=none 只要表数据（剪贴板/轻量导出：同环境导入附件本体已在存储端，引用行恢复后即可正常读取）
backupRouter.get('/', async (c) => {
  const wantEmbed = c.req.query('attachments') !== 'none';
  const { data, attachments } = await exportAllData(c.env.DB, wantEmbed ? c.env : undefined);
  await recordAudit(c.env.DB, {
    username: c.get('user').username, action: 'export', entity_type: 'backup',
    detail: `导出全库备份（${Object.keys(data).length} 张表${attachments.count > 0 ? ` · 附件 ${attachments.count} 个${attachments.embedded ? '（内嵌）' : '（仅引用）'}` : ''}）`,
  });
  return c.json({
    exported_at: new Date().toISOString(),
    data,
    ...(attachments.count > 0 ? { attachments } : {}),
  });
});

// POST /backup/import — 合并导入备份 JSON（App/小程序/Web 手动导入）：
// 逐表逐行 INSERT OR IGNORE，已存在主键的行跳过（保留现有数据），返回各表插入/跳过计数。
// 附件内嵌（{key,data}）写回存储端；引用模式（{key}）同环境直接可用。
backupRouter.post('/import', async (c) => {
  const body = await c.req.json().catch(() => null) as
    | { data?: Record<string, Record<string, unknown>[]> }
    | null;
  const data = body?.data;
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    return c.json({ error: '备份数据格式不正确（缺少 data 对象）' }, 400);
  }
  const { report, total_inserted } = await importBackupData(c.env.DB, data, c.env);
  await recordAudit(c.env.DB, { username: c.get('user').username, action: 'import', entity_type: 'backup', detail: `导入备份：共新增 ${total_inserted} 条记录` });
  return c.json({ ok: true, report, total_inserted });
});

// POST /backup/now — 立即云备份（BackupPack DO 打包 ZIP 归档包：db.json + attachments/ 附件原始文件）
backupRouter.post('/now', async (c) => {
  try {
    const r = await runBackupPack(c.env, '/backup');
    await recordAudit(c.env.DB, {
      username: c.get('user').username, action: 'create', entity_type: 'backup',
      entity_id: `${r['key'] ?? ''}`,
      detail: `手动全库备份：${r['message'] ?? ''}`,
    });
    return c.json({ ok: true, ...r });
  } catch (e) {
    return c.json({ ok: false, status: 'failed', message: `备份失败：${(e as Error).message}` });
  }
});

// GET /backup/files — 备份历史列表（新→旧；兼容 .zip 归档包与历史 .json）
backupRouter.get('/files', async (c) => {
  const store = createStorage(c.env);
  const list = await store.list(BACKUP_PREFIX);
  const files = list.objects
    .map((o) => {
      const name = o.key.slice(BACKUP_PREFIX.length);
      return {
        name,
        name_display: formatBackupName(name),
        key: o.key,
        size: o.size,
        created_at: o.uploaded?.toISOString() ?? '',
      };
    })
    .sort((a, b) => b.key.localeCompare(a.key));
  return c.json({ files });
});

// POST /backup/files/:key/restore — 从存储端历史备份恢复（BackupPack DO 解包：db.json 合并导入 + 附件写回）。
// 兼容 ZIP 归档包（新）与历史 JSON 备份（旧，附件引用同环境本体在存储端）。
backupRouter.post('/files/:key/restore', async (c) => {
  const key = c.req.param('key');
  if (key.includes('/') || key.startsWith('.') || key.startsWith('..')) {
    return c.json({ error: '非法备份标识' }, 400);
  }
  try {
    const r = await runBackupPack(c.env, `/restore?key=${encodeURIComponent(key)}`);
    await recordAudit(c.env.DB, {
      username: c.get('user').username,
      action: 'import', entity_type: 'backup', entity_id: key,
      detail: `从历史备份恢复：共新增 ${r['total_inserted'] ?? 0} 条记录`,
    });
    if (r['ok'] === false) {
      return c.json({ error: `${r['error'] ?? '备份文件内容损坏'}` }, 400);
    }
    return c.json({ ok: true, report: r['report'], total_inserted: r['total_inserted'], attachments: r['attachments'], key });
  } catch (e) {
    return c.json({ error: `恢复失败：${(e as Error).message}` }, 500);
  }
});
