<template>
  <view class="page">
    <!-- 今日卡片 -->
    <view class="cards">
      <view class="card"><text class="cl">今日出货</text><text class="cv">¥{{ fmt(today.sales_total) }}</text></view>
      <view class="card"><text class="cl green">今日毛利</text><text class="cv green">¥{{ fmt(today.gross_profit) }}</text></view>
      <view class="card"><text class="cl">今日收款</text><text class="cv">¥{{ fmt(today.paid_total) }}</text></view>
      <view class="card"><text class="cl red">今日进货</text><text class="cv red">¥{{ fmt(today.purchase_total) }}</text></view>
      <view class="card"><text class="cl red">总欠款</text><text class="cv red">¥{{ fmt(totals.debt) }}</text></view>
      <view class="card"><text class="cl">饭店数</text><text class="cv">{{ totals.client_count }}</text></view>
    </view>

    <!-- 功能入口 -->
    <view class="entries">
      <button class="btn" @click="go('/pages/items/items')">商品管理</button>
      <button class="btn" @click="go('/pages/clients/clients')">饭店管理</button>
      <button class="btn" @click="go('/pages/payments/payments')">收款结账</button>
      <button class="btn" @click="go('/pages/stats/stats')">统计</button>
    </view>

    <!-- 欠款排行 -->
    <view class="list">
      <view class="list-title">欠款排行（前 5）</view>
      <view v-for="c in topDebt" :key="c.id" class="list-row">
        <text class="lr-name">{{ c.name }}</text>
        <text class="lr-debt red">¥{{ fmt(c.debt) }}</text>
      </view>
      <view v-if="topDebt.length === 0" class="empty">暂无数据</view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

const today = ref({ sales_total: 0, gross_profit: 0, paid_total: 0, purchase_total: 0, sales_count: 0 });
const totals = ref({ debt: 0, client_count: 0, all_sales: 0, all_paid: 0, item_count: 0 });
const topDebt = ref<Array<{ id: string; name: string; debt: number }>>([]);
const fmt = (n: number) => Number(n || 0).toFixed(2);

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  try {
    const d = await request<{ today: typeof today.value; totals: typeof totals.value; top_debt_clients: Array<{ id: string; name: string; sales_total: number; paid_total: number; debt: number }> }>('/stats/overview', 'GET');
    today.value = d.today;
    totals.value = d.totals;
    topDebt.value = d.top_debt_clients;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
});

function go(url: string) {
  uni.navigateTo({ url });
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.cards { display: flex; flex-wrap: wrap; gap: 16rpx; margin-bottom: 24rpx; }
.card {
  width: calc(50% - 8rpx); background: #fff; border-radius: 12rpx;
  padding: 24rpx; box-sizing: border-box;
}
.cl { display: block; color: #909399; font-size: 26rpx; margin-bottom: 10rpx; }
.cv { font-size: 40rpx; font-weight: bold; }
.green { color: #67c23a; }
.red { color: #f56c6c; }
.entries { display: flex; flex-wrap: wrap; gap: 16rpx; margin-bottom: 24rpx; }
.btn { width: calc(50% - 8rpx); margin: 0; background: #fff; border-radius: 12rpx; font-size: 28rpx; }
.list { background: #fff; border-radius: 12rpx; padding: 24rpx; }
.list-title { font-size: 30rpx; font-weight: bold; margin-bottom: 16rpx; }
.list-row { display: flex; justify-content: space-between; padding: 16rpx 0; border-bottom: 1rpx solid #f0f0f0; }
.lr-name { font-size: 28rpx; }
.lr-debt { font-size: 28rpx; }
.empty { color: #c0c4cc; text-align: center; padding: 30rpx 0; font-size: 26rpx; }
</style>