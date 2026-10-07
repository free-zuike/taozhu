<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <!-- 顶部用户块（对齐 App my_page _userHeader：头像居中一行 + 问候/名字居中一行 + 统计三列，透明露背景） -->
    <view class="head">
      <image v-if="avatarUrl" class="avatar-img" :src="avatarUrl" mode="aspectFill" @click="changeAvatar" />
      <view v-else class="avatar" @click="changeAvatar">{{ (user.name || '陶').slice(0, 1) }}</view>
      <view class="hi-line">
        <text class="hi">{{ greetIcon }} {{ greeting }}</text>
        <text class="hi-name">{{ user.name || '未登录' }}</text>
      </view>
      <text class="hi-sub" @click="openServer">{{ isAdmin ? '老板' : '店员' }} · {{ curBase || '未设置服务器地址' }}</text>
      <!-- 统计三列（仅老板）：记账天数 / 本店交易（当前店铺，跟随交易页选择） / 店铺结余 -->
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
    </view>

    <!-- 账号与同步（对齐 App：成员/设备管理；小程序直连无手动同步，去掉同步状态行） -->
    <view class="grp">
      <!-- 成员=账号设置+账号管理（对齐 App「成员」单入口，含我的账号与成员管理） -->
      <view v-if="isAdmin" class="row" @click="go('/pages/users/users')">
        <view class="r-ic ic-blue"><text class="mi ic-tx">&#xE7FC;</text></view><view class="r-body"><text class="r-tx">成员</text><text class="r-sub">账号设置 · 店员/老板账号</text></view><text class="r-arrow">›</text>
      </view>
      <view v-if="isAdmin" class="row" @click="go('/pages/devices/devices')">
        <view class="r-ic ic-green"><text class="mi ic-tx">&#xE1B1;</text></view><view class="r-body"><text class="r-tx">设备管理</text><text class="r-sub">登录设备列表，可删除</text></view><text class="r-arrow">›</text>
      </view>
    </view>

    <view class="group-title">经营</view>
    <view class="grp">
      <view v-if="isAdmin" class="row" @click="go('/pages/clients/clients')">
        <view class="r-ic ic-blue"><text class="mi ic-tx">&#xE8D1;</text></view><view class="r-body"><text class="r-tx">店铺管理</text><text class="r-sub">店铺列表、新增、编辑</text></view><text class="r-arrow">›</text>
      </view>
      <view v-if="isAdmin" class="row" @click="go('/pages/payments/payments')">
        <view class="r-ic ic-green"><text class="mi ic-tx">&#xEF63;</text></view><view class="r-body"><text class="r-tx">收款结账</text><text class="r-sub">登记收款、查看收款历史</text></view><text class="r-arrow">›</text>
      </view>
      <view v-if="isAdmin" class="row" @click="go('/pages/payment-accounts/payment-accounts')">
        <view class="r-ic ic-blue"><text class="mi ic-tx">&#xE850;</text></view><view class="r-body"><text class="r-tx">收款账户</text><text class="r-sub">收款方式预设：现金/微信/支付宝…（独立页管理）</text></view><text class="r-arrow">›</text>
      </view>
      <view v-if="isAdmin" class="row" @click="go('/pages/statement/statement')">
        <view class="r-ic ic-orange"><text class="mi ic-tx">&#xE873;</text></view><view class="r-body"><text class="r-tx">对账单</text><text class="r-sub">按店铺+周期生成对账明细，一键复制发送</text></view><text class="r-arrow">›</text>
      </view>
    </view>

    <view class="group-title">商品与库存</view>
    <view class="grp">
      <view class="row" @click="go('/pages/stocks/stocks')">
        <view class="r-ic ic-blue"><text class="mi ic-tx">&#xE1A1;</text></view><view class="r-body"><text class="r-tx">库存</text><text class="r-sub">进货/出货自动维护，盘点与预警</text></view><text class="r-arrow">›</text>
      </view>
      <view class="row" @click="go('/pages/items/items')">
        <view class="r-ic ic-green"><text class="mi ic-tx">&#xEB70;</text></view><view class="r-body"><text class="r-tx">商品管理</text><text class="r-sub">商品与多单位价格</text></view><text class="r-arrow">›</text>
      </view>
      <view class="row" @click="go('/pages/categories/categories')">
        <view class="r-ic ic-orange"><text class="mi ic-tx">&#xE892;</text></view><view class="r-body"><text class="r-tx">分类管理</text><text class="r-sub">商品分类 / 店铺分类（两级）</text></view><text class="r-arrow">›</text>
      </view>
    </view>

    <view class="group-title">系统</view>
    <view class="grp">
      <view v-if="isAdmin" class="row" @click="go('/pages/backup/backup')">
        <view class="r-ic ic-orange"><text class="mi ic-tx">&#xE864;</text></view><view class="r-body"><text class="r-tx">数据备份</text><text class="r-sub">导出全库存档 / 从备份合并恢复</text></view><text class="r-arrow">›</text>
      </view>
      <view class="row" @click="go('/pages/logs/logs')">
        <view class="r-ic ic-blue"><text class="mi ic-tx">&#xE160;</text></view><view class="r-body"><text class="r-tx">错误日志</text><text class="r-sub">请求失败记录，排障用</text></view><text class="r-arrow">›</text>
      </view>
      <view v-if="isAdmin" class="row" @click="go('/pages/ai-settings/ai-settings')">
        <view class="r-ic ic-purple"><text class="mi ic-tx">&#xE65F;</text></view><view class="r-body"><text class="r-tx">AI 识别设置</text><text class="r-sub">配置 AI 记账 Key 与模型</text></view><text class="r-arrow">›</text>
      </view>
      <view v-if="isAdmin" class="row" @click="go('/pages/rounding-settings/rounding-settings')">
        <view class="r-ic ic-green"><text class="mi ic-tx">&#xEA5F;</text></view><view class="r-body"><text class="r-tx">金额舍入</text><text class="r-sub">所有金额计算的进位方式与精度</text></view><text class="r-arrow">›</text>
      </view>
      <view class="row" @click="go('/pages/theme-settings/theme-settings')">
        <view class="r-ic ic-gold"><text class="mi ic-tx">&#xE40A;</text></view><view class="r-body"><text class="r-tx">主题设置</text><text class="r-sub">配色主题 / 明暗模式 / 背景</text></view><text class="r-arrow">›</text>
      </view>
      <view v-if="isAdmin" class="row" @click="go('/pages/audit/audit')">
        <view class="r-ic ic-red"><text class="mi ic-tx">&#xE889;</text></view><view class="r-body"><text class="r-tx">操作审计</text><text class="r-sub">登录/删除/修改等关键操作留痕</text></view><text class="r-arrow">›</text>
      </view>
    </view>

    <view class="bottom">
      <button class="btn-logout" @click="logout">退出登录</button>
      <button class="btn-switch" @click="switchAccount">切换账号</button>
    </view>
    <view class="ver">陶朱 小程序 v{{ APP_VERSION }}</view>

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
const { tv, patternSrc } = useThemeVars();
import { ref, computed } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getRole, getToken, getApiBase, setApiBase, clearToken } from '../../api';
import { fmtAmount } from '../../utils/money';
import { APP_VERSION } from '../../version';

