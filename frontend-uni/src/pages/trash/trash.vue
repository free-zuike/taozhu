<template>
  <view class="page" :style="tv">
    <view class="wrap">
      <view class="tip">删除出货 / 进货 / 收款时会先归档到这里；作废行不进入统计、欠款与流水导出。</view>
      <view v-if="!items" class="loading">加载中…</view>
      <view v-else-if="items.length === 0" class="empty">回收站是空的</view>
      <view v-for="it in items" :key="it.id" class="card">
        <view class="head">
          <text class="kind">{{ typeLabel[it.entity_type] || it.entity_type }}</text>
          <text class="time">{{ shortTime(it.voided_at) }} · {{ it.voided_by }}</text>
          <text class="amount">¥{{ it.total }}</text>
        </view>
        <view v-if="it.reason" class="reason">原因：{{ it.reason }}</view>
        <view class="acts">
          <button class="btn ghost" :disabled="busy" @click="purge(it)">彻底删除</button>
          <button class="btn primary" :disabled="busy" @click="restore(it)">恢复入账</button>
        </view>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { useThemeVars } from '../../theme';
import { get, post, del } from '../../api';

const { tv } = useThemeVars();
interface Item {
  id: string; entity_type: string; reason: string;
  client_id: string; total: number; voided_at: string; voided_by: string;
}
const items = ref<Item[] | null>(null);
const busy = ref(false);
const typeLabel: Record<string, string> = { sale: '出货', purchase: '进货', payment: '收款' };

function shortTime(iso: string) {
  return (iso || '').length >= 16 ? iso.substring(5, 16).replace('T', ' ') : iso;
}

async function load() {
  try {
    const d = await get<{ items: Item[] }>('/trash?limit=100');
    items.value = d?.items || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}
onShow(load);

function confirm(text: string): Promise<boolean> {
  return new Promise((resolve) => {
    uni.showModal({
      title: '请确认', content: text,
      success: (r) => resolve(!!r.confirm),
      fail: () => resolve(false),
    });
  });
}

async function restore(it: Item) {
  if (busy.value || !(await confirm('将把这张单据恢复到账本，库存、欠款与同步会一起更新。'))) return;
  busy.value = true;
  try {
    await post(`/trash/${it.id}/restore`);
    uni.showToast({ title: '已恢复', icon: 'success' });
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '恢复失败', icon: 'none' });
  } finally {
    busy.value = false;
  }
}

async function purge(it: Item) {
  if (busy.value || !(await confirm('彻底删除后无法再恢复，确认继续？'))) return;
  busy.value = true;
  try {
    await del(`/trash/${it.id}`);
    uni.showToast({ title: '已清除', icon: 'success' });
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
  } finally {
    busy.value = false;
  }
}
</script>

<style scoped>
.page { min-height: 100vh; background: var(--page-bg); }
.wrap { padding: 24rpx; }
.tip { font-size: 24rpx; color: var(--text-sub); line-height: 1.6; margin-bottom: 20rpx; }
.loading, .empty { text-align: center; padding: 60rpx 0; color: var(--text-sub); font-size: 26rpx; }
.card { background: var(--card-bg); border: 1rpx solid var(--divider); border-radius: 20rpx; padding: 24rpx; margin-bottom: 20rpx; }
.head { display: flex; align-items: center; gap: 12rpx; }
.kind { padding: 4rpx 14rpx; border-radius: 12rpx; font-size: 22rpx; color: #2563eb; border: 1rpx solid #2563eb; background: #2563eb1f; }
.time { flex: 1; font-size: 22rpx; color: var(--text-sub); }
.amount { font-size: 24rpx; color: var(--text-main); }
.reason { margin-top: 14rpx; font-size: 24rpx; color: var(--text-main); }
.acts { display: flex; justify-content: flex-end; gap: 16rpx; margin-top: 20rpx; }
.btn { font-size: 24rpx; line-height: 2.2; padding: 0 28rpx; margin: 0; border-radius: 12rpx; }
.ghost { color: var(--text-sub); background: transparent; border: 1rpx solid var(--divider); }
.primary { color: #fff; background: #2563eb; border: 1rpx solid #2563eb; }
</style>
