<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="card">
      <picker class="field" mode="selector" :range="clientNames" @change="onClient">
        <view class="field-inner">
          <text class="label">店铺</text>
          <text class="value">{{ clientName }}</text>
        </view>
      </picker>

      <view class="seg">
        <view :class="['seg-item', { active: period === 'month' }]" @click="applyPeriod('month')">本月</view>
        <view :class="['seg-item', { active: period === 'last' }]" @click="applyPeriod('last')">上月</view>
      </view>

      <view class="dates">
        <picker class="ipt" mode="date" fields="month" :value="from.slice(0, 7)" @change="onFrom">
          <view class="date-pick">{{ from.slice(0, 7) }}</view>
        </picker>
        <text class="to">至</text>
        <picker class="ipt" mode="date" fields="month" :value="to.slice(0, 7)" @change="onTo">
          <view class="date-pick">{{ to.slice(0, 7) }}</view>
        </picker>
      </view>

      <button class="btn-save" :disabled="loading" @click="load">{{ loading ? '生成中…' : '生成对账单' }}</button>

      <view v-if="loaded">
        <!-- 模板切换（对齐 App 内置模板：标准 / 多栏） -->
        <view class="seg tpl-seg">
          <view :class="['seg-item', { active: tpl === 'std' }]" @click="tpl = 'std'">标准</view>
          <view :class="['seg-item', { active: tpl === 'multi' }]" @click="tpl = 'multi'">多栏</view>
        </view>
        <!-- 标准模板：标题 + 按日分组明细 + 旬段小计 -->
        <view v-if="tpl === 'std'" class="card stmt-tbl">
          <view class="t-title">{{ clientName }} {{ from.slice(5, 7) }}月份账单</view>
          <view class="t-sub">{{ from }} 至 {{ to }}</view>
          <view class="t-head">
            <text class="c-date">日期</text>
            <text class="c-detail">摘要</text>
            <text class="c-amt">金额</text>
          </view>
          <view v-for="g in dayGroups" :key="g.day" class="t-group">
            <view class="t-day">
              <text class="t-day-label">{{ g.label }}</text>
              <text class="t-day-total">小计 ¥{{ stmtFmt(g.total) }}</text>
            </view>
            <view v-for="(l, i) in g.rows" :key="i" class="t-row">
              <text class="c-date">{{ l.date.slice(5) }}</text>
              <text class="c-detail" :class="{ 't-pay': l.kind === 'pay' }">{{ l.kind === 'pay' ? '收·' + l.detail : l.detail }}</text>
              <text class="c-amt">{{ l.kind === 'pay' ? '−¥' + stmtFmt(l.amount) : '¥' + stmtFmt(l.amount) }}</text>
            </view>
          </view>
          <!-- 旬段小计（对齐 App：1-10 / 11-20 / 21 日以后） -->
          <view class="t-total"><text>1-10 日合计</text><text>¥{{ stmtFmt(segTotal(1, 10)) }}</text></view>
          <view class="t-total"><text>11-20 日合计</text><text>¥{{ stmtFmt(segTotal(11, 20)) }}</text></view>
          <view class="t-total"><text>21 日以后合计</text><text>¥{{ stmtFmt(segTotal(21, 31)) }}</text></view>
          <view class="t-total"><text>出货合计</text><text>¥{{ stmtFmt(saleTotal) }}（{{ sales.length }} 笔）</text></view>
          <view class="t-total"><text>收款合计</text><text>¥{{ stmtFmt(payTotal) }}（{{ payments.length }} 笔）</text></view>
          <view class="t-total"><text>期末欠款</text><text :class="debt > 0 ? 'red' : 'green'">¥{{ stmtFmt(debt) }}</text></view>
        </view>
        <!-- 多栏模板：寻牛记式每栏 10 天（日期+营业额 双列，栏底小计，底部总计；对齐 App 多栏月账单） -->
        <view v-if="tpl === 'multi'" class="card stmt-tbl">
          <view class="t-title">{{ clientName }} {{ from.slice(5, 7) }}月份账单</view>
          <view class="m-row m-head">
            <view v-for="ci in multi.cols" :key="ci" class="m-col">
              <text class="m-date">日期</text><text class="m-amt">营业额</text>
            </view>
          </view>
          <view v-for="(row, ri) in multi.rows" :key="ri" class="m-row">
            <view v-for="(cell, ci) in row" :key="ci" class="m-col">
              <text class="m-date">{{ cell.day ? multi.y + '.' + multi.m + '.' + cell.day : '' }}</text>
              <text class="m-amt">{{ cell.amt }}</text>
            </view>
          </view>
          <view class="m-row m-sub">
            <view v-for="(s, ci) in multi.subtotals" :key="ci" class="m-col">
              <text class="m-date"></text><text class="m-amt bold">{{ s }}</text>
            </view>
          </view>
          <view class="m-total"><text>总计</text><text class="bold">{{ multi.grand }}</text></view>
        </view>
        <view class="stat"><text>出货合计</text><text class="red">¥{{ stmtFmt(saleTotal) }}（{{ sales.length }} 笔）</text></view>
        <view class="stat"><text>收款合计</text><text class="green">¥{{ stmtFmt(payTotal) }}（{{ payments.length }} 笔）</text></view>
        <view class="stat"><text>期末欠款（累计）</text><text :class="debt > 0 ? 'red' : 'green'">¥{{ stmtFmt(debt) }}</text></view>
        <button class="btn-copy" @click="copy">复制对账文本</button>
        <button class="btn-copy" @click="copyCsv">复制 CSV（粘到 Excel）</button>
        <button class="btn-copy" @click="share">分享对账单（生成链接）</button>
        <button class="btn-copy" @click="manageShares">我的分享</button>
        <button class="btn-copy" @click="printStmt">打印（生成打印页，浏览器打开）</button>
      </view>
    </view>

    <!-- 我的分享管理（对齐 App：列表 + 延期 + 删除） -->
    <view v-if="shareDlg" class="mask" @click="shareDlg = false">
      <view class="sheet" @click.stop>
        <text class="s-title">我的分享</text>
        <view v-if="shares.length === 0" class="empty">暂无分享</view>
        <scroll-view scroll-y class="share-list">
          <view v-for="s in shares" :key="s.token" class="share-row">
            <view class="share-info">
              <text class="share-url">{{ s.url }}</text>
              <text class="share-exp">过期：{{ s.expires_at || '永久' }}</text>
            </view>
            <text class="share-op" @click="extendShare(s)">延期</text>
            <text class="share-op del" @click="delShare(s)">删除</text>
          </view>
        </scroll-view>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { onShow, onHide } from '@dcloudio/uni-app';
