<template>
  <view class="page" :style="tv">
    <!-- 头部：头像 + 问候语与名字一行（对齐 App） -->
    <view class="head">
      <image v-if="avatarUrl" class="avatar-img" :src="avatarUrl" mode="aspectFill" />
      <view v-else class="avatar">{{ (user.name || '陶').slice(0, 1) }}</view>
      <view class="head-info">
        <view class="hi-line">
          <text class="hi">{{ greeting }}</text>
          <text class="hi-name">{{ user.name || '未登录' }}</text>
        </view>
        <text class="hi-sub">{{ user.role === 'staff' ? '店员' : '老板' }} · {{ curBase || '未设置服务器地址' }}</text>
      </view>
      <text class="server-tag" @click="openServer">切换 ▾</text>
    </view>

    <!-- 统计三列（老板）：记账天数 / 本店交易 / 店铺结余 -->
    <view v-if="isAdmin" class="stats">
      <view class="stat">
        <text class="st-value">{{ stats.bookDays }}</text>
        <text class="st-label">记账天数</text>
      </view>
      <view class="stat-line"></view>
      <view class="stat">
        <text class="st-value">{{ stats.clientCount }}</text>
        <text class="st-label">本店交易</text>
      </view>
      <view class="stat-line"></view>
      <view class="stat">
        <text class="st-value" :class="{ green: stats.balance >= 0, red: stats.balance < 0 }">¥{{ fmt(stats.balance) }}</text>
        <text class="st-label">店铺结余</text>
      </view>
    </view>

    <view class="group-title">经营</view>
    <view class="grp">
      <view v-if="isAdmin" class="row" @click="go('/pages/clients/clients')">
        <view class="r-ic ic-blue"><text class="ic-tx">🏪</text></view><text class="r-tx">店铺管理</text><text class="r-arrow">›</text>
      </view>
      <view v-if="isAdmin" class="row" @click="go('/pages/payments/payments')">
        <view class="r-ic ic-green"><text class="ic-tx">💰</text></view><text class="r-tx">收款结账</text><text class="r-arrow">›</text>
      </view>
      <view v-if="isAdmin" class="row" @click="go('/pages/statement/statement')">
        <view class="r-ic ic-orange"><text class="ic-tx">📄</text></view><text class="r-tx">对账单</text><text class="r-arrow">›</text>
      </view>
    </view>

    <view class="group-title">商品与库存</view>
    <view class="grp">
      <view class="row" @click="go('/pages/stocks/stocks')">
        <view class="r-ic ic-blue"><text class="ic-tx">📊</text></view><text class="r-tx">库存</text><text class="r-arrow">›</text>
      </view>
      <view class="row" @click="go('/pages/items/items')">
        <view class="r-ic ic-green"><text class="ic-tx">📦</text></view><text class="r-tx">商品管理</text><text class="r-arrow">›</text>
      </view>
      <view class="row" @click="go('/pages/categories/categories')">
        <view class="r-ic ic-orange"><text class="ic-tx">🗂️</text></view><text class="r-tx">分类管理</text><text class="r-arrow">›</text>
      </view>
      <view class="row" @click="go('/pages/stats/stats')">
        <view class="r-ic ic-purple"><text class="ic-tx">📈</text></view><text class="r-tx">统计</text><text class="r-arrow">›</text>
      </view>
    </view>

    <view class="group-title">系统</view>
    <view class="grp">
      <view v-if="isAdmin" class="row" @click="go('/pages/users/users')">
        <view class="r-ic ic-blue"><text class="ic-tx">👥</text></view><text class="r-tx">账号管理</text><text class="r-arrow">›</text>
      </view>
      <view v-if="isAdmin" class="row" @click="go('/pages/ai-settings/ai-settings')">
        <view class="r-ic ic-purple"><text class="ic-tx">🤖</text></view><text class="r-tx">AI 识别设置</text><text class="r-arrow">›</text>
      </view>
      <view class="row" @click="go('/pages/theme-settings/theme-settings')">
        <view class="r-ic ic-gold"><text class="ic-tx">🎨</text></view><text class="r-tx">主题设置</text><text class="r-arrow">›</text>
      </view>
      <view v-if="isAdmin" class="row" @click="go('/pages/devices/devices')">
        <view class="r-ic ic-green"><text class="ic-tx">📱</text></view><text class="r-tx">设备管理</text><text class="r-arrow">›</text>
      </view>
      <view class="row" @click="go('/pages/backup/backup')">
        <view class="r-ic ic-orange"><text class="ic-tx">💾</text></view><text class="r-tx">数据备份</text><text class="r-arrow">›</text>
      </view>
      <view class="row" @click="checkUpdate">
        <view class="r-ic ic-blue"><text class="ic-tx">🔄</text></view><text class="r-tx">检查更新</text><text class="r-arrow">›</text>
      </view>
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
import { useThemeVars } from '../../theme';
const tv = useThemeVars();
import { ref, computed } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getRole, getToken, getApiBase, setApiBase, clearToken } from '../../api';

