<template>
  <view class="page" :style="tv">
    <view class="intro">跟 AI 助手说「记住：XXX」来记住重要事项（默认需确认），每次对话都会带上；说「忘记 XXX」或点右侧图标可遗忘。</view>
    <view class="wrap">
      <view v-if="!memories" class="loading">加载中…</view>
      <view v-else-if="memories.length === 0" class="empty">还没有记忆。</view>
      <view v-for="m in memories" :key="m.id" class="row">
        <view class="body">
          <text class="content">{{ m.content }}</text>
          <text class="date">{{ (m.created_at || '').slice(0, 10) }}</text>
        </view>
        <text class="del" @click="forget(m.id)">忘记</text>
      </view>
    </view>
    <view v-if="memories && memories.length" class="bottom">
      <button class="btn-clear" @click="clearAll">清空记忆</button>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onLoad } from '@dcloudio/uni-app';
import { useThemeVars } from '../../theme';
import { get, del } from '../../api';

const { tv } = useThemeVars();
interface Memory { id: string; content: string; created_at: string }
const memories = ref<Memory[] | null>(null);

async function load() {
  try {
    const d = await get<{ memories: Memory[] }>('/ai/memories');
    memories.value = d?.memories || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

onLoad(() => {
  load();
  uni.setNavigationBarTitle({ title: '本地记忆' });
});

async function forget(id: string) {
  try {
    await del(`/ai/memories/${id}`);
    uni.showToast({ title: '已忘记', icon: 'success' });
    load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '操作失败', icon: 'none' });
  }
}

async function clearAll() {
  const ok = await new Promise<boolean>((resolve) => {
    uni.showModal({ title: '清空记忆', content: '确定清空全部助手记忆吗？', success: (r) => resolve(!!r.confirm), fail: () => resolve(false) });
  });
  if (!ok) return;
  try {
    await del('/ai/memories');
    uni.showToast({ title: '已清空', icon: 'success' });
    load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '操作失败', icon: 'none' });
  }
}
</script>

<style scoped>
.page { min-height: 100vh; background: var(--page-bg); }
.intro { padding: 24rpx 28rpx; background: var(--card-bg); font-size: 24rpx; color: var(--text-sub); line-height: 1.6; }
.wrap { padding: 8rpx 28rpx 160rpx; }
.loading, .empty { text-align: center; padding: 60rpx 0; color: var(--text-sub); font-size: 26rpx; }
.row { display: flex; align-items: center; gap: 20rpx; padding: 20rpx 0; border-bottom: 1rpx solid var(--divider); }
.body { flex: 1; min-width: 0; }
.content { display: block; font-size: 26rpx; color: var(--text-main); line-height: 1.5; }
.date { display: block; margin-top: 6rpx; font-size: 22rpx; color: var(--text-sub); }
.del { color: #f56c6c; font-size: 26rpx; }
.bottom { position: fixed; left: 0; right: 0; bottom: 0; padding: 20rpx 28rpx calc(20rpx + env(safe-area-inset-bottom)); background: var(--page-bg); }
.btn-clear { background: var(--card-bg); color: #f56c6c; border: 1rpx solid var(--divider); border-radius: 16rpx; font-size: 28rpx; }
</style>