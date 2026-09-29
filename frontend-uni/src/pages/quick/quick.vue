<template>
  <view class="page" :style="tv">
    <view class="tip">记一笔，云端直连实时保存</view>
    <view class="grid">
      <view class="cell sale" @click="go('/pages/sale/sale')">
        <text class="ic">📦</text>
        <text class="tx">出货记单</text>
        <text class="sub">给店铺送货</text>
      </view>
      <view class="cell buy" @click="go('/pages/purchase/purchase')">
        <text class="ic">🛒</text>
        <text class="tx">进货记单</text>
        <text class="sub">从供应商进货</text>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { useThemeVars } from '../../theme';
const tv = useThemeVars();
import { getToken } from '../../api';
import { onShow } from '@dcloudio/uni-app';

onShow(() => {
  if (!getToken()) uni.reLaunch({ url: '/pages/login/login' });
});

function go(url: string) {
  uni.navigateTo({ url });
}
</script>

<style>
.page {  min-height: 100vh;  background-image: var(--bg-pattern), var(--bg-gradient); }
.tip { color: var(--text-sub); font-size: 26rpx; margin-bottom: 24rpx; }
.grid { display: flex; flex-wrap: wrap; justify-content: space-between; }
.cell {
  width: 48%; background: var(--card-bg); border-radius: 16rpx; padding: 40rpx 0 36rpx;
  display: flex; flex-direction: column; align-items: center; gap: 12rpx;
  box-sizing: border-box; margin-bottom: 20rpx;
}
.cell .ic { font-size: 72rpx; line-height: 1; }
.cell .tx { font-size: 30rpx; font-weight: bold; color: var(--text-main); }
.cell .sub { font-size: 24rpx; color: var(--text-sub); }
.sale { border: 2rpx solid var(--primary); }
.buy { border: 2rpx solid #67c23a; }
</style>