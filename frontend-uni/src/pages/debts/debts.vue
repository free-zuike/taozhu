<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="sum-card" v-if="loaded">
      <view class="sum-col">
        <text class="sum-label">累计欠款</text>
        <text :class="['sum-num', total > 0 ? 'red' : 'green']">¥{{ fmt(total) }}</text>
      </view>
      <view class="sum-col">
        <text class="sum-label">欠款店铺</text>
        <text class="sum-num">{{ debtCount }} 家</text>
      </view>
    </view>

    <view v-for="r in rows" :key="r.client_id" :class="['card', { warn: r.debt > 0 && r.days >= 30 }]" @click="viewTrace(r)">
      <view class="head">
        <text class="name">{{ r.client_name }}</text>
        <text :class="['qty', r.debt > 0 ? 'red' : 'green']">¥{{ fmt(r.debt) }}</text>
      </view>
      <view class="sub">{{ r.sale_count }} 笔{{ r.last_sale_date ? ' · 最近出货 ' + r.last_sale_date : '' }}{{ r.days >= 30 ? ' · 已拖 ' + r.days + ' 天' : '' }}</view>
    </view>
    <view v-if="loaded && rows.length === 0" class="empty">暂无欠款数据（进货/出货自动累计）</view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { useThemeVars } from '../../theme';
import { request, appLog } from '../../api';

const { tv, patternSrc } = useThemeVars();
const rows = ref<Array<{ client_id: string; client_name: string; debt: number; sale_count: number; last_sale_date: string; days: number }>>([]);
const total = ref(0);
const debtCount = ref(0);
const loaded = ref(false);

function fmt(v: number): string {
  const n = Math.round(v * 100) / 100;
  if (n === Math.round(n)) return `${n}`;
  if (n === Math.round(n * 10) / 10) return `${Math.round(n * 10) / 10}`;
  return n.toFixed(2);
}

async function load() {
  try {
    const d = await request<{ debts: Array<{ client_id: string; client_name: string; debt: number; sale_count: number; last_sale_date: string }>; today: string }>('/stats/debts', 'GET');
    const today = new Date();
    const todayStr = d?.today || `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
    const list = (d?.debts || []).map((r) => {
      let days = 0;
      if (r.last_sale_date) {
        const ld = new Date(r.last_sale_date);
        if (!isNaN(ld.getTime())) days = Math.max(0, Math.floor((today.getTime() - ld.getTime()) / 86400000));
      }
      return { ...r, days };
    });
    rows.value = list;
    total.value = list.reduce((s, r) => s + (Number(r.debt) || 0), 0);
    debtCount.value = list.filter((r) => Number(r.debt) > 0).length;
    loaded.value = true;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function viewTrace(r: { client_id: string }) {
  uni.navigateTo({ url: `/pages/clients/clients?focus=${r.client_id}` });
}

onShow(() => {
  load();
  appLog('op', '打开欠款看板', 'info');
});
</script>

<style scoped>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh; padding: 24rpx; box-sizing: border-box; background: var(--page-bg); }
.sum-card { display: flex; background: var(--card-bg); border: 2rpx solid var(--divider); border-radius: 16rpx; padding: 24rpx; margin-bottom: 16rpx; }
.sum-col { flex: 1; display: flex; flex-direction: column; gap: 8rpx; }
.sum-label { font-size: 22rpx; color: var(--text-sub); }
.sum-num { font-size: 34rpx; font-weight: 700; }
.red { color: #f56c6c; }
.green { color: #22c55e; }
.card { background: var(--card-bg); border: 2rpx solid var(--divider); border-radius: 16rpx; padding: 24rpx; margin-bottom: 12rpx; }
.card.warn { border-color: #f56c6c; background: rgba(245, 108, 108, 0.06); }
.head { display: flex; align-items: center; justify-content: space-between; }
.name { font-size: 30rpx; font-weight: 700; color: var(--text-main); }
.qty { font-size: 30rpx; font-weight: 700; }
.sub { font-size: 24rpx; color: var(--text-sub); margin-top: 8rpx; }
.empty { font-size: 24rpx; color: var(--text-sub); text-align: center; padding: 60rpx 0; }
</style>
