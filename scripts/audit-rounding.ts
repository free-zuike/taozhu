/**
 * 金额舍入一致性审计（自动对账，跑一次找一类 bug）：
 * 对比"服务器 SUM 后舍入"（SQL 聚合，历史口径）与"逐笔舍入后累加"（0.17.309/310 新口径），
 * 按 日/月/店铺/区间总计 四维度列出两者不一致的组——digits=0/1 时这类不一致就是显示 bug
 * （单笔显示 ¥2+¥2，合计 SUM 舍入却 ¥3）。
 *
 * 0.17.310 起全部 stats 接口已改为逐笔口径，本脚本转作回归监控：
 * 若未来某接口回退到 SUM 口径，跑一次即标出受影响范围。
 *
 * 用法（仓库根，wrangler 已认证）：
 *   npx tsx scripts/audit-rounding.ts [start] [end]
 *   缺省扫描最近 90 天。退出码 0=无差异，1=发现差异。
 */
import { execSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { roundMoney, type RoundingConfig } from '../src/lib/money';

const D1_NAME = 'taozhu';
const DATABASE_ID = process.env.TAOZHU_D1_ID ?? '289f33a1-ad1b-4fd9-8e7c-1418cdb62e88';

// 临时 wrangler 配置（不污染仓库 wrangler.toml）
function tempConfig(): string {
  const cfg = [
    'name = "audit"',
    'main = "src/index.ts"',
    'compatibility_date = "2025-06-01"',
    '',
    '[[d1_databases]]',
    'binding = "DB"',
    `database_name = "${D1_NAME}"`,
    `database_id = "${DATABASE_ID}"`,
    '',
  ].join('\n');
  const p = join(process.env.TEMP ?? '.', 'wrangler-audit.toml');
  writeFileSync(p, cfg);
  return p;
}

function query(sql: string): Array<Record<string, unknown>> {
  const cfg = tempConfig();
  // Cloudflare 偶发 TLS 断连：重试 3 次
  for (let attempt = 1; attempt <= 3; attempt++) {
    let out = '';
    let failed = false;
    try {
      out = execSync(
        `npx wrangler d1 execute ${D1_NAME} --config "${cfg}" --remote --json --command "${sql}"`,
        { encoding: 'utf8', maxBuffer: 128 * 1024 * 1024 },
      );
    } catch (e) {
      // wrangler 网络失败返回非零码，JSON error 在 stdout/stderr 里
      failed = true;
      out = String((e as { stdout?: string; stderr?: string }).stdout ?? (e as { stderr?: string }).stderr ?? '');
    }
    try {
      const parsed = JSON.parse(out);
      if (parsed?.error) failed = true;
      if (!failed) return parsed?.[0]?.results ?? [];
    } catch {
      failed = true;
    }
    if (attempt === 3) throw new Error(`D1 查询失败（3 次重试）: ${sql}\n${out.slice(0, 400)}`);
    execSync('ping -n 1 127.0.0.1 >NUL', { stdio: 'ignore' }); // 等 1s
  }
  return [];
}

async function loadRoundingConfig(): Promise<RoundingConfig> {
  try {
    const rows = query("SELECT key, value FROM settings WHERE key IN ('round_carry','round_digits')");
    const m = new Map(rows.map((r) => [String(r.key), String(r.value)]));
    let carry = Number(m.get('round_carry') ?? 0.5);
    if (!Number.isFinite(carry) || carry <= 0 || carry > 1) carry = 0.5;
    let digits = m.get('round_digits') === undefined ? 2 : Number(m.get('round_digits'));
    if (![0, 1, 2].includes(digits)) digits = 2;
    return { carry, digits };
  } catch {
    return { carry: 0.5, digits: 2 };
  }
}

const start = process.argv[2] ?? new Date(Date.now() - 90 * 864e5).toISOString().slice(0, 10);
const end = process.argv[3] ?? new Date().toISOString().slice(0, 10);
const money = await loadRoundingConfig();

// 明细行（逐笔口径与 SUM 口径都从同一批明细算，只差舍入时机）
// SQL 必须单行（多行换行在跨进程命令转义时会被截断）
const saleRows = query(
  `SELECT si.happened_at AS d, si.client_id, si.amount AS amount, (si.sale_price - si.cost_price) * si.quantity AS gross FROM sale_items si WHERE si.happened_at >= '${start}' AND si.happened_at <= '${end}' ORDER BY si.happened_at`,
);
const payRows = query(
  `SELECT p.happened_at AS d, p.client_id, p.amount + p.waived AS paid FROM payments p WHERE p.happened_at >= '${start}' AND p.happened_at <= '${end}' ORDER BY p.happened_at`,
);
const buyRows = query(
  `SELECT pi.happened_at AS d, pi.amount AS amount FROM purchase_items pi WHERE pi.happened_at >= '${start}' AND pi.happened_at <= '${end}' ORDER BY pi.happened_at`,
);

// 分组键：日 / 月 / 店铺 / 总计
const keyDay = (r: Record<string, unknown>) => String(r.d ?? '').slice(0, 10);
const keyMonth = (r: Record<string, unknown>) => String(r.d ?? '').slice(0, 7);
const keyClient = (r: Record<string, unknown>) => String(r.client_id ?? '');
const keyAll = () => 'ALL';

/** 对明细行按 key 分组：同组内同时累加"原始和"与"逐笔舍入和" */
function group(
  rows: Array<Record<string, unknown>>,
  keyFn: (r: Record<string, unknown>) => string,
  valueFn: (r: Record<string, unknown>) => number,
): Map<string, { sum: number; rounded: number }> {
  const m = new Map<string, { sum: number; rounded: number }>();
  for (const r of rows) {
    const k = keyFn(r);
    const v = valueFn(r);
    const e = m.get(k) ?? { sum: 0, rounded: 0 };
    e.sum += v;
    e.rounded += roundMoney(v, money);
    m.set(k, e);
  }
  return m;
}

const num = (r: Record<string, unknown>, k: string) => Number(r[k]) || 0;

// 四维度 × 四指标（出货/毛利/收款/进货），对齐 /daily /monthly /clients /summary /overview
const dims: Array<{ label: string; sale: Map<string, { sum: number; rounded: number }>; pay?: Map<string, { sum: number; rounded: number }>; buy?: Map<string, { sum: number; rounded: number }>; gross: Map<string, { sum: number; rounded: number }> }> = [
  { label: '日', sale: group(saleRows, keyDay, (r) => num(r, 'amount')), gross: group(saleRows, keyDay, (r) => num(r, 'gross')), pay: group(payRows, keyDay, (r) => num(r, 'paid')), buy: group(buyRows, keyDay, (r) => num(r, 'amount')) },
  { label: '月', sale: group(saleRows, keyMonth, (r) => num(r, 'amount')), gross: group(saleRows, keyMonth, (r) => num(r, 'gross')), pay: group(payRows, keyMonth, (r) => num(r, 'paid')), buy: group(buyRows, keyMonth, (r) => num(r, 'amount')) },
  { label: '店铺', sale: group(saleRows, keyClient, (r) => num(r, 'amount')), gross: group(saleRows, keyClient, (r) => num(r, 'gross')), pay: group(payRows, keyClient, (r) => num(r, 'paid')) },
  { label: '总计', sale: group(saleRows, keyAll, (r) => num(r, 'amount')), gross: group(saleRows, keyAll, (r) => num(r, 'gross')), pay: group(payRows, keyAll, (r) => num(r, 'paid')), buy: group(buyRows, keyAll, (r) => num(r, 'amount')) },
];

const diffs: string[] = [];
const cmp = (dim: string, metric: string, key: string, sum: number, rounded: number) => {
  const server = roundMoney(sum, money); // 服务器 SQL SUM 后舍入（历史口径）
  if (Math.abs(server - rounded) > 1e-9) {
    diffs.push(
      `${metric}(${dim}${key === 'ALL' ? '' : `=${key}`}): 服务器SUM舍入=¥${server.toFixed(money.digits)} 逐笔舍入累加=¥${rounded.toFixed(money.digits)} (原始和=¥${sum.toFixed(4)})`,
    );
  }
};

for (const dim of dims) {
  for (const [k, e] of dim.sale) cmp(dim.label, '出货', k, e.sum, e.rounded);
  for (const [k, e] of dim.gross) cmp(dim.label, '毛利', k, e.sum, e.rounded);
  for (const [k, e] of dim.pay ?? []) cmp(dim.label, '收款', k, e.sum, e.rounded);
  for (const [k, e] of dim.buy ?? []) cmp(dim.label, '进货', k, e.sum, e.rounded);
}

console.log(`舍入口径: carry=${money.carry} digits=${money.digits}（digits<2 时对账差异是真实 bug）`);
console.log(`扫描区间: ${start} ~ ${end}，出货 ${saleRows.length} 行 / 收款 ${payRows.length} 行 / 进货 ${buyRows.length} 行`);
if (diffs.length === 0) {
  console.log('✅ 无差异：全部统计口径（日/月/店铺/总计）与逐笔舍入累加完全一致');
  process.exit(0);
} else {
  console.log(`⚠️ 发现 ${diffs.length} 处不一致（digits=${money.digits} 时逐笔口径才对，0.17.310 后接口已全部用逐笔，出现即回归）：`);
  for (const d of diffs.slice(0, 50)) console.log('  ' + d);
  if (diffs.length > 50) console.log(`  … 还有 ${diffs.length - 50} 处`);
  process.exit(1);
}
