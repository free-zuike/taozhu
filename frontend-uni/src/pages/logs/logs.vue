<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <!-- 级别筛选 + 计数（对齐 App logs_page：全部/错误/信息 分段 + 各类条数） -->
    <view class="seg">
      <view :class="['seg-it', { on: filter === 'all' }]" @click="filter = 'all'">全部 {{ logs.length }}</view>
      <view :class="['seg-it', { on: filter === 'error' }]" @click="filter = 'error'">错误 {{ countError }}</view>
      <view :class="['seg-it', { on: filter === 'info' }]" @click="filter = 'info'">信息 {{ countInfo }}</view>
    </view>
    <view v-if="shown.length === 0" class="empty">{{ filter === 'error' ? '暂无错误日志' : '暂无日志' }}</view>
    <view v-for="(l, i) in shown" :key="i" :class="['card', { err: l.l === 'error' }]">
      <view class="head">
        <text class="t">{{ l.t }}</text>
        <text :class="['tag', 'lv-' + l.l]">{{ levelLabel(l.l) }}</text>
        <text class="g">{{ l.g }}</text>
      </view>
      <text class="m">{{ l.m }}</text>
    </view>
    <button v-if="logs.length > 0" class="btn" @click="clear">清空日志</button>
  </view>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { useThemeVars } from '../../theme';

const { tv, patternSrc } = useThemeVars();
type Entry = { t: string; l: string; g: string; m: string };
const logs = ref<Entry[]>([]);
const filter = ref<'all' | 'error' | 'info'>('all');

const countError = computed(() => logs.value.filter((e) => e.l === 'error').length);
const countInfo = computed(() => logs.value.filter((e) => e.l === 'info').length);
const shown = computed(() =>
  filter.value === 'all' ? logs.value : logs.value.filter((e) => e.l === filter.value));

function levelLabel(l: string) {
  if (l === 'error') return '错误';
  if (l === 'debug') return '调试';
  return '信息';
}

onShow(() => {
  try {
    const raw = (uni.getStorageSync('taozhu_logs') as string) || '';
    const arr = (raw ? (JSON.parse(raw) as Array<any>) : []) as Array<any>;
    // 兼容新旧格式：旧 {t,path,msg}（无级别=信息级，tag 用 path）；新 {t,l,g,m}
    logs.value = arr
      .map((x) => ({
        t: String(x.t || ''),
        l: x.l === 'error' || x.l === 'debug' ? String(x.l) : 'info',
        g: String(x.g ?? x.path ?? ''),
        m: String(x.m ?? x.msg ?? ''),
      }))
      .reverse();
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
/* 级别筛选段（对齐 App ChoiceChip 段：全部/错误/信息） */
.seg { display: flex; gap: 12rpx; margin-bottom: 20rpx; }
.seg-it { padding: 10rpx 28rpx; border-radius: 999rpx; font-size: 24rpx; color: var(--text-sub); background: var(--card-bg); border: 1rpx solid var(--divider); }
.seg-it.on { background: var(--primary); border-color: var(--primary); color: #fff; }
.card { background: var(--card-bg); border: 1rpx solid var(--card-border); border-radius: 16rpx; padding: 18rpx 24rpx; margin-bottom: 14rpx; }
.card.err { border-left: 6rpx solid #ef4444; }
.head { display: flex; align-items: center; gap: 12rpx; margin-bottom: 8rpx; flex-wrap: wrap; }
.t { font-size: 22rpx; color: var(--text-sub); }
.g { font-size: 22rpx; color: var(--primary); background: var(--primary-soft); border-radius: 6rpx; padding: 2rpx 10rpx; }
.tag { font-size: 20rpx; border-radius: 6rpx; padding: 2rpx 10rpx; }
.lv-error { color: #ef4444; background: rgba(239, 68, 68, 0.1); }
.lv-info { color: #22c55e; background: rgba(34, 197, 94, 0.1); }
.lv-debug { color: var(--text-sub); background: var(--input-bg); }
.m { font-size: 26rpx; color: var(--text-main); word-break: break-all; line-height: 1.5; }
.empty { text-align: center; color: var(--text-sub); padding: 100rpx 0; font-size: 26rpx; }
.btn { margin-top: 24rpx; background: var(--danger-bg); color: #f56c6c; font-weight: 700; border-radius: 44rpx; }
</style>