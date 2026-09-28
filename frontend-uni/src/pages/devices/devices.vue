<template>
  <view class="page" :style="tv">
    <view v-if="loading" class="loading">加载中…</view>
    <view v-else-if="devices.length === 0" class="empty">
      <text class="empty-tx">暂无登录设备</text>
      <text class="empty-sub">登录过的设备会显示在这里</text>
    </view>
    <view v-else class="list">
      <view v-for="d in devices" :key="d.id" class="card">
        <view class="head">
          <view class="d-icon">
            <text class="d-emoji">{{ d.platform === 'Web' ? '🌐' : d.platform === '小程序' ? '📱' : '🖥️' }}</text>
          </view>
          <view class="d-info">
            <text class="d-name">{{ d.device_name }}</text>
            <text class="d-sub">{{ d.platform }}<template v-if="d.version"> · v{{ d.version }}</template></text>
          </view>
          <text class="del" @click="remove(d)">删除</text>
        </view>
        <view class="meta">
          <text class="m-label">IP</text>
          <text class="m-value">{{ d.ip || '--' }}</text>
          <text class="m-label">最近活跃</text>
          <text class="m-value">{{ shortTime(d.last_active_at) }}</text>
        </view>
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

type Device = { id: string; device_name: string; platform: string; ip?: string; version?: string; last_active_at: string };
const devices = ref<Device[]>([]);
const loading = ref(true);

const shortTime = (iso: string) => (iso && iso.length >= 16 ? `${iso.slice(0, 10)} ${iso.slice(11, 16)}` : iso || '');

onShow(async () => {
  load();
});

async function load() {
  loading.value = true;
  try {
    if (!getToken) return;
    const d = await request<{ devices: Device[] }>('/devices', 'GET');
    devices.value = (d?.devices || []).filter((x: Device) => x.id !== '_realdevice');
  } catch (e) {
    uni.showToast({ title: '设备列表加载失败', icon: 'none' });
  } finally {
    loading.value = false;
  }
}

function remove(d: Device) {
  uni.showModal({
    title: '删除设备',
    content: `删除「${d.device_name}」后，该设备下次登录会重新记录。确定删除？`,
    success: async (r) => {
      if (!r.confirm) return;
      try {
        await request<any>(`/devices/${d.id}`, 'DELETE');
        uni.showToast({ title: '已删除', icon: 'none' });
        load();
      } catch (e) {
        uni.showToast({ title: '删除失败', icon: 'none' });
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
.loading { text-align: center; color: #909399; padding: 80rpx 0; font-size: 26rpx; }
.empty { display: flex; flex-direction: column; align-items: center; padding: 120rpx 0; gap: 12rpx; }
.empty-tx { font-size: 28rpx; color: #909399; }
.empty-sub { font-size: 22rpx; color: #c0c4cc; }
.list { display: flex; flex-direction: column; gap: 20rpx; }
.card { background: #fff; border-radius: 20rpx; padding: 24rpx; }
.head { display: flex; align-items: center; gap: 20rpx; }
.d-icon {
  width: 72rpx; height: 72rpx; border-radius: 18rpx; background: #eaf1fb;
  display: flex; align-items: center; justify-content: center; flex-shrink: 0;
}
.d-emoji { font-size: 34rpx; }
.d-info { flex: 1; display: flex; flex-direction: column; gap: 4rpx; }
.d-name { font-size: 30rpx; font-weight: bold; color: #303133; }
.d-sub { font-size: 22rpx; color: #909399; }
.del { font-size: 26rpx; color: #f56c6c; padding: 8rpx 16rpx; }
.meta { display: flex; align-items: center; gap: 12rpx; margin-top: 20rpx; padding-top: 20rpx; border-top: 1rpx solid #f5f5f5; }
.m-label { font-size: 22rpx; color: #909399; }
.m-value { font-size: 24rpx; color: #303133; font-weight: 600; }
</style>