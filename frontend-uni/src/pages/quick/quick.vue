<template>
  <view class="page">
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
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.tip { color: #909399; font-size: 26rpx; margin-bottom: 24rpx; }
.grid { display: flex; flex-wrap: wrap; justify-content: space-between; }
.cell {
  width: 48%; background: #fff; border-radius: 16rpx; padding: 40rpx 0 36rpx;
  display: flex; flex-direction: column; align-items: center; gap: 12rpx;
  box-sizing: border-box; margin-bottom: 20rpx;
}
.cell .ic { font-size: 72rpx; line-height: 1; }
.cell .tx { font-size: 30rpx; font-weight: bold; color: #303133; }
.cell .sub { font-size: 24rpx; color: #909399; }
.sale { border: 2rpx solid #409eff; }
.buy { border: 2rpx solid #67c23a; }
</style>