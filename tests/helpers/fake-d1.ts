/**
 * 测试用 Fake D1：sql.js（真 SQLite WASM）内存库，实现 D1 prepare/bind/first/all/run/batch 接口。
 * 真实执行 SQL（JOIN/子查询/聚合），比手写解析器可靠。
 */
// eslint-disable-next-line @typescript-eslint/no-require-imports
import initSqlJs from 'sql.js/dist/sql-asm.js';
import { afterAll } from 'vitest';

type Row = Record<string, unknown>;

type SqliteLike = {
  prepare(sql: string): {
    bind(...p: unknown[]): unknown;
    step(): boolean;
    getAsObject(): Row;
    run(...p: unknown[]): unknown;
    free(): void;
  };
  run(sql: string): void;
  close(): void;
};

// initSqlJs 是重量级模块（asm.js ~几十 MB 编译产物），模块级单例避免每个库重复加载触发 OOM
const SQL_PROMISE = initSqlJs() as unknown as Promise<{
  Database: new () => SqliteLike;
}>;

// 登记所有尚未关闭的库，控制 asm 堆上活跃库数量：
// 测试是「每用例一库、串行替换」模式，前一个库在下一个 beforeEach 必然被替换 —
// FIFO 保留最近 4 个（留足并发余量），超限即关闭最旧的，避免几十个库同时驻留 asm 堆触发 Aborted(OOM)
const openDbs = new Set<SqliteLike>();
const MAX_OPEN_DBS = 4;
function track(db: SqliteLike) {
  openDbs.add(db);
  if (openDbs.size > MAX_OPEN_DBS) {
    const oldest = openDbs.values().next().value;
    if (oldest) {
      try {
        oldest.close();
      } catch {
        // 已关闭的库重复 close 会抛错；忽略即可
      }
      openDbs.delete(oldest);
    }
  }
}

// 文件级兜底：全部用例结束后关闭仍存活的库（防用例间模式变化漏回收）
afterAll(() => {
  for (const db of openDbs) {
    try {
      db.close();
    } catch {
      // 同上
    }
  }
  openDbs.clear();
});

export class FakeStatement {
  private params: unknown[] = [];
  constructor(private db: SqliteLike, private sql: string) {}

  bind(...args: unknown[]): this {
    this.params = args;
    return this;
  }

  async first<T = Row>(): Promise<T | null> {
    const stmt = this.db.prepare(this.sql);
    try {
      stmt.bind(this.params); // sql.js: bind/run 参数必须是数组
      return (stmt.step() ? stmt.getAsObject() : null) as T | null;
    } finally {
      stmt.free();
    }
  }

  async all<T = Row>(): Promise<{ results: T[] }> {
    const stmt = this.db.prepare(this.sql);
    const rows: T[] = [];
    try {
      stmt.bind(this.params);
      while (stmt.step()) rows.push(stmt.getAsObject() as T);
      return { results: rows };
    } finally {
      stmt.free();
    }
  }

  async run(): Promise<{ success: boolean; meta: { last_row_id: number; changes: number }; results: Row[] }> {
    const stmt = this.db.prepare(this.sql);
    try {
      stmt.run(this.params);
      return { success: true, meta: { last_row_id: 0, changes: 1 }, results: [] };
    } finally {
      stmt.free();
    }
  }
}

export class FakeD1 {
  constructor(private db: SqliteLike) {}

  prepare(sql: string): FakeStatement {
    return new FakeStatement(this.db, sql);
  }

  /** 原子执行多语句（BEGIN/COMMIT 模拟 D1 batch 事务） */
  async batch(statements: FakeStatement[]): Promise<unknown[]> {
    this.db.run('BEGIN');
    try {
      const results: unknown[] = [];
      for (const stmt of statements) results.push(await stmt.run());
      this.db.run('COMMIT');
      return results;
    } catch (err) {
      this.db.run('ROLLBACK');
      throw err;
    }
  }
}

/** 创建内存 SQLite 库（开启外键以支持 ON DELETE CASCADE）；文件测试结束时由 afterAll 统一关闭 */
export async function createFakeD1(): Promise<FakeD1> {
  const SQL = await SQL_PROMISE;
  const db = new SQL.Database();
  db.run('PRAGMA foreign_keys = ON');
  track(db);
  return new FakeD1(db);
}

/** 最小 Fetcher（ASSETS mock：任意请求 404） */
export const fakeAssets = {
  async fetch(): Promise<Response> {
    return new Response('not found', { status: 404 });
  },
};