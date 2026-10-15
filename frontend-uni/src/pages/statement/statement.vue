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
        <view v-if="msd > 1" :class="['seg-item', { active: period === 'cycle' }]" @click="applyPeriod('cycle')">账期本期</view>
        <view v-if="msd > 1" :class="['seg-item', { active: period === 'cycleLast' }]" @click="applyPeriod('cycleLast')">账期上期</view>
        <view :class="['seg-item', { active: period === 'custom' }]" @click="applyPeriod('custom')">自定义</view>
      </view>

      <!-- 自定义账期时才显示日期选择（对齐 App：本月/上月/账期本期/账期上期自动算起止） -->
      <view v-if="period === 'custom'" class="dates">
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
        <!-- 对账单样式（对齐 App：样式 chips 切换 + 排版工具条 标题对齐/字号） -->
        <view class="tpl-title">对账单样式</view>
        <view class="tpl-chips">
          <view :class="['chip', { active: tpl === 'std' }]" @click="setTpl('std')">标准</view>
          <view :class="['chip', { active: tpl === 'multi' }]" @click="setTpl('multi')">多栏</view>
        </view>
        <view class="toolbar">
          <text class="tb-label">标题：</text>
          <view class="tb-seg">
            <view :class="['tb-item', { active: titleAlign === 'left' }]" @click="titleAlign = 'left'">左对齐</view>
            <view :class="['tb-item', { active: titleAlign === 'center' }]" @click="titleAlign = 'center'">居中</view>
            <view :class="['tb-item', { active: titleAlign === 'right' }]" @click="titleAlign = 'right'">右对齐</view>
          </view>
          <text class="tb-label">字号：</text>
          <view class="tb-seg">
            <view :class="['tb-item', { active: fontSize === 10 }]" @click="fontSize = 10">小</view>
            <view :class="['tb-item', { active: fontSize === 12 }]" @click="fontSize = 12">中</view>
            <view :class="['tb-item', { active: fontSize === 14 }]" @click="fontSize = 14">大</view>
          </view>
        </view>
        <!-- 成品预览（对齐 App 标准模板：标题 + 日期/营业额表头 + 逐日行 + 合计；view+flex 模拟表格——
        小程序 WXML 不支持 table 语义（会竖排），用行内 flex 单元格横排渲染，每格四边浅灰线同 App） -->
        <view v-if="tpl === 'std'" class="card stmt-tbl">
          <view class="t-title" :style="titleStyle">{{ clientName }} {{ from.slice(5, 7) }}月份账单</view>
          <view class="t-sub">{{ from }} 至 {{ to }}</view>
          <view class="tbl">
            <view class="tbl-row tbl-head">
              <view class="tbl-cell">日期</view>
              <view class="tbl-cell amt">营业额</view>
            </view>
            <view v-for="d in dailyRows" :key="d.day" class="tbl-row">
              <view class="tbl-cell">{{ d.label }}</view>
              <view class="tbl-cell amt">{{ stmtFmt(d.amt) }}</view>
            </view>
            <view class="tbl-row tbl-foot">
              <view class="tbl-cell">合计</view>
              <view class="tbl-cell amt">{{ stmtFmt(saleTotal) }}</view>
            </view>
          </view>
        </view>
        <!-- 多栏模板（对齐 App 展开网格：每栏「日期|营业额」左右两列，31 天→4 栏=8 列；月末补空格保矩形；栏底小计+底部总计） -->
        <view v-else class="card stmt-tbl">
          <view class="t-title" :style="titleStyle">{{ clientName }} {{ from.slice(5, 7) }}月份账单</view>
          <view class="t-sub">{{ from }} 至 {{ to }}</view>
          <view class="tbl">
            <view class="tbl-row tbl-head">
              <template v-for="ci in multi.cols" :key="'h'+ci">
                <view class="tbl-cell">日期</view>
                <view class="tbl-cell amt">营业额</view>
              </template>
            </view>
            <view v-for="(row, ri) in multi.rows" :key="'r'+ri" class="tbl-row">
              <template v-for="(cell, ci) in row" :key="'c'+ci">
                <view :class="['tbl-cell', cell.isAmt ? 'amt' : '']">{{ cell.isAmt ? cell.amt : cell.label }}</view>
              </template>
            </view>
            <view class="tbl-row tbl-foot">
              <template v-for="ci in multi.cols" :key="'s'+ci">
                <view class="tbl-cell">小计</view>
                <view class="tbl-cell amt">{{ multi.subtotals[ci - 1] }}</view>
              </template>
            </view>
            <view class="tbl-row tbl-foot">
              <view class="tbl-cell">总计</view>
              <view class="tbl-cell amt" :style="{ flex: multi.totalColspan + 1 }">{{ multi.grand }}</view>
            </view>
          </view>
        </view>
        <!-- 统计卡（对齐 App：出货合计/收款合计 并排卡片 + 期末欠款卡片；金额纯数字不带 ¥，用户"不需要显示金额符号￥"） -->
        <view class="stat-row2">
          <view class="stat-card"><text class="stat-card-tx">出货合计</text><text class="stat-card-num red">{{ fmtAmount(saleTotal) }}（{{ sales.length }} 笔）</text></view>
          <view class="stat-card"><text class="stat-card-tx">收款合计（实收）</text><text class="stat-card-num green">{{ fmtAmount(payTotal) }}（{{ payments.length }} 笔）</text></view>
        </view>
        <view v-if="waivedTotal > 0" class="stat-card"><text class="stat-card-tx">减免合计（平账）</text><text class="stat-card-num orange">{{ fmtAmount(waivedTotal) }}</text></view>
        <view class="stat-card"><text class="stat-card-tx">期末欠款（累计）</text><text :class="['stat-card-num', debt > 0 ? 'red' : 'green']">{{ stmtFmt(debt) }}</text></view>
        <button class="btn-copy" @click="exportXlsx">导出 Excel（生成文件）</button>
        <button class="btn-copy" @click="openTpl">模板设置</button>
        <button class="btn-copy" @click="printStmt">打印（按当前模板）</button>
        <button class="btn-copy" @click="share">分享对账单（生成链接）</button>
        <button class="btn-copy" @click="manageShares">我的分享</button>
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
import { request, getToken, getApiBase, appLog } from '../../api';
import { roundAmount, fmtAmount, fmtByUnit, initRounding } from '../../utils/money';
// @ts-ignore 迷你版（体积小，小程序可用）：真 xlsx 文件生成，替代剪贴板 CSV
import * as XLSX from 'xlsx/dist/xlsx.mini.min.js';

