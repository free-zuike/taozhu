<template>
  <view class="page">
    <picker class="field" mode="date" :value="date" @change="onDate">
      <view class="field-inner">
        <text class="label">日期</text>
        <text class="value">{{ date }}</text>
      </view>
    </picker>

    <view v-for="(row, i) in rows" :key="i" class="row">
      <picker class="picker" mode="selector" :range="itemNames" @change="(e) => onItem(i, e.detail.value)">
        <view class="mini-field">{{ row.itemName || '选商品' }}</view>
      </picker>
      <picker class="picker" mode="selector" :range="row.priceLabels" @change="(e) => onPrice(i, e.detail.value)">
        <view class="mini-field">{{ row.priceLabel || '单位' }}</view>
      </picker>
      <input class="num" type="digit" v-model="row.quantity" placeholder="数量" />
      <input class="num" type="digit" v-model="row.purchasePrice" placeholder="进价" />
      <text class="amt">¥{{ rowAmount(row) }}</text>
      <text class="del" @click="rows.splice(i, 1)">删</text>
    </view>

    <view class="footer">
      <button class="btn-add" @click="addRow">+ 添加商品</button>
      <text class="total">合计 <text class="total-num">¥{{ total }}</text></text>
    </view>
    <button class="btn-submit" :disabled="saving" @click="submit">{{ saving ? '提交中…' : '提交进货单' }}</button>
  </view>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

interface Price { id: string; unit: string; sale_price: number; purchase_price: number }
interface Item { id: string; name: string; prices: Price[] }
interface Row {
  itemId: string; itemName: string; prices: Price[];
  priceId: string; priceLabel: string; unit: string;
  quantity: string; purchasePrice: string;
}

const items = ref<Item[]>([]);
const itemNames = ref<string[]>([]);
const date = ref('');
const rows = ref<Row[]>([]);
const saving = ref(false);

const total = computed(() =>
  rows.value.reduce((s, r) => s + (Number(r.quantity) || 0) * (Number(r.purchasePrice) || 0), 0),
);
const rowAmount = (r: Row) => ((Number(r.quantity) || 0) * (Number(r.purchasePrice) || 0)).toFixed(2);

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  date.value = todayLocal();
  try {
    const i = await request<{ items: Item[] }>('/items/summary', 'GET');
    items.value = i.items;
    itemNames.value = i.items.map((x) => x.name);
    if (rows.value.length === 0) addRow();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
});

function todayLocal(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function onDate(e: { detail: { value: string } }) {
  date.value = e.detail.value;
}

function addRow() {
  rows.value.push({ itemId: '', itemName: '', prices: [], priceId: '', priceLabel: '', unit: '', quantity: '', purchasePrice: '' });
}

function onItem(i: number, idx: number) {
  const it = items.value[idx];
  const row = rows.value[i];
  if (!it) return;
  row.itemId = it.id;
  row.itemName = it.name;
  row.prices = it.prices;
  row.priceId = '';
  row.priceLabel = '';
  row.unit = '';
  row.purchasePrice = '';
}
function onPrice(i: number, idx: number) {
  const p = rows.value[i].prices[idx];
  if (!p) return;
  const row = rows.value[i];
  row.priceId = p.id;
  row.unit = p.unit;
  row.priceLabel = `${p.unit}（进 ¥${p.purchase_price}）`;
  row.purchasePrice = String(p.purchase_price);
}

async function submit() {
  const valid = rows.value.filter((r) => r.itemId && r.priceId && Number(r.quantity) > 0);
  if (valid.length === 0) return uni.showToast({ title: '请填写完整的商品明细', icon: 'none' });
  saving.value = true;
  try {
    await request('/purchases', 'POST', {
      happened_at: date.value,
      items: valid.map((r) => ({ price_id: r.priceId, quantity: Number(r.quantity), purchase_price: Number(r.purchasePrice) || 0 })),
    });
    uni.showToast({ title: `已提交 ¥${total.value.toFixed(2)}`, icon: 'success' });
    rows.value = [];
    addRow();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '提交失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.field { background: #fff; border-radius: 12rpx; padding: 24rpx; margin-bottom: 16rpx; }
.field-inner { display: flex; justify-content: space-between; }
.label { color: #909399; }
.value { color: #303133; }
.row {
  display: flex; align-items: center; gap: 12rpx;
  background: #fff; border-radius: 12rpx; padding: 16rpx; margin-bottom: 12rpx;
}
.picker { flex: 1; min-width: 0; }
.mini-field {
  background: #f5f7fa; border-radius: 8rpx; padding: 12rpx; font-size: 24rpx; text-align: center;
  overflow: hidden; white-space: nowrap; text-overflow: ellipsis;
}
.num { width: 90rpx; background: #f5f7fa; border-radius: 8rpx; padding: 12rpx; font-size: 24rpx; text-align: center; }
.amt { width: 110rpx; font-size: 24rpx; color: #f56c6c; }
.del { color: #f56c6c; font-size: 24rpx; padding: 8rpx; }
.footer { display: flex; justify-content: space-between; align-items: center; margin: 20rpx 0; }
.btn-add { font-size: 28rpx; }
.total { font-size: 28rpx; }
.total-num { color: #f56c6c; font-weight: bold; font-size: 34rpx; }
.btn-submit { background: #409eff; color: #fff; border-radius: 12rpx; font-size: 32rpx; }
</style>