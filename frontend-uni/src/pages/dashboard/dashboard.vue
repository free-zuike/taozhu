<template>
  <view class="page">
    <!-- 今日卡片 -->
    <view class="cards">
      <view class="card"><text class="cl">今日出货</text><text class="cv">¥{{ fmt(today.sales_total) }}</text></view>
      <view v-if="canSeeProfit" class="card"><text class="cl green">今日毛利</text><text class="cv green">¥{{ fmt(today.gross_profit) }}</text></view>
      <view class="card"><text class="cl">今日收款</text><text class="cv">¥{{ fmt(today.paid_total) }}</text></view>
      <view class="card"><text class="cl red">今日进货</text><text class="cv red">¥{{ fmt(today.purchase_total) }}</text></view>
      <view class="card"><text class="cl red">总欠款</text><text class="cv red">¥{{ fmt(totals.debt) }}</text></view>
      <view class="card"><text class="cl">饭店数</text><text class="cv">{{ totals.client_count }}</text></view>
    </view>

    <!-- 功能入口 -->
    <view class="entries">
      <button class="btn" @click="go('/pages/items/items')">商品管理</button>
      <button class="btn" @click="go('/pages/clients/clients')">饭店管理</button>
      <button class="btn" @click="go('/pages/categories/categories')">分类管理</button>
      <button class="btn" @click="go('/pages/ledger/ledger')">交易</button>
      <button class="btn" @click="go('/pages/payments/payments')">收款结账</button>
      <button class="btn" @click="go('/pages/statement/statement')">对账单</button>
      <button class="btn" @click="go('/pages/stocks/stocks')">库存</button>
      <button class="btn" @click="go('/pages/stats/stats')">统计</button>
      <button class="btn" @click="go('/pages/users/users')">账号管理</button>
      <button class="btn" @click="openServer">服务器设置</button>
    </view>

    <!-- 服务器设置弹层：切换域名（保存后清 token 回登录页重新登录，与切账号语义一致） -->
    <view v-if="showServer" class="mask" @click="showServer = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">服务器设置</view>
        <view class="server-cur">当前服务器：{{ curBase || '未设置' }}</view>
        <input class="ipt" v-model="serverInput" placeholder="https://你的服务器域名" />
        <button class="btn-save" :disabled="saving" @click="saveServer">{{ saving ? '保存中…' : '保存并重新登录' }}</button>
        <button class="btn-cancel" @click="showServer = false">取消</button>
      </view>
    </view>

    <!-- 欠款排行 -->
    <view class="list">
      <view class="list-title">欠款排行（前 5）</view>
      <view v-for="c in topDebt" :key="c.id" class="list-row">
        <text class="lr-name">{{ c.name }}</text>
        <text class="lr-debt red">¥{{ fmt(c.debt) }}</text>
      </view>
      <view v-if="topDebt.length === 0" class="empty">暂无数据</view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken, getApiBase, setApiBase, clearToken } from '../../api';

const today = ref({ sales_total: 0, gross_profit: 0, paid_total: 0, purchase_total: 0, sales_count: 0 });
const totals = ref({ debt: 0, client_count: 0, all_sales: 0, all_paid: 0, item_count: 0 });
const topDebt = ref<Array<{ id: string; name: string; debt: number }>>([]);
const canSeeProfit = ref(true); // 店员看不到毛利（后端 can_see_profit=false 时隐藏）
const fmt = (n: number) => Number(n || 0).toFixed(2);

// 服务器设置：切换域名（小程序无本地库，切服务器=清 token 回登录页重新登录）
const showServer = ref(false);
const saving = ref(false);
const curBase = ref(getApiBase());
const serverInput = ref(getApiBase());

function openServer() {
  curBase.value = getApiBase();
  serverInput.value = getApiBase();
  showServer.value = true;
}

async function saveServer() {
  const url = serverInput.value.trim().replace(/\/+$/, '');
  if (!url) {
    uni.showToast({ title: '请输入服务器地址（https://...）', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    setApiBase(url);
    // 切换服务器后原 token 属于旧服务器，清掉回登录页重新填账号密码
    clearToken();
    uni.showToast({ title: '服务器已切换，请重新登录', icon: 'none' });
    setTimeout(() => uni.reLaunch({ url: '/pages/login/login' }), 600);
  } catch (e) {
    uni.showToast({ title: '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  try {
    const d = await request<{ today: typeof today.value; totals: typeof totals.value; can_see_profit: boolean; top_debt_clients: Array<{ id: string; name: string; sales_total: number; paid_total: number; debt: number }> }>('/stats/overview', 'GET');
    today.value = d.today;
    totals.value = d.totals;
    topDebt.value = d.top_debt_clients;
    canSeeProfit.value = d.can_see_profit !== false;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
});

function go(url: string) {
  uni.navigateTo({ url });
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
/* 两列网格：小程序对 flex gap / calc(50% - x) 兼容性差，用 48% + space-between 最稳 */
.cards { display: flex; flex-wrap: wrap; justify-content: space-between; margin-bottom: 24rpx; }
.card {
  width: 48%; background: #fff; border-radius: 12rpx;
  padding: 22rpx 20rpx; box-sizing: border-box; margin-bottom: 16rpx;
}
.cl { display: block; color: #909399; font-size: 26rpx; margin-bottom: 10rpx; }
.cv { font-size: 38rpx; font-weight: bold; }
.green { color: #67c23a; }
.red { color: #f56c6c; }
.entries { display: flex; flex-wrap: wrap; justify-content: space-between; margin-bottom: 24rpx; }
.btn { width: 48%; margin: 0 0 16rpx; background: #fff; border-radius: 12rpx; font-size: 28rpx; }
.list { background: #fff; border-radius: 12rpx; padding: 24rpx; }
.list-title { font-size: 30rpx; font-weight: bold; margin-bottom: 16rpx; }
.list-row { display: flex; justify-content: space-between; padding: 16rpx 0; border-bottom: 1rpx solid #f0f0f0; }
.lr-name { font-size: 28rpx; }
.lr-debt { font-size: 28rpx; }
.empty { color: #c0c4cc; text-align: center; padding: 30rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: #fff; border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.server-cur { font-size: 24rpx; color: #909399; margin-bottom: 16rpx; word-break: break-all; }
.ipt { background: #f5f7fa; border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: #409eff; color: #fff; border-radius: 12rpx; font-size: 30rpx; margin-bottom: 12rpx; }
.btn-cancel { background: #f5f7fa; color: #909399; border-radius: 12rpx; font-size: 30rpx; }
</style>