import { onWs, offWs } from '../../ws';

import { useThemeVars, utf8ToBase64 } from '../../theme';
const { tv, patternSrc } = useThemeVars();
import { ref, computed } from 'vue';
;
;
import { request, getToken, getApiBase } from '../../api';
import { roundAmount, fmtAmount, fmtByUnit, initRounding } from '../../utils/money';

const clients = ref<Array<{ id: string; name: string; round_stage?: string; round_unit?: string }>>([]);
const clientNames = ref<string[]>(['全部店铺']);
const clientName = ref('全部店铺');
let clientId = '';

// 对账单模板（对齐 App 内置模板切换）：标准=按日明细表；多栏=每栏 10 天的寻牛记式月账单
const tpl = ref<'std' | 'multi'>('std');

/// 当前店铺抹零显示精度：只有选了抹零（每单/按天/结账）才按精度；不抹零=实际金额（全局口径）
const roundUnit = computed(() => {
  const c = clients.value.find((x) => x.id === clientId);
  const stage = String(c?.round_stage || 'none');
  if (stage !== 'txn' && stage !== 'day' && stage !== 'total') return '';
  return String(c?.round_unit || '');
});

/// 对账单金额显示（对齐 App 按店铺抹零方式：不抹零=fmtAmount；抹零=fmtByUnit）
const stmtFmt = (v: number) => (roundUnit.value ? fmtByUnit(v, roundUnit.value) : fmtAmount(v));

