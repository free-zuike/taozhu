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
  `CREATE TABLE IF NOT EXISTS purchase_items (
    id TEXT PRIMARY KEY,
    purchase_id TEXT NOT NULL,
    item_id TEXT NOT NULL,
    unit TEXT NOT NULL,
    quantity REAL NOT NULL CHECK (quantity > 0),
    purchase_price REAL NOT NULL DEFAULT 0,
    amount REAL NOT NULL DEFAULT 0,
    happened_at TEXT,
    note TEXT DEFAULT '',
    created_by TEXT,
    sync_key TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON purchase_items (purchase_id)`,
  `CREATE INDEX IF NOT EXISTS idx_purchase_items_date ON purchase_items (happened_at)`,
  `CREATE TABLE IF NOT EXISTS sale_items (
    id TEXT PRIMARY KEY,
    sale_id TEXT NOT NULL,
    item_id TEXT NOT NULL,
    client_id TEXT,
    unit TEXT NOT NULL,
    quantity REAL NOT NULL CHECK (quantity > 0),
    sale_price REAL NOT NULL DEFAULT 0,
    cost_price REAL NOT NULL DEFAULT 0,
    amount REAL NOT NULL DEFAULT 0,
    happened_at TEXT,
    note TEXT DEFAULT '',
    created_by TEXT,
    sync_key TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items (sale_id)`,
  `CREATE INDEX IF NOT EXISTS idx_sale_items_item ON sale_items (item_id)`,
  `CREATE INDEX IF NOT EXISTS idx_sale_items_date ON sale_items (happened_at)`,
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
  `CREATE TABLE IF NOT EXISTS payment_accounts (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    bank_name TEXT DEFAULT '',
    card_last_four TEXT DEFAULT '',
    sort INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
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
  `CREATE TABLE IF NOT EXISTS attachment_refs (
    id TEXT PRIMARY KEY,
    entity TEXT NOT NULL,          -- sale | purchase | payment | sale_item | purchase_item
    entity_id TEXT NOT NULL,
    file_key TEXT NOT NULL,        -- R2 唯一 key（taozhu/images/attachments/...）
    md5 TEXT NOT NULL,             -- 内容去重（一图多单共用：同 md5 多个实体各自引用）
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
  )`,
  `CREATE INDEX IF NOT EXISTS idx_attachment_refs_entity ON attachment_refs (entity, entity_id)`,
  `CREATE INDEX IF NOT EXISTS idx_attachment_refs_key ON attachment_refs (file_key)`,
  // v0.17.118.0：登录防爆破限流计数（username:IP 维度，滑动窗口）
  `CREATE TABLE IF NOT EXISTS login_attempts (
    key TEXT PRIMARY KEY,
    fails INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
  )`,
];

let schemaReady = false;
/** 进程内互斥：同一 Worker isolate 并发请求同时触发冷启动迁移时串行化（多 isolate 场景靠 ensureColumn 幂等兜底） */
let schemaLock: Promise<void> = Promise.resolve();

function withSchemaLock<T>(fn: () => Promise<T>): Promise<T> {
  const run = schemaLock.then(fn, fn);
  schemaLock = run.then(() => undefined, () => undefined);
  return run;
}

/**
 * 幂等加列：SQLite 无 ADD COLUMN IF NOT EXISTS，需 PRAGMA 查列。
 * 并发冷启动（多 isolate 同库同时触发迁移）时第二个 ALTER 会抛 "duplicate column name"——
 * 已存在即忽略（返回 false=本次未加），避免整个 ensureSchema 抛错导致同刻全部 API 请求 500。
 */
async function ensureColumn(
  db: D1Database, table: string, column: string, ddl: string,
): Promise<boolean> {
  try {
    const cols = await db.prepare(`PRAGMA table_info(${table})`).all<{ name: string }>();
    if (cols.results.some((x) => x.name === column)) return false;
    await db.prepare(`ALTER TABLE ${table} ADD COLUMN ${column} ${ddl}`).run();
    return true;
  } catch (e) {
    // 并发下其他 isolate 已先加上该列：忽略（幂等），只重抛非并发错误
    if (`${e}`.includes('duplicate column')) return false;
    throw e;
  }
}

/** 首次调用时建表；失败不置标志，下次重试 */
export async function ensureSchema(db: D1Database): Promise<void> {
  if (schemaReady) return;
  return withSchemaLock(async () => {
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
    // v0.17.84.0：附件引用表 attachment_refs（引用驱动：文件被哪些实体引用 → 孤儿=零引用）
    const aRefTable = await db.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'attachment_refs'",
    ).first<{ name: string }>();
    if (!aRefTable) {
      const i = DDL.findIndex((s) => s.includes('CREATE TABLE IF NOT EXISTS attachment_refs'));
      await db.batch([
        db.prepare(DDL[i]),
        db.prepare(DDL[i + 1]), // idx_attachment_refs_entity
        db.prepare(DDL[i + 2]), // idx_attachment_refs_key
      ]);
    }
    // v0.17.68.0：收款账户 payment_accounts（收款方式预设：现金/微信/支付宝等，同步实体）
    const paTable = await db.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'payment_accounts'",
    ).first<{ name: string }>();
    if (!paTable) {
      const i = DDL.findIndex((s) => s.includes('CREATE TABLE IF NOT EXISTS payment_accounts'));
      await db.batch([db.prepare(DDL[i])]);
    }
    // v0.17.90.0：payment_accounts 加开户行 bank_name + 卡号后四位 card_last_four
    // （多张同类型卡靠卡号区分；老表无列 → ALTER 补齐，新表 DDL 已含；ensureColumn 并发幂等）
    await ensureColumn(db, 'payment_accounts', 'bank_name', "TEXT DEFAULT ''");
    await ensureColumn(db, 'payment_accounts', 'card_last_four', "TEXT DEFAULT ''");
    // v0.17.118.0：登录防爆破限流计数表（username:IP 维度）
    const laTable = await db.prepare(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'login_attempts'",
    ).first<{ name: string }>();
    if (!laTable) {
      const i = DDL.findIndex((s) => s.includes('CREATE TABLE IF NOT EXISTS login_attempts'));
      await db.prepare(DDL[i]).run();
    }
    // 首次使用（空表）自动写入默认账户（现金/微信/支付宝/银行卡/转账），用户可后续增删改；
    // 空表才插，避免覆盖用户已自定义的列表
    const paCount = await db.prepare('SELECT COUNT(*) AS n FROM payment_accounts').first<{ n: number }>();
    if (!paCount || (paCount.n ?? 0) === 0) {
      await db.prepare('INSERT OR IGNORE INTO payment_accounts (id, name, sort) VALUES (?, ?, ?), (?, ?, ?), (?, ?, ?), (?, ?, ?), (?, ?, ?)')
        .bind('acct_cash', '现金', 0, 'acct_wechat', '微信', 1, 'acct_alipay', '支付宝', 2, 'acct_bank', '银行卡', 3, 'acct_transfer', '转账', 4).run();
    }
    // v0.17.17.0：users 账号列（头像 / 两步验证 TOTP）
    await ensureColumn(db, 'users', 'avatar', 'TEXT');
    // 头像版本号（对齐参考架构 profile 体系）：每次上传 +1，客户端按版本比对决定是否重下载（省流量/防脏缓存）
    await ensureColumn(db, 'users', 'avatar_version', 'INTEGER NOT NULL DEFAULT 0');
    await ensureColumn(db, 'users', 'totp_secret', 'TEXT');
    await ensureColumn(db, 'users', 'totp_enabled', 'INTEGER NOT NULL DEFAULT 0');
    // v0.17.18.0：users 显示名 display_name（登录账号不可改，用户名=显示名可改；默认取登录账号 @ 前部分）
    if (await ensureColumn(db, 'users', 'display_name', 'TEXT')) {
      await db.prepare(
        `UPDATE users SET display_name = CASE
          WHEN instr(username, '@') > 0 THEN substr(username, 1, instr(username, '@') - 1)
          ELSE username END
        WHERE display_name IS NULL OR display_name = ''`,
      ).run();
    }
    // v0.17.24.0：单据明细行独立日期 happened_at（每行商品可有自己的日期；历史行回退用单据日期）
    for (const t of ['sale_items', 'purchase_items'] as const) {
      await ensureColumn(db, t, 'happened_at', 'TEXT');
    }
    // v0.17.101.0 去单据化：商品行自包含店铺 client_id（同步/删除/统计按行走，不再依赖单据头）
    await ensureColumn(db, 'sale_items', 'client_id', 'TEXT');
    // 头表（sales/purchases）仅旧库存在：删除行表自包含回填依赖头表数据，新库/已删头表库跳过
    const hasSalesHead = (await db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sales'").first()) != null;
    const hasPurchasesHead = (await db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'purchases'").first()) != null;
    if (hasSalesHead) {
      await db.prepare(
        `UPDATE sale_items SET client_id = (SELECT s.client_id FROM sales s WHERE s.id = sale_items.sale_id)
         WHERE client_id IS NULL OR client_id = ''`,
      ).run();
    }
    // v0.17.104.0 彻底去单据化：商品行升级为独立主记录，头表字段（创建人/幂等键）全部并入行
    for (const t of ['sale_items', 'purchase_items'] as const) {
      await ensureColumn(db, t, 'created_by', 'TEXT');
    }
    for (const t of ['sale_items', 'purchase_items'] as const) {
      await ensureColumn(db, t, 'sync_key', 'TEXT');
    }
    if (hasSalesHead) {
      await db.prepare(
        `UPDATE sale_items SET created_by = (SELECT s.created_by FROM sales s WHERE s.id = sale_items.sale_id)
         WHERE created_by IS NULL OR created_by = ''`,
      ).run();
    }
    if (hasPurchasesHead) {
      await db.prepare(
        `UPDATE purchase_items SET created_by = (SELECT p.created_by FROM purchases p WHERE p.id = purchase_items.purchase_id)
         WHERE created_by IS NULL OR created_by = ''`,
      ).run();
    }
    // v0.17.82.0：明细行 happened_at 为 NULL 的历史行回填单据日期（此后查询可直接走列索引，无需 COALESCE 包裹导致全表扫）
    if (hasSalesHead) {
      await db.prepare(
        `UPDATE sale_items SET happened_at = (SELECT s.happened_at FROM sales s WHERE s.id = sale_items.sale_id)
         WHERE happened_at IS NULL`,
      ).run();
    }
    if (hasPurchasesHead) {
      await db.prepare(
        `UPDATE purchase_items SET happened_at = (SELECT p.happened_at FROM purchases p WHERE p.id = purchase_items.purchase_id)
         WHERE happened_at IS NULL`,
      ).run();
    }
    // v0.17.68.0：明细行级备注 note（每行商品可加备注；历史行回退单据级备注）
    for (const t of ['sale_items', 'purchase_items'] as const) {
      await ensureColumn(db, t, 'note', "TEXT DEFAULT ''");
    }
    for (const t of ['clients', 'items'] as const) {
      await ensureColumn(db, t, 'category_id', 'TEXT');
    }
    // clients 另有：记账开始/结束日期（结账周期起止）+ 每月起始日（1-28，1=自然月）
    await ensureColumn(db, 'clients', 'start_date', 'TEXT');
    await ensureColumn(db, 'clients', 'end_date', 'TEXT');
    await ensureColumn(db, 'clients', 'month_start_day', 'INTEGER NOT NULL DEFAULT 1');
    // payments 平账减免列（waived：欠款 = Σsales − Σ(amount+waived)）
    await ensureColumn(db, 'payments', 'waived', 'REAL NOT NULL DEFAULT 0');
    // v0.16.26.0：支付表幂等键 sync_key（sales/purchases 头表已物理删除，行级携带 sync_key）
    await ensureColumn(db, 'payments', 'sync_key', 'TEXT');
    // v0.17.105.0 彻底删表：sale_items/purchase_items 为独立主记录（自包含 client_id/日期/备注/创建人/幂等键），
    // 物理删除 sales/purchases 头表——回填已全部并入行；旧库在此 DROP，新库（DDL 已无头表）IF EXISTS no-op。
    // 业务读路径（stats/attachments/clients/stocks/sync）已验证全部行级直查，无残留 JOIN。
    // 先重建行表去外键（SQLite 无法 ALTER 去除 FK；旧库行表 FK 引用将被删的头表——
    // 若外键约束开启，删头后 INSERT 行会违约失败）。幂等：foreign_key_list 已无对应头表则跳过。
    for (const [table, headTable, rebuild] of [
      ['sale_items', 'sales', `CREATE TABLE sale_items_new (
        id TEXT PRIMARY KEY, sale_id TEXT NOT NULL, item_id TEXT NOT NULL, client_id TEXT,
        unit TEXT NOT NULL, quantity REAL NOT NULL CHECK (quantity > 0),
        sale_price REAL NOT NULL DEFAULT 0, cost_price REAL NOT NULL DEFAULT 0, amount REAL NOT NULL DEFAULT 0,
        happened_at TEXT, note TEXT DEFAULT '', created_by TEXT, sync_key TEXT,
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
      )`],
      ['purchase_items', 'purchases', `CREATE TABLE purchase_items_new (
        id TEXT PRIMARY KEY, purchase_id TEXT NOT NULL, item_id TEXT NOT NULL,
        unit TEXT NOT NULL, quantity REAL NOT NULL CHECK (quantity > 0),
        purchase_price REAL NOT NULL DEFAULT 0, amount REAL NOT NULL DEFAULT 0,
        happened_at TEXT, note TEXT DEFAULT '', created_by TEXT, sync_key TEXT,
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
      )`],
    ] as const) {
      const fks = await db.prepare(`PRAGMA foreign_key_list(${table})`).all<{ table: string }>();
      if (!fks.results.some((x) => x.table === headTable)) continue;
      await db.prepare(rebuild).run();
      await db.prepare(
        `INSERT INTO ${table}_new (id, ${table === 'sale_items' ? 'sale_id, client_id, item_id, unit, quantity, sale_price, cost_price, amount' : 'purchase_id, item_id, unit, quantity, purchase_price, amount'}, happened_at, note, created_at)
         SELECT id, ${table === 'sale_items' ? 'sale_id, client_id, item_id, unit, quantity, sale_price, cost_price, amount' : 'purchase_id, item_id, unit, quantity, purchase_price, amount'}, happened_at, note, COALESCE(created_at, strftime('%Y-%m-%dT%H:%M:%fZ','now')) FROM ${table}`,
      ).run();
      await db.prepare(`DROP TABLE ${table}`).run();
      await db.prepare(`ALTER TABLE ${table}_new RENAME TO ${table}`).run();
      // 重建索引（DROP 时随表删除）
      const relCol = table === 'sale_items' ? 'sale' : 'purchase';
      await db.prepare(`CREATE INDEX IF NOT EXISTS idx_${table}_${relCol} ON ${table} (${relCol}_id)`).run();
      await db.prepare(`CREATE INDEX IF NOT EXISTS idx_${table}_item ON ${table} (item_id)`).run();
      await db.prepare(`CREATE INDEX IF NOT EXISTS idx_${table}_date ON ${table} (happened_at)`).run();
    }
    await db.prepare('DROP TABLE IF EXISTS sales').run();
    await db.prepare('DROP TABLE IF EXISTS purchases').run();
    // CREATE INDEX IF NOT EXISTS 幂等：已存在时 no-op（不耗 D1 写配额），新库补齐索引
    for (const marker of [
      'idx_payments_sync_key', 'idx_payments_date', 'idx_sale_items_item',
      'idx_sale_items_date', 'idx_purchase_items_date',
    ]) {
      const i = DDL.findIndex((s) => s.includes(marker));
      if (i >= 0) await db.prepare(DDL[i]).run();
    }
    schemaReady = true;
    } catch (err) {
      console.error('[taozhu] ensureSchema failed:', err);
      throw err;
    }
  });
}

/** 仅供测试：重置建表缓存（每个用例用独立内存库时需要） */
export function resetSchemaState(): void {
  schemaReady = false;
}