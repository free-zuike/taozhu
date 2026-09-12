-- 通用进销存（taozhu）D1 Schema
-- 幂等建表：重复执行不报错（CREATE ... IF NOT EXISTS）
-- 与 src/schema.ts 的 DDL 保持一致；部署时由 CI 执行（wrangler d1 execute --remote --file），
-- 请求路径的 ensureSchema 仅作已有库缺列/缺表的兜底（对完整库只读检查）。

-- 用户（老板 admin / 店员 staff；display_name 显示名、avatar 头像 R2 key、totp 两步验证）
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'staff' CHECK (role IN ('admin','staff')),
  display_name TEXT,
  avatar TEXT,
  totp_secret TEXT,
  totp_enabled INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- 店铺（客户）
CREATE TABLE IF NOT EXISTS clients (
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
);
CREATE INDEX IF NOT EXISTS idx_clients_deleted ON clients (deleted_at);

-- 商品
CREATE TABLE IF NOT EXISTS items (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  category TEXT DEFAULT '',
  category_id TEXT,
  deleted_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_items_deleted ON items (deleted_at);

-- 商品 单位+双价 组合（同菜可：斤 2.0→2.5 / 包 25→30）
CREATE TABLE IF NOT EXISTS item_prices (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL REFERENCES items(id),
  unit TEXT NOT NULL,
  purchase_price REAL NOT NULL DEFAULT 0,
  sale_price REAL NOT NULL DEFAULT 0,
  active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_item_prices_item ON item_prices (item_id);

-- 进货单（主表）：sync_key = 客户端幂等键（离线重放/多端提交不重复建单）
CREATE TABLE IF NOT EXISTS purchases (
  id TEXT PRIMARY KEY,
  happened_at TEXT NOT NULL,
  note TEXT DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  created_by TEXT REFERENCES users(id),
  sync_key TEXT
);
CREATE INDEX IF NOT EXISTS idx_purchases_date ON purchases (happened_at);-- 进货明细
CREATE TABLE IF NOT EXISTS purchase_items (
  id TEXT PRIMARY KEY,
  purchase_id TEXT NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
  item_id TEXT NOT NULL REFERENCES items(id),
  unit TEXT NOT NULL,
  quantity REAL NOT NULL CHECK (quantity > 0),
  purchase_price REAL NOT NULL DEFAULT 0,
  amount REAL NOT NULL DEFAULT 0,
  happened_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON purchase_items (purchase_id);

-- 出货单（主表）：sync_key = 客户端幂等键
CREATE TABLE IF NOT EXISTS sales (
  id TEXT PRIMARY KEY,
  client_id TEXT NOT NULL REFERENCES clients(id),
  happened_at TEXT NOT NULL,
  note TEXT DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  created_by TEXT REFERENCES users(id),
  sync_key TEXT
);
CREATE INDEX IF NOT EXISTS idx_sales_client ON sales (client_id);
CREATE INDEX IF NOT EXISTS idx_sales_date ON sales (happened_at);
-- 出货明细：快照 sale_price 与 cost_price（出货当时的进价），毛利=Σ((sale-cost)*qty) 不受日后改价影响
CREATE TABLE IF NOT EXISTS sale_items (
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
);
CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items (sale_id);
CREATE INDEX IF NOT EXISTS idx_sale_items_item ON sale_items (item_id);

-- 收款（结账登记：店铺欠款 = Σsales.amount − Σ(payments.amount + payments.waived)）
-- waived = 平账减免金额（实收 amount，减免部分账面视为已结清）
CREATE TABLE IF NOT EXISTS payments (
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
);
CREATE INDEX IF NOT EXISTS idx_payments_client ON payments (client_id);
CREATE INDEX IF NOT EXISTS idx_payments_date ON payments (happened_at);

-- 系统设置（AI 配置等键值）
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- 两级分类：type ∈ (item, client)；parent_id 非空为二级（最多两级由 API 层限制）
CREATE TABLE IF NOT EXISTS categories (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL CHECK (type IN ('item','client')),
  name TEXT NOT NULL,
  parent_id TEXT REFERENCES categories(id),
  sort INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_categories_type ON categories (type);

-- 库存（按 商品+单位）：进货 +quantity、出货 −quantity；min_stock 为低库存预警阈值
CREATE TABLE IF NOT EXISTS stocks (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL REFERENCES items(id),
  unit TEXT NOT NULL,
  quantity REAL NOT NULL DEFAULT 0,
  min_stock REAL NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_stocks_item_unit ON stocks (item_id, unit);
CREATE INDEX IF NOT EXISTS idx_categories_type ON categories (type);

-- 对账单分享链接（token 随机；expires_at 到期后页面提示已过期，永久分享为空）
CREATE TABLE IF NOT EXISTS share_links (
  token TEXT PRIMARY KEY,
  payload TEXT NOT NULL,
  expires_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_share_links_expires ON share_links (expires_at);

-- 同步变更流（append-only，id 自增即拉取游标；业务表即投影）。
-- 每写操作追加一行；实体多次变更按 id 递增，pull 按游标增量下发。
CREATE TABLE IF NOT EXISTS sync_changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entity_type TEXT NOT NULL,
  entity_sync_id TEXT NOT NULL,
  action TEXT NOT NULL DEFAULT 'upsert',
  payload_json TEXT NOT NULL DEFAULT '',
  updated_at TEXT NOT NULL,
  updated_by_device_id TEXT,
  updated_by_username TEXT
);
CREATE INDEX IF NOT EXISTS idx_sync_changes_entity ON sync_changes (entity_type, entity_sync_id);