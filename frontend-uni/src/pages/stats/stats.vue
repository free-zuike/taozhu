<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <!-- 范围快速切换（今天/当月/今年/全部/自定义，自定义在最后；对齐 App stats 页 _quickBar） -->
    <view class="quick">
      <view v-for="r in ranges" :key="r.key" :class="['q-item', { active: range === r.key }]" @click="switchRange(r.key)">{{ r.label }}</view>
    </view>
    <!-- 自定义区间（range=custom 时显示起止日期选择） -->
    <view v-if="range === 'custom'" class="custom-bar">
      <picker mode="date" :value="customStart" @change="onCustomStart">
        <view class="date-pill">{{ customStart }}</view>
      </picker>
      <text class="custom-tilde">~</text>
      <picker mode="date" :value="customEnd" @change="onCustomEnd">
        <view class="date-pill">{{ customEnd }}</view>
      </picker>
    </view>

    <!-- 出货/进货切换（对齐 App：统计维度随时切换） -->
    <view class="seg">
      <view :class="['seg-item', { active: kind === 'sale' }]" @click="switchKind('sale')">出货</view>
      <view :class="['seg-item', { active: kind === 'purchase' }]" @click="switchKind('purchase')">进货</view>
    </view>

    <!-- 汇总卡（区间合计；出货/进货维度分别显示，对齐 App 汇总卡） -->
    <view class="card sum-card">
      <view v-if="kind === 'sale'" class="sum-row">
        <view class="sum-cell"><text class="sl">出货额</text><text class="sv" style="color:var(--primary)">¥{{ fmt(sub.sales_total) }}</text></view>
        <view class="sum-cell"><text class="sl">收款</text><text class="sv" style="color:#22c55e">¥{{ fmt(sub.paid_total) }}</text></view>
        <view class="sum-cell"><text class="sl">欠款</text><text class="sv" style="color:#f59e0b">¥{{ fmt(sub.debt) }}</text></view>
        <view class="sum-cell"><text class="sl">毛利</text><text class="sv" :style="{ color: sub.gross_profit >= 0 ? '#22c55e' : '#ef4444' }">¥{{ fmt(sub.gross_profit) }}</text></view>
      </view>
      <view v-else class="sum-row">
        <view class="sum-cell"><text class="sl">进货额</text><text class="sv" style="color:#f59e0b">¥{{ fmt(sub.purchase_total) }}</text></view>
        <view class="sum-cell"><text class="sl">天数</text><text class="sv" style="color:var(--text-main)">{{ days.length }}</text></view>
        <view class="sum-cell"><text class="sl">笔数</text><text class="sv" style="color:var(--text-main)">{{ sub.sales_count }}</text></view>
      </view>
    </view>

    <!-- 日流水柱状图（最近 14 天，纯 view 柱；对齐 App 折线图趋势） -->
    <view class="card">
      <view class="card-title">
        <text>{{ kind === 'purchase' ? '进货' : '出货' }}日流水（近 14 天）</text>
        <text class="range-txt">{{ rangeLabel }}</text>
      </view>
      <view v-if="bars.length" class="chart">
        <!-- 折线图（对齐 App 折线趋势；SVG data URI 由 image 渲染，圆点为流水日金额） -->
        <image class="line-chart" :src="lineSvg" mode="widthFix" />
        <view class="x-labels">
          <text class="bar-label" v-for="b in bars" :key="b.day">{{ b.label }}</text>
        </view>
      </view>
      <view v-else class="empty">该区间暂无流水</view>
    </view>

    <!-- 按店统计 -->
    <view class="card">
      <view class="card-title">按店统计（区间）</view>
      <view v-for="c in byClient" :key="c.id" class="row">
        <view class="left">
          <text class="name">{{ c.name }}</text>
          <text class="meta">出货 ¥{{ fmt(c.sales_total) }} · 收款 ¥{{ fmt(c.paid_total) }}<template v-if="canSeeProfit"> · 毛利 ¥{{ fmt(c.gross_profit) }}</template></text>
        </view>
        <text class="debt red">欠 ¥{{ fmt(c.debt) }}</text>
      </view>
      <view v-if="byClient.length === 0" class="empty">暂无数据</view>
    </view>

    <!-- 按月统计（本年度） -->
    <view class="card">
      <view class="card-title">
        <text>{{ year }} 年月度</text>
        <picker class="year-picker" mode="selector" :range="yearLabels" @change="onYear">
          <view class="year-btn">{{ year }} 年 ▾</view>
        </picker>
      </view>
      <view v-for="m in monthly" :key="m.month" class="row">
        <view class="left">
          <text class="name">{{ monthLabel(m.month) }}</text>
          <text class="meta">出货 ¥{{ fmt(m.sales_total) }} · 进货 ¥{{ fmt(m.purchase_total) }}</text>
        </view>
        <text class="pay" :style="{ color: m.balance >= 0 ? '#67c23a' : '#ef4444' }">{{ m.balance >= 0 ? '盈 +' : '亏 ' }}¥{{ fmt(Math.abs(m.balance)) }}</text>
      </view>
      <view v-if="monthly.length === 0" class="empty">该年份暂无数据</view>
    </view>

    <!-- 分类排行（区间内出货/进货额） -->
    <view class="card">
      <view class="card-title">{{ kind === 'purchase' ? '进货' : '出货' }}分类排行</view>
      <view v-for="(c, i) in catRank" :key="i" class="row">
        <view class="left">
          <text class="name">{{ c.category }}</text>
          <text class="meta">{{ c.quantity }} 件</text>
        </view>
        <text class="pay" style="color:var(--primary)">¥{{ fmt(c.amount) }}</text>
      </view>
      <view v-if="catRank.length === 0" class="empty">该区间暂无数据</view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { onShow, onHide } from '@dcloudio/uni-app';