const clients = ref<Array<{ id: string; name: string; round_stage?: string; round_unit?: string; month_start_day?: number }>>([]);
const clientNames = ref<string[]>(['全部店铺']);
const clientName = ref('全部店铺');
let clientId = '';

// 对账单模板（对齐 App 内置模板切换：标准=单栏逐日金额表；多栏=每栏 10 天寻牛记式月账单；
// 初始按模板设置页选择（storage），默认标准）
const tpl = ref<'std' | 'multi'>((uni.getStorageSync('taozhu_stmt_tpl') as string) === 'multi' ? 'multi' : 'std');

function setTpl(t: 'std' | 'multi') {
  tpl.value = t;
  uni.setStorageSync('taozhu_stmt_tpl', t);
  appLog('op', `对账单模板 切换：「${t === 'std' ? '标准' : '多栏'}」`, 'info');
}

/// 模板设置（对齐 App「模板设置」按钮 → 独立页：选择/查看/恢复默认）
function openTpl() {
  uni.navigateTo({ url: '/pages/statement/statement-template' });
}

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

/// 多栏月账单（对齐 App：每栏「日期|营业额」左右两列，31 天→4 栏=8 列；月末补空格保矩形；日期「M月D日」）
const multi = computed(() => {
  const y = Number(from.value.slice(0, 4)) || new Date().getFullYear();
  const m = Number(from.value.slice(5, 7)) || new Date().getMonth() + 1;
  const n = from.value ? monthDays(y, m) : 31;
  const cols = Math.max(1, Math.ceil(n / 10));
  const rows: Array<Array<{ isAmt: boolean; label: string; amt: string; day: number }>> = [];
  for (let r = 0; r < 10; r++) {
    const cells: Array<{ isAmt: boolean; label: string; amt: string; day: number }> = [];
    for (let c = 0; c < cols; c++) {
      const day = c * 10 + r + 1;
      if (day <= n) {
        // 日期点分带年（用户定稿 2026.10.16）
        cells.push({ isAmt: false, label: `${y}.${m}.${day}`, amt: '', day });
        cells.push({ isAmt: true, label: '', amt: stmtFmt(dailyAmt.value[day] || 0), day });
      } else {
        // 31 天月第 4 栏超出部分补空格格（对齐 App：保留表格线成矩形）
        cells.push({ isAmt: false, label: '', amt: '', day: 0 });
        cells.push({ isAmt: true, label: '', amt: '', day: 0 });
      }
    }
    rows.push(cells);
  }
  const subtotals: string[] = [];
  let grand = 0;
  for (let c = 0; c < cols; c++) {
    let s = 0;
    for (let dd = c * 10; dd < (c + 1) * 10 && dd < n; dd++) s += dailyAmt.value[dd + 1] || 0;
    grand += s;
    subtotals.push(stmtFmt(s));
  }
  return { y, m, cols, rows, subtotals, grand: stmtFmt(grand), totalColspan: cols * 2 - 2 };
});

