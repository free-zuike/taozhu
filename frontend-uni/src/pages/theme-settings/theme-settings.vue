<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="group-title">配色主题</view>
    <view class="presets">
      <view v-for="p in presets" :key="p.id" class="preset" @click="pickPreset(p)">
        <view class="swatch" :style="{ background: p.color }">
          <text v-if="cur === p.id" class="check">✓</text>
        </view>
        <text class="p-name" :class="{ active: cur === p.id }">{{ p.name }}</text>
      </view>
    </view>

    <view class="group-title">明暗模式</view>
    <view class="mode-row">
      <view v-for="m in modes" :key="m.id" :class="['mode-pill', mode === m.id ? 'on' : '']" @click="pickMode(m.id)">
        {{ m.name }}
      </view>
    </view>

    <view class="group-title">背景图案</view>
    <view class="skins">
      <view v-for="s in skins" :key="s.id" class="skin" :class="{ sel: curSkin === s.id }" @click="pickSkin(s.id)">
        <view class="swatch skin-swatch" :style="{ background: typeof s.preview === 'function' ? s.preview(selectedColor()) : s.preview }">
          <text v-if="curSkin === s.id" class="check">✓</text>
        </view>
        <text class="p-name" :class="{ active: curSkin === s.id }">{{ s.name }}</text>
      </view>
    </view>

    <view class="group-title">实时预览</view>
    <view class="pv-card" :style="{ background: skinPreview() }">
      <view class="pv-head">
        <view class="pv-logo" :style="{ background: selectedColor() }"><text class="mi">&#xe7f1;</text></view>
        <text class="pv-title">预览</text>
        <text class="pv-badge" :style="{ color: selectedColor(), background: selectedColor() + '26' }">本月结余</text>
      </view>
      <view class="pv-sheet">
        <view class="pv-line" style="width: 40%"></view>
        <view class="pv-line" style="width: 60%"></view>
        <view class="pv-btns">
          <view class="pv-btn" :style="{ background: selectedColor() }">按钮</view>
          <view class="pv-btn-o" :style="{ color: selectedColor(), borderColor: selectedColor() }">次要按钮</view>
        </view>
      </view>
    </view>

    <view class="tip">选择即生效并同步其他端；图案颜色跟随所选主题色，明暗切换立即生效</view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';
import { useThemeVars, setThemePrimary, setThemeMode, setThemeSkin, getThemeMode, getThemeSkin, getThemePrimary, isDark, skinPreviewCss, type ThemeMode } from '../../theme';

const { tv, patternSrc, refresh } = useThemeVars();
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
// 图案预览用真实 SVG 迷你图（与 App/Web CustomPainter 同几何，颜色随主题主色+明暗）
const skins = [
  { id: '', name: '渐变', preview: (p: string) => skinPreviewCss('', p, isDark()) },
  { id: 'none', name: '纯色', preview: (p: string) => skinPreviewCss('none', p, isDark()) },
  { id: 'coin', name: '铜钱', preview: (p: string) => skinPreviewCss('coin', p, isDark()) },
  { id: 'bamboo', name: '竹韵', preview: (p: string) => skinPreviewCss('bamboo', p, isDark()) },
  { id: 'ledger', name: '账本', preview: (p: string) => skinPreviewCss('ledger', p, isDark()) },
  { id: 'flow', name: '进销', preview: (p: string) => skinPreviewCss('flow', p, isDark()) },
  { id: 'ripple', name: '涟漪', preview: (p: string) => skinPreviewCss('ripple', p, isDark()) },
];
// 当前选中主题色：从本地已存主题色反推对应预设（不写死 default——
// 服务器拉取失败/离线时仍回选真实生效色，否则每次重开都显示选中 default）
const cur = ref(
  presets.find((p) => p.color.toLowerCase() === getThemePrimary().toLowerCase())?.id ?? 'default',
);
const curSkin = ref(getThemeSkin());
/** 点击即生效 + 自动同步服务器（无保存按钮；主题配置=配置类，点击直接 PUT 服务器，其他端 WS 即时应用） */
function applyLocal() {
  setThemeMode(mode.value);
  setThemeSkin(curSkin.value);
  const c = presets.find((p) => p.id === cur.value);
  if (c) setThemePrimary(c.color);
  refresh();
  applyTabBar();
  pushTheme();
}
/** 立即同步主题配置到服务器（小程序直连架构，无本地库；失败静默，下次进入再同步） */
async function pushTheme() {
  if (!getToken()) return;
  try {
    await request('/settings/theme_config', 'PUT', { preset_id: cur.value, skin_id: curSkin.value, bg_enabled: true });
  } catch (_) {}
}
/** tabBar 深色适配：跟随当前明暗模式动态设置底部栏配色（微信原生 tabBar 不随 CSS 变量） */
function applyTabBar() {
  try {
    const dark = isDark();
    const primary = getThemePrimary();
    uni.setTabBarStyle({
      color: dark ? '#9aa2b3' : '#909399',
      selectedColor: primary,
      backgroundColor: dark ? '#181b22' : '#ffffff',
      borderStyle: dark ? 'black' : 'white',
    });
  } catch (_) {}
}
function pickPreset(p: { id: string; color: string }) {
  cur.value = p.id;
  applyLocal();
}
function pickMode(m: ThemeMode) {
  mode.value = m;
  applyLocal();
}
function pickSkin(id: string) {
  curSkin.value = id;
  applyLocal();
}
/** 当前选中主题色的 hex（供图案预览实时取色） */
const selectedColor = () => (presets.find((p) => p.id === cur.value)?.color ?? '#409EFF');
/** 当前选中主题色的图案预览（随配色实时变化） */
const skinPreview = (): string => {
  const p = selectedColor();
  const s = skins.find((x) => x.id === curSkin.value);
  if (s && typeof s.preview === 'function') return s.preview(p);
  return typeof s?.preview === 'string' ? s.preview : '#f5f7fa';
};

