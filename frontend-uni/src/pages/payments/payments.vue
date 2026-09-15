<template>
  <view class="page">
    <!-- 登记收款 -->
    <view class="card">
      <picker class="field" mode="selector" :range="clientNames" @change="onClient">
        <view class="field-inner">
          <text class="label">饭店</text>
          <text :class="['value', { placeholder: !clientId }]">{{ clientId ? clientName : '请选择饭店' }}</text>
        </view>
      </picker>
      <input class="ipt" v-model="amount" type="digit" placeholder="实收金额（必填）" />
      <view v-if="selDebtLabel" class="debt-tip">{{ selDebtLabel }}</view>
      <input class="ipt" v-model="waived" type="digit" placeholder="平账减免（可选，实收+减免=账面已收）" />
      <input class="ipt" v-model="date" placeholder="日期 YYYY-MM-DD（默认今天）" />
      <picker class="field" mode="selector" :range="accounts" :value="methodIdx" @change="onMethod">
        <view class="field-inner">
          <text class="label">收款方式（账户）</text>
          <text :class="['value', { placeholder: !method }]">{{ method || '点击选择账户' }}</text>
        </view>
      </picker>
      <input class="ipt" v-model="note" placeholder="备注（可选）" />
      <button class="btn-save" :disabled="saving" @click="submit">{{ saving ? '登记中…' : '登记收款' }}</button>
      <view class="acct-link" @click="openAccountMgr">管理收款账户（增/删/改）</view>
    </view>

    <!-- 收款历史 -->
    <view class="card">
      <view class="card-title">收款历史</view>
      <view v-for="p in payments" :key="p.id" class="pay-row">
        <view class="pay-left">
          <text class="pay-name">{{ p.client_name }}</text>
          <text class="pay-meta">{{ p.happened_at }} · {{ p.method || '—' }}{{ Number(p.waived || 0) > 0 ? ' · 平账¥' + p.waived : '' }}</text>
        </view>
        <text class="pay-amount green">¥{{ fmt(p.amount) }}</text>
        <text class="edit" @click="editPayment(p)">编辑</text>
        <text class="del" @click="remove(p.id)">撤销</text>
      </view>
      <view v-if="payments.length === 0" class="empty">暂无收款记录</view>
    </view>

    <!-- 编辑收款弹层 -->
    <view v-if="payForm.show" class="mask" @click="payForm.show = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">编辑收款</view>
        <input class="ipt" v-model="payForm.amount" type="digit" placeholder="金额（元）" />
        <input class="ipt" v-model="payForm.waived" type="digit" placeholder="平账减免（元）" />
        <input class="ipt" v-model="payForm.date" placeholder="日期 YYYY-MM-DD" />
        <picker class="field" mode="selector" :range="accounts" @change="onEditMethod">
          <view class="field-inner">
            <text class="label">收款方式（账户）</text>
            <text :class="['value', { placeholder: !payForm.method }]">{{ payForm.method || '点击选择账户' }}</text>
          </view>
        </picker>
        <input class="ipt" v-model="payForm.note" placeholder="备注" />
        <button class="btn-save" :disabled="saving" @click="savePayment">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>

    <!-- 账户管理弹层 -->
    <view v-if="showAccountMgr" class="mask" @click="showAccountMgr = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">管理收款账户</view>
        <view v-for="(a, i) in accounts" :key="i" class="acct-row">
          <view class="acct-info">
            <text class="acct-name">{{ a }}</text>
            <text class="acct-stats">进账 ¥{{ fmt(acctStats[a]?.total ?? 0) }} · {{ acctStats[a]?.count ?? 0 }} 笔</text>
          </view>
          <text class="acct-edit" @click="renameAccount(i)">改名</text>
          <text class="acct-del" @click="removeAccount(i)">删除</text>
        </view>
        <view class="acct-add-row">
          <input class="ipt add" v-model="mgrName" placeholder="新账户名称" />
          <button class="btn-sub" @click="addAccount">添加</button>
        </view>
        <button class="btn-save" @click="showAccountMgr = false">完成</button>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

