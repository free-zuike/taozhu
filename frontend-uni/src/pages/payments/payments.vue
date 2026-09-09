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
      <input class="ipt" v-model="amount" type="digit" placeholder="收款金额（必填）" />
      <input class="ipt" v-model="date" placeholder="日期 YYYY-MM-DD（默认今天）" />
      <input class="ipt" v-model="method" placeholder="方式（现金/微信/转账…）" />
      <input class="ipt" v-model="note" placeholder="备注（可选）" />
      <button class="btn-save" :disabled="saving" @click="submit">{{ saving ? '登记中…' : '登记收款' }}</button>
    </view>

    <!-- 收款历史 -->
    <view class="card">
      <view class="card-title">收款历史</view>
      <view v-for="p in payments" :key="p.id" class="pay-row">
        <view class="pay-left">
          <text class="pay-name">{{ p.client_name }}</text>
          <text class="pay-meta">{{ p.happened_at }} · {{ p.method || '—' }}</text>
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
        <input class="ipt" v-model="payForm.date" placeholder="日期 YYYY-MM-DD" />
        <input class="ipt" v-model="payForm.method" placeholder="收款方式" />
        <input class="ipt" v-model="payForm.note" placeholder="备注" />
        <button class="btn-save" :disabled="saving" @click="savePayment">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

const clientId = ref('');
const clientName = ref('');
const clientNames = ref<string[]>([]);
const clients = ref<Array<{ id: string; name: string; debt: number }>>([]);
const amount = ref('');
const date = ref('');
const method = ref('');
const note = ref('');
const saving = ref(false);
const payments = ref<Array<{ id: string; client_name: string; happened_at: string; amount: number; method: string; note: string }>>([]);
const payForm = ref<{
  show: boolean; id: string; amount: string; date: string; method: string; note: string;
}>({ show: false, id: '', amount: '', date: '', method: '', note: '' });

const fmt = (n: number) => Number(n || 0).toFixed(2);

function todayLocal(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  date.value = todayLocal();
  await load();
});

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
      happened_at: date.value,
      method: method.value.trim(),
      note: note.value.trim(),
    });
    uni.showToast({ title: '收款已登记', icon: 'success' });
    amount.value = '';
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
    date: String(p.happened_at || '').slice(0, 10),
    method: p.method || '',
    note: p.note || '',
  };
}

async function savePayment() {
  const amt = Number(payForm.value.amount);
  if (!amt || amt <= 0) {
    uni.showToast({ title: '请输入有效金额', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    await request(`/payments/${payForm.value.id}`, 'PATCH', {
      amount: amt,
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
</style>