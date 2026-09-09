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
});