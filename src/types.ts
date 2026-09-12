/** Workers 环境类型 */
export interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
  JWT_SECRET: string;
  /** R2 附件存储（交易凭证图片），与 D1 配额独立 */
  BUCKET: R2Bucket;
  /** 附件存储驱动（默认 r2；未来可 webdav 等），由 createStorage 工厂读取 */
  STORAGE_DRIVER?: string;
}

/** JWT 载荷中的用户信息 */
export interface AuthUser {
  id: string;
  username: string;
  role: 'admin' | 'staff';
}

/** 常用行类型 */
export interface UserRow {
  id: string;
  username: string;
  password_hash: string;
  role: 'admin' | 'staff';
  display_name?: string | null;
  avatar?: string | null;
  totp_secret?: string | null;
  totp_enabled?: number;
}

export interface ClientRow {
  id: string;
  name: string;
  contact: string | null;
  phone: string | null;
  note: string | null;
  start_date: string | null;
  end_date: string | null;
  month_start_day: number;
  category_id: string | null;
  deleted_at: string | null;
}

export interface ItemRow {
  id: string;
  name: string;
  category: string | null;
  category_id: string | null;
  deleted_at: string | null;
}

export interface ItemPriceRow {
  id: string;
  item_id: string;
  unit: string;
  purchase_price: number;
  sale_price: number;
  active: number;
}