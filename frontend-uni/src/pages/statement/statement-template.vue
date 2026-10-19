<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="sec-tip">选择对账单排版模板（云端同步：App 设计器保存的模板自动出现在这里）</view>
    <view v-for="t in list" :key="t.name" :class="['card', { on: cur === t.name }]" @click="show = show === t.name ? '' : t.name">
      <view class="head">
        <view class="left">
          <view class="name-line">
            <text class="name">{{ t.name }}</text>
            <text v-if="cur === t.name" class="badge">当前使用</text>
          </view>
          <text class="desc">{{ t.orientation === 'landscape' ? '横版打印' : '竖版打印' }}{{ t.grid.length ? ` · ${t.grid.length} 行网格` : '' }}</text>
        </view>
        <text class="arrow">›</text>
      </view>
      <view v-if="show === t.name" class="detail">
        <text class="dt">网格模板（{{ t.grid.length }} 行 × {{ t.colAligns.length || '多' }} 列），标题「{{ t.title }}」；保存于云端，多端共用。</text>
        <view class="ops" @click.stop>
          <view class="op" @click="pick(t.name)">使用此模板</view>
        </view>
      </view>
    </view>
    <view v-if="list.length === 0" class="empty">暂无模板，请先在 App 端模板设计器创建，或恢复默认</view>
    <button class="btn" @click="reset">恢复默认布局</button>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onLoad } from '@dcloudio/uni-app';
import { useThemeVars } from '../../theme';
import { request, appLog } from '../../api';
import { xlsCfgFromJson, defaultStdTemplate, defaultMultiTemplate, type XlsCfg } from '../../utils/stmt-tmpl';

const { tv, patternSrc } = useThemeVars();
const TPL_KEY = 'taozhu_stmt_tpl';
const cur = ref<string>('');
const show = ref<string>('');
const list = ref<XlsCfg[]>([]);

/// 旧值兼容：std→标准、multi→多栏（旧版本存 'std'/'multi'，新版本存模板名）
function normalizeName(v: string): string {
  if (v === 'std') return '标准';
  if (v === 'multi') return '多栏';
  return v;
}

onLoad(() => {
  cur.value = normalizeName(String(uni.getStorageSync(TPL_KEY) || '标准'));
  loadTemplates();
});

async function loadTemplates() {
  try {
    const d = await request<{ templates?: Array<Record<string, any>> }>('/stmt-templates', 'GET');
    const cloud = (d?.templates ?? []).map((j) => xlsCfgFromJson(j)).filter((t) => t.name);
    list.value = cloud.length > 0 ? cloud : [defaultStdTemplate(), defaultMultiTemplate()];
  } catch (_) {
    list.value = [defaultStdTemplate(), defaultMultiTemplate()];
  }
  // 当前选中名不在列表（云端被删/重置）→ 回退第一条
  if (!list.value.some((t) => t.name === cur.value)) cur.value = list.value[0]?.name ?? '标准';
}

function pick(name: string) {
  uni.setStorageSync(TPL_KEY, name);
  cur.value = name;
  appLog('op', `对账单模板 切换：「${name}」`, 'info');
  uni.showToast({ title: `已切换到「${name}」`, icon: 'success' });
  setTimeout(() => uni.navigateBack(), 500);
}

function reset() {
  uni.removeStorageSync(TPL_KEY);
  cur.value = '标准';
  appLog('op', '对账单模板 恢复默认布局', 'info');
  uni.showToast({ title: '已恢复默认（标准）', icon: 'success' });
  setTimeout(() => uni.navigateBack(), 500);
}
</script>

<style scoped>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh; padding: 24rpx; box-sizing: border-box; background: var(--page-bg); }
.sec-tip { font-size: 24rpx; color: var(--text-sub); margin-bottom: 20rpx; }
.card { background: var(--card-bg); border: 2rpx solid var(--divider); border-radius: 16rpx; padding: 24rpx; margin-bottom: 16rpx; }
.card.on { border-color: var(--primary); }
.head { display: flex; align-items: center; }
.left { flex: 1; min-width: 0; }
.name-line { display: flex; align-items: center; gap: 12rpx; }
.name { font-size: 30rpx; font-weight: 700; color: var(--text-main); }
.badge { font-size: 20rpx; color: #fff; background: var(--primary); border-radius: 6rpx; padding: 2rpx 12rpx; }
.desc { display: block; font-size: 24rpx; color: var(--text-sub); margin-top: 8rpx; }
.arrow { font-size: 34rpx; color: var(--text-sub); }
.detail { margin-top: 16rpx; border-top: 1rpx solid var(--divider); padding-top: 16rpx; }
.dt { font-size: 24rpx; color: var(--text-main); line-height: 1.6; }
.ops { margin-top: 16rpx; }
.op { background: var(--primary); color: #fff; text-align: center; padding: 16rpx 0; border-radius: 10rpx; font-size: 28rpx; }
.empty { font-size: 24rpx; color: var(--text-sub); text-align: center; padding: 40rpx 0; }
.btn { margin-top: 24rpx; background: var(--danger-bg); color: #f56c6c; font-weight: 700; border-radius: 44rpx; }
</style>
