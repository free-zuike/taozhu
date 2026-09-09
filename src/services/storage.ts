/** 附件存储抽象：统一管理交易凭证图片，支持多驱动（R2 / 未来 WebDAV 等）。
 *  路由层只依赖 AttachmentStorage 接口；新增存储端只需实现接口并接入 createStorage。 */
import type { Env } from '../types';

export interface AttachmentObject {
  key: string;
  size: number;
  uploaded?: Date;
}

export type StorageValue = string | ArrayBuffer | ArrayBufferView | ReadableStream | Blob;

export interface AttachmentStorage {
  /** 写入对象（contentType 如 image/jpeg） */
  put(key: string, value: StorageValue, contentType?: string): Promise<void>;
  /** 读取对象；不存在返回 null */
  get(key: string): Promise<{ body: ReadableStream; contentType?: string } | null>;
  /** 按前缀列出对象 */
  list(prefix: string): Promise<AttachmentObject[]>;
  /** 删除对象 */
  delete(key: string): Promise<void>;
}

/** Cloudflare R2 实现 */
export class R2Storage implements AttachmentStorage {
  constructor(private bucket: R2Bucket) {}

  async put(key: string, value: StorageValue, contentType?: string): Promise<void> {
    await this.bucket.put(key, value, {
      httpMetadata: contentType ? { contentType } : undefined,
    });
  }

  async get(key: string): Promise<{ body: ReadableStream; contentType?: string } | null> {
    const obj = await this.bucket.get(key);
    if (!obj) return null;
    const headers = new Headers();
    obj.writeHttpMetadata(headers);
    return { body: obj.body, contentType: headers.get('content-type') ?? undefined };
  }

  async list(prefix: string): Promise<AttachmentObject[]> {
    const r = await this.bucket.list({ prefix });
    return r.objects.map((o) => ({
      key: o.key,
      size: o.size,
      uploaded: o.uploaded ? new Date(o.uploaded) : undefined,
    }));
  }

  async delete(key: string): Promise<void> {
    await this.bucket.delete(key);
  }
}

/**
 * 存储工厂：按环境变量 STORAGE_DRIVER 选择驱动（默认 r2）。
 * 新增存储端（如 webdav）时：实现 AttachmentStorage → 在 createStorage 加一个 branch。
 */
export function createStorage(env: Env): AttachmentStorage {
  const driver = (env.STORAGE_DRIVER || 'r2').trim().toLowerCase();
  switch (driver) {
    case 'r2':
      return new R2Storage(env.BUCKET);
    default:
      throw new Error(`不支持的存储驱动: ${driver}（可选 r2）`);
  }
}