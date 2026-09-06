/** Workers 环境类型 */
export interface Env {
  DB: D1Database;
  ASSETS: Fetcher;
  JWT_SECRET: string;
  /** 智谱 API key（AI 拍照识别，glm-4v-flash 免费模型） */
  ZHIPU_API_KEY?: string;
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
  deleted_at: string | null;
}

export interface ItemRow {
  id: string;
  name: string;
  category: string | null;
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