import { onWs, offWs } from '../../ws';
import { useThemeVars } from '../../theme';
const { tv, patternSrc } = useThemeVars();
import { ref, computed } from 'vue';
import { request, getToken } from '../../api';

interface ByClient { id: string; name: string; sales_total: number; paid_total: number; debt: number; gross_profit: number }
interface Monthly { month: string; sales_total: number; purchase_total: number; balance: number }
interface DayRow { day: string; sales_total: number; paid_total: number; purchase_total: number; gross_profit: number }

const ranges = [
  { key: 'today', label: '今天' },
  { key: 'month', label: '当月' },
  { key: 'year', label: '今年' },
  { key: 'all', label: '全部' },
  { key: 'custom', label: '自定义' },
];
const range = ref('month');
const customStart = ref('');
const customEnd = ref('');
const kind = ref<'sale' | 'purchase'>('sale');
const byClient = ref<ByClient[]>([]);
const monthly = ref<Monthly[]>([]);
const days = ref<DayRow[]>([]);
const catRank = ref<Array<{ category: string; quantity: number; amount: number }>>([]);
const sub = ref({ sales_total: 0, paid_total: 0, debt: 0, gross_profit: 0, purchase_total: 0, sales_count: 0 });
const years = ref<number[]>([]);
const yearLabels = ref<string[]>([]);
const year = ref<number>(new Date().getFullYear());
const firstDate = ref('');
const canSeeProfit = ref(true);
const fmt = (n: number | null | undefined) => Number(n || 0).toFixed(2);
const monthLabel = (m: string) => (m && m.length >= 7 ? `${Number(m.slice(5, 7))}月` : m);

function dStr(dt: Date) {
  return `${dt.getFullYear()}-${String(dt.getMonth() + 1).padStart(2, '0')}-${String(dt.getDate()).padStart(2, '0')}`;
}
function rangeSpan() {
  const now = new Date();
  const today = dStr(now);
  if (range.value === 'today') return { start: today, end: today };
  if (range.value === 'month') return { start: `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-01`, end: today };
  if (range.value === 'year') return { start: `${now.getFullYear()}-01-01`, end: today };
  if (range.value === 'custom' && customStart.value && customEnd.value) {
    // 起止日期可倒置，统一为 start <= end
    return customStart.value <= customEnd.value
      ? { start: customStart.value, end: customEnd.value }
      : { start: customEnd.value, end: customStart.value };
  }
  // 全部：最早一笔记账日到今天
  return { start: firstDate.value || `${now.getFullYear()}-01-01`, end: today };
}
const rangeLabel = computed(() => {
  const s = rangeSpan();
  return s.start === s.end ? (s.start || '') : `${s.start} ~ ${s.end}`;
});

// 日流水数据：最近 14 天（无流水日金额 0，归一化供折线/标签）
const bars = computed(() => {
  const list = days.value.slice(-14);
  if (!list.length) return [];
  const max = Math.max(...list.map((d) => Number(d.sales_total) || 0), 1);
  return list.map((d) => ({
    day: d.day,
    label: d.day.length >= 10 ? `${Number(d.day.slice(5, 7))}/${Number(d.day.slice(8, 10))}` : d.day,
    h: Math.max(2, Math.round((Number(d.sales_total) / max) * 100)),
  }));
});