const period = ref<'month' | 'last' | 'cycle' | 'cycleLast' | 'custom'>('month');
const from = ref('');
const to = ref('');
const loading = ref(false);
const loaded = ref(false);
const sales = ref<Array<Record<string, any>>>([]);
const payments = ref<Array<Record<string, any>>>([]);
const debt = ref(0);

// 排版工具条（对齐 App：标题对齐 + 字号；标题字号 = 正文 +2）
const titleAlign = ref<'left' | 'center' | 'right'>('center');
const fontSize = ref<10 | 12 | 14>(12);
const titleStyle = computed(() => ({
  textAlign: titleAlign.value,
  fontSize: `${(fontSize.value + 2) * 2}rpx`,
}));

/// 选中店铺的每月起始日（1=自然月，对齐 App _msd）
const msd = computed(() => {
  if (clientId) {
    const c = clients.value.find((x) => x.id === clientId);
    const v = Number(c?.month_start_day || 0);
    if (v >= 1 && v <= 28) return v;
  }
  return 1;
});

/// 结账周期（按起始日）：[起始日, 次月起始日-1]；起始日=1 时按自然月（对齐 App _cyclePeriod）
function cyclePeriod(startDay: number, anchor: Date): [string, string] {
  const p = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  if (startDay <= 1) {
    return [
      p(new Date(anchor.getFullYear(), anchor.getMonth(), 1)),
      p(new Date(anchor.getFullYear(), anchor.getMonth() + 1, 0)),
    ];
  }
  const thisStart = new Date(anchor.getFullYear(), anchor.getMonth(), startDay);
  const [s, e] = anchor.getDate() >= startDay
      ? [thisStart, new Date(anchor.getFullYear(), anchor.getMonth() + 1, startDay)]
      : [new Date(anchor.getFullYear(), anchor.getMonth() - 1, startDay), thisStart];
  return [p(s), p(new Date(e.getTime() - 86400000))];
}

const saleTotal = ref(0);
const payTotal = ref(0);