/// 多栏月账单：每日营业额（出货，不含收款）→ 每栏 10 天平铺 + 栏底小计 + 总计
const dailyAmt = computed(() => {
  const days: number[] = [];
  for (const s of sales.value) {
    const d = String(s.happened_at || '').slice(0, 10);
    if (d.length < 10) continue;
    const day = Number(d.slice(8, 10));
    days[day] = (days[day] || 0) + roundAmount(Number(s.amount ?? s.total) || 0);
  }
  return days; // 下标即日号 1..31
});

function monthDays(y: number, m: number): number {
  return new Date(y, m, 0).getDate();
}

const multi = computed(() => {
  const y = Number(from.value.slice(0, 4)) || new Date().getFullYear();
  const m = Number(from.value.slice(5, 7)) || new Date().getMonth() + 1;
  const n = from.value ? monthDays(y, m) : 31;
  const cols = Math.max(1, Math.ceil(n / 10));
  const rows: Array<Array<{ day: number; amt: string }>> = [];
  for (let r = 0; r < 10; r++) {
    const cells: Array<{ day: number; amt: string }> = [];
    for (let c = 0; c < cols; c++) {
      const day = c * 10 + r + 1;
      cells.push({
        day: day <= n ? day : 0,
        amt: day <= n ? String(roundAmount(dailyAmt.value[day] || 0).toFixed(roundUnit.value === 'yuan' ? 0 : roundUnit.value === 'jiao' ? 1 : 2)) : '',
      });
    }
    rows.push(cells);
  }
  const subtotals: string[] = [];
  let grand = 0;
  for (let c = 0; c < cols; c++) {
    let s = 0;
    for (let dd = c * 10; dd < (c + 1) * 10 && dd < n; dd++) s += dailyAmt.value[dd + 1] || 0;
    grand += s;
    subtotals.push(roundAmount(s).toFixed(roundUnit.value === 'yuan' ? 0 : roundUnit.value === 'jiao' ? 1 : 2));
  }
  return { y, m, cols, rows, subtotals, grand: roundAmount(grand).toFixed(roundUnit.value === 'yuan' ? 0 : roundUnit.value === 'jiao' ? 1 : 2) };
});

const period = ref<'month' | 'last' | 'custom'>('month');
const from = ref('');
const to = ref('');
const loading = ref(false);
const loaded = ref(false);
const sales = ref<Array<Record<string, any>>>([]);
const payments = ref<Array<Record<string, any>>>([]);
const debt = ref(0);

const saleTotal = ref(0);
const payTotal = ref(0);

/// 对账单表格数据（对齐 App 标准模板：按日分组出货/收款明细 + 每日小计）
const dayGroups = computed(() => {
  type Row = { date: string; detail: string; amount: number; kind: 'sale' | 'pay' };
  type Group = { day: string; label: string; total: number; rows: Row[] };
  const map = new Map<string, Group>();
  const push = (date: unknown, detail: string, amount: unknown, kind: 'sale' | 'pay') => {
    const d = String(date || '').slice(0, 10);
    if (d.length < 10) return;
    const g = map.get(d) || { day: d, label: '', total: 0, rows: [] };
    g.total += roundAmount(Number(amount) || 0);
    g.rows.push({ date: d, detail, amount: Number(amount) || 0, kind });
    map.set(d, g);
  };
  for (const s of sales.value) {
    const detail = s.item_name
      ? `${s.item_name}${s.quantity ?? ''}${s.unit ?? ''}${s.client_name ? ' ' + s.client_name : ''}`
      : (s.client_name || '出货');
    push(s.happened_at, detail, s.amount ?? s.total, 'sale');
  }
  for (const p of payments.value) {
    push(p.happened_at,
      `${p.client_name || ''}${p.method ? ' ' + p.method : ''}${Number(p.waived) > 0 ? '（平账 ' + fmtAmount(p.waived) + '）' : ''}`,
      p.amount, 'pay');
  }
  const list = [...map.values()].sort((a, b) => a.day.localeCompare(b.day));
  const WEEKS = ['日', '一', '二', '三', '四', '五', '六'];
  for (const g of list) {
    const dt = new Date(`${g.day}T00:00:00`);
    g.label = `${Number(g.day.slice(5, 7))}月${Number(g.day.slice(8, 10))}日 周${WEEKS[dt.getDay()]}`;
  }
  return list;
});

