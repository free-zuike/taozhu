<template>
  <view class="page">
    <!-- 用户卡：账号名 + 角色 -->
    <view class="user-card">
      <view class="avatar">{{ (user.name || '陶').slice(0, 1) }}</view>
      <view class="user-info">
        <text class="user-name">{{ user.name || '未登录' }}</text>
        <text class="user-role">{{ user.role === 'staff' ? '店员' : '老板' }}</text>
      </view>
      <text class="server-tag" @click="openServer">服务器 ▾</text>
    </view>

    <!-- 统计卡（老板）：今日出货 / 总欠款 / 本月结余 -->
    <view v-if="isAdmin" class="stats">
      <view class="stat"><text class="st-label">今日出货</text><text class="st-value">¥{{ fmt(stats.sales_total) }}</text></view>
      <view class="stat"><text class="st-label">今日收款</text><text class="st-value green">¥{{ fmt(stats.paid_total) }}</text></view>
      <view class="stat"><text class="st-label">总欠款</text><text class="st-value red">¥{{ fmt(stats.debt) }}</text></view>
    </view>

    <view class="group-title">经营</view>
    <view class="grp">
      <view v-if="isAdmin" class="row" @click="go('/pages/clients/clients')"><text class="r-ic">🏪</text><text class="r-tx">店铺管理</text><text class="r-arrow">›</text></view>
      <view v-if="isAdmin" class="row" @click="go('/pages/payments/payments')"><text class="r-ic">💰</text><text class="r-tx">收款结账</text><text class="r-arrow">›</text></view>
      <view v-if="isAdmin" class="row" @click="go('/pages/statement/statement')"><text class="r-ic">📄</text><text class="r-tx">对账单</text><text class="r-arrow">›</text></view>
    </view>

    <view class="group-title">商品与库存</view>
    <view class="grp">
      <view class="row" @click="go('/pages/stocks/stocks')"><text class="r-ic">📊</text><text class="r-tx">库存</text><text class="r-arrow">›</text></view>
      <view class="row" @click="go('/pages/items/items')"><text class="r-ic">📦</text><text class="r-tx">商品管理</text><text class="r-arrow">›</text></view>
      <view class="row" @click="go('/pages/categories/categories')"><text class="r-ic">🗂️</text><text class="r-tx">分类管理</text><text class="r-arrow">›</text></view>
      <view class="row" @click="go('/pages/stats/stats')"><text class="r-ic">📈</text><text class="r-tx">统计</text><text class="r-arrow">›</text></view>
    </view>

    <view class="group-title">系统</view>
    <view class="grp">
      <view v-if="isAdmin" class="row" @click="go('/pages/users/users')"><text class="r-ic">👥</text><text class="r-tx">账号管理</text><text class="r-arrow">›</text></view>
      <view class="row" @click="checkUpdate"><text class="r-ic">🔄</text><text class="r-tx">检查更新</text><text class="r-arrow">›</text></view>
    </view>

    <button class="logout" @click="logout">退出登录</button>
    <view class="ver">陶朱 小程序</view>

    <!-- 服务器设置弹层：切换域名（保存后清 token 回登录页重新登录） -->
    <view v-if="showServer" class="mask" @click="showServer = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">服务器设置</view>
        <view class="server-cur">当前服务器：{{ curBase || '未设置' }}</view>
        <input class="ipt" v-model="serverInput" placeholder="https://你的服务器域名" />
        <button class="btn-save" :disabled="saving" @click="saveServer">{{ saving ? '保存中…' : '保存并重新登录' }}</button>
        <button class="btn-cancel" @click="showServer = false">取消</button>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getRole, getToken, getApiBase, setApiBase, clearToken } from '../../api';

const user = ref({ name: '', role: '' });
const isAdmin = ref(true);
const stats = ref({ sales_total: 0, paid_total: 0, debt: 0 });
const fmt = (n: number) => Number(n || 0).toFixed(2);

const showServer = ref(false);
const saving = ref(false);
const curBase = ref(getApiBase());
const serverInput = ref(getApiBase());

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  isAdmin.value = getRole() !== 'staff';
  user.value = { name: (uni.getStorageSync('taozhu_username') as string) || '老板', role: getRole() };
  try {
    const d = await request<{ user?: { username?: string; display_name?: string; role?: string } }>('/auth/me', 'GET').catch(() => null);
    if (d?.user) {
      user.value = {
        name: (d.user.display_name || d.user.username || user.value.name),
        role: isAdmin.value ? '老板' : '店员',
      };
    }
  } catch (e) {
    // 用户信息拉取失败不阻塞页面
  }
  loadStats();
});

