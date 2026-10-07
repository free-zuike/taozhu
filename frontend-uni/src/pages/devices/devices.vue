<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view v-if="loading" class="loading">加载中…</view>
    <view v-else-if="devices.length === 0" class="empty">
      <text class="empty-tx">暂无登录设备</text>
      <text class="empty-sub">登录过的设备会显示在这里</text>
    </view>
    <view v-else class="list">
      <view v-for="d in devices" :key="d.id" class="card">
        <view class="head">
          <view class="d-icon">
            <text class="mi d-mi">{{ platformIcon(d.platform) }}</text>
          </view>
          <view class="d-info">
            <text class="d-name">{{ d.device_name }}</text>
            <text class="d-sub">{{ d.platform }}<template v-if="d.version"> · v{{ d.version }}</template></text>
          </view>
          <text :class="['state', online(d.last_active_at) ? 'on' : 'off']">{{ online(d.last_active_at) ? '在线' : '离线' }}</text>
          <text class="mi d-del" @click="remove(d)">&#xe872;</text>
        </view>
        <view class="meta">
          <view class="m-col">
            <text class="m-value">{{ d.ip || '--' }}</text>
            <text class="m-label">IP</text>
          </view>
          <view class="m-sep"></view>
          <view class="m-col">
            <text class="m-value">{{ d.version ? 'v' + d.version : '--' }}</text>
            <text class="m-label">版本</text>
          </view>
          <view class="m-sep"></view>
          <view class="m-col">
            <text class="m-value m-time">{{ shortTime(d.last_active_at) }}</text>
            <text class="m-label">最近活跃</text>
          </view>
        </view>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { onWs, offWs } from '../../ws';

import { useThemeVars } from '../../theme';
const { tv, patternSrc } = useThemeVars();
import { ref } from 'vue';
import { onShow, onHide } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

type Device = { id: string; device_name: string; platform: string; ip?: string; version?: string; last_active_at: string };
const devices = ref<Device[]>([]);
const loading = ref(true);

const shortTime = (iso: string) => (iso && iso.length >= 16 ? `${iso.slice(0, 10)} ${iso.slice(11, 16)}` : iso || '');

/** 平台图标（Material 图标码点，对齐 App language/phone_iphone/smartphone 语义） */
const platformIcon = (platform: string) =>
  platform === 'Web' ? '&#xe894;' : platform === '小程序' ? '&#xe325;' : '&#xe32c;';

/** 在线判定：最近活跃 5 分钟内=在线（设备任意请求都会节流更新 last_active_at） */
const online = (iso: string) => {
  if (!iso) return false;
  const last = Date.parse(iso);
  return !isNaN(last) && Date.now() - last < 5 * 60 * 1000;
};

onShow(async () => {
  onWs('*', load);
  load();
  // 在线状态按时间衰减（5 分钟窗口），周期性刷新让"在线/离线"及时翻转
  timer = setInterval(() => {
    load();
  }, 60000);
});

onHide(() => {
  if (timer) clearInterval(timer);
  timer = null;
  offWs('*', load);
});

let timer: ReturnType<typeof setInterval> | null = null;

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
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh;  background: var(--page-bg); }
.loading { text-align: center; color: var(--text-sub); padding: 80rpx 0; font-size: 26rpx; }
.empty { display: flex; flex-direction: column; align-items: center; padding: 120rpx 0; gap: 12rpx; }
.empty-tx { font-size: 28rpx; color: var(--text-sub); }
.empty-sub { font-size: 22rpx; color: var(--text-sub); }
.list { display: flex; flex-direction: column; gap: 20rpx; }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 24rpx; }
.head { display: flex; align-items: center; gap: 20rpx; }
.d-icon {
  width: 72rpx; height: 72rpx; border-radius: 18rpx; background: var(--primary-soft);
  display: flex; align-items: center; justify-content: center; flex-shrink: 0;
}
.d-mi { font-size: 32rpx; color: var(--primary); }
.d-info { flex: 1; display: flex; flex-direction: column; gap: 4rpx; }
.d-name { font-size: 30rpx; font-weight: bold; color: var(--text-main); }
.d-sub { font-size: 22rpx; color: var(--text-sub); }
.state { font-size: 20rpx; padding: 4rpx 14rpx; border-radius: 999rpx; flex-shrink: 0; }
.state.on { background: var(--ok-bg); color: #22c55e; }
.state.off { background: var(--warn-bg); color: #e6a23c; }
.d-del { font-size: 34rpx; color: #f56c6c; padding: 8rpx 12rpx; flex-shrink: 0; }
.meta { display: flex; align-items: center; margin-top: 20rpx; padding-top: 20rpx; border-top: 1rpx solid var(--divider); }
.m-col { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 6rpx; min-width: 0; }
.m-sep { width: 1rpx; height: 40rpx; background: var(--divider); flex-shrink: 0; }
.m-label { font-size: 20rpx; color: var(--text-sub); }
.m-value { font-size: 26rpx; color: var(--text-main); font-weight: 600; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.m-time { font-size: 22rpx; }
</style>