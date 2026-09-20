/**
 * schema.sql（CI 部署时执行）与 schema.ts（ensureSchema）一致性测试：
 * ① schema.sql 能在全新库独立建出全部 11 张表
 * ② 建过的库再跑 ensureSchema 幂等（不抛错、不重复建）
 */
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { createFakeD1 } from './helpers/fake-d1';

const TABLES = [
  'users', 'clients', 'items', 'item_prices',
  'purchase_items', 'sale_items',
  'payments', 'settings', 'categories',
];

/** 把 schema.sql 拆成可逐条执行的语句（去注释、空行，按分号拆分） */
function statements(): string[] {
  const sql = readFileSync('src/schema.sql', 'utf8')
    .split('\n')
    .filter((l) => !l.trim().startsWith('--'))
    .join('\n');
  return sql.split(';').map((s) => s.trim()).filter((s) => s.length > 0);
}

describe('schema.sql 完整建表与幂等', () => {
  it('schema.sql 能在空库建出全部核心表（含新表 categories/settings）', async () => {
    const db = await createFakeD1();
    for (const stmt of statements()) {
      await db.prepare(stmt).run();
    }
    for (const t of TABLES) {
      const row = await db.prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
      ).bind(t).first<{ name: string }>();
      expect(row, `表 ${t} 应已建出`).toBeTruthy();
    }
  });

  it('schema.sql 建过的库再跑 ensureSchema 幂等（不抛错）', async () => {
    const db = await createFakeD1();
    for (const stmt of statements()) {
      await db.prepare(stmt).run();
    }
    resetSchemaState();
    await expect(ensureSchema(db as never)).resolves.toBeUndefined();
    // 数据可用性抽查：categories 表可写读
    await db.prepare('INSERT INTO categories (id, type, name) VALUES (?, ?, ?)')
      .bind('c1', 'item', '蔬菜').run();
    const row = await db.prepare('SELECT name FROM categories WHERE id = ?').bind('c1').first<{ name: string }>();
    expect(row?.name).toBe('蔬菜');
  });

  it('schema.sql 重复执行幂等（IF NOT EXISTS）', async () => {
    const db = await createFakeD1();
    for (const stmt of statements()) {
      await db.prepare(stmt).run();
    }
    // 再执行一轮不报错
    for (const stmt of statements()) {
      await db.prepare(stmt).run();
    }
    const row = await db.prepare(
      "SELECT COUNT(*) AS cnt FROM sqlite_master WHERE type='table' AND name IN ('users','categories')",
    ).first<{ cnt: number }>();
    expect(row?.cnt).toBe(2);
  });

  it('并发冷启动迁移幂等：同一库并发 ensureSchema 不抛 duplicate column（回归 v0.17.90 500）', async () => {
    // 先完整迁移一次建出全部表（schema.sql 落后不含 payment_accounts，直接走 ensureSchema），
    // 再把 payment_accounts 还原成老结构（缺 bank_name/card_last_four）制造"缺列"场景
    const db = await createFakeD1();
    resetSchemaState();
    await ensureSchema(db as never);
    await db.prepare('DROP TABLE payment_accounts').run();
    await db.prepare('CREATE TABLE payment_accounts (id TEXT PRIMARY KEY, name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0)').run();
    // 清迁移标记：否则 ensureSchema 快检直接返回，不触发补列（模拟"老库缺列待迁移"）
    await db.prepare("DELETE FROM schema_meta WHERE key = 'schema_version'").run();
    resetSchemaState();
    // 同一库并发触发两次迁移：若 ALTER 竞争未被锁/幂等兜底，第二个会抛 duplicate column name
    await expect(Promise.all([
      ensureSchema(db as never),
      ensureSchema(db as never),
    ])).resolves.toBeDefined();
    // 迁移后列存在且数据可写读
    const cols = await db.prepare('PRAGMA table_info(payment_accounts)').all<{ name: string }>();
    expect(cols.results.map((c) => c.name)).toEqual(
      expect.arrayContaining(['bank_name', 'card_last_four']),
    );
  });

  it('v0.17.139 回归：老生产库（users 已存在、无 schema_meta 表）跑 ensureSchema → 不抛错、补建标记表、写入标记、二次调用走快检', async () => {
    // 模拟老库：全部业务表已建（users 存在 → 跳过全量 DDL batch），schema_meta 不存在
    // （v0.17.137 缺陷场景：迁移末尾 INSERT schema_meta 抛 no such table → 每次请求都 500，Web 全卡）
    const db = await createFakeD1();
    await db.prepare('CREATE TABLE users (id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, role TEXT NOT NULL DEFAULT \'staff\', display_name TEXT, avatar TEXT, totp_secret TEXT, totp_enabled INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL)').run();
    await db.prepare('CREATE TABLE sale_items (id TEXT PRIMARY KEY, sale_id TEXT NOT NULL, item_id TEXT NOT NULL, client_id TEXT, unit TEXT NOT NULL, quantity REAL NOT NULL, sale_price REAL NOT NULL DEFAULT 0, cost_price REAL NOT NULL DEFAULT 0, amount REAL NOT NULL DEFAULT 0, happened_at TEXT, note TEXT DEFAULT \'\', created_at TEXT NOT NULL)').run();
    await db.prepare('CREATE TABLE purchase_items (id TEXT PRIMARY KEY, purchase_id TEXT NOT NULL, item_id TEXT NOT NULL, unit TEXT NOT NULL, quantity REAL NOT NULL, purchase_price REAL NOT NULL DEFAULT 0, amount REAL NOT NULL DEFAULT 0, happened_at TEXT, note TEXT DEFAULT \'\', created_at TEXT NOT NULL)').run();
    await db.prepare('CREATE TABLE payments (id TEXT PRIMARY KEY, client_id TEXT NOT NULL, happened_at TEXT NOT NULL, amount REAL NOT NULL, waived REAL NOT NULL DEFAULT 0, method TEXT DEFAULT \'\', note TEXT DEFAULT \'\', created_at TEXT NOT NULL, created_by TEXT, sync_key TEXT)').run();
    await db.prepare('CREATE TABLE clients (id TEXT PRIMARY KEY, name TEXT NOT NULL, contact TEXT DEFAULT \'\', phone TEXT DEFAULT \'\', note TEXT DEFAULT \'\', start_date TEXT, end_date TEXT, month_start_day INTEGER NOT NULL DEFAULT 1, category_id TEXT, deleted_at TEXT, created_at TEXT NOT NULL)').run();
    await db.prepare('CREATE TABLE items (id TEXT PRIMARY KEY, name TEXT NOT NULL, category TEXT DEFAULT \'\', deleted_at TEXT, created_at TEXT NOT NULL)').run();
    await db.prepare('CREATE TABLE payment_accounts (id TEXT PRIMARY KEY, name TEXT NOT NULL, sort INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL)').run();
    resetSchemaState();
    await expect(ensureSchema(db as never)).resolves.toBeUndefined();
    // 标记表已补建且有行（v0.17.175 进销单位换算迁移 → 快检版本 '3'）
    const meta = await db.prepare("SELECT value FROM schema_meta WHERE key = 'schema_version'").first<{ value: string }>();
    expect(meta?.value).toBe('3');
    // 二次调用（模拟后续请求）不抛
    resetSchemaState();
    await expect(ensureSchema(db as never)).resolves.toBeUndefined();
  });

  it('v0.17.114 彻底删表迁移：旧库（含头表+FK 与数据）跑 ensureSchema → 头表删除、行表无 FK、数据保留自包含', async () => {
    // 构造旧库：头表 + 带 FK 的行表 + 数据（模拟 v0.17.113 之前的物理结构）
    const db = await createFakeD1();
    await db.prepare('CREATE TABLE sales (id TEXT PRIMARY KEY, client_id TEXT, happened_at TEXT, note TEXT, created_by TEXT, sync_key TEXT)').run();
    await db.prepare('CREATE TABLE purchase_items (id TEXT PRIMARY KEY, purchase_id TEXT REFERENCES purchases(id) ON DELETE CASCADE, item_id TEXT, unit TEXT, quantity REAL, purchase_price REAL, amount REAL, happened_at TEXT, note TEXT, created_at TEXT)').run();
    await db.prepare('CREATE TABLE purchases (id TEXT PRIMARY KEY, happened_at TEXT, note TEXT, created_by TEXT, sync_key TEXT)').run();
    await db.prepare('CREATE TABLE sale_items (id TEXT PRIMARY KEY, sale_id TEXT NOT NULL REFERENCES sales(id) ON DELETE CASCADE, item_id TEXT, client_id TEXT, unit TEXT, quantity REAL, sale_price REAL, cost_price REAL, amount REAL, happened_at TEXT, note TEXT, created_at TEXT)').run();
    await db.prepare('INSERT INTO sales (id, client_id, happened_at) VALUES (?, ?, ?)').bind('s1', 'c1', '2026-01-01').run();
    await db.prepare('INSERT INTO sale_items (id, sale_id, client_id, item_id, unit, quantity, sale_price, cost_price, amount, happened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
      .bind('x1', 's1', 'c1', 'i1', '斤', 5, 2, 1, 10, '2026-01-01').run();
    await db.prepare('INSERT INTO purchases (id, happened_at) VALUES (?, ?)').bind('p1', '2026-01-02').run();
    await db.prepare('INSERT INTO purchase_items (id, purchase_id, item_id, unit, quantity, purchase_price, amount, happened_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)')
      .bind('y1', 'p1', 'i1', '斤', 3, 1, 3, '2026-01-02').run();
    resetSchemaState();
    await ensureSchema(db as never);
    // 头表已物理删除
    for (const t of ['sales', 'purchases']) {
      const r = await db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name = ?").bind(t).first<{ name: string }>();
      expect(r, `头表 ${t} 应已删除`).toBeFalsy();
    }
    // 行表不再引用头表（FK 已去除）
    for (const t of ['sale_items', 'purchase_items']) {
      const fks = await db.prepare(`PRAGMA foreign_key_list(${t})`).all<{ table: string }>();
      expect(fks.results.length, `${t} 外键应已去除`).toBe(0);
    }
    // 数据保留且行自包含
    const sale = await db.prepare('SELECT * FROM sale_items WHERE id = ?').bind('x1').first<{ client_id: string; happened_at: string; note: string; created_by: string }>();
    expect(sale?.client_id).toBe('c1');
    expect(sale?.happened_at).toBe('2026-01-01');
    const buy = await db.prepare('SELECT * FROM purchase_items WHERE id = ?').bind('y1').first<{ purchase_id: string }>();
    expect(buy?.purchase_id).toBe('p1');
    // 索引重建完整（含 v0.17.138 店铺维度索引）
    const idx = await db.prepare("SELECT name FROM sqlite_master WHERE type='index' AND name IN ('idx_sale_items_sale','idx_sale_items_item','idx_sale_items_date','idx_sale_items_client','idx_sale_items_date_client','idx_payments_date_client','idx_purchase_items_purchase','idx_purchase_items_date')").all<{ name: string }>();
    expect(idx.results.length).toBe(8);
    // 迁移幂等：再跑一轮不抛错、数据仍在
    resetSchemaState();
    await ensureSchema(db as never);
    const after = await db.prepare('SELECT COUNT(*) AS cnt FROM sale_items').first<{ cnt: number }>();
    expect(after?.cnt).toBe(1);
  });
});