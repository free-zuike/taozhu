/**
 * 端功能对齐审计（自动发现"小程序少了什么"）：
 * 对比 App 页面清单（frontend-flutter/lib/pages/*.dart）与小程序页面清单（frontend-uni/src/pages.json），
 * 列出"App 有而小程序无"与"小程序有而 App 无"的页面级差异，供功能对齐排期。
 *
 * 用法（仓库根）：
 *   npx tsx scripts/audit-pages.ts
 * 退出码 0=页面级无差异，1=存在差异。
 */
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const root = process.cwd();
const appPagesDir = join(root, 'frontend-flutter', 'lib', 'pages');
const uniPagesJson = join(root, 'frontend-uni', 'src', 'pages.json');

/** 归一化：小写 + 去下划线/连字符（App 用 sale_page/下划线，小程序用 pages/sale/sale/连字符） */
const norm = (s: string) => s.toLowerCase().replace(/[-_]/g, '');

/** App 页面文件 → 归一化名（sale_page.dart → sale） */
function appPages(): string[] {
  return readdirSync(appPagesDir)
    .filter((f) => f.endsWith('.dart') && !f.startsWith('router.'))
    .map((f) => f.replace(/_page\.dart$/, '').replace(/\.dart$/, ''));
}

/** 小程序 pages.json → 归一化名（pages/sale/sale → sale） */
function uniPages(): string[] {
  const json = JSON.parse(readFileSync(uniPagesJson, 'utf8')) as { pages: Array<{ path: string }> };
  return (json.pages ?? []).map((p) => p.path.split('/').pop() ?? '').filter(Boolean);
}

const app = [...new Set(appPages())].sort();
const uni = [...new Set(uniPages())].sort();

const appOnly = app.filter((a) => !uni.some((u) => norm(u) === norm(a)));
const uniOnly = uni.filter((u) => !app.some((a) => norm(a) === norm(u)));

// 归一化不保证语义等价（如 app 的 statement_template_page 在小程序里可能是 statement.vue 的子能力）——
// 输出后需按功能核对，勿把"页面名不同"直接当"缺功能"。
const diffs: string[] = [];
if (appOnly.length > 0) {
  diffs.push(`App 有而小程序无页面（${appOnly.length}）：\n  ${appOnly.join('\n  ')}`);
}
if (uniOnly.length > 0) {
  diffs.push(`小程序有而 App 无页面（${uniOnly.length}）：\n  ${uniOnly.join('\n  ')}`);
}

console.log(`App 页面 ${app.length} 个，小程序页面 ${uni.length} 个`);
if (diffs.length === 0) {
  console.log('✅ 页面清单一致（页面级无差异）');
  process.exit(0);
}
console.log(diffs.join('\n\n'));
process.exit(1);
