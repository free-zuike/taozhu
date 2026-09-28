<template>
  <view class="page" :style="tv">
    <view class="group-title">配色主题</view>
    <view class="presets">
      <view v-for="p in presets" :key="p.id" class="preset" @click="cur = p.id">
        <view class="swatch" :style="{ background: p.color }">
          <text v-if="cur === p.id" class="check">✓</text>
        </view>
        <text class="p-name" :class="{ active: cur === p.id }">{{ p.name }}</text>
      </view>
    </view>

    <view class="group-title">明暗模式</view>
    <view class="mode-row">
      <view v-for="m in modes" :key="m.id" :class="['mode-pill', mode === m.id ? 'on' : '']" @click="mode = m.id">
        {{ m.name }}
      </view>
    </view>

    <view class="group-title">背景图案</view>
    <view class="presets">
      <view v-for="s in skins" :key="s.id" class="preset skin" @click="curSkin = s.id">
        <view class="swatch skin-swatch" :style="{ background: s.preview }">
          <text v-if="curSkin === s.id" class="check">✓</text>
        </view>
        <text class="p-name" :class="{ active: curSkin === s.id }">{{ s.name }}</text>
      </view>
    </view>

    <view class="tip">图案颜色跟随上方所选主题色；明暗切换立即生效</view>

    <button class="btn" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';
import { useThemeVars, setThemePrimary, setThemeMode, getThemeMode, type ThemeMode } from '../../theme';

const tv = useThemeVars();
const modes: Array<{ id: ThemeMode; name: string }> = [
  { id: 'follow', name: '跟随系统' },
  { id: 'light', name: '浅色' },
  { id: 'dark', name: '深色' },
];
const mode = ref<ThemeMode>(getThemeMode());
const presets = [
  { id: 'default', name: '默认蓝', color: '#409EFF' },
  { id: 'zhuhong', name: '陶朱红', color: '#C04633' },
  { id: 'gold', name: '富贵金', color: '#B8860B' },
  { id: 'green', name: '墨绿', color: '#2F7D63' },
  { id: 'navy', name: '藏青', color: '#2B5FD9' },
];
const skins = [
  { id: '', name: '渐变', preview: 'linear-gradient(180deg, #f4f9ff, #e6f0fb)' },
  { id: 'none', name: '纯色', preview: '#f5f7fa' },
  { id: 'coin', name: '铜钱', preview: 'radial-gradient(circle at 30% 35%, #fff 0 6rpx, transparent 7rpx), radial-gradient(circle at 70% 30%, #fff 0 5rpx, transparent 6rpx), radial-gradient(circle at 40% 70%, #fff 0 8rpx, transparent 9rpx), radial-gradient(circle at 80% 75%, #fff 0 5rpx, transparent 6rpx), #409EFF' },
  { id: 'bamboo', name: '竹韵', preview: 'linear-gradient(90deg, transparent 0 18%, #fff 18% 21%, transparent 21% 45%, #fff 45% 48%, transparent 48%), #2F7D63' },
  { id: 'ledger', name: '账本', preview: 'linear-gradient(0deg, #fff 0 8%, transparent 8% 50%, #fff 50% 58%, transparent 58%), linear-gradient(90deg, #fff 0 14%, transparent 14%), #409EFF' },
  { id: 'flow', name: '进销', preview: 'linear-gradient(135deg, transparent 0 45%, #fff 45% 55%, transparent 55%), linear-gradient(315deg, transparent 0 45%, #fff 45% 55%, transparent 55%), #C04633' },
  { id: 'ripple', name: '涟漪', preview: 'radial-gradient(circle at 35% 40%, transparent 0 10rpx, #fff 10rpx 14rpx, transparent 15rpx), radial-gradient(circle at 70% 65%, transparent 0 6rpx, #fff 6rpx 9rpx, transparent 10rpx), #409EFF' },
];
const cur = ref('default');
const curSkin = ref('');
const saving = ref(false);

onShow(async () => {
  if (!getToken()) return;
  try {
    const d = await request<{ preset_id?: string; skin_id?: string; bg_enabled?: boolean }>('/settings/theme_config', 'GET');
    if (d?.preset_id) cur.value = d.preset_id;
    if (d?.skin_id) curSkin.value = d.skin_id;
  } catch (e) {
    // 未配置使用默认
  }
});

async function save() {
  saving.value = true;
  try {
    await request('/settings/theme_config', 'PUT', { preset_id: cur.value, skin_id: curSkin.value, bg_enabled: true });
    const c = presets.find((p) => p.id === cur.value);
    if (c) setThemePrimary(c.color);
    setThemeMode(mode.value);
    tv.value = useThemeVars().value;
    uni.showToast({ title: '已保存，本页与其他端同步生效', icon: 'none' });
  } catch (e) {
    uni.showToast({ title: '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}
</script>

<style>
.page { padding: 24rpx; background: linear-gradient(180deg, var(--primary-fade) 0%, #f5f7fa 34%); min-height: 100vh; }
.group-title { font-size: 25rpx; color: var(--text-sub); margin: 8rpx 8rpx 20rpx; }
.presets { display: flex; flex-wrap: wrap; gap: 20rpx; background: var(--card-bg); border-radius: 20rpx; padding: 32rpx 24rpx; margin-bottom: 24rpx; }
.mode-row { display: flex; gap: 16rpx; background: var(--card-bg); border-radius: 20rpx; padding: 20rpx 24rpx; margin-bottom: 24rpx; }
.mode-pill { flex: 1; text-align: center; font-size: 26rpx; color: var(--text-sub); padding: 14rpx 0; border-radius: 12rpx; border: 2rpx solid var(--divider); }
.mode-pill.on { color: var(--primary); font-weight: bold; border-color: var(--primary); background: var(--primary-soft); }
.preset { width: 25%; display: flex; flex-direction: column; align-items: center; gap: 12rpx; }
.swatch {
  width: 88rpx; height: 88rpx; border-radius: 24rpx;
  display: flex; align-items: center; justify-content: center;
  border: 4rpx solid transparent;
}
.preset .swatch { box-shadow: 0 4rpx 12rpx rgba(0,0,0,0.12); }
.skin-swatch { width: 120rpx; height: 80rpx; border-radius: 16rpx; }
.check { color: #fff; font-size: 40rpx; font-weight: bold; }
.p-name { font-size: 24rpx; color: var(--text-sub); }
.p-name.active { color: var(--primary); font-weight: bold; }
.tip { font-size: 22rpx; color: var(--text-sub); margin: 24rpx 8rpx; }
.btn { background: var(--primary); color: #fff; border-radius: 14rpx; font-size: 30rpx; margin-top: 16rpx; }
</style>