/// 旬段小计（1-10 / 11-20 / 21 日以后；对齐 App 旬段合计）
const segTotal = (from: number, to: number) =>
  dayGroups.value
    .filter((g) => {
      const d = Number(g.day.slice(8, 10));
      return d >= from && d <= to;
    })
    .reduce((s, g) => s + g.total, 0);

onShow(async () => {
  onWs('*', load);
  initRounding(); // 进入先刷新本地舍入配置（防服务器已舍入值被本地旧配置二次进位）
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  applyPeriod('month');
  try {
    const d = await request<{ clients: Array<{ id: string; name: string }> }>('/clients', 'GET');
    clients.value = d.clients;
    clientNames.value = ['全部店铺', ...d.clients.map((c) => c.name)];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
});

function today(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/// 年月直接选择（对齐"直接选年月"）：开始月=该月 1 号，结束月=该月最后一天
function onFrom(e: { detail: { value: string } }) {
  const v = e.detail.value; // YYYY-MM
  if (!v) return;
  from.value = `${v}-01`;
  const end = monthEnd(v);
  if (!to.value || to.value.slice(0, 7) < v) to.value = end;
  period.value = 'custom';
}
function onTo(e: { detail: { value: string } }) {
  const v = e.detail.value;
  if (!v) return;
  to.value = monthEnd(v);
  if (!from.value || from.value.slice(0, 7) > v) from.value = `${v}-01`;
  period.value = 'custom';
}
function monthEnd(ym: string): string {
  const [y, m] = ym.split('-').map(Number);
  const last = new Date(y, m, 0).getDate();
  return `${y}-${String(m).padStart(2, '0')}-${String(last).padStart(2, '0')}`;
}

function applyPeriod(p: 'month' | 'last') {
  period.value = p;
  const now = new Date();
  const p2 = (n: number) => String(n).padStart(2, '0');
  if (p === 'last') {
    const first = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    const last = new Date(now.getFullYear(), now.getMonth(), 0);
    from.value = `${first.getFullYear()}-${p2(first.getMonth() + 1)}-${p2(first.getDate())}`;
    to.value = `${last.getFullYear()}-${p2(last.getMonth() + 1)}-${p2(last.getDate())}`;
  } else {
    from.value = `${now.getFullYear()}-${p2(now.getMonth() + 1)}-01`;
    to.value = today();
  }
}

function onClient(e: { detail: { value: number } }) {
  const idx = e.detail.value;
  if (idx <= 0) { clientId = ''; clientName.value = '全部店铺'; return; }
  const c = clients.value[idx - 1];
  if (c) { clientId = c.id; clientName.value = c.name; }
}

async function load() {
  if (!from.value || !to.value) {
    uni.showToast({ title: '请选择起止日期', icon: 'none' });
    return;
  }
  loading.value = true;
  try {
    const cid = clientId ? `&client_id=${clientId}` : '';
    const results = await Promise.all([
      request<{ sales: any[]; sale_items?: any[] }>(`/sales?date_from=${from.value}&date_to=${to.value}&limit=1000${cid}`, 'GET'),
      request<{ payments: any[] }>(`/payments?date_from=${from.value}&date_to=${to.value}&limit=1000${cid}`, 'GET'),
      request<{ debt: number }>(`/stats/summary?start=${from.value}&end=${to.value}${cid}`, 'GET'),
    ]);
    // 去单据化主结构：优先行级 sale_items（每条商品一行，出货明细=商品行），否则整单嵌套兼容
    const saleItems = results[0].sale_items;
    sales.value = (saleItems && saleItems.length > 0) ? saleItems : (results[0].sales || []);
    payments.value = results[1].payments;
    debt.value = Number(results[2].debt || 0);
    saleTotal.value = sales.value.reduce((s, x) => s + roundAmount(Number((x.amount ?? x.total) || 0)), 0);
    payTotal.value = payments.value.reduce((s, x) => s + roundAmount(Number(x.amount || 0)), 0);
    loaded.value = true;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '生成失败', icon: 'none' });
  } finally {
    loading.value = false;
  }
}