onShow(async () => {
  if (!getToken()) return;
  try {
    const d = await request<{ preset_id?: string; skin_id?: string; bg_enabled?: boolean }>('/settings/theme_config', 'GET');
    if (d?.preset_id) cur.value = d.preset_id;
    if (d?.skin_id) curSkin.value = d.skin_id;
    if (d?.preset_id || d?.skin_id) {
      applyLocal();
    }
  } catch (e) {
    // 未配置使用默认
  }
});
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { padding: 24rpx;  min-height: 100vh;  background: var(--page-bg); }
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
/* 背景图案缩略图：2 列大格（对齐 App GridView 2 列），预览随主题色+明暗 */
.skins { display: flex; flex-wrap: wrap; gap: 20rpx; background: var(--card-bg); border-radius: 20rpx; padding: 24rpx; margin-bottom: 24rpx; }
.skin { width: calc(50% - 10rpx); display: flex; flex-direction: column; align-items: center; gap: 10rpx; }
.skin .skin-swatch { width: 100%; height: 170rpx; border-radius: 16rpx; border: 4rpx solid transparent; box-sizing: border-box; }
.skin.sel .skin-swatch { border-color: var(--primary); }
/* 实时预览卡（对齐 App：当前背景+卡片+按钮） */
.pv-card { border-radius: 20rpx; padding: 24rpx; margin-bottom: 8rpx; border: 1px solid rgba(0,0,0,0.05); }
.pv-head { display: flex; align-items: center; gap: 12rpx; }
.pv-logo { width: 44rpx; height: 44rpx; border-radius: 10rpx; display: flex; align-items: center; justify-content: center; }
.pv-logo .mi { color: #fff; font-size: 26rpx; }
.pv-title { font-size: 26rpx; font-weight: 600; color: var(--text-main); flex: 1; }
.pv-badge { font-size: 18rpx; padding: 4rpx 12rpx; border-radius: 8rpx; opacity: 0.9; }
.pv-sheet { margin-top: 18rpx; background: var(--card-bg); border-radius: 14rpx; padding: 20rpx; }
.pv-line { height: 14rpx; background: var(--divider); border-radius: 7rpx; margin-bottom: 12rpx; }
.pv-btns { display: flex; gap: 16rpx; margin-top: 8rpx; }
.pv-btn { flex: 1; height: 60rpx; border-radius: 12rpx; color: #fff; font-size: 24rpx; display: flex; align-items: center; justify-content: center; }
.pv-btn-o { flex: 1; height: 60rpx; border-radius: 12rpx; border: 2rpx solid; font-size: 24rpx; display: flex; align-items: center; justify-content: center; background: var(--card-bg); }
</style>