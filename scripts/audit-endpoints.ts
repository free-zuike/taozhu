/**
 * 端功能对齐审计·API 端点差集（自动发现"小程序少了什么功能"）：
 * ① 从 index.ts 提取路由挂载（prefix ↔ router 变量）
 * ② 从各 router 文件提取全部后端端点
 * ③ 分别提取 App（Api.instance.*）与小程序（request()）实际调用的端点
 * ④ 归一化（数字/模板段 → :id）后取差集：后端有、App 在用、小程序未调 = 功能缺口候选。
 *
 * 用法（仓库根）：
 *   npx tsx scripts/audit-endpoints.ts
 * 退出码 0=小程序覆盖全部 App 调用端点，1=存在缺口候选。
 */
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const root = process.cwd();
const routesDir = join(root, 'src', 'routes');
const indexTs = readFileSync(join(root, 'src', 'index.ts'), 'utf8');

/** 归一化端点：数字段 / ${} 模板段 → :id（/sales/123 → /sales/:id） */
function norm(p: string): string {
  return p
    .split('/')
    .filter(Boolean)
    .map((seg) => (/^\$\{/.test(seg) || /^\d+$/.test(seg) ? ':id' : seg))
    .join('/');
}

/** 从 .ts 源码提取路由注册端点（Hono：.get('. ..' 或 ('..'），含挂载路径本身） */
function extractEndpoints(src: string): string[] {
  const out: string[] = [];
  const re = /\.(get|post|patch|put|delete)\(\s*['"]([^'"]*)['"]/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(src)) !== null) {
    const p = m[2].trim();
    if (p.startsWith('/')) out.push(p);
  }
  return out;
}

/** 前端调用端点（App: Api.instance.*('/..')；uni: request('/..', ...)） */
function extractCalls(src: string, pattern: RegExp): string[] {
  const out: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = pattern.exec(src)) !== null) {
    // 去掉 query / 尾部模板碎片：取字符串内第一段路径（/sales?x → /sales；/sales/${id} → /sales）
    const raw = m[1].split('?')[0];
    out.push(raw.split('$').shift() ?? raw);
  }
  return out;
}

// ── ① 路由映射：/api/v1/sales ↔ salesRouter ──
const routeRe = /app\.route\(\s*['"]\/api\/v1\/([\w-]+)['"]\s*,\s*(\w+)/g;
const prefixByRouter = new Map<string, string>();
let rm: RegExpExecArray | null;
while ((rm = routeRe.exec(indexTs)) !== null) {
  prefixByRouter.set(rm[2], `/${rm[1]}`);
}

// ── ② 后端端点全集（含路由根 '/'）──
const backendPts = new Set<string>();
for (const f of readdirSync(routesDir).filter((x) => x.endsWith('.ts'))) {
  const src = readFileSync(join(routesDir, f), 'utf8');
  const varName = (f.replace(/_router\.ts$/, '') + 'Router').replace(/\.ts$/, 'Router');
  const prefix = prefixByRouter.get(varName);
  // 变量名推断可能失败（如 stats.ts → statsRouter），用 index.ts 的 router 变量集合兜底
  const real = [...prefixByRouter.entries()].find(([, p]) => src.includes(`Router`) && p === `/${f.replace(/\.ts$/, '')}`)?.[0];
  const routerVar = prefixByRouter.has(varName)
    ? varName
    : (real ?? (src.includes('Router') ? varName : null));
  const base = prefix ?? `/${f.replace(/\.ts$/, '')}`;
  for (const ep of extractEndpoints(src)) {
    backendPts.add(norm(base + (ep === '/' ? '' : ep)));
  }
}

// ── ③ 双端调用集 ──
function collectCalls(dir: string, pattern: RegExp): Set<string> {
  const set = new Set<string>();
  const walk = (d: string) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (/\.(dart|ts|vue)$/.test(e.name)) {
        for (const c of extractCalls(readFileSync(p, 'utf8'), pattern)) {
          if (c.startsWith('/')) set.add(norm(c));
        }
      }
    }
  };
  walk(dir);
  return set;
}

const appCalls = collectCalls(join(root, 'frontend-flutter', 'lib'), /Api\.instance\.(?:get|post|patch|delete|put)\(\s*['"`]([^'"`]+)/g);
const uniCalls = collectCalls(join(root, 'frontend-uni', 'src'), /request\b[^(]*\(\s*['"`]([^'"`]+)/g);

// ── ④ 差异 ──
const appBackend = [...appCalls].filter((p) => backendPts.has(p));
const uniBackend = [...uniCalls].filter((p) => backendPts.has(p));
const appOnly = [...appBackend].filter((p) => !uniBackend.includes(p));

// 人工核实的差异归类：平台差异（小程序直连无本地库/微信分发，App 特有）vs 待核对（潜在真缺口）
const knownGap: Record<string, string> = {
  'sync/full': '平台差异：小程序直连无本地库',
  'sync/pull': '平台差异：小程序直连无本地库',
  'sync/push': '平台差异：小程序直连无本地库',
  'sync/stats': '平台差异：小程序直连无本地库',
  'auth/latest-version': '平台差异：更新检查由微信分发',
  'me/download-sources': '平台差异：App 安装更新源探测',
  'me/probe-source': '平台差异：App 安装更新源探测',
  'attachments/in-use': '平台差异：App 本地库在用引用扫描',
  'attachments/orphans': '平台差异：App 本地库孤儿扫描',
  'attachments/total': '平台差异：App 本地同步管理统计',
  'stocks/rebuild': '平台差异：App 库存重算管理操作',
  'backup/auto': '待核对：小程序备份自动备份是否实现',
  'backup/import': '待核对：小程序备份导入是否实现',
  'ai/parse-text': '待核对：小程序 AI 识别端点路径',
  'payment-accounts/stats': '待核对：小程序账户统计是否实现',
  share: '待核对：小程序对账单分享是否实现',
};

const expectedGaps: string[] = [];
const realGaps: Array<{ ep: string; note: string }> = [];
for (const ep of appOnly) {
  const note = knownGap[ep];
  if (note && note.includes('平台差异')) expectedGaps.push(`${ep}（${note}）`);
  else realGaps.push({ ep, note: note ?? '' });
}

console.log(`后端端点 ${backendPts.size} 个 | App 调用 ${appBackend.length} | 小程序调用 ${uniBackend.length}`);
if (realGaps.length === 0 && expectedGaps.length === 0) {
  console.log('✅ 小程序覆盖了 App 的全部后端调用（端点差集为空）');
  process.exit(0);
}
if (expectedGaps.length > 0) {
  console.log(`\nℹ️ 预期平台差异（${expectedGaps.length}，小程序直连无本地库/微信分发，不处理）：`);
  for (const g of expectedGaps) console.log('  - ' + g);
}
if (realGaps.length > 0) {
  console.log(`\n⚠️ 小程序未调用的端点（${realGaps.length}）——待人工核对：`);
  for (const g of realGaps) console.log('  - ' + g.ep + (g.note ? '（' + g.note + '）' : ''));
  process.exit(1);
}
console.log('\n✅ 无待核对缺口（仅预期平台差异）');
process.exit(0);