function copy() {
  if (!loaded.value) {
    uni.showToast({ title: '请先生成对账单', icon: 'none' });
    return;
  }
  const lines: string[] = [
    '【陶朱对账单】',
    `客户：${clientName.value}`,
    `周期：${from.value} 至 ${to.value}`,
    `出货合计：¥${fmtAmount(saleTotal.value)}（${sales.value.length} 笔）`,
    `收款合计：¥${fmtAmount(payTotal.value)}（${payments.value.length} 笔）`,
    `期末欠款：¥${fmtAmount(debt.value)}`,
    '—— 出货明细 ——',
  ];
  for (const s of sales.value) lines.push(`${s.happened_at} ${s.item_name || '出货'} ¥${fmtAmount(Number((s.amount ?? s.total) || 0))}`);
  lines.push('—— 收款明细 ——');
  for (const p of payments.value) {
    lines.push(`${p.happened_at}${p.method ? ' ' + p.method : ''} ¥${fmtAmount(Number(p.amount || 0))}`);
  }
  uni.setClipboardData({ data: lines.join('\n') });
  uni.showToast({ title: '对账文本已复制', icon: 'success' });
}

/// CSV 字段转义：含逗号/引号/换行的加引号包裹
function csv(v: unknown): string {
  const s = String(v ?? '');
  return s.includes(',') || s.includes('"') || s.includes('\n') ? `"${s.replaceAll('"', '""')}"` : s;
}

function copyCsv() {
  if (!loaded.value) {
    uni.showToast({ title: '请先生成对账单', icon: 'none' });
    return;
  }
  const lines: string[] = ['\uFEFF类型,日期,店铺,金额,明细'];
  for (const s of sales.value) {
    // 行级主结构：该行即一条商品（item_name×qty）；整单兼容：items 数组拼明细
    const rowAmount = Number((s.amount ?? s.total) || 0);
    const rowDetail = s.item_name
        ? `${s.item_name}${s.quantity ?? ''}${s.unit ?? ''}`
        : ((s.items || []).map((it: Record<string, any>) => `${it.item_name}${it.quantity}${it.unit}`).join(';'));
    lines.push(`出货,${csv(s.happened_at)},${csv(s.client_name)},${csv(rowAmount)},${csv(rowDetail)}`);
  }
  for (const p of payments.value) {
    lines.push(`收款,${csv(p.happened_at)},${csv(p.client_name)},${csv(p.amount)},${csv(p.method)}`);
  }
  uni.setClipboardData({ data: lines.join('\n') });
  uni.showToast({ title: 'CSV 已复制（带表头）', icon: 'success' });
}