const user = ref({ name: '', role: '' });
const isAdmin = ref(true);
// 头像（/auth/avatar?token= 带鉴权，小程序 image 组件无法带 header）
const avatarUrl = ref('');
// 问候语（对齐 App：早上好/下午好/晚上好）+ 时段图标
const greeting = computed(() => {
  const h = new Date().getHours();
  if (h >= 5 && h < 12) return '早上好';
  if (h >= 12 && h < 18) return '下午好';
  if (h >= 18 && h < 23) return '晚上好';
  return '夜深了，注意休息';
});
const greetIcon = computed(() => {
  const h = new Date().getHours();
  if (h >= 5 && h < 12) return '🌅';
  if (h >= 12 && h < 18) return '☀️';
  if (h >= 18 && h < 23) return '🌙';
  return '🌌';
});
// 对齐 App 我的页统计卡：记账天数 / 本店交易（商品行数） / 店铺结余（当前店铺毛利）
const stats = ref({ bookDays: 0, clientCount: 0, balance: 0 });
// 金额显示按「我的 → 金额舍入」设置的位数/进位口径（对齐 App fmtMoney）
const fmt = (n: number) => fmtAmount(Number(n) || 0);

const showServer = ref(false);
const saving = ref(false);
const curBase = ref(getApiBase());
const serverInput = ref(getApiBase());
// 当前店铺由交易页选择（taozhu_cur_client），我的页统计随交易页对齐，不再单独选择

