/** Workers 环境类型 */
export interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
  JWT_SECRET: string;
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
}

export interface ClientRow {
  id: string;
  name: string;
  contact: string | null;
  phone: string | null;
  note: string | null;
  start_date: string | null;
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