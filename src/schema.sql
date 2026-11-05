-- 通用进销存（taozhu）D1 Schema
-- 幂等建表：重复执行不报错（CREATE ... IF NOT EXISTS）
-- 与 src/schema.ts 的 DDL 保持一致；部署时由 CI 执行（wrangler d1 execute --remote --file）。
-- 这是生产库索引的全量落地入口：已初始化的库不会重跑 ensureSchema 的全量 DDL，
-- 新增表/索引必须两处同步，否则查询退化成全表扫描、烧穿 D1 rows_read 额度。
-- tests/schema.test.ts 会校验本文件与 src/schema.ts 的表/索引集合一致（唯一例外见文件末尾）。
-- 注意：本文件由测试按分号逐条执行，注释只能是整行，不要写行内 -- 注释。

CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'staff' CHECK (role IN ('admin','staff')),
  display_name TEXT,
  avatar TEXT,
  avatar_version INTEGER NOT NULL DEFAULT 0,
  totp_secret TEXT,
  totp_enabled INTEGER NOT NULL DEFAULT 0,
  refresh_iat INTEGER,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS clients (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  contact TEXT DEFAULT '',
  phone TEXT DEFAULT '',
  note TEXT DEFAULT '',
  start_date TEXT,
  end_date TEXT,
  month_start_day INTEGER NOT NULL DEFAULT 1,
  round_stage TEXT NOT NULL DEFAULT 'none',
  round_unit TEXT NOT NULL DEFAULT 'yuan',
  round_carry REAL,
  category_id TEXT,
  price_group_id TEXT,
  deleted_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_clients_deleted ON clients (deleted_at);

CREATE TABLE IF NOT EXISTS items (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  category TEXT DEFAULT '',
  category_id TEXT,
  count_unit TEXT DEFAULT '',
  deleted_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_items_deleted ON items (deleted_at);

CREATE TABLE IF NOT EXISTS item_prices (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL,
  unit TEXT NOT NULL,
  purchase_price REAL NOT NULL DEFAULT 0,
  sale_price REAL NOT NULL DEFAULT 0,
  per REAL,
  active INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_item_prices_item ON item_prices (item_id);

CREATE TABLE IF NOT EXISTS price_groups (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  sort INTEGER NOT NULL DEFAULT 0,
  deleted_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE TABLE IF NOT EXISTS item_group_prices (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL,
  unit TEXT NOT NULL,
  group_id TEXT NOT NULL,
  sale_price REAL NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_item_group_prices_item ON item_group_prices (item_id);
CREATE INDEX IF NOT EXISTS idx_item_group_prices_group ON item_group_prices (group_id);

CREATE TABLE IF NOT EXISTS purchase_items (
  id TEXT PRIMARY KEY,
  purchase_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  unit TEXT NOT NULL,
  quantity REAL NOT NULL CHECK (quantity > 0),
  count_qty REAL,
  purchase_price REAL NOT NULL DEFAULT 0,
  amount REAL NOT NULL DEFAULT 0,
  happened_at TEXT,
  note TEXT DEFAULT '',
  expiry_date TEXT DEFAULT '',
  created_by TEXT,
  sync_key TEXT,
  sort INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_purchase_items_purchase ON purchase_items (purchase_id);
CREATE INDEX IF NOT EXISTS idx_purchase_items_date ON purchase_items (happened_at);

CREATE TABLE IF NOT EXISTS sale_items (
  id TEXT PRIMARY KEY,
  sale_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  client_id TEXT,
  unit TEXT NOT NULL,
  quantity REAL NOT NULL CHECK (quantity > 0),
  count_qty REAL,
  sale_price REAL NOT NULL DEFAULT 0,
  cost_price REAL NOT NULL DEFAULT 0,
  amount REAL NOT NULL DEFAULT 0,
  happened_at TEXT,
  note TEXT DEFAULT '',
  created_by TEXT,
  sync_key TEXT,
  sort INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items (sale_id);
CREATE INDEX IF NOT EXISTS idx_sale_items_item ON sale_items (item_id);
CREATE INDEX IF NOT EXISTS idx_sale_items_date ON sale_items (happened_at);
CREATE INDEX IF NOT EXISTS idx_sale_items_client ON sale_items (client_id);
CREATE INDEX IF NOT EXISTS idx_sale_items_date_client ON sale_items (happened_at, client_id);

CREATE TABLE IF NOT EXISTS payments (
  id TEXT PRIMARY KEY,
  client_id TEXT NOT NULL,
  happened_at TEXT NOT NULL,
  amount REAL NOT NULL CHECK (amount > 0),
  waived REAL NOT NULL DEFAULT 0 CHECK (waived >= 0),
  method TEXT DEFAULT '',
  note TEXT DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  created_by TEXT,
  sync_key TEXT
);
CREATE INDEX IF NOT EXISTS idx_payments_client ON payments (client_id);
CREATE INDEX IF NOT EXISTS idx_payments_date ON payments (happened_at);
CREATE INDEX IF NOT EXISTS idx_payments_date_client ON payments (happened_at, client_id);

CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS categories (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL CHECK (type IN ('item','client')),
  name TEXT NOT NULL,
  parent_id TEXT,
  sort INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_categories_type ON categories (type);

CREATE TABLE IF NOT EXISTS payment_accounts (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  bank_name TEXT DEFAULT '',
  card_last_four TEXT DEFAULT '',
  sort INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS stocks (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL,
  unit TEXT NOT NULL,
  quantity REAL NOT NULL DEFAULT 0,
  min_stock REAL NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_stocks_item_unit ON stocks (item_id, unit);

CREATE TABLE IF NOT EXISTS stock_batches (
  batch_id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL,
  unit TEXT NOT NULL,
  price REAL NOT NULL DEFAULT 0,
  remaining REAL NOT NULL DEFAULT 0,
  happened_at TEXT NOT NULL DEFAULT '',
  expiry_date TEXT DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_stock_batches_item ON stock_batches (item_id, unit);

CREATE TABLE IF NOT EXISTS sale_batch_uses (
  sale_item_id TEXT NOT NULL,
  batch_id TEXT NOT NULL,
  qty REAL NOT NULL DEFAULT 0,
  PRIMARY KEY (sale_item_id, batch_id)
);

CREATE TABLE IF NOT EXISTS loss_records (
  id TEXT PRIMARY KEY,
  item_id TEXT NOT NULL,
  unit TEXT NOT NULL,
  qty REAL NOT NULL DEFAULT 0,
  price REAL NOT NULL DEFAULT 0,
  amount REAL NOT NULL DEFAULT 0,
  happened_at TEXT NOT NULL DEFAULT '',
  note TEXT DEFAULT '',
  created_by TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_loss_records_item ON loss_records (item_id, unit);
CREATE INDEX IF NOT EXISTS idx_loss_records_date ON loss_records (happened_at);

CREATE TABLE IF NOT EXISTS share_links (
  token TEXT PRIMARY KEY,
  payload TEXT NOT NULL,
  expires_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_share_links_expires ON share_links (expires_at);

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

CREATE TABLE IF NOT EXISTS attachment_refs (
  id TEXT PRIMARY KEY,
  entity TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  file_key TEXT NOT NULL,
  md5 TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_attachment_refs_entity ON attachment_refs (entity, entity_id);
CREATE INDEX IF NOT EXISTS idx_attachment_refs_key ON attachment_refs (file_key);

CREATE TABLE IF NOT EXISTS login_attempts (
  key TEXT PRIMARY KEY,
  fails INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS audit_logs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL,
  action TEXT NOT NULL,
  entity_type TEXT,
  entity_id TEXT,
  detail TEXT,
  client_type TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created ON audit_logs (created_at DESC);

CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  device_name TEXT NOT NULL,
  platform TEXT,
  ip TEXT,
  version TEXT,
  last_active_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_devices_user ON devices (user_id);

CREATE TABLE IF NOT EXISTS backup_runs (
  id TEXT PRIMARY KEY,
  status TEXT NOT NULL DEFAULT 'running',
  started_at TEXT NOT NULL,
  finished_at TEXT,
  message TEXT,
  file_name TEXT,
  size INTEGER,
  log_text TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS stock_adjustments (
  id TEXT PRIMARY KEY,
  adjust_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  unit TEXT NOT NULL,
  qty REAL NOT NULL DEFAULT 0,
  price REAL NOT NULL DEFAULT 0,
  amount REAL NOT NULL DEFAULT 0,
  happened_at TEXT NOT NULL DEFAULT '',
  note TEXT DEFAULT '',
  created_by TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_stock_adjustments_item ON stock_adjustments (item_id, unit);
CREATE INDEX IF NOT EXISTS idx_stock_adjustments_date ON stock_adjustments (happened_at);

CREATE TABLE IF NOT EXISTS ai_memories (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  content TEXT NOT NULL,
  keywords TEXT DEFAULT '',
  source_message_id TEXT,
  status TEXT NOT NULL DEFAULT 'active',
  expires_at TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_ai_memories_user ON ai_memories (user_id, status);

CREATE TABLE IF NOT EXISTS ai_conversations (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_ai_conversations_user ON ai_conversations (user_id);

CREATE TABLE IF NOT EXISTS ai_messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_ai_messages_conv ON ai_messages (conversation_id, created_at);

CREATE TABLE IF NOT EXISTS ai_tool_permissions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  tool_name TEXT NOT NULL,
  policy TEXT NOT NULL DEFAULT 'ask',
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_ai_tool_permissions_user_tool ON ai_tool_permissions (user_id, tool_name);
CREATE INDEX IF NOT EXISTS idx_ai_tool_permissions_user ON ai_tool_permissions (user_id);

CREATE TABLE IF NOT EXISTS ai_runs (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  intent TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'ok',
  started_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  finished_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  summary TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_ai_runs_user ON ai_runs (user_id, started_at DESC);

CREATE TABLE IF NOT EXISTS ai_tool_calls (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  tool_name TEXT NOT NULL,
  args TEXT NOT NULL DEFAULT '',
  result TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'ok',
  duration_ms INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_ai_tool_calls_run ON ai_tool_calls (run_id);
CREATE INDEX IF NOT EXISTS idx_ai_tool_calls_user ON ai_tool_calls (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS ai_pending_actions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  tool_name TEXT NOT NULL,
  args TEXT NOT NULL,
  preview TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  expires_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ai_pending_actions_user ON ai_pending_actions (user_id, expires_at);

CREATE TABLE IF NOT EXISTS schema_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- D1 rows_read 止血索引：等值列在前、范围列在后，与 src/schema.ts 的 PERF_INDEX_DDL 一一对应。
CREATE INDEX IF NOT EXISTS idx_sale_items_client_date ON sale_items (client_id, happened_at);
CREATE INDEX IF NOT EXISTS idx_payments_client_date ON payments (client_id, happened_at);
CREATE INDEX IF NOT EXISTS idx_sale_items_sync_key ON sale_items (sync_key);
CREATE INDEX IF NOT EXISTS idx_purchase_items_sync_key ON purchase_items (sync_key);
CREATE INDEX IF NOT EXISTS idx_clients_category ON clients (category_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_items_category ON items (category_id, deleted_at);
CREATE INDEX IF NOT EXISTS idx_stock_batches_expiry ON stock_batches (expiry_date, remaining);
CREATE INDEX IF NOT EXISTS idx_stock_adjustments_adjust ON stock_adjustments (adjust_id);

-- 唯一例外：idx_payments_sync_key 是 payments 上的 UNIQUE 索引。
-- 存量库若存在历史重复 sync_key，CI 的 wrangler d1 execute --file 会整批失败并阻断部署，
-- 故不写进本快照，由运行时 ensureIndexes 带 try/catch 单独补齐（失败只跳过该索引，不影响 API）。
