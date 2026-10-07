<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="group-title">金额舍入（所有金额计算按此）</view>
    <view class="card">
      <view class="tip">进/出货行金额、合计、毛利、统计、欠款统一按此计算。历史数据存储不变，统计与欠款展示按新规则实时重算。</view>
    </view>

    <view class="group-title">进位临界（四舍五入的变体）</view>
    <view class="card">
      <view class="b-row" v-for="(p, i) in presets" :key="i" @click="carry = p.v">
        <view class="b-left">
          <text class="r-tx">{{ p.label }}</text>
        </view>
        <view :class="['radio', carry === p.v ? 'on' : '']"></view>
      </view>
    </view>

    <view class="group-title">精度（保留到多少分/角/元）</view>
    <view class="card">
      <view class="b-row" v-for="(d, i) in digitOpts" :key="i" @click="digits = d.v">
        <view class="b-left">
          <text class="r-tx">{{ d.label }}</text>
        </view>
        <view :class="['radio', digits === d.v ? 'on' : '']"></view>
      </view>
    </view>

    <button class="btn" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>

    <view class="group-title">店铺结账抹零（欠款按各店设置计算）</view>
    <view class="tip">记录金额不变，仅欠款面按店铺抹零方式/精度计算；点店铺修改</view>
    <view class="card">
      <view class="b-row" v-for="c in clients" :key="c.id" @click="editClientRounding(c)">
        <view class="b-left">
          <text class="r-tx">{{ c.name }}</text>
          <text class="r-sub">抹零：{{ stageLabel(c.round_stage, c.round_unit) }}</text>
        </view>
        <text class="r-arrow">›</text>
      </view>
      <view v-if="clients.length === 0" class="tip">暂无店铺</view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';
import { useThemeVars } from '../../theme';
import { initRounding, applyRounding, roundingCfg } from '../../utils/money';

const { tv, patternSrc } = useThemeVars();
const presets = [
  { label: '四舍五入（尾数≥5 进，<5 舍）', v: 0.5 },
  { label: '5舍6入（尾数 5 舍、≥6 进）', v: 0.6 },
  { label: '四舍六入（尾数≥7 进，更收紧）', v: 0.7 },
];
const digitOpts = [
  { label: '元（整数）', v: 0 },
  { label: '角（1 位小数）', v: 1 },
  { label: '分（2 位小数）', v: 2 },
];
const carry = ref(0.5);
const digits = ref(2);
const saving = ref(false);
const clients = ref<Array<Record<string, any>>>([]);

const stageNames = ['不抹零', '每单抹零', '按天抹零', '结账抹零'];
const stageValues = ['none', 'txn', 'day', 'total'];
const unitNames = ['元', '角', '分'];
const unitValues = ['yuan', 'jiao', 'fen'];
const stageLabel = (s: any, u: any) => {
  const si = stageValues.indexOf(String(s || 'none'));
  const ui = unitValues.indexOf(String(u || 'yuan'));
  return `${stageNames[si >= 0 ? si : 0]}${unitNames[ui >= 0 ? ui : 0]}`;
};

/// 店铺抹零设置：先选方式再选精度（对齐 App 店铺编辑弹窗两个下拉）
function editClientRounding(c: Record<string, any>) {
  uni.showActionSheet({
    itemList: stageNames,
    success: (r1) => {
      const stage = stageValues[r1.tapIndex] || 'none';
      uni.showActionSheet({
        itemList: unitNames,
        success: async (r2) => {
          const unit = unitValues[r2.tapIndex] || 'yuan';
          try {
            await request(`/clients/${c.id}`, 'PATCH', { round_stage: stage, round_unit: unit });
            c.round_stage = stage;
            c.round_unit = unit;
            uni.showToast({ title: '已保存（欠款按新口径重算）', icon: 'success' });
          } catch (e) {
            uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
          }
        },
      });
    },
  });
}

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  const c = roundingCfg();
  carry.value = c.carry;
  digits.value = c.digits;
  try {
    const d = await request<{ carry: number; digits: number }>('/settings/rounding', 'GET');
    if (d) {
      carry.value = Number(d.carry) || 0.5;
      digits.value = [0, 1, 2].includes(Number(d.digits)) ? Number(d.digits) : 2;
    }
  } catch (_) {}
  // 店铺抹零列表（欠款按各店口径；本地优先渲染+后台核对）
  try {
    const dc = await request<{ clients: Array<Record<string, any>> }>('/clients', 'GET');
    clients.value = dc.clients || [];
  } catch (_) {}
});

async function save() {
  saving.value = true;
  try {
    await request('/settings/rounding', 'PUT', { carry: carry.value, digits: digits.value });
    // 本地优先：服务器已接受 → 同步写本地缓存（立即生效且重进仍生效，不依赖网络回读）
    applyRounding(carry.value, digits.value);
    initRounding(); // 后台与服务器核对（失败静默，本地值已正确）
    uni.showToast({ title: '已保存（新记账按新规则）', icon: 'success' });
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}
</script>

<style scoped>
.page { padding: 24rpx 24rpx 60rpx; background: var(--page-bg); min-height: 100vh; }
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.group-title { font-size: 26rpx; color: #8a8f98; margin: 30rpx 8rpx 12rpx; font-weight: 700; }
.card { background: var(--card-bg, #fff); border: 1px solid var(--card-border, #eee); border-radius: 24rpx; padding: 10rpx 24rpx; }
.tip { font-size: 25rpx; color: var(--text-sub, #8a8f98); line-height: 1.6; padding: 16rpx 4rpx; }
.b-row { display: flex; align-items: center; justify-content: space-between; padding: 24rpx 4rpx; border-bottom: 1px solid var(--card-border, #f2f3f5); }
.b-left { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 6rpx; }
.r-tx { font-size: 30rpx; color: var(--text-main); }
.r-sub { font-size: 24rpx; color: var(--text-sub); }
.r-arrow { font-size: 32rpx; color: var(--text-sub); margin-left: 16rpx; }
.b-row:last-child { border-bottom: none; }
.r-tx { font-size: 28rpx; color: var(--text-main, #222); }
.radio { width: 36rpx; height: 36rpx; border-radius: 50%; border: 3rpx solid #c8ccd4; box-sizing: border-box; }
.radio.on { border-color: var(--primary, #f8c91c); border-width: 10rpx; }
.btn { margin-top: 60rpx; background: var(--primary, #f8c91c); color: #3a2e00; font-weight: 700; border-radius: 44rpx; }
</style>