/**
 * 测试用 Fake D1：sql.js（真 SQLite WASM）内存库，实现 D1 prepare/bind/first/all/run/batch 接口。
 * 真实执行 SQL（JOIN/子查询/聚合），比手写解析器可靠。
 */
// eslint-disable-next-line @typescript-eslint/no-require-imports
import initSqlJs from 'sql.js/dist/sql-asm.js';

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
};

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

/** 创建内存 SQLite 库（开启外键以支持 ON DELETE CASCADE） */
export async function createFakeD1(): Promise<FakeD1> {
  const SQL = await initSqlJs() as unknown as { Database: new () => SqliteLike & { close(): void } };
  const db = new SQL.Database();
  db.run('PRAGMA foreign_keys = ON');
  return new FakeD1(db);
}

/** 最小 Fetcher（ASSETS mock：任意请求 404） */
export const fakeAssets = {
  async fetch(): Promise<Response> {
    return new Response('not found', { status: 404 });
  },
};