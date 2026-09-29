<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <!-- 范围快速切换（对齐 App stats 页 _quickBar） -->
    <view class="quick">
      <view v-for="r in ranges" :key="r.key" :class="['q-item', { active: range === r.key }]" @click="switchRange(r.key)">{{ r.label }}</view>
    </view>

    <!-- 出货/进货切换（对齐 App：统计维度随时切换） -->
    <view class="seg">
      <view :class="['seg-item', { active: kind === 'sale' }]" @click="switchKind('sale')">出货</view>
      <view :class="['seg-item', { active: kind === 'purchase' }]" @click="switchKind('purchase')">进货</view>
    </view>

    <!-- 汇总卡（区间合计） -->
    <view class="card sum-card">
      <view class="sum-row">
        <view class="sum-cell"><text class="sl">出货额</text><text class="sv" style="color:var(--primary)">¥{{ fmt(sub.sales_total) }}</text></view>
        <view class="sum-cell"><text class="sl">收款</text><text class="sv" style="color:#22c55e">¥{{ fmt(sub.paid_total) }}</text></view>
        <view class="sum-cell"><text class="sl">欠款</text><text class="sv" style="color:#f59e0b">¥{{ fmt(sub.debt) }}</text></view>
        <view class="sum-cell"><text class="sl">毛利</text><text class="sv" :style="{ color: sub.gross_profit >= 0 ? '#22c55e' : '#ef4444' }">¥{{ fmt(sub.gross_profit) }}</text></view>
      </view>
      <view v-if="kind === 'purchase'" class="sum-sub">进货合计 ¥{{ fmt(sub.purchase_total) }} · {{ sub.sales_count }} 件</view>
    </view>

    <!-- 日流水柱状图（最近 14 天，纯 view 柱；对齐 App 折线图趋势） -->
    <view class="card">
      <view class="card-title">
        <text>{{ kind === 'purchase' ? '进货' : '出货' }}日流水（近 14 天）</text>
        <text class="range-txt">{{ rangeLabel }}</text>
      </view>
      <view v-if="bars.length" class="chart">
        <view class="bar-col" v-for="b in bars" :key="b.day">
          <view class="bar-wrap"><view class="bar" :style="{ height: b.h + '%', background: kind === 'purchase' ? '#f59e0b' : 'var(--primary)' }"></view></view>
          <text class="bar-label">{{ b.label }}</text>
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
  { key: 'today', label: '今日' },
  { key: 'month', label: '本月' },
  { key: 'year', label: '本年' },
  { key: 'all', label: '全部' },
];
const range = ref('month');
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
  // 全部：最早一笔记账日到今天
  return { start: firstDate.value || `${now.getFullYear()}-01-01`, end: today };
}
const rangeLabel = computed(() => {
  const s = rangeSpan();
  return s.start === s.end ? (s.start || '') : `${s.start} ~ ${s.end}`;
});

// 日柱状图：最近 14 天（无流水日金额 0，柱高按最大值归一化）
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
.quick { display: flex; background: var(--card-bg); border-radius: 12rpx; padding: 8rpx; margin-bottom: 16rpx; box-shadow: var(--card-shadow);}
.q-item { flex: 1; text-align: center; font-size: 26rpx; color: var(--text-sub); padding: 12rpx 0; border-radius: 8rpx; }
.q-item.active { color: #fff; background: var(--primary); font-weight: 600; }
.seg { display: flex; background: var(--card-bg); border-radius: 12rpx; padding: 8rpx; margin-bottom: 16rpx; box-shadow: var(--card-shadow);}
.seg-item { flex: 1; text-align: center; font-size: 26rpx; color: var(--text-sub); padding: 12rpx 0; border-radius: 8rpx; }
.seg-item.active { color: #fff; background: var(--primary); font-weight: 600; }
.card { background: var(--card-bg); border-radius: 16rpx; padding: 24rpx; margin-bottom: 16rpx; box-shadow: var(--card-shadow);}
.card-title { display: flex; justify-content: space-between; align-items: center; font-size: 30rpx; font-weight: bold; margin-bottom: 16rpx; }
.range-txt { font-size: 22rpx; color: var(--text-sub); font-weight: normal; }
.sum-card { background: var(--card-bg); }
.sum-row { display: flex; }
.sum-cell { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 8rpx; }
.sl { font-size: 22rpx; color: var(--text-sub); }
.sv { font-size: 30rpx; font-weight: bold; }
.sum-sub { margin-top: 16rpx; font-size: 24rpx; color: var(--text-sub); text-align: center; }
.chart { display: flex; align-items: flex-end; height: 240rpx; gap: 8rpx; padding-top: 10rpx; }
.bar-col { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: flex-end; height: 100%; }
.bar-wrap { flex: 1; width: 100%; display: flex; align-items: flex-end; }
.bar { width: 100%; min-height: 2rpx; border-radius: 4rpx 4rpx 0 0; }
.bar-label { font-size: 18rpx; color: var(--text-sub); margin-top: 8rpx; }
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