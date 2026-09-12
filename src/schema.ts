/** 幂等建表：首次请求时执行 DDL（CREATE TABLE IF NOT EXISTS），重复跑无副作用 */

const DDL: string[] = [
  `CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'staff' CHECK (role IN ('admin','staff')),
    display_name TEXT,
    avatar TEXT,
    totp_secret TEXT,
    totp_enabled INTEGER NOT NULL DEFAULT 0,
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
    created_by TEXT REFERENCES users(id),
    sync_key TEXT
  )`,
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_purchases_sync_key ON purchases (sync_key)`,
  `CREATE INDEX IF NOT EXISTS idx_purchases_date ON purchases (happened_at)`,
  `CREATE TABLE IF NOT EXISTS purchase_items (
    id TEXT PRIMARY KEY,
    purchase_id TEXT NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
    item_id TEXT NOT NULL REFERENCES items(id),
    unit TEXT NOT NULL,
    quantity REAL NOT NULL CHECK (quantity > 0),
    purchase_price REAL NOT NULL DEFAULT 0,
    amount REAL NOT NULL DEFAULT 0,
    happened_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON purchase_items (purchase_id)`,
  `CREATE TABLE IF NOT EXISTS sales (
    id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL REFERENCES clients(id),
    happened_at TEXT NOT NULL,
    note TEXT DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    created_by TEXT REFERENCES users(id),
    sync_key TEXT
  )`,
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_sync_key ON sales (sync_key)`,
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
    happened_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items (sale_id)`,
  `CREATE INDEX IF NOT EXISTS idx_sale_items_item ON sale_items (item_id)`,
  `CREATE TABLE IF NOT EXISTS payments (
    id TEXT PRIMARY KEY,
    client_id TEXT NOT NULL REFERENCES clients(id),
    happened_at TEXT NOT NULL,
    amount REAL NOT NULL CHECK (amount > 0),
    waived REAL NOT NULL DEFAULT 0 CHECK (waived >= 0),
    method TEXT DEFAULT '',
    note TEXT DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    created_by TEXT REFERENCES users(id),
    sync_key TEXT
  )`,
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_payments_sync_key ON payments (sync_key)`,
  `CREATE INDEX IF NOT EXISTS idx_payments_client ON payments (client_id)`,
  `CREATE INDEX IF NOT EXISTS idx_payments_date ON payments (happened_at)`,
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
  `CREATE TABLE IF NOT EXISTS stocks (
    id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL REFERENCES items(id),
    unit TEXT NOT NULL,
    quantity REAL NOT NULL DEFAULT 0,
    min_stock REAL NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_stocks_item_unit ON stocks (item_id, unit)`,
  `CREATE TABLE IF NOT EXISTS share_links (
    token TEXT PRIMARY KEY,
    payload TEXT NOT NULL,
    expires_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE INDEX IF NOT EXISTS idx_share_links_expires ON share_links (expires_at)`,
  `CREATE TABLE IF NOT EXISTS sync_changes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL,
    entity_sync_id TEXT NOT NULL,
    action TEXT NOT NULL DEFAULT 'upsert',
    payload_json TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL,
    updated_by_device_id TEXT,
    updated_by_username TEXT
  )`,
  `CREATE INDEX IF NOT EXISTS idx_sync_changes_entity ON sync_changes (entity_type, entity_sync_id)`,
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
      const i = DDL.findIndex((s) => s.includes('CREATE TABLE IF NOT EXISTS categories'));
      await db.batch([db.prepare(DDL[i]), db.prepare(DDL[i + 1])]);
    }
    // 库存表（v0.14.0.0）：商品+单位 唯一，进货 + / 出货 −
    const stockTable = await db.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'stocks'",
    ).first<{ name: string }>();
    if (!stockTable) {
      const i = DDL.findIndex((s) => s.includes('CREATE TABLE IF NOT EXISTS stocks'));
      await db.batch([db.prepare(DDL[i]), db.prepare(DDL[i + 1])]);
    }
    // 分享链接表（v0.16.17.0）：对账单分享页面用
    const shareTable = await db.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'share_links'",
    ).first<{ name: string }>();
    if (!shareTable) {
      const i = DDL.findIndex((s) => s.includes('CREATE TABLE IF NOT EXISTS share_links'));
      await db.batch([db.prepare(DDL[i]), db.prepare(DDL[i + 1])]);
    }
    // 同步变更流（v0.17.0.0）：append-only 变更日志（id=游标）
    const syncTable = await db.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sync_changes'",
    ).first<{ name: string }>();
    if (!syncTable) {
      const i = DDL.findIndex((s) => s.includes('CREATE TABLE IF NOT EXISTS sync_changes'));
      await db.batch([db.prepare(DDL[i]), db.prepare(DDL[i + 1])]);
    }
    // v0.17.17.0：users 账号列（头像 / 两步验证 TOTP）
    const uCols = await db.prepare('PRAGMA table_info(users)').all<{ name: string }>();
    if (!uCols.results.some((x) => x.name === 'avatar')) {
      await db.prepare('ALTER TABLE users ADD COLUMN avatar TEXT').run();
    }
    if (!uCols.results.some((x) => x.name === 'totp_secret')) {
      await db.prepare('ALTER TABLE users ADD COLUMN totp_secret TEXT').run();
    }
    if (!uCols.results.some((x) => x.name === 'totp_enabled')) {
      await db.prepare('ALTER TABLE users ADD COLUMN totp_enabled INTEGER NOT NULL DEFAULT 0').run();
    }
    // v0.17.18.0：users 显示名 display_name（登录账号不可改，用户名=显示名可改；默认取登录账号 @ 前部分）
    if (!uCols.results.some((x) => x.name === 'display_name')) {
      await db.prepare('ALTER TABLE users ADD COLUMN display_name TEXT').run();
      await db.prepare(
        `UPDATE users SET display_name = CASE
          WHEN instr(username, '@') > 0 THEN substr(username, 1, instr(username, '@') - 1)
          ELSE username END
        WHERE display_name IS NULL OR display_name = ''`,
      ).run();
    }
    // v0.17.24.0：单据明细行独立日期 happened_at（每行商品可有自己的日期；历史行回退用单据日期）
    for (const t of ['sale_items', 'purchase_items'] as const) {
      const iCols = await db.prepare(`PRAGMA table_info(${t})`).all<{ name: string }>();
      if (!iCols.results.some((x) => x.name === 'happened_at')) {
        await db.prepare(`ALTER TABLE ${t} ADD COLUMN happened_at TEXT`).run();
      }
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
    // v0.16.26.0：单据表幂等键 sync_key（离线重放/多端不重复建单）+ 查询索引
    for (const t of ['sales', 'purchases', 'payments'] as const) {
      const cols = await db.prepare(`PRAGMA table_info(${t})`).all<{ name: string }>();
      if (!cols.results.some((x) => x.name === 'sync_key')) {
        await db.prepare(`ALTER TABLE ${t} ADD COLUMN sync_key TEXT`).run();
      }
    }
    // CREATE INDEX IF NOT EXISTS 幂等：已存在时 no-op（不耗 D1 写配额），新库补齐索引
    for (const marker of [
      'idx_sales_sync_key', 'idx_purchases_sync_key', 'idx_payments_sync_key',
      'idx_purchases_date', 'idx_payments_date', 'idx_sale_items_item',
    ]) {
      const i = DDL.findIndex((s) => s.includes(marker));
      if (i >= 0) await db.prepare(DDL[i]).run();
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