// 打印对账单：构造行集（标题+汇总+出货/收款明细）→ base64 → 服务端 /print/template 渲染打印页
// （对齐 App：服务端自包含 HTML + 自动打印；小程序无法直接唤浏览器，复制链接后用户浏览器打开打印）
async function printStmt() {
  if (!loaded.value) {
    uni.showToast({ title: '请先生成对账单', icon: 'none' });
    return;
  }
  const rows: unknown[] = [
    [['对账单', 'center', true, '', 1, 4]],
    [['店铺', 'left', true, '', 1, 1], [clientName.value, 'left', false, '', 1, 3]],
    [['周期', 'left', true, '', 1, 1], [`${from.value} 至 ${to.value}`, 'left', false, '', 1, 3]],
  ];
  // 出货明细
  rows.push([['出货明细', 'left', true, 'grey', 1, 4]]);
  rows.push([['日期', 'left', true, '', 1, 1], ['商品/店铺', 'left', true, '', 1, 2], ['金额', 'right', true, '', 1, 1]]);
  for (const s of sales.value) {
    const name = s.item_name ? `${s.item_name}${s.quantity ?? ''}${s.unit ?? ''} ${s.client_name || ''}` : (s.client_name || '出货');
    rows.push([['', '', false, '', 1, 1], [name, 'left', false, '', 1, 2], [fmtAmount(Number((s.amount ?? s.total) || 0)), 'right', false, '', 1, 1]]);
  }
  // 收款明细
  rows.push([['收款明细', 'left', true, 'grey', 1, 4]]);
  rows.push([['日期', 'left', true, '', 1, 1], ['店铺/方式', 'left', true, '', 1, 2], ['金额', 'right', true, '', 1, 1]]);
  for (const p of payments.value) {
    rows.push([['', '', false, '', 1, 1], [`${p.client_name || ''}${p.method ? ' ' + p.method : ''}`, 'left', false, '', 1, 2], [fmtAmount(Number(p.amount || 0)), 'right', false, '', 1, 1]]);
  }
  // 汇总
  rows.push([['出货合计', 'left', true, '', 1, 1], [`¥${fmtAmount(saleTotal.value)}（${sales.value.length} 笔）`, 'left', false, '', 1, 3]]);
  rows.push([['收款合计', 'left', true, '', 1, 1], [`¥${fmtAmount(payTotal.value)}（${payments.value.length} 笔）`, 'left', false, '', 1, 3]]);
  rows.push([['期末欠款', 'left', true, '', 1, 1], [`¥${fmtAmount(debt.value)}`, 'left', false, '', 1, 3]]);

  const rowsJson = JSON.stringify(rows);
  // base64url（UTF-8 → base64 → base64url，与 App 一致；小程序无 btoa/TextEncoder，用 theme 自实现）
  const b64 = utf8ToBase64(rowsJson).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const token = getToken() || '';
  const base = getApiBase();
  const title = encodeURIComponent(`${clientName.value} 对账单`);
  const url = `${base}/api/v1/print/template?title=${title}&rows=${b64}&token=${token}${clientId ? `&client_id=${clientId}` : ''}`;
  uni.setClipboardData({
    data: url,
    success: () => uni.showModal({
      title: '打印页链接已复制',
      content: '请用浏览器打开该链接，页面会自动弹出打印（可另存为 PDF）。\n已复制到剪贴板。',
      showCancel: false,
    }),
  });
}

type ShareItem = { token: string; url?: string; expires_at?: string; created_at?: string };
const shares = ref<ShareItem[]>([]);
const shareDlg = ref(false);