const user = ref({ name: '', role: '' });
const isAdmin = ref(true);
// 头像（/auth/avatar?token= 带鉴权，小程序 image 组件无法带 header）
const avatarUrl = ref('');
// 问候语（对齐 App：早上好/下午好/晚上好）
const greeting = computed(() => {
  const h = new Date().getHours();
  if (h >= 5 && h < 12) return '早上好';
  if (h >= 12 && h < 18) return '下午好';
  if (h >= 18 && h < 23) return '晚上好';
  return '夜深了，注意休息';
});
// 对齐 App 我的页统计卡：记账天数 / 本店交易（商品行数） / 店铺结余（当前店铺毛利）
const stats = ref({ bookDays: 0, clientCount: 0, balance: 0 });
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
    const d = await request<{ user?: { username?: string; display_name?: string; role?: string; avatar?: string | null } }>('/auth/me', 'GET').catch(() => null);
    if (d?.user) {
      user.value = {
        name: (d.user.display_name || d.user.username || user.value.name),
        role: isAdmin.value ? '老板' : '店员',
      };
      avatarUrl.value = d.user.avatar ? `${getApiBase()}/api/v1/auth/avatar?token=${getToken()}` : '';
    }
  } catch (e) {
    // 用户信息拉取失败不阻塞页面
  }
  loadStats();
});

