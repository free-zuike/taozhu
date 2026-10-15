<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="sec-tip">选择对账单排版模板，返回对账单页立即生效（对齐 App「模板设置」入口）</view>
    <view v-for="t in list" :key="t.id" :class="['card', { on: cur === t.id }]" @click="show = show === t.id ? '' : t.id">
      <view class="head">
        <view class="left">
          <view class="name-line">
            <text class="name">{{ t.name }}</text>
            <text v-if="cur === t.id" class="badge">当前使用</text>
          </view>
          <text class="desc">{{ t.desc }}</text>
        </view>
        <text class="arrow">›</text>
      </view>
      <view v-if="show === t.id" class="detail">
        <text class="dt">{{ t.detail }}</text>
        <view class="ops" @click.stop>
          <view class="op" @click="pick(t.id)">使用此模板</view>
        </view>
      </view>
    </view>
    <button class="btn" @click="reset">恢复默认布局</button>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { useThemeVars } from '../../theme';
import { appLog } from '../../api';

const { tv, patternSrc } = useThemeVars();
const TPL_KEY = 'taozhu_stmt_tpl';
const cur = ref<string>((uni.getStorageSync(TPL_KEY) as string) || 'std');
const show = ref<string>('');

// 内置两模板（对齐 App 内置「标准」「多栏」展开网格）：选择决定对账单页默认预览
const list = [
  {
    id: 'std',
    name: '标准',
    desc: '单栏逐日金额表',
    detail: '标题「店铺 x月份账单」→ 日期/营业额表头（无底色）→ 1..当月天数逐行（每天营业额，无数据日=0）→ 合计行。金额纯数字不带 ¥，与「总计 41349.81」示例口径一致。',
  },
  {
    id: 'multi',
    name: '多栏',
    desc: '寻牛记式每栏 10 天，31 天→4 栏',
    detail: '标题 → 每栏「日期|营业额」左右两列（31 天月共 8 列）→ 每栏栏底小计 → 底部总计。月末超出天数补空格保留表格线成矩形；金额纯数字不带 ¥。',
  },
];

function pick(id: string) {
  uni.setStorageSync(TPL_KEY, id);
  cur.value = id;
  appLog('op', `对账单模板 切换：「${list.find((t) => t.id === id)?.name}」`, 'info');
  uni.showToast({ title: `已切换到「${list.find((t) => t.id === id)?.name}」`, icon: 'success' });
  setTimeout(() => uni.navigateBack(), 500);
}

function reset() {
  uni.removeStorageSync(TPL_KEY);
  cur.value = 'std';
  appLog('op', '对账单模板 恢复默认布局', 'info');
  uni.showToast({ title: '已恢复默认（标准）', icon: 'success' });
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
.btn { margin-top: 24rpx; background: var(--danger-bg); color: #f56c6c; font-weight: 700; border-radius: 44rpx; }
</style>