/// 分享对账单：选失效时间 → POST /share 生成链接 → 复制（对齐 App：对方浏览器打开即可查看）
async function share() {
  if (!loaded.value) {
    uni.showToast({ title: '请先生成对账单', icon: 'none' });
    return;
  }
  const ttlOptions: Array<[string, number]> = [['3 天', 72], ['7 天', 168], ['1 个月', 720], ['永久', 0]];
  uni.showActionSheet({
    itemList: ttlOptions.map((o) => o[0]),
    success: async (r) => {
      const ttl = ttlOptions[r.tapIndex]?.[1] ?? 0;
      const payload = JSON.stringify({
        client: clientName.value,
        from: from.value,
        to: to.value,
        debt: debt.value,
        sales: sales.value.map((s) => ({
          date: s.happened_at,
          name: s.client_name || clientName.value,
          items: s.item_name
            ? `${s.item_name}${s.quantity ?? ''}${s.unit ?? ''}`
            : ((s.items || []).map((it: Record<string, any>) => `${it.item_name} ×${it.quantity}${it.unit}`).join('、')),
          amount: Number((s.amount ?? s.total) || 0),
        })),
        payments: payments.value.map((p) => ({
          date: p.happened_at,
          method: p.method || '',
          amount: Number(p.amount || 0),
          waived: Number(p.waived || 0),
        })),
      });
      uni.showLoading({ title: '生成分享链接…' });
      try {
        const d = await request<{ url?: string; expires_at?: string }>('/share', 'POST', { payload, ttl_hours: ttl });
        uni.hideLoading();
        const url = d?.url || '';
        if (!url) throw new Error('empty url');
        uni.showModal({
          title: '分享链接已生成',
          content: `对方用浏览器打开即可查看对账单：\n\n${url}\n\n链接在选定时间后自动失效。`,
          confirmText: '复制链接',
          cancelText: '好',
          success: (m) => {
            if (m.confirm) {
              uni.setClipboardData({ data: url });
              uni.showToast({ title: '链接已复制', icon: 'success' });
            }
          },
        });
      } catch (e) {
        uni.hideLoading();
        uni.showToast({ title: '生成分享失败', icon: 'none' });
      }
    },
  });
}

/// 我的分享列表（admin 才可用；staff 被拒静默）
async function manageShares() {
  try {
    const d = await request<{ shares?: ShareItem[] }>('/share', 'GET');
    shares.value = d?.shares || [];
  } catch (_) {
    shares.value = [];
  }
  shareDlg.value = true;
}

async function extendShare(s: ShareItem) {
  try {
    await request(`/share/${s.token}`, 'PATCH', { ttl_hours: 720 });
    uni.showToast({ title: '已延期 1 个月', icon: 'success' });
    manageShares();
  } catch (e) {
    uni.showToast({ title: '延期失败', icon: 'none' });
  }
}