/// 标准模板逐日金额表（对齐 App 标准模板：1..当月天数 逐行 日期+营业额，无数据日金额 0；
/// 日期点分带年格式 2026.10.16——用户定稿"年月日改成 ."，模板内金额纯数字无 ¥）
const dailyRows = computed(() => {
  const y = Number(from.value.slice(0, 4)) || new Date().getFullYear();
  const m = Number(from.value.slice(5, 7)) || new Date().getMonth() + 1;
  const n = from.value ? monthDays(y, m) : 31;
  const rows: Array<{ day: number; label: string; amt: number }> = [];
  for (let d = 1; d <= n; d++) {
    rows.push({ day: d, label: `${y}.${m}.${d}`, amt: dailyAmt.value[d] || 0 });
  }
  return rows;
});

/// 减免合计（平账）：收款里 waive 部分（对齐 App _waivedTotal）
const waivedTotal = computed(() =>
  payments.value.reduce((s, p) => s + roundAmount(Number(p.waived || 0)), 0));

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

function applyPeriod(p: 'month' | 'last' | 'cycle' | 'cycleLast' | 'custom') {
  period.value = p;
  const now = new Date();
  const p2 = (n: number) => String(n).padStart(2, '0');
  if (p === 'last') {
    const first = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    const last = new Date(now.getFullYear(), now.getMonth(), 0);
    from.value = `${first.getFullYear()}-${p2(first.getMonth() + 1)}-${p2(first.getDate())}`;
    to.value = `${last.getFullYear()}-${p2(last.getMonth() + 1)}-${p2(last.getDate())}`;
  } else if (p === 'cycle' || p === 'cycleLast') {
    // 按店铺结账周期（month_start_day）：本期/上期（对齐 App _applyPeriod）
    const anchor = p === 'cycle' ? now : new Date(now.getFullYear(), now.getMonth() - 1, Math.min(now.getDate(), 28));
    const [s, e] = cyclePeriod(msd.value, anchor);
    from.value = s;
    to.value = e;
  } else if (p === 'month') {
    from.value = `${now.getFullYear()}-${p2(now.getMonth() + 1)}-01`;
    to.value = today();
  }
  // custom：保留当前起止日期，由用户改日期（对齐 App：自定义时才显示日期选择）
  // 切换账期后立即重新生成（对齐 App _applyPeriod 末尾 _load）
  if (loaded.value) load();
}

function onClient(e: { detail: { value: number } }) {
  const idx = e.detail.value;
  if (idx <= 0) { clientId = ''; clientName.value = '全部店铺'; } else {
    const c = clients.value[idx - 1];
    if (c) { clientId = c.id; clientName.value = c.name; }
  }
  // 切换店铺立即按新店铺重新生成（对齐 App onChanged 切店即 _load——之前切换后仍显示旧店铺数据）
  load();
}

