/** 公共图片存储 key 规范：taozhu/images/{type}/{...segments}/{md5}.jpg
 *  同一内容（如附件、未来头像）哈希一致 → 同一 key（幂等去重）。
 *  type 区分业务域；segments 按业务组织（附件：entity/交易id；头像：用户id 等）。 */
import { md5 } from './md5';

export function imageKey(type: string, segments: string[], bytes: Uint8Array): string {
  const h = md5(bytes);
  return `taozhu/images/${type}/${segments.join('/')}/${h}.jpg`;
}

/** 历史前缀（去重兼容）：list 时一并查询，避免旧数据"消失" */
export const LEGACY_IMAGE_PREFIXES: readonly string[] = ['taozhu/attachments/', ''];