async function loadStats() {
  if (!isAdmin.value) return;
  try {
    // 记账天数：最早一笔记账（出货/进货/收款并集）到今天；店铺结余/本店交易：当前店铺全区间毛利+商品行数
    const y = await request<{ years: number[]; first_date?: string }>('/stats/years', 'GET').catch(() => null);
    const first = y?.first_date || '';
    if (!first) {
      stats.value = { bookDays: 0, clientCount: 0, balance: 0 };
      return;
    }
    const now = new Date();
    const fd = new Date(first.replace(/-/g, '/'));
    const days = Math.max(1, Math.floor((now.getTime() - fd.getTime()) / 86400000) + 1);
    const today = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
    const cid = (uni.getStorageSync('taozhu_cur_client') as string) || '';
    const cq = cid ? `&client_id=${cid}` : '';
    const sum = await request<Record<string, any>>(`/stats/summary?start=${first}&end=${today}${cq}`, 'GET').catch(() => null);
    stats.value = {
      bookDays: days,
      clientCount: Number(sum?.sales_count || 0),
      balance: Number(sum?.gross_profit || 0),
    };
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
.page {
  background:
      radial-gradient(circle at 18% 12%, var(--primary-soft) 0 6rpx, transparent 10rpx),
      radial-gradient(circle at 75% 20%, var(--primary-soft) 0 9rpx, transparent 14rpx),
      radial-gradient(circle at 35% 42%, var(--primary-soft) 0 5rpx, transparent 9rpx),
      radial-gradient(circle at 65% 58%, var(--primary-soft) 0 11rpx, transparent 16rpx),
      radial-gradient(circle at 20% 75%, var(--primary-soft) 0 7rpx, transparent 12rpx),
      linear-gradient(180deg, var(--primary-fade) 0%, #f5f7fa 34%);; min-height: 100vh; padding-bottom: 60rpx; }
.head {
  display: flex; align-items: center; gap: 20rpx;
  background: linear-gradient(135deg, var(--primary), #60a5fa);
  border-radius: 20rpx; padding: 32rpx 28rpx; margin-bottom: 20rpx; color: #fff;
}
.avatar-img { width: 108rpx; height: 108rpx; border-radius: 50%; border: 4rpx solid rgba(255,255,255,0.5); flex-shrink: 0; }
.avatar {
  width: 108rpx; height: 108rpx; border-radius: 50%; background: rgba(255,255,255,0.25);
  display: flex; align-items: center; justify-content: center; font-size: 48rpx; font-weight: bold; flex-shrink: 0;
}
.head-info { flex: 1; display: flex; flex-direction: column; gap: 8rpx; }
.hi-line { display: flex; align-items: baseline; }
.hi { font-size: 26rpx; font-weight: 600; margin-right: 12rpx; opacity: 0.95; }
.hi-name { font-size: 34rpx; font-weight: bold; max-width: 220rpx; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.hi-sub { font-size: 22rpx; opacity: 0.85; word-break: break-all; }
.server-tag { font-size: 24rpx; background: rgba(255,255,255,0.2); border-radius: 999rpx; padding: 8rpx 20rpx; flex-shrink: 0; }
.stats { display: flex; align-items: stretch; background: #fff; border-radius: 20rpx; padding: 26rpx 10rpx; margin-bottom: 24rpx; }
.stat { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 8rpx; justify-content: center; }
.stat-line { width: 1rpx; background: #ebeef5; margin: 6rpx 0; }
.st-label { font-size: 22rpx; color: #909399; }
.st-value { font-size: 32rpx; font-weight: bold; color: #303133; }
.green { color: #67c23a; }
.red { color: #f56c6c; }
.group-title { font-size: 25rpx; color: #909399; margin: 8rpx 8rpx 12rpx; }
.grp { background: #fff; border-radius: 20rpx; margin-bottom: 20rpx; overflow: hidden; }
.row { display: flex; align-items: center; padding: 26rpx 24rpx; border-bottom: 1rpx solid #f5f5f5; }
.row:last-child { border-bottom: none; }
.r-ic {
  width: 56rpx; height: 56rpx; border-radius: 16rpx; margin-right: 20rpx;
  display: flex; align-items: center; justify-content: center; flex-shrink: 0;
}
.ic-blue { background: #eaf1fb; } .ic-green { background: #e8f7ee; }
.ic-orange { background: #fdf3e7; } .ic-purple { background: #f3eefb; } .ic-gold { background: #fdf6e3; }
.ic-tx { font-size: 28rpx; line-height: 1; }
.r-tx { flex: 1; font-size: 28rpx; color: #303133; }
.r-arrow { font-size: 34rpx; color: #c0c4cc; }
.logout { margin: 24rpx 0 16rpx; background: #fff; color: #f56c6c; border-radius: 16rpx; font-size: 30rpx; border: 1rpx solid #f56c6c; }
.ver { text-align: center; color: #c0c4cc; font-size: 22rpx; margin-top: 8rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: #fff; border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.server-cur { font-size: 24rpx; color: #909399; margin-bottom: 16rpx; word-break: break-all; }
.ipt { background: #f5f7fa; border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; margin-bottom: 12rpx; }
.btn-cancel { background: #f5f7fa; color: #606266; border-radius: 12rpx; font-size: 30rpx; }
</style>