// 从 R2 物理文件重建/核对交易附件引用（自愈误删 refs 但 R2 文件还在，见 src/routes/attachments.ts 自愈逻辑）
//
// 前置：
//   1. 本机已配置 Cloudflare 凭证（wrangler login 或环境变量 CF_API_TOKEN / CLOUDFLARE_API_TOKEN）
//   2. wrangler.toml 中 [[r2_buckets]] bucket_name = "taozhu-attachments" 已就绪
//   3. 本机 wrangler 版本较新（支持 `r2 object list --json`），脚本用 npx wrangler@latest 拉取
//
// 用法：
//   查询（默认，不写库，仅列出 + 预览 SQL）：
//     FILTER_AFTER=2026-11-04T18:00:00Z node scripts/recover-attachment-refs.mjs
//   实际重建引用（INSERT OR IGNORE，已存在的跳过）：
//     APPLY=1 FILTER_AFTER=2026-11-04T18:00:00Z node scripts/recover-attachment-refs.mjs
//
// 说明：R2 key 格式 taozhu/images/attachments/{entity}/{id}/{md5}.jpg 含 entity/id/md5，
//       可完整重建 attachment_refs（id=`${entity}:${id}:${key}`），重新关联交易。
import { execSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const BUCKET = 'taozhu-attachments';
const PREFIX = 'taozhu/images/attachments/';
const FILTER_AFTER = process.env.FILTER_AFTER || null; // 如 2026-11-04T18:00:00Z
const APPLY = process.env.APPLY === '1';

console.log('列出 R2 附件对象（首次可能需下载 wrangler，请稍候）...');
const raw = execSync(
  `npx --yes wrangler@latest r2 object list ${BUCKET} --prefix "${PREFIX}" --json`,
  { encoding: 'utf8', maxBuffer: 1024 * 1024 * 64 },
);
const objs = JSON.parse(raw);

const filtered = FILTER_AFTER
  ? objs.filter((o) => o.uploaded && o.uploaded > FILTER_AFTER)
  : objs;
console.log(
  `R2 ${PREFIX} 共 ${objs.length} 个对象；筛选(${FILTER_AFTER || '全部'})后 ${filtered.length} 个：`,
);
filtered.forEach((o) => console.log(`  ${o.uploaded || '?'}  ${o.key}`));

function parse(key) {
  // 新格式：taozhu/images/attachments/{entity}/{id}/{file}
  const m = key.match(/^taozhu\/images\/attachments\/([^/]+)\/([^/]+)\/(.+)$/);
  if (!m) return null;
  const file = m[3];
  const md5 = file.replace(/\.[^.]+$/, '');
  return { entity: m[1], id: m[2], key, md5 };
}
const rows = filtered.map((o) => parse(o.key)).filter(Boolean);

if (rows.length === 0) {
  console.log('没有可重建的附件引用。');
  process.exit(0);
}

const esc = (s) => String(s).replace(/'/g, "''");
const values = rows
  .map(
    (r) =>
      `('${esc(`${r.entity}:${r.id}:${r.key}`)}', '${esc(r.entity)}', '${esc(r.id)}', '${esc(r.key)}', '${esc(r.md5)}')`,
  )
  .join(',\n');
const sql = `INSERT OR IGNORE INTO attachment_refs (id, entity, entity_id, file_key, md5) VALUES\n${values};`;

if (!APPLY) {
  console.log(
    `\n[DRY_RUN] 以下为将重建的引用条数（设 APPLY=1 才写库）：${rows.length}`,
  );
  console.log('SQL 预览（前 600 字符）：\n' + sql.slice(0, 600));
} else {
  writeFileSync('/tmp/recover-attachment-refs.sql', sql);
  console.log('\n写入 D1 attachment_refs（INSERT OR IGNORE，已存在跳过）...');
  execSync(
    `npx --yes wrangler@latest d1 execute taozhu --remote --file=/tmp/recover-attachment-refs.sql`,
    { encoding: 'utf8', stdio: 'inherit' },
  );
  console.log(`已尝试重建 ${rows.length} 条附件引用。`);
}