async function delShare(s: ShareItem) {
  uni.showModal({
    title: '删除分享',
    content: '删除后链接立即失效，确认？',
    success: async (r) => {
      if (!r.confirm) return;
      try {
        await request(`/share/${s.token}`, 'DELETE', {});
        uni.showToast({ title: '已删除', icon: 'success' });
        manageShares();
      } catch (e) {
        uni.showToast({ title: '删除失败', icon: 'none' });
      }
    },
  });
}

  onHide(() => { offWs('*', load); });
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh;  background: var(--page-bg); }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 24rpx; margin-bottom: 20rpx; }
.field { margin-bottom: 20rpx; }
.field-inner { display: flex; justify-content: space-between; }
.label { color: var(--text-sub); font-size: 26rpx; }
.value { font-size: 28rpx; }
.seg { display: flex; background: var(--input-bg); border-radius: 12rpx; margin-bottom: 20rpx; overflow: hidden; }
.seg-item { flex: 1; text-align: center; padding: 16rpx; font-size: 26rpx; color: var(--text-sub); }
.seg-item.active { color: var(--primary); font-weight: bold; background: var(--primary-soft); }
.dates { display: flex; align-items: center; gap: 12rpx; margin-bottom: 20rpx; }
.ipt { flex: 1; background: var(--input-bg); border-radius: 12rpx; padding: 16rpx 20rpx; font-size: 26rpx; }
.date-pick { color: var(--text-main); }
.to { color: var(--text-sub); }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; margin-bottom: 20rpx; }
.btn-copy { background: var(--card-bg); border: 1rpx solid var(--primary); color: var(--primary); border-radius: 12rpx; font-size: 28rpx; margin-top: 12rpx; }
.stat { display: flex; justify-content: space-between; padding: 12rpx 0; font-size: 28rpx; }
.red { color: #f56c6c; }
.green { color: #67c23a; }
/* 对账单表格（对齐 App 标准模板形态） */
.stmt-tbl { padding: 0; overflow: hidden; }
.t-title { font-size: 32rpx; font-weight: bold; text-align: center; padding: 24rpx 24rpx 4rpx; color: var(--text-main); }
.t-sub { font-size: 24rpx; color: var(--text-sub); text-align: center; padding: 0 24rpx 16rpx; }
.t-head, .t-row { display: flex; align-items: center; padding: 12rpx 24rpx; }
/* 表头无底色（对齐 App：用户"日期营业额那行文字有底部颜色要去掉"） */
.t-head { font-size: 24rpx; color: var(--text-sub); font-weight: 600; border-bottom: 1rpx solid var(--divider); }
.t-row { border-bottom: 1rpx solid var(--divider); font-size: 26rpx; color: var(--text-main); }
/* 模板切换（标准/多栏） */
.tpl-seg { margin-bottom: 20rpx; }
/* 多栏月账单（寻牛记式：每栏 日期+营业额 双列） */
.m-row { display: flex; border-bottom: 1rpx solid var(--divider); }
/* 多栏表头无底色（对齐 App 表头去底） */
.m-head { font-weight: 600; color: var(--text-sub); font-size: 22rpx; }
.m-col { flex: 1; display: flex; flex-direction: column; align-items: center; padding: 10rpx 2rpx; border-left: 1rpx solid var(--divider); }
.m-col:first-child { border-left: none; }
.m-date { font-size: 20rpx; color: var(--text-sub); }
.m-amt { font-size: 24rpx; color: var(--text-main); }
.m-amt.bold { font-weight: 700; }
.m-sub { background: var(--primary-soft); }
.m-total { display: flex; justify-content: space-between; padding: 14rpx 24rpx; font-weight: 700; font-size: 26rpx; border-top: 1rpx solid var(--divider); }
.c-date { width: 110rpx; flex-shrink: 0; font-size: 24rpx; color: var(--text-sub); }
.c-detail { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.c-amt { width: 150rpx; flex-shrink: 0; text-align: right; }
.t-pay { color: #67c23a; }
.t-group { border-bottom: 1rpx solid var(--divider); }
.t-day { display: flex; justify-content: space-between; align-items: center; padding: 14rpx 24rpx; background: var(--primary-soft); }
.t-day-label { font-size: 26rpx; font-weight: 600; color: var(--text-main); }
.t-day-total { font-size: 24rpx; color: var(--text-sub); }
.t-total { display: flex; justify-content: space-between; padding: 12rpx 24rpx; font-size: 26rpx; font-weight: 600; border-bottom: 1rpx solid var(--divider); color: var(--text-main); }
.t-total:last-child { border-bottom: none; }
.empty { color: var(--text-sub); text-align: center; padding: 24rpx 0; font-size: 26rpx; }
/* 我的分享弹层 */
.mask { position: fixed; left: 0; top: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.45); z-index: 100; display: flex; align-items: flex-end; }
.sheet { width: 100%; background: var(--page-bg); border-radius: 28rpx 28rpx 0 0; padding: 28rpx 24rpx calc(28rpx + env(safe-area-inset-bottom)); max-height: 75vh; display: flex; flex-direction: column; }
.s-title { font-size: 32rpx; font-weight: bold; text-align: center; margin-bottom: 20rpx; color: var(--text-main); }
.share-list { flex: 1; min-height: 0; max-height: 50vh; }
.share-row { display: flex; align-items: center; gap: 12rpx; padding: 16rpx 0; border-bottom: 1rpx solid var(--divider); }
.share-info { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4rpx; }
.share-url { font-size: 22rpx; color: var(--text-main); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.share-exp { font-size: 20rpx; color: var(--text-sub); }
.share-op { font-size: 24rpx; color: var(--primary); padding: 8rpx 16rpx; flex-shrink: 0; }
.share-op.del { color: #f56c6c; }
</style>