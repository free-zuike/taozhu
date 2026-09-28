<template>
  <view class="page" :style="tv">
    <button class="btn" :disabled="busy" @click="backupNow">{{ busy ? '备份中…' : '立即备份到云端' }}</button>
    <view class="tip">备份为全库 JSON 存档（云端历史可直接恢复，不覆盖现有数据）</view>

    <view class="group-title">备份历史<span class="badge">{{ backups.length }}</span></view>
    <view v-if="backups.length === 0" class="empty">暂无备份，点上方按钮创建</view>
    <view v-else class="list">
      <view v-for="b in backups" :key="b.key" class="card">
        <view class="info">
          <text class="b-name">{{ b.name_display || b.name }}</text>
          <text class="b-size">{{ b.size ? (b.size / 1024).toFixed(1) + ' KB' : '' }}</text>
        </view>
        <text class="op" @click="restore(b)">恢复</text>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { useThemeVars } from '../../theme';
const tv = useThemeVars();
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

type BackupItem = { name: string; name_display?: string; key: string; size?: number };
const backups = ref<BackupItem[]>([]);
const busy = ref(false);

onShow(async () => {
  if (!getToken()) return;
  load();
});

async function load() {
  try {
    const d = await request<{ files: BackupItem[] }>('/backup/files', 'GET');
    backups.value = d?.files || [];
  } catch (e) {
    uni.showToast({ title: '备份历史读取失败', icon: 'none' });
  }
}

async function backupNow() {
  busy.value = true;
  try {
    await request('/backup/now', 'POST', {});
    uni.showToast({ title: '备份成功', icon: 'success' });
    load();
  } catch (e) {
    uni.showToast({ title: '备份失败', icon: 'none' });
  } finally {
    busy.value = false;
  }
}

function restore(b: BackupItem) {
  uni.showModal({
    title: '恢复备份',
    content: `从「${b.name_display || b.name}」合并恢复（不覆盖现有数据）？`,
    success: async (r) => {
      if (!r.confirm) return;
      uni.showLoading({ title: '恢复中…' });
      try {
        await request<any>(`/backup/files/${b.name}/restore`, 'POST', {});
        uni.hideLoading();
        uni.showToast({ title: '恢复完成', icon: 'success' });
      } catch (e) {
        uni.hideLoading();
        uni.showToast({ title: '恢复失败', icon: 'none' });
      }
    },
  });
}
</script>

<style>
.page {
  background:
      radial-gradient(circle at 18% 12%, var(--primary-soft) 0 6rpx, transparent 10rpx),
      radial-gradient(circle at 75% 20%, var(--primary-soft) 0 9rpx, transparent 14rpx),
      radial-gradient(circle at 35% 42%, var(--primary-soft) 0 5rpx, transparent 9rpx),
      radial-gradient(circle at 65% 58%, var(--primary-soft) 0 11rpx, transparent 16rpx),
      radial-gradient(circle at 20% 75%, var(--primary-soft) 0 7rpx, transparent 12rpx),
      linear-gradient(180deg, var(--primary-fade) 0%, #f5f7fa 34%);; min-height: 100vh; }
.btn { background: var(--primary); color: #fff; border-radius: 14rpx; font-size: 30rpx; }
.tip { font-size: 22rpx; color: var(--text-sub); margin: 20rpx 8rpx 28rpx; line-height: 1.6; }
.group-title { font-size: 25rpx; color: var(--text-sub); margin: 8rpx 8rpx 16rpx; display: flex; align-items: center; }
.badge { display: inline-block; background: #eaf1fb; color: var(--primary); border-radius: 999rpx; padding: 2rpx 14rpx; font-size: 20rpx; margin-left: 12rpx; }
.empty { background: var(--card-bg); border-radius: 20rpx; text-align: center; color: #c0c4cc; padding: 60rpx 0; font-size: 26rpx; }
.list { display: flex; flex-direction: column; gap: 16rpx; }
.card { background: var(--card-bg); border-radius: 20rpx; padding: 24rpx; display: flex; align-items: center; justify-content: space-between; }
.info { display: flex; flex-direction: column; gap: 6rpx; }
.b-name { font-size: 28rpx; font-weight: 600; color: var(--text-main); }
.b-size { font-size: 22rpx; color: var(--text-sub); }
.op { font-size: 26rpx; color: var(--primary); padding: 8rpx 20rpx; }
</style>