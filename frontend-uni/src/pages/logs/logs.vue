<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view v-if="logs.length === 0" class="empty">暂无错误日志</view>
    <view v-for="(l, i) in logs" :key="i" class="card">
      <view class="head">
        <text class="t">{{ l.t }}</text>
        <text class="p">{{ l.path }}</text>
      </view>
      <text class="m">{{ l.msg }}</text>
    </view>
    <button v-if="logs.length > 0" class="btn" @click="clear">清空日志</button>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { useThemeVars } from '../../theme';

const { tv, patternSrc } = useThemeVars();
const logs = ref<Array<{ t: string; path: string; msg: string }>>([]);

onShow(() => {
  try {
    const raw = (uni.getStorageSync('taozhu_logs') as string) || '';
    logs.value = raw ? (JSON.parse(raw) as Array<{ t: string; path: string; msg: string }>) : [];
  } catch (_) {
    logs.value = [];
  }
});

function clear() {
  uni.removeStorageSync('taozhu_logs');
  logs.value = [];
}
</script>

<style scoped>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh; padding: 24rpx; box-sizing: border-box; background: var(--page-bg); }
.card { background: var(--card-bg); border: 1rpx solid var(--card-border); border-radius: 16rpx; padding: 20rpx 24rpx; margin-bottom: 16rpx; }
.head { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 8rpx; }
.t { font-size: 22rpx; color: var(--text-sub); }
.p { font-size: 22rpx; color: var(--primary); }
.m { font-size: 26rpx; color: var(--text-main); word-break: break-all; line-height: 1.5; }
.empty { text-align: center; color: var(--text-sub); padding: 100rpx 0; font-size: 26rpx; }
.btn { margin-top: 24rpx; background: var(--danger-bg); color: #f56c6c; font-weight: 700; border-radius: 44rpx; }
</style>
