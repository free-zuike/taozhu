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
  'purchases', 'purchase_items', 'sales', 'sale_items',
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
});