<template>
  <view class="page">
    <view class="card">
      <picker class="field" mode="selector" :range="clientNames" @change="onClient">
        <view class="field-inner">
          <text class="label">店铺</text>
          <text class="value">{{ clientName }}</text>
        </view>
      </picker>

      <view class="seg">
        <view :class="['seg-item', { active: period === 'month' }]" @click="applyPeriod('month')">本月</view>
        <view :class="['seg-item', { active: period === 'last' }]" @click="applyPeriod('last')">上月</view>
      </view>

      <view class="dates">
        <input class="ipt" v-model="from" placeholder="开始日期" />
        <text class="to">至</text>
        <input class="ipt" v-model="to" placeholder="结束日期" />
      </view>

      <button class="btn-save" :disabled="loading" @click="load">{{ loading ? '生成中…' : '生成对账单' }}</button>

      <view v-if="loaded">
        <view class="stat"><text>出货合计</text><text class="red">¥{{ saleTotal.toFixed(2) }}（{{ sales.length }} 笔）</text></view>
        <view class="stat"><text>收款合计</text><text class="green">¥{{ payTotal.toFixed(2) }}（{{ payments.length }} 笔）</text></view>
        <view class="stat"><text>期末欠款</text><text :class="debt > 0 ? 'red' : 'green'">¥{{ debt.toFixed(2) }}</text></view>
        <button class="btn-copy" @click="copy">复制对账文本</button>
        <button class="btn-copy" @click="copyCsv">复制 CSV（粘到 Excel）</button>
      </view>
    </view>

    <view v-if="loaded" class="list">
      <view class="list-title">出货明细</view>
      <view v-for="s in sales" :key="s.id" class="list-row">
        <text class="lr-l">{{ s.client_name }} {{ s.happened_at }}</text>
        <text class="lr-r red">¥{{ Number(s.total).toFixed(2) }}</text>
      </view>
      <view v-if="sales.length === 0" class="empty">周期内无出货</view>

      <view class="list-title">收款明细</view>
      <view v-for="p in payments" :key="p.id" class="list-row">
        <text class="lr-l">{{ p.client_name }} {{ p.happened_at }}<text v-if="p.method"> {{ p.method }}</text></text>
        <text class="lr-r green">¥{{ Number(p.amount).toFixed(2) }}</text>
      </view>
      <view v-if="payments.length === 0" class="empty">周期内无收款</view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

const clients = ref<Array<{ id: string; name: string }>>([]);
const clientNames = ref<string[]>(['全部店铺']);
const clientName = ref('全部店铺');
let clientId = '';

const period = ref<'month' | 'last'>('month');
const from = ref('');
const to = ref('');
const loading = ref(false);
const loaded = ref(false);
const sales = ref<Array<Record<string, any>>>([]);
const payments = ref<Array<Record<string, any>>>([]);
const debt = ref(0);

const saleTotal = ref(0);
const payTotal = ref(0);

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  applyPeriod('month');
  try {
    const d = await request<{ clients: Array<{ id: string; name: string }> }>('/clients', 'GET');
    clients.value = d.clients;
    clientNames.value = ['全部店铺', ...d.clients.map((c) => c.name)];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
});

function today(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function applyPeriod(p: 'month' | 'last') {
  period.value = p;
  const now = new Date();
  const p2 = (n: number) => String(n).padStart(2, '0');
  if (p === 'last') {
    const first = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    const last = new Date(now.getFullYear(), now.getMonth(), 0);
    from.value = `${first.getFullYear()}-${p2(first.getMonth() + 1)}-${p2(first.getDate())}`;
    to.value = `${last.getFullYear()}-${p2(last.getMonth() + 1)}-${p2(last.getDate())}`;
  } else {
    from.value = `${now.getFullYear()}-${p2(now.getMonth() + 1)}-01`;
    to.value = today();
  }
}

function onClient(e: { detail: { value: number } }) {
  const idx = e.detail.value;
  if (idx <= 0) { clientId = ''; clientName.value = '全部店铺'; return; }
  const c = clients.value[idx - 1];
  if (c) { clientId = c.id; clientName.value = c.name; }
}

async function load() {
  if (!from.value || !to.value) {
    uni.showToast({ title: '请选择起止日期', icon: 'none' });
    return;
  }
  loading.value = true;
  try {
    const cid = clientId ? `&client_id=${clientId}` : '';
    const results = await Promise.all([
      request<{ sales: any[] }>(`/sales?date_from=${from.value}&date_to=${to.value}&limit=1000${cid}`, 'GET'),
      request<{ payments: any[] }>(`/payments?date_from=${from.value}&date_to=${to.value}&limit=1000${cid}`, 'GET'),
      request<{ debt: number }>(`/stats/summary?start=${from.value}&end=${to.value}${cid}`, 'GET'),
    ]);
    sales.value = results[0].sales;
    payments.value = results[1].payments;
    debt.value = Number(results[2].debt || 0);
    saleTotal.value = sales.value.reduce((s, x) => s + Number(x.total || 0), 0);
    payTotal.value = payments.value.reduce((s, x) => s + Number(x.amount || 0), 0);
    loaded.value = true;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '生成失败', icon: 'none' });
  } finally {
    loading.value = false;
  }
}

