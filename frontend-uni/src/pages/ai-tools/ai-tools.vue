<template>
  <view class="page" :style="tv">
    <view class="wrap">
      <view class="intro">AI 会用到以下工具。查询类只读不询问；写操作（一句话记账、修改记忆）默认每次询问，也可设为总是允许/拒绝。</view>
      <view v-if="!tools" class="loading">加载中…</view>
      <view v-for="t in tools" :key="t.name" class="row" @click="pickPolicy(t)">
        <view class="body">
          <text class="name">{{ t.label }}</text>
          <text class="desc">{{ t.description }}</text>
        </view>
        <text class="pill" :style="pillStyle(t)">{{ policyLabel[t.policy] || t.policy }}</text>
      </view>
      <button class="btn-reset" @click="resetAll">恢复默认</button>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onLoad } from '@dcloudio/uni-app';
import { useThemeVars } from '../../theme';
import { get, put, post } from '../../api';

const { tv } = useThemeVars();
interface Tool { name: string; label: string; description: string; permission: string; policy: string }
const tools = ref<Tool[] | null>(null);
const policyLabel: Record<string, string> = { ask: '每次询问', allow: '总是允许', deny: '总是拒绝' };

function pillStyle(t: Tool) {
  const isWrite = t.permission === 'write';
  const color = isWrite ? (t.policy === 'allow' ? '#22c55e' : t.policy === 'deny' ? '#f56c6c' : '#f59e0b') : '#22c55e';
  return { color, borderColor: color, background: color + '1f' };
}

onLoad(async () => {
  try {
    const d = await get<{ tools: Tool[] }>('/ai/tools');
    tools.value = d?.tools || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
});

async function pickPolicy(t: Tool) {
  const labels = ['每次询问', '总是允许', '总是拒绝'];
  const values = ['ask', 'allow', 'deny'];
  const res = await new Promise<number>((resolve) => {
    uni.showActionSheet({
      itemList: labels,
      success: (r) => resolve(r.tapIndex),
      fail: () => resolve(-1),
    });
  });
  if (res < 0 || values[res] === t.policy) return;
  try {
    await put(`/ai/tools/${t.name}`, { policy: values[res] });
    uni.showToast({ title: `已设为「${labels[res]}」`, icon: 'success' });
    const d = await get<{ tools: Tool[] }>('/ai/tools');
    tools.value = d?.tools || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '设置失败', icon: 'none' });
  }
}

async function resetAll() {
  const ok = await new Promise<boolean>((resolve) => {
    uni.showModal({ title: '恢复默认', content: '所有工具回到缺省策略：读工具放行，写工具（落单/记忆）每次询问。', success: (r) => resolve(!!r.confirm), fail: () => resolve(false) });
  });
  if (!ok) return;
  try {
    await post('/ai/tools/reset', {});
    uni.showToast({ title: '已恢复默认', icon: 'success' });
    const d = await get<{ tools: Tool[] }>('/ai/tools');
    tools.value = d?.tools || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '操作失败', icon: 'none' });
  }
}
</script>

<style scoped>
.page { min-height: 100vh; background: var(--page-bg); }
.wrap { padding: 24rpx; }
.intro { padding: 22rpx 24rpx; background: var(--card-bg); border: 1rpx solid var(--divider); border-radius: 20rpx; font-size: 24rpx; color: var(--text-sub); line-height: 1.6; }
.loading { text-align: center; padding: 60rpx 0; color: var(--text-sub); font-size: 26rpx; }
.row { display: flex; align-items: center; gap: 16rpx; padding: 24rpx 8rpx; border-bottom: 1rpx solid var(--divider); }
.body { flex: 1; min-width: 0; }
.name { display: block; font-size: 28rpx; color: var(--text-main); }
.desc { display: block; margin-top: 6rpx; font-size: 22rpx; color: var(--text-sub); line-height: 1.5; }
.pill { flex-shrink: 0; padding: 8rpx 18rpx; border-radius: 28rpx; font-size: 22rpx; border: 1rpx solid; }
.btn-reset { margin-top: 40rpx; background: var(--card-bg); color: var(--text-main); border: 1rpx solid var(--divider); border-radius: 16rpx; font-size: 28rpx; }
</style>