function onClientPick() {
  void 0; // 占位（picker @change 走 onClient）
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
    appLog('op', `生成对账单：${clientName.value} ${from.value} 至 ${to.value}（出货 ${sales.value.length} 笔 / 收款 ${payments.value.length} 笔）`, 'info');
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

/// 导出对账单为真正的 Excel 文件（用户要求，替代剪贴板 CSV）：SheetJS 生成 .xlsx →
/// 微信端写临时文件分享到聊天/文件、H5 端浏览器直接下载。
/// 内容=当前模板成品（对齐 App「导出 Excel」：导出用当前选中模板渲染）——
/// 标准=标题+日期/营业额 1..月末逐日（无交易日期也显示 0）+合计；多栏=每栏「日期|营业额」+小计+总计。
async function exportXlsx() {
  if (!loaded.value) {
    uni.showToast({ title: '请先生成对账单', icon: 'none' });
    return;
  }
  try {
    // Excel 金额一律纯数字（去 ¥/￥/千分位逗号/空格，防任何带符号残留；用户"不需要显示金额符号￥"）
    const toNum = (v: unknown) => {
      const n = Number(String(v ?? '').replace(/[¥￥,，\s]/g, ''));
      return Number.isFinite(n) ? n : 0;
    };
    // 内容结构：0=标题行（合并整行居中，用 !merges 跨列）→ 表头 → 逐日 → 小计/合计 → 总计。
    // 不含"周期"行与"出货合计/收款合计/期末欠款"统计行（用户"多出一行周期/总计下边又多了几行"→去掉，
    // 对齐 App 模板渲染结果）；日期点分带年（用户定稿 2026.10.16），金额纯数字。
    const aoa: Array<Array<string | number>> = [
      [`${clientName.value} ${from.value.slice(5, 7)}月份账单`],
    ];
    const y = Number(from.value.slice(0, 4)) || new Date().getFullYear();
    if (tpl.value === 'multi') {
      const m = Number(from.value.slice(5, 7)) || new Date().getMonth() + 1;
      const hdr: string[] = [];
      for (let c = 0; c < multi.value.cols; c++) hdr.push('日期', '营业额');
      aoa.push(hdr);
      for (const row of multi.value.rows) {
        // 日期点分年格式（用户定稿 2026.10.16）："10月16日" → "2026.10.16"
        aoa.push(row.map((cell) => (cell.isAmt ? toNum(cell.amt) : (cell.day ? `${y}.${m}.${cell.day}` : ''))));
      }
      const sub: Array<string | number> = ['小计'];
      multi.value.subtotals.forEach((s, i) => {
        if (i > 0) sub.push('');
        sub.push(toNum(s));
      });
      aoa.push(sub);
      aoa.push(['总计', '', '', '', '', '', '', toNum(multi.value.grand)]);
    } else {
      const m = Number(from.value.slice(5, 7)) || new Date().getMonth() + 1;
      aoa.push(['日期', '营业额']);
      for (const d of dailyRows.value) aoa.push([`${y}.${m}.${d.day}`, d.amt]);
      aoa.push(['合计', saleTotal.value]);
    }
    const wb = XLSX.utils.book_new();
    const ws = XLSX.utils.aoa_to_sheet(aoa);
    // 标题行合并整行居中（用户"导出的 excel 标题要合并居中"）：1 行跨 colN 列 + 居中加粗样式
    const colN = tpl.value === 'multi' ? multi.value.cols * 2 : 2;
    ws['!merges'] = [{ s: { r: 0, c: 0 }, e: { r: 0, c: colN - 1 } }];
    const hcell = ws[XLSX.utils.encode_cell({ r: 0, c: 0 })];
    if (hcell) hcell.s = { font: { bold: true, sz: 14 }, alignment: { horizontal: 'center' } };
    // 合计/小计/总计用 Excel 公式（对齐 App 模板 =sum(...)：不是死数字，改动自动重算）
    // 公式文本不带 = 前缀（SheetJS 原样写入 <f>，带 = 会变成 ==SUM 非法公式——openpyxl 验证）
    const fSum = (ref: string) => `SUM(${ref})`;
    if (tpl.value === 'multi') {
      const subIdx = 2 + multi.value.rows.length; // 小计行 aoa 索引（0标题 1表头 2.. 逐日）
      const subExcelRow = subIdx + 1;
      for (let c = 0; c < multi.value.cols; c++) {
        const col = c * 2 + 1;
        const cell = ws[XLSX.utils.encode_cell({ r: subIdx, c: col })];
        if (cell) cell.f = fSum(`${XLSX.utils.encode_col(col)}3:${XLSX.utils.encode_col(col)}${subIdx}`);
      }
      const gcell = ws[XLSX.utils.encode_cell({ r: subIdx + 1, c: multi.value.cols * 2 - 1 })];
      if (gcell) {
        const refs: string[] = [];
        for (let c = 0; c < multi.value.cols; c++) refs.push(`${XLSX.utils.encode_col(c * 2 + 1)}${subExcelRow}`);
        gcell.f = fSum(refs.join(','));
      }
    } else {
      const n = dailyRows.value.length;
      const sumIdx = 2 + n; // 合计行 aoa 索引
      const cell = ws[XLSX.utils.encode_cell({ r: sumIdx, c: 1 })];
      if (cell) cell.f = fSum(`B3:B${sumIdx}`);
    }
    XLSX.utils.book_append_sheet(wb, ws, '对账单');
    // 列宽（金额列留足宽度，较长数字不挤压显示 ####；金额纯数字不带 ¥ 符号）
    const ws2 = wb.Sheets['对账单'];
    const widths: Array<{ wch: number }> = [];
    for (let c = 0; c < colN; c++) widths.push({ wch: c % 2 === 0 ? 12 : 14 });
    if (ws2) ws2['!cols'] = widths;
    // cellStyles: 保留标题/合并样式
    const out = XLSX.write(wb, { bookType: 'xlsx', type: 'array', cellStyles: true }) as ArrayBuffer;
    const fileName = `${clientName.value.replace(/\s+/g, '')}-对账单.xlsx`;
    // #ifdef MP-WEIXIN
    try {
      const fs = uni.getFileSystemManager();
      const filePath = `${((uni as any).env?.USER_DATA_PATH) || ''}/${fileName}`;
      fs.writeFileSync(filePath, out);
      (globalThis as any).wx?.shareFileMessage?.({
        filePath,
        fileName,
        success: () => uni.showToast({ title: `已分享「${fileName}」`, icon: 'success' }),
        fail: () => uni.showToast({ title: '分享失败', icon: 'none' }),
      });
      appLog('op', `导出对账单 Excel：${clientName.value} ${from.value} 至 ${to.value}`, 'info');
      return;
    } catch (e2) {
      uni.showToast({ title: '生成 Excel 失败', icon: 'none' });
      return;
    }
    // #endif
    // H5/其他端：浏览器直接下载
    XLSX.writeFile(wb, fileName);
    appLog('op', `导出对账单 Excel：${clientName.value} ${from.value} 至 ${to.value}`, 'info');
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '生成 Excel 失败', icon: 'none' });
  }
}

