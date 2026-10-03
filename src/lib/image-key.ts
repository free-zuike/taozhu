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

/** 附件内容 key（对齐参考实现"同图一份物理文件"）：key 仅按内容 md5 命名，不含实体/行 id——
 *  同一张图被 N 个商品/单据引用时 R2 只存 1 份，attachment_refs 表按实体各写一行引用。
 *  兼容：旧格式 key（含实体前缀，v0.17.281 前）仍按 parseAttachmentKey 兼容解析与展示。 */
export function attachmentContentKey(bytes: Uint8Array): string {
  return `taozhu/images/attachments/${md5(bytes)}.jpg`;
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

/** 附件 key → {entity, id}（三前缀兼容：当前规范 taozhu/images/attachments/、
 *  历史 taozhu/attachments/、根级裸前缀 {entity}/{id}/{file}）。解析不出返回 null。
 *  引用驱动：实体级引用删除/孤儿判定共用同一解析，避免各处正则不一致 */
export function parseAttachmentKey(key: string): { entity: string; id: string } | null {
  let m = /^taozhu\/images\/attachments\/([a-z_]+)\/([^/]+)\/[^/]+$/.exec(key);
  if (m) return { entity: m[1], id: m[2] };
  m = /^(?:taozhu\/attachments\/)?([a-z_]+)\/([^/]+)\/[^/]+$/.exec(key);
  if (m && ['sale', 'purchase', 'payment', 'sale_item', 'purchase_item'].includes(m[1])) {
    return { entity: m[1], id: m[2] };
  }
  return null;
}

/** 删除某交易/明细行的全部附件（删除交易后调用，避免 R2 残留孤儿文件）。
 *  顺序：**先删引用行**（引用是 in-use/下载的权威来源，实体删除即引用删除，绝不残留"引用在文件无"的坏引用）；
 *  R2 文件**仅当无其他实体引用时才删**（同内容多实体共享一份物理文件，对齐参考实现"同图一份"）；
 *  引用行缺失的历史旧格式 key（v0.17.84 前存量）按前缀兜底删。R2 删除失败不阻断（残留由孤儿扫描兜底） */
export async function deleteEntityAttachments(env: Env, entity: string, id: string): Promise<void> {
  try {
    const refs = await env.DB.prepare(
      'SELECT file_key FROM attachment_refs WHERE entity = ? AND entity_id = ?',
    ).bind(entity, id).all<{ file_key: string }>();
    await env.DB.prepare('DELETE FROM attachment_refs WHERE entity = ? AND entity_id = ?').bind(entity, id).run();
    const store: AttachmentStorage = createStorage(env);
    for (const r of refs.results) {
      const others = await env.DB.prepare('SELECT COUNT(*) AS cnt FROM attachment_refs WHERE file_key = ?')
        .bind(r.file_key).first<{ cnt: number }>();
      if ((others?.cnt ?? 0) > 0) continue; // 仍有其他实体引用 → 保留文件（共享）
      try {
        await store.delete(r.file_key);
      } catch (_) {}
    }
  } catch (_) {}
  // 兼容历史：旧格式前缀（含实体 id）兜底删——极老数据引用行缺失时仍能清
  const store: AttachmentStorage = createStorage(env);
  for (const prefix of attachmentPrefixesOf(entity, id)) {
    let cursor: string | undefined;
    do {
      try {
        const r = await store.list(prefix, cursor);
        for (const o of r.objects) await store.delete(o.key);
        cursor = r.truncated ? r.cursor : undefined;
      } catch (_) {
        break; // 单前缀删除失败即停：剩余文件交给孤儿扫描兜底，不阻断引用已删的语义
      }
    } while (cursor);
  }
}