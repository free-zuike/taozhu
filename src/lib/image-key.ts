/** 公共图片存储 key 规范：taozhu/images/{type}/{...segments}/{md5}.jpg
 *  同一内容（如附件、未来头像）哈希一致 → 同一 key（幂等去重）。
 *  type 区分业务域；segments 按业务组织（附件：entity/交易id；头像：用户id 等）。 */
import { md5 } from './md5';
import { createStorage, type AttachmentStorage } from '../services/storage';
import type { Env } from '../types';

export function imageKey(type: string, segments: string[], bytes: Uint8Array): string {
  const h = md5(bytes);
  return `taozhu/images/${type}/${segments.join('/')}/${h}.jpg`;
}

/** 历史前缀（去重兼容）：list 时一并查询，避免旧数据"消失" */
export const LEGACY_IMAGE_PREFIXES: readonly string[] = ['taozhu/attachments/', ''];

/** 某交易附件的前缀家族：当前规范 + 历史规范（互不重叠，删交易时全清） */
export function attachmentPrefixesOf(entity: string, id: string): string[] {
  return [
    `taozhu/images/attachments/${entity}/${id}/`,
    ...LEGACY_IMAGE_PREFIXES.map((p) => `${p}${entity}/${id}/`),
  ];
}

/** 删除某交易的全部附件对象（分页列 + 逐个删；删除交易后调用，避免 R2 残留孤儿文件） */
export async function deleteEntityAttachments(env: Env, entity: string, id: string): Promise<void> {
  const store: AttachmentStorage = createStorage(env);
  for (const prefix of attachmentPrefixesOf(entity, id)) {
    let cursor: string | undefined;
    do {
      const r = await store.list(prefix, cursor);
      for (const o of r.objects) await store.delete(o.key);
      cursor = r.truncated ? r.cursor : undefined;
    } while (cursor);
  }
}