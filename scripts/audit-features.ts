/**
 * 端功能对齐审计·功能点矩阵（自动发现"小程序少了什么功能"）：
 * 每个功能点带 App 特征与小程序特征（关键词/组件/API），双端源码扫特征 → 输出矩阵，
 * App ✓ 而小程序 ✗ = 缺口候选。配套 audit-pages.ts（页面）与 audit-endpoints.ts（API）。
 *
 * 用法（仓库根）：
 *   npx tsx scripts/audit-features.ts
 * 退出码 0=无缺口，1=存在缺口候选。
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const root = process.cwd();

function walkFiles(dir: string, ext: RegExp): string[] {
  const out: string[] = [];
  const walk = (d: string) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (ext.test(e.name)) out.push(p);
    }
  };
  if (statSync(dir).isDirectory()) walk(dir);
  return out;
}

function containsAny(paths: string[], keywords: string[]): boolean {
  for (const p of paths) {
    const s = readFileSync(p, 'utf8');
    if (keywords.some((k) => s.includes(k))) return true;
  }
  return false;
}

const appFiles = walkFiles(join(root, 'frontend-flutter', 'lib'), /\.dart$/);
const uniFiles = walkFiles(join(root, 'frontend-uni', 'src'), /\.(vue|ts)$/);

type Feature = { name: string; app: string[]; uni: string[]; expectMissing?: boolean };
const features: Feature[] = [
  { name: 'AI 识别记账', app: ['识别图片', '_parseBytes'], uni: ['uploadAi', 'AI 识别'] },
  { name: '附件查看/上传', app: ['attachment_viewer', 'enqueueAttachmentUpload'], uni: ['attach.show', 'uploadAttach'] },
  { name: '附件删除', app: ['_deleteCurrent'], uni: ['removeAttach', 'deleteAttachment'] },
  { name: '对账单（模板/导出）', app: ['statement_template_page', 'renderTemplateRows'], uni: ['statement', '对账单'] },
  { name: '对账单逐笔舍入口径', app: ['saleTotalOf'], uni: ['roundAmount'], expectMissing: true },
  { name: '同步面板', app: ['sync_panel_page'], uni: ['手动同步'], expectMissing: true },
  { name: '存储清理', app: ['cleanup_page'], uni: ['清理'], expectMissing: true },
  { name: '错误日志', app: ['logs_page'], uni: ['错误日志'], expectMissing: true },
  { name: '更新源设置', app: ['update_sources_page'], uni: ['更新源'], expectMissing: true },
  { name: '两步验证', app: ['totp'], uni: ['totp'] },
  { name: '审计日志', app: ['audit_page'], uni: ['audit'] },
  { name: '备份/恢复', app: ['backup_page'], uni: ['backup'] },
  { name: '设备管理', app: ['devices_page'], uni: ['devices'] },
  { name: '库存预警', app: ['stocks_page'], uni: ['stocks'] },
  { name: '收款账户', app: ['payment_accounts_page'], uni: ['payment-accounts'] },
  { name: '月度卡收入列残留（uni 不应有 mIncome）', app: ['_mIncome'], uni: ['mIncome'], expectMissing: true },
  { name: '记账天数', app: ['记账天数'], uni: ['记账天数'] },
  { name: '成员单入口', app: ["'成员'"], uni: ['账号设置', '成员'] },
  { name: '金额舍入设置', app: ['rounding_settings_page'], uni: ['rounding-settings', 'applyRounding'] },
  { name: 'AI 设置（Key/模型）', app: ['ai_settings_page'], uni: ['ai-settings'] },
];

const rows: Array<{ name: string; app: boolean; uni: boolean; note: string; expectMissing: boolean }> = [];
for (const f of features) {
  const app = containsAny(appFiles, f.app);
  const uni = containsAny(uniFiles, f.uni);
  let note = '';
  if (app && !uni) note = f.expectMissing ? '（预期缺=平台差异/目标态）' : '缺口候选';
  if (!app && uni) note = 'App 特征未中（特征需修正？）';
  rows.push({ name: f.name, app, uni, note, expectMissing: f.expectMissing === true });
}

console.log('功能点矩阵（App vs 小程序）：');
for (const r of rows) {
  console.log(
    `  ${r.app ? '✅' : '❌'} App  ${r.uni ? '✅' : '❌'} 小程序  ${r.name}${r.note ? '  ' + r.note : ''}`,
  );
}
const gaps = rows.filter((r) => r.app && !r.uni && !r.expectMissing);
if (gaps.length) {
  console.log(`\n⚠️ ${gaps.length} 个缺口候选（需人工核对/排期）：`);
  for (const g of gaps) console.log('  - ' + g.name);
  process.exit(1);
}
console.log('\n✅ 无待处理缺口（预期差异已标注）');
process.exit(0);