function copy() {
  if (!loaded.value) {
    uni.showToast({ title: '请先生成对账单', icon: 'none' });
    return;
  }
  const lines: string[] = [
    '【陶朱对账单】',
    `客户：${clientName.value}`,
    `周期：${from.value} 至 ${to.value}`,
    `出货合计：¥${saleTotal.value.toFixed(2)}（${sales.value.length} 笔）`,
    `收款合计：¥${payTotal.value.toFixed(2)}（${payments.value.length} 笔）`,
    `期末欠款：¥${debt.value.toFixed(2)}`,
    '—— 出货明细 ——',
  ];
  for (const s of sales.value) lines.push(`${s.happened_at} 出货 ¥${Number(s.total || 0).toFixed(2)}`);
  lines.push('—— 收款明细 ——');
  for (const p of payments.value) {
    lines.push(`${p.happened_at}${p.method ? ' ' + p.method : ''} ¥${Number(p.amount || 0).toFixed(2)}`);
  }
  uni.setClipboardData({ data: lines.join('\n') });
  uni.showToast({ title: '对账文本已复制', icon: 'success' });
}

/// CSV 字段转义：含逗号/引号/换行的加引号包裹
function csv(v: unknown): string {
  const s = String(v ?? '');
  return s.includes(',') || s.includes('"') || s.includes('\n') ? `"${s.replaceAll('"', '""')}"` : s;
}

function copyCsv() {
  if (!loaded.value) {
    uni.showToast({ title: '请先生成对账单', icon: 'none' });
    return;
  }
  const lines: string[] = ['\uFEFF类型,日期,店铺,金额,明细'];
  for (const s of sales.value) {
    const detail = (s.items || []).map((it: Record<string, any>) => `${it.item_name}${it.quantity}${it.unit}`).join(';');
    lines.push(`出货,${csv(s.happened_at)},${csv(s.client_name)},${csv(s.total)},${csv(detail)}`);
  }
  for (const p of payments.value) {
    lines.push(`收款,${csv(p.happened_at)},${csv(p.client_name)},${csv(p.amount)},${csv(p.method)}`);
  }
  uni.setClipboardData({ data: lines.join('\n') });
  uni.showToast({ title: 'CSV 已复制（带表头）', icon: 'success' });
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.card { background: #fff; border-radius: 12rpx; padding: 24rpx; margin-bottom: 20rpx; }
.field { margin-bottom: 20rpx; }
.field-inner { display: flex; justify-content: space-between; }
.label { color: #909399; font-size: 26rpx; }
.value { font-size: 28rpx; }
.seg { display: flex; background: #f5f7fa; border-radius: 12rpx; margin-bottom: 20rpx; overflow: hidden; }
.seg-item { flex: 1; text-align: center; padding: 16rpx; font-size: 26rpx; color: #909399; }
.seg-item.active { color: #409eff; font-weight: bold; background: #ecf5ff; }
.dates { display: flex; align-items: center; gap: 12rpx; margin-bottom: 20rpx; }
.ipt { flex: 1; background: #f5f7fa; border-radius: 10rpx; padding: 16rpx 20rpx; font-size: 26rpx; }
.to { color: #909399; }
.btn-save { background: #409eff; color: #fff; border-radius: 12rpx; font-size: 30rpx; margin-bottom: 20rpx; }
.btn-copy { background: #fff; border: 1rpx solid #409eff; color: #409eff; border-radius: 12rpx; font-size: 28rpx; margin-top: 12rpx; }
.stat { display: flex; justify-content: space-between; padding: 12rpx 0; font-size: 28rpx; }
.red { color: #f56c6c; }
.green { color: #67c23a; }
.list { background: #fff; border-radius: 12rpx; padding: 24rpx; }
.list-title { font-size: 30rpx; font-weight: bold; margin: 20rpx 0 12rpx; }
.list-row { display: flex; justify-content: space-between; padding: 14rpx 0; border-bottom: 1rpx solid #f0f0f0; font-size: 26rpx; }
.lr-l { color: #303133; }
.lr-r { font-weight: bold; }
.empty { color: #c0c4cc; text-align: center; padding: 24rpx 0; font-size: 26rpx; }
</style>