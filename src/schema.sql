-- 送菜进销存（vegbook）D1 Schema
-- 幂等建表：重复执行不报错（OR IGNORE 用于索引）

-- 用户（老板 admin / 店员 staff）
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,               -- 随机 id
  username TEXT NOT NULL UNIQUE,     -- 登录名
  password_hash TEXT NOT NULL,       -- PBKDF2-SHA256: salt:hash (hex)
  role TEXT NOT NULL DEFAULT 'staff' CHECK (role IN ('admin','staff')),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- 饭店（客户）
CREATE TABLE IF NOT EXISTS clients (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,                -- 饭店名
  contact TEXT DEFAULT '',           -- 联系人
  phone TEXT DEFAULT '',
  note TEXT DEFAULT '',
  deleted_at TEXT,                   -- 软删
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_clients_deleted ON clients (deleted_at);

-- 商品
CREATE TABLE IF NOT EXISTS items (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,                -- 商品名（如 白菜）
  category TEXT DEFAULT '',          -- 分类（蔬菜/肉/水产…）
  deleted_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_items_deleted ON items (deleted_at);

-- 商品 单位+双价 组合（同菜可：斤 2.0→2.5 / 包 25→30）
CREATE TABLE IF NOT EXISTS item_prices (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL REFERENCES items(id),
  unit TEXT NOT NULL,                -- 斤/公斤/件/包/箱…
  purchase_price REAL NOT NULL DEFAULT 0,  -- 进价
  sale_price REAL NOT NULL DEFAULT 0,      -- 出价
  active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_item_prices_item ON item_prices (item_id);

-- 进货单（主表：日期/备注/经手人）
CREATE TABLE IF NOT EXISTS purchases (
  id TEXT PRIMARY KEY,
  happened_at TEXT NOT NULL,         -- 进货日期（本地日期）
  note TEXT DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  created_by TEXT REFERENCES users(id)
);
-- 进货明细（商品/单位/数量/进价/小计）
CREATE TABLE IF NOT EXISTS purchase_items (
  id TEXT PRIMARY KEY,
  purchase_id TEXT NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
  item_id TEXT NOT NULL REFERENCES items(id),
  unit TEXT NOT NULL,
  quantity REAL NOT NULL CHECK (quantity > 0),
  purchase_price REAL NOT NULL DEFAULT 0,
  amount REAL NOT NULL DEFAULT 0,    -- = quantity * purchase_price
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON purchase_items (purchase_id);

-- 出货单（送饭店的账单）
CREATE TABLE IF NOT EXISTS sales (
  id TEXT PRIMARY KEY,
  client_id TEXT NOT NULL REFERENCES clients(id),
  happened_at TEXT NOT NULL,         -- 送货日期
  note TEXT DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  created_by TEXT REFERENCES users(id)
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
  cost_price REAL NOT NULL DEFAULT 0,   -- 进价快照
  amount REAL NOT NULL DEFAULT 0,       -- = quantity * sale_price
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items (sale_id);

-- 收款（结账登记：饭店欠款 = Σsales.amount - Σpayments.amount）
CREATE TABLE IF NOT EXISTS payments (
  id TEXT PRIMARY KEY,
  client_id TEXT NOT NULL REFERENCES clients(id),
  happened_at TEXT NOT NULL,         -- 收款日期
  amount REAL NOT NULL CHECK (amount > 0),
  method TEXT DEFAULT '',            -- 现金/微信/转账…
  note TEXT DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  created_by TEXT REFERENCES users(id)
);
CREATE INDEX IF NOT EXISTS idx_payments_client ON payments (client_id);