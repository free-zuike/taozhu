<template>
  <view class="page" :style="tv">
    <view class="wrap">
      <view v-if="!activity" class="loading">加载中…</view>
      <view v-else-if="activity.length === 0" class="empty">还没有活动记录。和 AI 助手聊几句（问数/落单/记忆）后这里会展示执行过程。</view>
      <view v-for="a in activity" :key="a.run.id" class="card">
        <view class="head">
          <text class="kind" :style="kindStyle(a.run.intent)">{{ kindLabel[a.run.intent] || a.run.intent }}</text>
          <text class="time">{{ shortTime(a.run.started_at) }}</text>
          <text class="summary">{{ cut(a.run.summary, 18) }}</text>
        </view>
        <view v-for="c in a.tool_calls" :key="c.id" class="call">
          <text :class="['dot', c.status === 'error' ? 'dot-err' : 'dot-ok']"></text>
          <text class="call-tx">{{ c.tool_name }} · {{ cut(c.result, 40) }}</text>
          <text v-if="c.duration_ms > 0" class="ms">{{ c.duration_ms }}ms</text>
        </view>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onLoad } from '@dcloudio/uni-app';
import { useThemeVars } from '../../theme';
import { get } from '../../api';

const { tv } = useThemeVars();
interface Run { id: string; intent: string; started_at: string; summary: string; status: string }
interface Call { id: string; tool_name: string; result: string; status: string; duration_ms: number }
interface Activity { run: Run; tool_calls: Call[] }
const activity = ref<Activity[] | null>(null);
const kindLabel: Record<string, string> = { query: '问数', kb: '用法', record: '落单', chat: '对话' };

function kindStyle(intent: string) {
  const map: Record<string, string> = { query: '#22c55e', kb: '#3b82f6', record: '#f59e0b', chat: '#6b7280' };
  const color = map[intent] || '#6b7280';
  return { color, borderColor: color, background: color + '1f' };
}
function shortTime(iso: string) {
  return (iso || '').length >= 16 ? iso.substring(5, 16).replace('T', ' ') : iso;
}
function cut(s: string, n: number) {
  s = s || '';
  return s.length > n ? s.slice(0, n) + '…' : s;
}

onLoad(async () => {
  try {
    const d = await get<{ activity: Activity[] }>('/ai/activity');
    activity.value = d?.activity || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
});
</script>

<style scoped>
.page { min-height: 100vh; background: var(--page-bg); }
.wrap { padding: 24rpx; }
.loading, .empty { text-align: center; padding: 60rpx 24rpx; color: var(--text-sub); font-size: 26rpx; line-height: 1.6; }
.card { background: var(--card-bg); border: 1rpx solid var(--divider); border-radius: 20rpx; padding: 24rpx; margin-bottom: 20rpx; }
.head { display: flex; align-items: center; gap: 14rpx; }
.kind { padding: 4rpx 14rpx; border-radius: 12rpx; font-size: 22rpx; border: 1rpx solid; }
.time { flex: 1; font-size: 22rpx; color: var(--text-sub); }
.summary { font-size: 22rpx; color: var(--text-sub); }
.call { display: flex; align-items: flex-start; gap: 10rpx; margin-top: 14rpx; }
.dot { width: 14rpx; height: 14rpx; border-radius: 50%; margin-top: 8rpx; flex-shrink: 0; }
.dot-ok { background: #22c55e; }
.dot-err { background: #f56c6c; }
.call-tx { flex: 1; font-size: 24rpx; color: var(--text-main); line-height: 1.5; }
.ms { font-size: 20rpx; color: var(--text-sub); }
</style>