async function loadStats() {
  if (!isAdmin.value) return;
  try {
    const d = await request<{ today?: Record<string, number>; totals?: Record<string, number> }>('/stats/overview', 'GET').catch(() => null);
    if (d) {
      stats.value = {
        sales_total: Number(d.today?.sales_total || 0),
        paid_total: Number(d.today?.paid_total || 0),
        debt: Number(d.totals?.debt || 0),
      };
    }
  } catch (e) {
    // 统计失败静默
  }
}

function go(url: string) {
  // tabBar 页必须 switchTab；普通页 navigateTo
  const tabs = ['/pages/ledger/ledger', '/pages/stats/stats', '/pages/quick/quick', '/pages/purchase-history/purchase-history', '/pages/my/my'];
  if (tabs.includes(url)) {
    uni.switchTab({ url });
  } else {
    uni.navigateTo({ url });
  }
}

function checkUpdate() {
  uni.showToast({ title: '小程序随版本自动更新，刷新即可', icon: 'none' });
}

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
    clearToken();
    uni.showToast({ title: '服务器已切换，请重新登录', icon: 'none' });
    setTimeout(() => uni.reLaunch({ url: '/pages/login/login' }), 600);
  } catch (e) {
    uni.showToast({ title: '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

function logout() {
  uni.showModal({
    title: '退出登录',
    content: '确定退出当前账号吗？',
    success: (r) => {
      if (r.confirm) {
        clearToken();
        uni.reLaunch({ url: '/pages/login/login' });
      }
    },
  });
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.user-card {
  display: flex; align-items: center; gap: 20rpx;
  background: linear-gradient(135deg, #409eff, #60a5fa);
  border-radius: 16rpx; padding: 32rpx 28rpx; margin-bottom: 20rpx; color: #fff;
}
.avatar {
  width: 88rpx; height: 88rpx; border-radius: 50%; background: rgba(255,255,255,0.25);
  display: flex; align-items: center; justify-content: center; font-size: 40rpx; font-weight: bold; flex-shrink: 0;
}
.user-info { flex: 1; display: flex; flex-direction: column; gap: 6rpx; }
.user-name { font-size: 32rpx; font-weight: bold; }
.user-role { font-size: 22rpx; opacity: 0.85; }
.server-tag { font-size: 24rpx; background: rgba(255,255,255,0.2); border-radius: 999rpx; padding: 8rpx 20rpx; flex-shrink: 0; }
.stats { display: flex; background: #fff; border-radius: 16rpx; padding: 24rpx 12rpx; margin-bottom: 24rpx; }
.stat { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 8rpx; }
.st-label { font-size: 22rpx; color: #909399; }
.st-value { font-size: 30rpx; font-weight: bold; color: #303133; }
.green { color: #67c23a; }
.red { color: #f56c6c; }
.group-title { font-size: 26rpx; color: #909399; margin: 8rpx 8rpx 12rpx; }
.grp { background: #fff; border-radius: 16rpx; margin-bottom: 20rpx; overflow: hidden; }
.row { display: flex; align-items: center; padding: 26rpx 24rpx; border-bottom: 1rpx solid #f5f5f5; }
.row:last-child { border-bottom: none; }
.r-ic { font-size: 34rpx; margin-right: 20rpx; }
.r-tx { flex: 1; font-size: 28rpx; color: #303133; }
.r-arrow { font-size: 34rpx; color: #c0c4cc; }
.logout { margin: 24rpx 0 16rpx; background: #fff; color: #f56c6c; border-radius: 16rpx; font-size: 30rpx; border: 1rpx solid #f56c6c; }
.ver { text-align: center; color: #c0c4cc; font-size: 22rpx; margin-top: 8rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: #fff; border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.server-cur { font-size: 24rpx; color: #909399; margin-bottom: 16rpx; word-break: break-all; }
.ipt { background: #f5f7fa; border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: #409eff; color: #fff; border-radius: 12rpx; font-size: 30rpx; margin-bottom: 12rpx; }
.btn-cancel { background: #f5f7fa; color: #606266; border-radius: 12rpx; font-size: 30rpx; }
</style>