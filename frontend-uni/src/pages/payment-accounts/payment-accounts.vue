<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <!-- 总览卡（对齐 App：账户数 + 累计进账） -->
    <view class="overview">
      <text class="ov-main">{{ accounts.length }} 个收款账户 · 累计进账 ¥{{ fmt(totalIncome) }}</text>
      <text class="ov-sub">登记收款时下拉选择；点账户可改名，长按删除</text>
    </view>

    <!-- 账户列表：每账户 名称+进账统计（对齐 App 账户卡） -->
    <view v-for="a in accounts" :key="a.id" class="acct-card" @click="edit(a)" @longpress="remove(a)">
      <view class="acct-head">
        <view class="acct-ic" :class="icClass(a.name)"><text class="ic-tx">{{ icOf(a.name) }}</text></view>
        <view class="acct-info">
          <text class="acct-name">{{ a.name }}<text v-if="a.card_last_four" class="acct-bank"> · {{ a.bank_name || '' }}尾号{{ a.card_last_four }}</text></text>
        </view>
        <view class="acct-ops">
          <text class="op-edit" @click.stop="edit(a)">编辑</text>
          <text class="op-del" @click.stop="remove(a)">删除</text>
        </view>
      </view>
      <view class="stat-row">
        <view class="stat"><text class="stat-num">¥{{ fmt(stats[a.name]?.total) }}</text><text class="stat-label">进账</text></view>
        <view class="stat-divider"></view>
        <view class="stat"><text class="stat-num">{{ stats[a.name]?.count || 0 }}</text><text class="stat-label">笔数</text></view>
      </view>
    </view>
    <view v-if="accounts.length === 0" class="empty">暂无账户，点下方新增</view>

    <button class="btn-add" @click="showAdd = true">+ 新增收款账户</button>

    <!-- 新增/编辑弹层 -->
    <view v-if="showForm" class="mask" @click="showForm = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">{{ editId ? '编辑账户' : '新增收款账户' }}</view>
        <input class="ipt" v-model="form.name" placeholder="账户名称（如 现金/微信/支付宝…）" />
        <input class="ipt" v-model="form.bankName" placeholder="开户行（可选，仅银行卡）" />
        <input class="ipt" v-model="form.cardLastFour" placeholder="卡号后四位（可选，仅银行卡）" maxlength="4" />
        <button class="btn-save" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { useThemeVars } from '../../theme';
const { tv, patternSrc } = useThemeVars();
import { ref, computed } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

interface Acct { id: string; name: string; bank_name?: string; card_last_four?: string }
const accounts = ref<Acct[]>([]);
const stats = ref<Record<string, { total: number; count: number }>>({});
const saving = ref(false);
const showForm = ref(false);
const editId = ref('');
const form = ref({ name: '', bankName: '', cardLastFour: '' });
const fmt = (n: number) => Number(n || 0).toFixed(2);

const totalIncome = computed(() =>
  Object.values(stats.value).reduce((s, x) => s + Number(x.total || 0), 0),
);

// 常见账户图标/色系（对齐 App：现金/微信/支付宝/银行卡/转账/其他）
const ICONS: Array<{ m: RegExp; ic: string; cls: string }> = [
  { m: /现金/, ic: '💵', cls: 'ic-green' },
  { m: /微信/, ic: '💬', cls: 'ic-blue' },
  { m: /支付宝/, ic: '🅰️', cls: 'ic-blue' },
  { m: /银行|卡/, ic: '🏦', cls: 'ic-gold' },
  { m: /转账|转/, ic: '🔄', cls: 'ic-purple' },
  { m: /余额|钱包|其他/, ic: '👛', cls: 'ic-orange' },
];
function icOf(name: string) {
  const hit = ICONS.find((x) => x.m.test(name || ''));
  return hit?.ic || '👛';
}
function icClass(name: string) {
  const hit = ICONS.find((x) => x.m.test(name || ''));
  return hit?.cls || 'ic-orange';
}

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await load();
});

