<template>
  <view class="page">
    <view class="group-title">配色主题</view>
    <view class="presets">
      <view v-for="p in presets" :key="p.id" class="preset" @click="cur = p.id">
        <view class="swatch" :style="{ background: p.color }">
          <text v-if="cur === p.id" class="check">✓</text>
        </view>
        <text class="p-name" :class="{ active: cur === p.id }">{{ p.name }}</text>
      </view>
    </view>
    <view class="tip">选择配色后保存，App/Web 等端同步生效</view>
    <button class="btn" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

const presets = [
  { id: 'default', name: '默认蓝', color: '#409EFF' },
  { id: 'zhuhong', name: '陶朱红', color: '#C0392B' },
  { id: 'gold', name: '富贵金', color: '#D4A017' },
  { id: 'green', name: '墨绿', color: '#2F7D63' },
  { id: 'navy', name: '藏青', color: '#2B5FD9' },
];
const cur = ref('default');
const saving = ref(false);

onShow(async () => {
  if (!getToken()) return;
  try {
    const d = await request<{ preset_id?: string; skin_id?: string; bg_enabled?: boolean }>('/settings/theme_config', 'GET');
    if (d?.preset_id) cur.value = d.preset_id;
  } catch (e) {
    // 未配置使用默认
  }
});

async function save() {
  saving.value = true;
  try {
    await request('/settings/theme_config', 'PUT', { preset_id: cur.value, skin_id: '', bg_enabled: true });
    uni.showToast({ title: '已保存，其他端同步生效', icon: 'none' });
  } catch (e) {
    uni.showToast({ title: '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.group-title { font-size: 25rpx; color: #909399; margin: 8rpx 8rpx 20rpx; }
.presets { display: flex; flex-wrap: wrap; gap: 24rpx; background: #fff; border-radius: 20rpx; padding: 32rpx 24rpx; }
.preset { width: 25%; display: flex; flex-direction: column; align-items: center; gap: 12rpx; }
.swatch {
  width: 88rpx; height: 88rpx; border-radius: 24rpx;
  display: flex; align-items: center; justify-content: center;
  border: 4rpx solid transparent;
}
.preset .swatch { box-shadow: 0 4rpx 12rpx rgba(0,0,0,0.12); }
.preset[data-active] {
  /* 无动态选择态用 class */
}
.check { color: #fff; font-size: 40rpx; font-weight: bold; }
.p-name { font-size: 24rpx; color: #606266; }
.p-name.active { color: #409eff; font-weight: bold; }
.tip { font-size: 22rpx; color: #909399; margin: 24rpx 8rpx; }
.btn { background: #409eff; color: #fff; border-radius: 14rpx; font-size: 30rpx; margin-top: 16rpx; }
</style>