// 头像更换：选图 → 上传 /auth/avatar（multipart photo，header 带 token）→ 刷新（对齐 App 头像更换）
function changeAvatar() {
  uni.chooseImage({
    count: 1,
    sizeType: ['compressed'],
    success: (res) => {
      const file = res.tempFilePaths[0];
      if (!file) return;
      uni.showLoading({ title: '上传中' });
      uni.uploadFile({
        url: `${getApiBase()}/api/v1/auth/avatar`,
        filePath: file,
        name: 'photo',
        header: { Authorization: `Bearer ${getToken()}` },
        success: () => {
          uni.hideLoading();
          uni.showToast({ title: '头像已更新', icon: 'success' });
          avatarUrl.value = `${getApiBase()}/api/v1/auth/avatar?token=${getToken()}&v=${Date.now()}`;
        },
        fail: () => {
          uni.hideLoading();
          uni.showToast({ title: '上传失败', icon: 'none' });
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

function switchAccount() {
  uni.showModal({
    title: '切换账号',
    content: '将清除当前账号的本地登录状态，返回登录页换号登录。',
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
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh; padding: 24rpx 24rpx 60rpx; box-sizing: border-box; background: var(--page-bg); }
/* 顶部用户块：透明露背景（对齐 App _userHeader 无卡片底），头像居中一行 + 问候/名字一行居中 + 统计三列 */
.head {
  display: flex; flex-direction: column; align-items: center;
  padding: 20rpx 0 12rpx; margin-bottom: 24rpx;
}
.avatar-img { width: 176rpx; height: 176rpx; border-radius: 50%; flex-shrink: 0; }
.avatar {
  width: 176rpx; height: 176rpx; border-radius: 50%; background: var(--primary-soft); color: var(--primary);
  display: flex; align-items: center; justify-content: center; font-size: 80rpx; font-weight: bold; flex-shrink: 0;
}
.hi-line { display: flex; align-items: baseline; gap: 12rpx; margin-top: 24rpx; }
.hi { font-size: 30rpx; font-weight: 600; color: var(--primary); }
.hi-name { font-size: 36rpx; font-weight: bold; max-width: 320rpx; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--text-main); }
.hi-sub { font-size: 24rpx; color: var(--text-sub); margin-top: 10rpx; word-break: break-all; padding: 0 24rpx; }
/* 统计三列（仅老板）：宽松间距 + 分隔线（对齐 App cell 17w800/11 标签 + 30px 分隔线） */
.stats { display: flex; align-items: stretch; width: 100%; margin-top: 24rpx; padding: 24rpx 8rpx 4rpx; border-top: 1rpx solid var(--divider); }
.stat { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 10rpx; justify-content: center; }
.stat-line { width: 1rpx; background: var(--divider); margin: 6rpx 0; }
.st-label { font-size: 22rpx; color: var(--text-sub); }
.st-value { font-size: 34rpx; font-weight: 800; color: var(--text-main); }
.green { color: #67c23a; }
.ver { display: block; text-align: center; color: var(--text-sub); font-size: 22rpx; padding: 20rpx 0 8rpx; }
.red { color: #f56c6c; }
.group-title { font-size: 26rpx; font-weight: 600; color: var(--text-sub); margin: 8rpx 8rpx 16rpx; }
.grp { background: var(--card-bg); border: var(--card-border); border-radius: 32rpx; margin-bottom: 24rpx; overflow: hidden; }
.row { display: flex; align-items: center; padding: 24rpx; border-bottom: 1rpx solid var(--divider); }
.row:last-child { border-bottom: none; }
.r-ic {
  width: 64rpx; height: 64rpx; border-radius: 20rpx; margin-right: 24rpx;
  display: flex; align-items: center; justify-content: center; flex-shrink: 0;
}
.ic-blue { background: var(--primary-soft); } .ic-green { background: var(--ok-bg); }
.ic-orange { background: var(--warn-bg); } .ic-purple { background: var(--violet-bg); } .ic-gold { background: var(--warn-bg); } .ic-red { background: var(--danger-bg); }
.ic-tx { font-size: 32rpx; line-height: 1; }
.r-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4rpx; }
.r-tx { font-size: 30rpx; color: var(--text-main); }
.r-sub { font-size: 24rpx; color: var(--text-sub); }
.r-arrow { font-size: 36rpx; color: var(--text-sub); }
.bottom { display: flex; gap: 20rpx; margin: 24rpx 0 16rpx; }
.btn-logout { flex: 1; background: var(--card-bg); color: #f56c6c; border-radius: 24rpx; font-size: 30rpx; border: 1rpx solid #f56c6c; }
.btn-switch { flex: 1; background: var(--primary); color: #fff; border-radius: 24rpx; font-size: 30rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: var(--sheet-bg); border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.server-cur { font-size: 24rpx; color: var(--text-sub); margin-bottom: 16rpx; word-break: break-all; }
.ipt { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; margin-bottom: 12rpx; }
.btn-cancel { background: var(--input-bg); color: var(--text-sub); border-radius: 12rpx; font-size: 30rpx; }
</style>