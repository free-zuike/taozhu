/** 幂等建表：首次请求时执行 DDL（CREATE TABLE IF NOT EXISTS），重复跑无副作用 */

const DDL: string[] = [
  `CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'staff' CHECK (role IN ('admin','staff')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE TABLE IF NOT EXISTS clients (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    contact TEXT DEFAULT '',
    phone TEXT DEFAULT '',
    note TEXT DEFAULT '',
    start_date TEXT,
    end_date TEXT,
    month_start_day INTEGER NOT NULL DEFAULT 1,
    category_id TEXT,
    deleted_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE INDEX IF NOT EXISTS idx_clients_deleted ON clients (deleted_at)`,
  `CREATE TABLE IF NOT EXISTS items (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT DEFAULT '',
    deleted_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE INDEX IF NOT EXISTS idx_items_deleted ON items (deleted_at)`,
  `CREATE TABLE IF NOT EXISTS item_prices (
    id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL REFERENCES items(id),
    unit TEXT NOT NULL,
    purchase_price REAL NOT NULL DEFAULT 0,
    sale_price REAL NOT NULL DEFAULT 0,
    active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE INDEX IF NOT EXISTS idx_item_prices_item ON item_prices (item_id)`,
  `CREATE TABLE IF NOT EXISTS purchases (
    id TEXT PRIMARY KEY,
    happened_at TEXT NOT NULL,
    note TEXT DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    created_by TEXT REFERENCES users(id)
  )`,
  `CREATE TABLE IF NOT EXISTS purchase_items (
    id TEXT PRIMARY KEY,
    purchase_id TEXT NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
    item_id TEXT NOT NULL REFERENCES items(id),
    unit TEXT NOT NULL,
    quantity REAL NOT NULL CHECK (quantity > 0),
    purchase_price REAL NOT NULL DEFAULT 0,
    amount REAL NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON purchase_items (purchase_id)`,
  `CREATE TABLE IF NOT EXISTS sales (
    id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL REFERENCES clients(id),
    happened_at TEXT NOT NULL,
    note TEXT DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    created_by TEXT REFERENCES users(id)
  )`,
  `CREATE INDEX IF NOT EXISTS idx_sales_client ON sales (client_id)`,
  `CREATE INDEX IF NOT EXISTS idx_sales_date ON sales (happened_at)`,
  `CREATE TABLE IF NOT EXISTS sale_items (
    id TEXT PRIMARY KEY,
    sale_id TEXT NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
    item_id TEXT NOT NULL REFERENCES items(id),
    unit TEXT NOT NULL,
    quantity REAL NOT NULL CHECK (quantity > 0),
    sale_price REAL NOT NULL DEFAULT 0,
    cost_price REAL NOT NULL DEFAULT 0,
    amount REAL NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items (sale_id)`,
  `CREATE TABLE IF NOT EXISTS payments (
    id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL REFERENCES clients(id),
    happened_at TEXT NOT NULL,
    amount REAL NOT NULL CHECK (amount > 0),
    waived REAL NOT NULL DEFAULT 0 CHECK (waived >= 0),
    method TEXT DEFAULT '',
    note TEXT DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    created_by TEXT REFERENCES users(id)
  )`,
  `CREATE INDEX IF NOT EXISTS idx_payments_client ON payments (client_id)`,
  `CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS categories (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL CHECK (type IN ('item','client')),
    name TEXT NOT NULL,
    parent_id TEXT REFERENCES categories(id),
    sort INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE INDEX IF NOT EXISTS idx_categories_type ON categories (type)`,
];

let schemaReady = false;

/** 首次调用时建表；失败不置标志，下次重试 */
export async function ensureSchema(db: D1Database): Promise<void> {
  if (schemaReady) return;
  try {
    const exists = await db.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'users'",
    ).first<{ name: string }>();
    if (!exists) {
      await db.batch(DDL.map((sql) => db.prepare(sql)));
    }
    // 增量迁移（幂等，已有库也会补齐新表/新列；SQLite 无 ADD COLUMN IF NOT EXISTS，需查列）
    const catTable = await db.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'categories'",
    ).first<{ name: string }>();
    if (!catTable) {
      await db.batch([
        db.prepare(DDL[DDL.length - 2]),
        db.prepare(DDL[DDL.length - 1]),
      ]);
    }
    for (const t of ['clients', 'items'] as const) {
      const cols = await db.prepare(`PRAGMA table_info(${t})`).all<{ name: string }>();
      if (!cols.results.some((x) => x.name === 'category_id')) {
        await db.prepare(`ALTER TABLE ${t} ADD COLUMN category_id TEXT`).run();
      }
    }
    // clients 另有：记账开始/结束日期（结账周期起止）+ 每月起始日（1-28，1=自然月）
    const cCols = await db.prepare('PRAGMA table_info(clients)').all<{ name: string }>();
    if (!cCols.results.some((x) => x.name === 'start_date')) {
      await db.prepare('ALTER TABLE clients ADD COLUMN start_date TEXT').run();
    }
    if (!cCols.results.some((x) => x.name === 'end_date')) {
      await db.prepare('ALTER TABLE clients ADD COLUMN end_date TEXT').run();
    }
    if (!cCols.results.some((x) => x.name === 'month_start_day')) {
      await db.prepare('ALTER TABLE clients ADD COLUMN month_start_day INTEGER NOT NULL DEFAULT 1').run();
    }
    // payments 平账减免列（waived：欠款 = Σsales − Σ(amount+waived)）
    const payCols = await db.prepare('PRAGMA table_info(payments)').all<{ name: string }>();
    if (!payCols.results.some((x) => x.name === 'waived')) {
      await db.prepare('ALTER TABLE payments ADD COLUMN waived REAL NOT NULL DEFAULT 0').run();
    }
    schemaReady = true;
  } catch (err) {
    console.error('[taozhu] ensureSchema failed:', err);
    throw err;
  }
}

/** 仅供测试：重置建表缓存（每个用例用独立内存库时需要） */
export function resetSchemaState(): void {
  schemaReady = false;
}