const clientId = ref('');
const clientName = ref('');
const clientNames = ref<string[]>([]);
const clients = ref<Array<{ id: string; name: string; debt: number }>>([]);
const amount = ref('');
const waived = ref('');
const selDebtLabel = ref('');
const date = ref('');
const method = ref('');
const note = ref('');
const saving = ref(false);
const payments = ref<Array<{ id: string; client_name: string; happened_at: string; amount: number; waived?: number; method: string; note: string }>>([]);
// 收款方式账户：服务器同步实体（云端直连读取，非小程序本地存储）
const accounts = ref<string[]>(['现金', '微信', '支付宝', '银行卡', '转账']);
// 每账户进账统计：method → { total, count }（GET /payment-accounts/stats）
const acctStats = ref<Record<string, { total: number; count: number }>>({});
const showAccountMgr = ref(false);
const mgrName = ref('');
const payForm = ref<{
  show: boolean; id: string; amount: string; waived: string; date: string; method: string; note: string;
}>({ show: false, id: '', amount: '', waived: '0', date: '', method: '', note: '' });

const fmt = (n: number) => Number(n || 0).toFixed(2);

function todayLocal(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

// 收款账户：服务器同步实体（云端直连；App 本地镜像，小程序无本地库直接读服务器）
const ACC_API = '/payment-accounts';
async function loadAccounts() {
  try {
    const d = await request<{ accounts: Array<{ id: string; name: string }> }>(ACC_API, 'GET');
    const list = (d.accounts || []).map((a) => a.name).filter((s) => s && s.trim());
    if (list.length > 0) accounts.value = list;
  } catch (e) {
    // 服务器暂不可达：保留默认预设兜底（登记时仍可手填历史方式）
    accounts.value = ['现金', '微信', '支付宝', '银行卡', '转账'];
  }
  // 进账统计：失败静默（弹层仅显示数字，无统计也不影响登记）
  try {
    const s = await request<{ stats: Array<{ method: string; total: number; count: number }> }>(ACC_API + '/stats', 'GET');
    acctStats.value = Object.fromEntries(
      (s.stats || []).map((x) => [x.method, { total: x.total, count: x.count }]),
    );
  } catch {
    acctStats.value = {};
  }
}
// 全量覆盖保存（与 App 端一致：PUT /payment-accounts 整表提交）
async function saveAccounts() {
  const list = accounts.value.filter((s) => s && s.trim());
  if (list.length === 0) {
    uni.showToast({ title: '至少保留一个账户', icon: 'none' });
    return false;
  }
  try {
    await request(ACC_API, 'PUT', { accounts: list.map((name) => ({ name })) });
    await loadAccounts();
    return true;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
    return false;
  }
}
onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  date.value = todayLocal();
  await loadAccounts();
  await load();
});

const methodIdx = computed(() => {
  const i = accounts.value.indexOf(method.value);
  return i >= 0 ? i : 0;
});
function onMethod(e: { detail: { value: number } }) {
  method.value = accounts.value[e.detail.value] || '';
}
function onEditMethod(e: { detail: { value: number } }) {
  payForm.value.method = accounts.value[e.detail.value] || '';
}
function openAccountMgr() {
  showAccountMgr.value = true;
  mgrName.value = '';
}
async function addAccount() {
  const name = mgrName.value.trim();
  if (!name) {
    uni.showToast({ title: '请输入账户名称', icon: 'none' });
    return;
  }
  if (accounts.value.includes(name)) {
    uni.showToast({ title: '该账户已存在', icon: 'none' });
    return;
  }
  accounts.value.push(name);
  if (await saveAccounts()) {
    uni.showToast({ title: '已添加', icon: 'success' });
    mgrName.value = '';
  }
}
function renameAccount(i: number) {
  const old = accounts.value[i];
  uni.showModal({
    title: '重命名账户',
    editable: true,
    placeholderText: old,
    success: async (r) => {
      if (!r.confirm) return;
      const name = String(r.content || '').trim();
      if (!name || name === old) return;
      if (accounts.value.includes(name)) {
        uni.showToast({ title: '该账户已存在', icon: 'none' });
        return;
      }
      accounts.value[i] = name;
      if (await saveAccounts()) uni.showToast({ title: '已保存', icon: 'success' });
    },
  });
}
function removeAccount(i: number) {
  const name = accounts.value[i];
  uni.showModal({
    title: '删除账户',
    content: `确定删除账户「${name}」吗？（历史收款记录不受影响）`,
    success: async (r) => {
      if (!r.confirm) return;
      accounts.value.splice(i, 1);
      if (await saveAccounts()) uni.showToast({ title: '已删除', icon: 'success' });
    },
  });
}