// ASCII-only 简易 base64（小程序无 btoa；对齐 theme.ts 自实现，SVG 折线 data URI 用）
function svgB64(svg: string): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out = '';
  for (let i = 0; i < svg.length; i += 3) {
    const b0 = svg.charCodeAt(i);
    const b1 = i + 1 < svg.length ? svg.charCodeAt(i + 1) : NaN;
    const b2 = i + 2 < svg.length ? svg.charCodeAt(i + 2) : NaN;
    out += chars[b0 >> 2];
    out += chars[((b0 & 3) << 4) | (isNaN(b1) ? 0 : b1 >> 4)];
    out += isNaN(b1) ? '=' : chars[((b1 & 15) << 2) | (isNaN(b2) ? 0 : b2 >> 6)];
    out += isNaN(b2) ? '=' : chars[b2 & 63];
  }
  return out;
}

/// 日流水折线图（对齐 App：折线+数据圆点，随出货/进货切换颜色）
const lineSvg = computed(() => {
  if (!bars.value.length) return '';
  const W = 360, H = 130;
  const n = bars.value.length;
  const stroke = kind.value === 'purchase' ? '#f59e0b' : '#409eff';
  const pts = bars.value.map((b, i) => {
    const x = n === 1 ? W / 2 : (W * i) / (n - 1);
    const y = H - 12 - (b.h / 100) * (H - 34);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  });
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">` +
    `<polyline fill="none" stroke="${stroke}" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" points="${pts.join(' ')}"/>` +
    pts.map((p) => `<circle cx="${p.split(',')[0]}" cy="${p.split(',')[1]}" r="3.5" fill="${stroke}"/>`).join('') +
    '</svg>';
  return 'data:image/svg+xml;base64,' + svgB64(svg);
});

onShow(async () => {
  onWs('*', load);
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await load();
});

onHide(() => {
  offWs('*', load);
});

