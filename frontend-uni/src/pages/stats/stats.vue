<template>
  <view class="page">
    <!-- 按店统计 -->
    <view class="card">
      <view class="card-title">按店统计</view>
      <view v-for="c in byClient" :key="c.id" class="row">
        <view class="left">
          <text class="name">{{ c.name }}</text>
          <text class="meta">出货 ¥{{ fmt(c.sales_total) }} · 收款 ¥{{ fmt(c.paid_total) }} · 毛利 ¥{{ fmt(c.gross_profit) }}</text>
        </view>
        <text class="debt red">欠 ¥{{ fmt(c.debt) }}</text>
      </view>
      <view v-if="byClient.length === 0" class="empty">暂无数据</view>
    </view>

    <!-- 按月统计 -->
    <view class="card">
      <view class="card-title">
        <text>{{ year }} 年月度统计</text>
        <picker class="year-picker" mode="selector" :range="yearLabels" @change="onYear">
          <view class="year-btn">{{ year }} 年 ▾</view>
        </picker>
      </view>
      <view v-for="m in monthly" :key="m.month" class="row">
        <view class="left">
          <text class="name">{{ monthLabel(m.month) }}</text>
          <text class="meta">出货 ¥{{ fmt(m.sales_total) }} · 毛利 ¥{{ fmt(m.gross_profit) }}</text>
        </view>
        <text class="pay green">收 ¥{{ fmt(m.paid_total) }}</text>
      </view>
      <view v-if="monthly.length === 0" class="empty">该年份暂无数据</view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

interface ByClient { id: string; name: string; sales_total: number; paid_total: number; debt: number; gross_profit: number }
interface Monthly { month: string; sales_total: number; gross_profit: number; paid_total: number }

const byClient = ref<ByClient[]>([]);
const monthly = ref<Monthly[]>([]);
const years = ref<number[]>([]);
const yearLabels = ref<string[]>([]);
const year = ref(new Date().getFullYear());
const fmt = (n: number) => Number(n || 0).toFixed(2);
const monthLabel = (m: string) => (m && m.length >= 7 ? `${Number(m.slice(5, 7))}月` : m);

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await load();
});

async function load() {
  try {
    const [c, m, y] = await Promise.all([
      request<{ clients: ByClient[] }>('/stats/clients', 'GET'),
      request<{ months: Monthly[] }>('/stats/monthly', 'GET', { year: year.value }),
      request<{ years: number[] }>('/stats/years', 'GET'),
    ]);
    byClient.value = c.clients;
    monthly.value = m.months;
    const list = (y.years || []).filter((n) => n <= new Date().getFullYear());
    if (list.length) {
      years.value = list;
      yearLabels.value = list.map((n) => `${n} 年`);
      if (!list.includes(year.value)) {
        year.value = list[list.length - 1];
        const mm = await request<{ months: Monthly[] }>('/stats/monthly', 'GET', { year: year.value });
        monthly.value = mm.months;
      }
    } else {
      years.value = [year.value];
      yearLabels.value = [`${year.value} 年`];
    }
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

async function onYear(e: { detail: { value: number } }) {
  const y = years.value[e.detail.value];
  if (!y) return;
  year.value = y;
  try {
    const m = await request<{ months: Monthly[] }>('/stats/monthly', 'GET', { year: y });
    monthly.value = m.months;
  } catch (err) {
    uni.showToast({ title: (err as Error).message || '加载失败', icon: 'none' });
  }
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.card { background: #fff; border-radius: 12rpx; padding: 24rpx; margin-bottom: 16rpx; }
.card-title { display: flex; justify-content: space-between; align-items: center; font-size: 30rpx; font-weight: bold; margin-bottom: 16rpx; }
.year-btn { font-size: 26rpx; color: #409eff; border: 1rpx solid #409eff; border-radius: 8rpx; padding: 6rpx 16rpx; }
.row { display: flex; align-items: center; padding: 14rpx 0; border-bottom: 1rpx solid #f0f0f0; }
.left { flex: 1; min-width: 0; }
.name { font-size: 28rpx; display: block; }
.meta { font-size: 22rpx; color: #909399; display: block; margin-top: 4rpx; }
.debt { font-size: 28rpx; font-weight: bold; }
.pay { font-size: 28rpx; font-weight: bold; }
.red { color: #f56c6c; }
.green { color: #67c23a; }
.empty { color: #c0c4cc; text-align: center; padding: 30rpx 0; font-size: 26rpx; }
</style>