async function load() {
  try {
    const [c, p] = await Promise.all([
      request<{ clients: Array<{ id: string; name: string; debt: number }> }>('/clients', 'GET'),
      request<{ payments: typeof payments.value }>('/payments', 'GET'),
    ]);
    clients.value = c.clients;
    clientNames.value = c.clients.map((x) => `${x.name}（欠 ¥${fmt(x.debt)}）`);
    payments.value = p.payments.slice(0, 100);
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function onClient(e: { detail: { value: number } }) {
  const c = clients.value[e.detail.value];
  if (c) {
    clientId.value = c.id;
    clientName.value = `${c.name}（欠 ¥${fmt(c.debt)}）`;
    selDebtLabel.value = `应收 ¥${fmt(c.debt)}（实收 + 减免 = 账面已收）`;
  }
}

async function submit() {
  if (!clientId.value) {
    uni.showToast({ title: '请选择饭店', icon: 'none' });
    return;
  }
  if (!(Number(amount.value) > 0)) {
    uni.showToast({ title: '请输入收款金额', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    await request('/payments', 'POST', {
      client_id: clientId.value,
      amount: Number(amount.value),
      waived: Number(waived.value) || 0,
      happened_at: date.value,
      method: method.value.trim(),
      note: note.value.trim(),
    });
    uni.showToast({ title: '收款已登记', icon: 'success' });
    amount.value = '';
    waived.value = '';
    method.value = '';
    note.value = '';
    date.value = todayLocal();
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '登记失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

function editPayment(p: Record<string, any>) {
  payForm.value = {
    show: true, id: p.id,
    amount: String(p.amount),
    waived: String(p.waived || 0),
    date: String(p.happened_at || '').slice(0, 10),
    method: p.method || '',
    note: p.note || '',
  };
}

async function savePayment() {
  const amt = Number(payForm.value.amount);
  const wd = Number(payForm.value.waived) || 0;
  if (!amt || amt <= 0) {
    uni.showToast({ title: '请输入有效金额', icon: 'none' });
    return;
  }
  if (wd < 0) {
    uni.showToast({ title: '减免金额不能为负数', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    await request(`/payments/${payForm.value.id}`, 'PATCH', {
      amount: amt,
      waived: wd,
      happened_at: payForm.value.date,
      method: payForm.value.method,
      note: payForm.value.note,
    });
    uni.showToast({ title: '已保存', icon: 'success' });
    payForm.value.show = false;
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

async function remove(id: string) {
  try {
    await request(`/payments/${id}`, 'DELETE');
    uni.showToast({ title: '已撤销', icon: 'success' });
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '撤销失败', icon: 'none' });
  }
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.card { background: #fff; border-radius: 12rpx; padding: 24rpx; margin-bottom: 16rpx; }
.card-title { font-size: 30rpx; font-weight: bold; margin-bottom: 16rpx; }
.field { margin-bottom: 16rpx; }
.field-inner { display: flex; justify-content: space-between; padding: 18rpx 0; }
.label { color: #909399; }
.value { color: #303133; }
.placeholder { color: #c0c4cc; }
.ipt { background: #f5f7fa; border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.debt-tip { color: #f56c6c; font-size: 24rpx; margin: -8rpx 0 16rpx; }
.btn-save { background: #409eff; color: #fff; border-radius: 12rpx; font-size: 30rpx; }
.pay-row { display: flex; align-items: center; padding: 16rpx 0; border-bottom: 1rpx solid #f0f0f0; }
.pay-left { flex: 1; min-width: 0; }
.pay-name { display: block; font-size: 28rpx; }
.pay-meta { display: block; font-size: 22rpx; color: #909399; margin-top: 4rpx; }
.pay-amount { font-size: 30rpx; font-weight: bold; margin-right: 20rpx; }
.green { color: #67c23a; }
.edit { color: #409eff; font-size: 24rpx; margin-right: 20rpx; }
.del { color: #f56c6c; font-size: 24rpx; }
.empty { color: #c0c4cc; text-align: center; padding: 30rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: #fff; border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.acct-link { color: #409eff; font-size: 24rpx; text-align: center; margin-top: 10rpx; }
.acct-row { display: flex; align-items: center; padding: 14rpx 0; border-bottom: 1rpx solid #f0f0f0; }
.acct-info { flex: 1; display: flex; flex-direction: column; }
.acct-name { font-size: 28rpx; }
.acct-stats { font-size: 22rpx; color: #999; margin-top: 4rpx; }
.acct-edit { color: #409eff; font-size: 24rpx; margin-right: 24rpx; }
.acct-del { color: #f56c6c; font-size: 24rpx; }
.acct-add-row { display: flex; align-items: center; margin-top: 16rpx; }
.acct-add-row .add { flex: 1; margin-bottom: 0; }
.btn-sub { background: #fff; border: 1rpx solid #409eff; color: #409eff; border-radius: 10rpx; font-size: 26rpx; margin-left: 16rpx; }
</style>