async function load() {
  try {
    const { start, end } = rangeSpan();
    // 年月数据与区间/kind 无关，首次加载一次；区间数据每次刷新
    const y = await request<{ years: number[]; first_date?: string }>('/stats/years', 'GET').catch(() => null);
    if (y?.first_date) firstDate.value = y.first_date;
    const list = (y?.years || []).filter((n) => n <= new Date().getFullYear());
    if (list.length) {
      years.value = list;
      yearLabels.value = list.map((n) => `${n} 年`);
      if (!list.includes(year.value)) year.value = list[list.length - 1];
    } else {
      years.value = [year.value];
      yearLabels.value = [`${year.value} 年`];
    }
    const results = await Promise.all([
      request<Record<string, any>>(`/stats/summary?start=${start}&end=${end}&kind=${kind.value}`, 'GET').catch(() => null),
      request<{ days: DayRow[]; can_see_profit?: boolean }>(`/stats/daily?start=${start}&end=${end}&kind=${kind.value}`, 'GET').catch(() => null),
      request<{ clients: ByClient[] }>(`/stats/clients?start=${start}&end=${end}`, 'GET').catch(() => null),
      request<{ months: Monthly[]; can_see_profit?: boolean }>(`/stats/monthly-flow?year=${year.value}`, 'GET').catch(() => null),
      request<{ categories?: Array<{ category: string; quantity: number; amount: number }> }>(`/stats/categories?start=${start}&end=${end}&kind=${kind.value}`, 'GET').catch(() => null),
    ]);
    const s = results[0];
    if (s) {
      sub.value = {
        sales_total: Number(s.sales_total || 0),
        paid_total: Number(s.paid_total || 0),
        debt: Number(s.debt || 0),
        gross_profit: Number(s.gross_profit || 0),
        purchase_total: Number(s.purchase_total || 0),
        sales_count: Number(s.sales_count || 0),
      };
    }
    const d = results[1];
    if (d) {
      days.value = d.days || [];
      canSeeProfit.value = d.can_see_profit !== false;
    }
    byClient.value = results[2]?.clients || [];
    if (results[3]) {
      monthly.value = results[3].months || [];
      canSeeProfit.value = results[3].can_see_profit !== false;
    }
    const cats = results[4];
    catRank.value = (cats as any)?.categories || (cats as any)?.rows || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function switchRange(k: string) {
  if (range.value === k) return;
  range.value = k;
  // 首次进入自定义：默认近一个月区间（起止今天往前 30 天）
  if (k === 'custom') {
    const now = new Date();
    const end = dStr(now);
    const start = dStr(new Date(now.getFullYear(), now.getMonth() - 1, now.getDate()));
    customStart.value = start;
    customEnd.value = end;
  }
  load();
}

function onCustomStart(e: { detail: { value: string } }) {
  customStart.value = e.detail.value;
  load();
}

function onCustomEnd(e: { detail: { value: string } }) {
  customEnd.value = e.detail.value;
  load();
}

function switchKind(k: 'sale' | 'purchase') {
  if (kind.value === k) return;
  kind.value = k;
  load();
}

async function onYear(e: { detail: { value: number } }) {
  const y = years.value[e.detail.value];
  if (!y) return;
  year.value = y;
  try {
    const m = await request<{ months: Monthly[] }>(`/stats/monthly-flow?year=${y}`, 'GET');
    monthly.value = m.months || [];
  } catch (err) {
    uni.showToast({ title: (err as Error).message || '加载失败', icon: 'none' });
  }
}
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh; padding: 20rpx; box-sizing: border-box; background: var(--page-bg); }
.quick { display: flex; background: var(--card-bg); border: var(--card-border); border-radius: 12rpx; padding: 8rpx; margin-bottom: 16rpx; }
.q-item { flex: 1; text-align: center; font-size: 26rpx; color: var(--text-sub); padding: 12rpx 0; border-radius: 8rpx; }
.q-item.active { color: #fff; background: var(--primary); font-weight: 600; }
.custom-bar { display: flex; align-items: center; justify-content: center; gap: 16rpx; margin-bottom: 16rpx; }
.date-pill { font-size: 26rpx; color: var(--primary); border: 1rpx solid var(--primary); border-radius: 8rpx; padding: 10rpx 20rpx; background: var(--card-bg); }
.custom-tilde { font-size: 26rpx; color: var(--text-sub); }
.seg { display: flex; background: var(--card-bg); border: var(--card-border); border-radius: 12rpx; padding: 8rpx; margin-bottom: 16rpx; }
.seg-item { flex: 1; text-align: center; font-size: 26rpx; color: var(--text-sub); padding: 12rpx 0; border-radius: 8rpx; }
.seg-item.active { color: #fff; background: var(--primary); font-weight: 600; }
.card { background: var(--card-bg); border-radius: 16rpx; border: var(--card-border); padding: 24rpx; margin-bottom: 16rpx; }
.card-title { display: flex; justify-content: space-between; align-items: center; font-size: 30rpx; font-weight: bold; margin-bottom: 16rpx; }
.range-txt { font-size: 22rpx; color: var(--text-sub); font-weight: normal; }
/* 汇总卡透明（对齐 App 统计头透明：数字直露在渐变背景上，仅下方分隔线） */
.sum-card { background: transparent; border: none; padding: 8rpx 0 16rpx; margin-bottom: 8rpx; }
.sum-row { display: flex; }
.sum-cell { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 8rpx; }
.sl { font-size: 22rpx; color: var(--text-sub); }
.sv { font-size: 30rpx; font-weight: bold; }
.sum-sub { margin-top: 16rpx; font-size: 24rpx; color: var(--text-sub); text-align: center; }
.chart { position: relative; padding-top: 10rpx; }
.line-chart { width: 100%; height: 130rpx; }
.x-labels { display: flex; justify-content: space-between; margin-top: 10rpx; }
.bar-label { font-size: 18rpx; color: var(--text-sub); }
.year-btn { font-size: 26rpx; color: var(--primary); border: 1rpx solid var(--primary); border-radius: 8rpx; padding: 6rpx 16rpx; }
.row { display: flex; align-items: center; padding: 14rpx 0; border-bottom: 1rpx solid var(--divider); }
.left { flex: 1; min-width: 0; }
.name { font-size: 28rpx; display: block; color: var(--text-main); }
.meta { font-size: 22rpx; color: var(--text-sub); display: block; margin-top: 4rpx; }
.debt { font-size: 28rpx; font-weight: bold; }
.pay { font-size: 28rpx; font-weight: bold; }
.red { color: #f56c6c; }
.empty { color: var(--text-sub); text-align: center; padding: 30rpx 0; font-size: 26rpx; }
</style>