// 打印对账单：生成与 App《_rowsToHtml》同构的自包含打印页 HTML（SimSun 表格、自动打印脚本）
// → 微信端存 .html 文件分享到聊天（收到后用浏览器打开即自动打印/可另存 PDF）；H5 端打开服务端打印页。
// 内容=当前模板成品（对齐 App 打印：标准=标题+日期/营业额逐日+合计；多栏=每栏「日期|营业额」+小计+总计）。
// 无独立 h2 标题、无"出货合计/收款合计/期末欠款"统计行（用户"web打印依然是两个标题行/总计下边又多出几行"→
// 表格首行即模板标题唯一标题，与 App 打印页完全一致）。
async function printStmt() {
  if (!loaded.value) {
    uni.showToast({ title: '请先生成对账单', icon: 'none' });
    return;
  }
  const esc = (s: unknown) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  // 模板行集合 [文本, 对齐, 加粗, 底纹, rowspan, colspan]（与服务端 /print/template 同构，H5 直接复用）
  type PrintCell = [string, string, boolean, string, number, number];
  const y = Number(from.value.slice(0, 4)) || new Date().getFullYear();
  const m = Number(from.value.slice(5, 7)) || new Date().getMonth() + 1;
  const colN = tpl.value === 'multi' ? multi.value.cols * 2 : 2;
  const title = `${clientName.value} ${m}月份账单`;
  const trows: PrintCell[][] = [
    [[title, 'center', true, '', 1, colN]],
  ];
  if (tpl.value === 'multi') {
    const hdr: PrintCell[] = [];
    for (let c = 0; c < multi.value.cols; c++) hdr.push(['日期', 'center', true, 'grey', 1, 1], ['营业额', 'center', true, 'grey', 1, 1]);
    trows.push(hdr);
    for (const row of multi.value.rows) {
      const cells: PrintCell[] = [];
      for (const cell of row) {
        if (cell.isAmt) {
          if (cell.amt !== '' && cell.amt !== null && cell.amt !== undefined) cells.push([cell.amt, 'right', false, '', 1, 1]);
          else cells.push(['', 'right', false, '', 1, 1]);
        } else {
          if (cell.label !== '') cells.push([cell.label, 'center', false, '', 1, 1]);
          else cells.push(['', 'center', false, '', 1, 1]);
        }
      }
      trows.push(cells);
    }
    const sub: PrintCell[] = [['小计', 'center', true, '', 1, 1]];
    multi.value.subtotals.forEach((s, i) => {
      if (i > 0) sub.push(['', 'center', true, '', 1, 1]);
      sub.push([s, 'right', true, '', 1, 1]);
    });
    trows.push(sub);
    const last: PrintCell[] = [['总计', 'center', true, '', 1, 1]];
    for (let i = 0; i < multi.value.cols * 2 - 2; i++) last.push(['', '', false, '', 1, 1]);
    last.push([multi.value.grand, 'right', true, '', 1, 1]);
    trows.push(last);
  } else {
    trows.push([['日期', 'center', true, 'grey', 1, 1], ['营业额', 'center', true, 'grey', 1, 1]]);
    for (const d of dailyRows.value) {
      trows.push([[d.label, 'center', false, '', 1, 1], [String(d.amt), 'right', false, '', 1, 1]]);
    }
    trows.push([['合计', 'center', true, '', 1, 1], [String(saleTotal.value), 'right', true, '', 1, 1]]);
  }
  // 打印页 HTML 直接由 trows 生成（与服务端渲染同构；无独立 h2——表格首行即模板标题，用户"双标题"→去除）
  const rows: string[] = [];
  rows.push('<table>');
  for (const row of trows) {
    const cells: string[] = [];
    row.forEach((cell, c) => {
      if (cell[5] > 1) {
        // colspan>1 标题行
        const ta = cell[1] === 'center' ? ' style="text-align:center"' : (cell[1] === 'right' ? ' style="text-align:right"' : '');
        cells.push(`<td${ta} colspan="${cell[5]}">${esc(cell[0])}</td>`);
        return;
      }
      const cls = [cell[2] ? 'b' : '', cell[3] === 'grey' ? 'g' : ''].filter(Boolean).join(' ');
      const ta = cell[1] === 'center' ? ' style="text-align:center"' : (cell[1] === 'right' ? ' style="text-align:right"' : '');
      cells.push(`<td${ta}${cls ? ` class="${cls}"` : ''}>${esc(cell[0])}</td>`);
    });
    rows.push(`<tr>${cells.join('')}</tr>`);
  }
  rows.push('</table>');
  const html = `<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">
<title>${esc(title)}</title>
<style>body{font-family:SimSun,serif;margin:24px;}table{border-collapse:collapse;width:100%;font-size:13px;}td{border:1px solid #666;padding:4px 8px;}td.b{font-weight:700;}td.g{background:#f2f2f2;}@media print{@page{margin:12mm;}}</style>
</head><body onload="window.print()">${rows.join('')}</body></html>`;
  const fileName = `${clientName.value.replace(/\s+/g, '')}-对账单.html`;
  // #ifdef MP-WEIXIN
  try {
    const fs = uni.getFileSystemManager();
    const filePath = `${((uni as any).env?.USER_DATA_PATH) || ''}/${fileName}`;
    fs.writeFileSync(filePath, html, 'utf8');
    (globalThis as any).wx?.shareFileMessage?.({
      filePath,
      fileName,
      success: () => uni.showToast({ title: `已分享打印页「${fileName}」`, icon: 'success' }),
      fail: () => uni.showToast({ title: '分享失败，请重试', icon: 'none' }),
    });
    appLog('op', `打印对账单：${clientName.value} ${from.value} 至 ${to.value}`, 'info');
    return;
  } catch (e2) {
    uni.showToast({ title: '生成打印页失败', icon: 'none' });
    return;
  }
  // #endif
  // H5/其他端：服务端渲染打印页 → 复制链接浏览器打开（对齐原逻辑）
  // 标题统一为模板标题（与 App 打印页首行一致："店铺 N月份账单"）：服务端 <h1> 显示该标题，
  // 表格行已剔除首行（H5 分支不重复标题——用户"web打印依然是两个标题行"）
  const rowsData: unknown[] = [];
  for (let i = 1; i < trows.length; i++) {
    rowsData.push(trows[i].map((cell) => [cell[0], cell[1], cell[2], cell[3], cell[4], cell[5]]));
  }
  const b64 = utf8ToBase64(JSON.stringify(rowsData)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const url = `${getApiBase()}/api/v1/print/template?title=${encodeURIComponent(title)}&rows=${b64}&token=${getToken() || ''}${clientId ? `&client_id=${clientId}` : ''}`;
  uni.setClipboardData({
    data: url,
    success: () => uni.showModal({
      title: '打印页链接已复制',
      content: '请用浏览器打开该链接，页面会自动弹出打印（可另存为 PDF）。',
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
/* 对账单样式 chips（对齐 App ChoiceChip：胶囊、选中主题色） */
.tpl-title { font-size: 30rpx; font-weight: 600; margin: 24rpx 0 12rpx; color: var(--text-main); }
.tpl-chips { display: flex; gap: 16rpx; margin-bottom: 16rpx; }
.chip { padding: 10rpx 30rpx; border-radius: 999rpx; font-size: 24rpx; color: var(--text-sub); background: var(--card-bg); border: 1rpx solid var(--divider); }
.chip.active { color: #fff; background: var(--primary); border-color: var(--primary); }
/* 排版工具条（对齐 App：标题对齐 + 字号） */
.toolbar { display: flex; align-items: center; flex-wrap: wrap; gap: 12rpx; margin-bottom: 16rpx; }
.tb-label { font-size: 24rpx; color: var(--text-sub); }
.tb-seg { display: flex; background: var(--input-bg); border-radius: 10rpx; overflow: hidden; }
.tb-item { padding: 8rpx 20rpx; font-size: 24rpx; color: var(--text-sub); }
.tb-item.active { background: var(--primary); color: #fff; }
/* 统计卡（对齐 App _statCard：圆角卡片、标签在上金额在下） */
.stat-row2 { display: flex; gap: 16rpx; margin-top: 20rpx; }
.stat-card { flex: 1; background: var(--card-bg); border: var(--card-border); border-radius: 16rpx; padding: 20rpx 24rpx; display: flex; flex-direction: column; gap: 8rpx; margin-top: 16rpx; }
.stat-row2 .stat-card { margin-top: 16rpx; }
.stat-card-tx { font-size: 24rpx; color: var(--text-sub); }
.stat-card-num { font-size: 30rpx; font-weight: 700; color: var(--text-main); }
.orange { color: #f59e0b; }
/* 成品预览卡片（对齐 App：白卡 + 边框含预览表格） */
.preview-card { background: var(--card-bg); border: var(--card-border); border-radius: 16rpx; padding: 16rpx; margin-top: 16rpx; }
/* 成品表格（view+flex 模拟，小程序不支持 table 语义；每格四边浅灰线、金额右对齐纯数字，对齐 App） */
.tbl { margin-top: 8rpx; border-top: 1rpx solid #d9d9d9; border-left: 1rpx solid #d9d9d9; }
.tbl-row { display: flex; }
.tbl-cell { flex: 1; min-width: 0; border-right: 1rpx solid #d9d9d9; border-bottom: 1rpx solid #d9d9d9; padding: 8rpx 6rpx; text-align: center; font-size: 24rpx; color: var(--text-main); }
.tbl-cell.amt { text-align: right; }
.tbl-head .tbl-cell { font-weight: 600; color: var(--text-sub); }
.tbl-foot .tbl-cell { font-weight: 700; color: var(--text-main); }
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