async function load() {
  try {
    const [a, s] = await Promise.all([
      request<{ accounts: Acct[] }>('/payment-accounts', 'GET'),
      request<{ stats: Array<{ method: string; total: number; count: number }> }>('/payment-accounts/stats', 'GET'),
    ]);
    accounts.value = a.accounts || [];
    const m: Record<string, { total: number; count: number }> = {};
    for (const x of s?.stats || []) m[x.method] = { total: Number(x.total || 0), count: Number(x.count || 0) };
    stats.value = m;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function openAdd() {
  editId.value = '';
  form.value = { name: '', bankName: '', cardLastFour: '' };
  showForm.value = true;
}
function edit(a: Acct) {
  editId.value = a.id;
  form.value = { name: a.name || '', bankName: a.bank_name || '', cardLastFour: a.card_last_four || '' };
  showForm.value = true;
}

async function save() {
  const name = form.value.name.trim();
  if (!name) {
    uni.showToast({ title: '请输入账户名称', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    // 服务端全量覆盖（对齐 App：PUT /payment-accounts 传完整列表）
    const list = editId.value
      ? accounts.value.map((x) => (x.id === editId.value ? { ...x, name, bank_name: form.value.bankName.trim(), card_last_four: form.value.cardLastFour.trim() } : x))
      : [...accounts.value, { id: '', name, bank_name: form.value.bankName.trim(), card_last_four: form.value.cardLastFour.trim() }];
    await request('/payment-accounts', 'PUT', { accounts: list });
    uni.showToast({ title: '已保存', icon: 'success' });
    showForm.value = false;
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

function remove(a: Acct) {
  uni.showModal({
    title: '删除账户',
    content: `确定删除「${a.name}」吗？\n历史收款记录不受影响。`,
    success: async (r) => {
      if (!r.confirm) return;
      try {
        const list = accounts.value.filter((x) => x.id !== a.id);
        await request('/payment-accounts', 'PUT', { accounts: list });
        uni.showToast({ title: '已删除', icon: 'success' });
        await load();
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
      }
    },
  });
}
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh; padding: 24rpx 24rpx 60rpx; box-sizing: border-box; background: var(--page-bg); }
.overview { background: transparent; border: var(--card-border); border-radius: 24rpx; padding: 28rpx 24rpx; margin-bottom: 24rpx; }
.ov-main { font-size: 28rpx; font-weight: bold; color: var(--text-main); display: block; }
.ov-sub { font-size: 22rpx; color: var(--text-sub); margin-top: 8rpx; display: block; }
.acct-card { background: var(--card-bg); border: var(--card-border); border-radius: 24rpx; padding: 24rpx; margin-bottom: 20rpx; }
.acct-head { display: flex; align-items: center; gap: 20rpx; }
.acct-ic { width: 64rpx; height: 64rpx; border-radius: 20rpx; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.ic-blue { background: var(--primary-soft); } .ic-green { background: var(--ok-bg); }
.ic-orange { background: var(--warn-bg); } .ic-purple { background: var(--violet-bg); } .ic-gold { background: var(--warn-bg); }
.ic-tx { font-size: 30rpx; line-height: 1; }
.acct-info { flex: 1; min-width: 0; }
.acct-name { font-size: 30rpx; font-weight: 600; color: var(--text-main); }
.acct-bank { font-size: 22rpx; color: var(--text-sub); }
.acct-ops { display: flex; gap: 20rpx; }
.op-edit { font-size: 24rpx; color: var(--primary); }
.op-del { font-size: 24rpx; color: #f56c6c; }
.stat-row { display: flex; align-items: stretch; margin-top: 16rpx; border-top: 1rpx solid var(--divider); padding-top: 16rpx; }
.stat { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 6rpx; }
.stat-divider { width: 1rpx; background: var(--divider); margin: 4rpx 0; }
.stat-num { font-size: 30rpx; font-weight: 800; color: var(--text-main); }
.stat-label { font-size: 20rpx; color: var(--text-sub); }
.empty { color: var(--text-sub); text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.btn-add { background: var(--primary); color: #fff; border-radius: 16rpx; font-size: 30rpx; margin-top: 8rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: var(--sheet-bg); border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; }
</style>
