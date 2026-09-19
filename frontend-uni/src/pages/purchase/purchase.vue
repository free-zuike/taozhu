<template>
  <view class="page">
    <view class="head-row">
      <picker class="field" mode="date" :value="date" @change="onDate">
        <view class="field-inner">
          <text class="label">日期</text>
          <text class="value">{{ date }}</text>
        </view>
      </picker>
      <button class="copy-btn" :disabled="loading" @click="copyLast">复制上一笔</button>
    </view>

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
    <button class="btn-submit" :disabled="saving" @click="submit">{{ saving ? '提交中…' : (editId ? '保存修改' : '提交进货单') }}</button>
  </view>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue';
import { onLoad, onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

interface Price { id: string; unit: string; sale_price: number; purchase_price: number }
interface Item { id: string; name: string; prices: Price[] }
interface Row {
  itemId: string; itemName: string; prices: Price[];
  priceId: string; priceLabel: string; unit: string;
  quantity: string; purchasePrice: string; countQty: string;
}

const items = ref<Item[]>([]);
const itemNames = ref<string[]>([]);
const date = ref('');
const rows = ref<Row[]>([]);
const saving = ref(false);
const loading = ref(false);
const editId = ref(''); // 非空 = 编辑已有进货单（账本进入，提交走 PATCH）

onLoad((options) => {
  editId.value = options?.id || '';
  if (editId.value) uni.setNavigationBarTitle({ title: '编辑进货单' });
});

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
    if (editId.value) await loadEdit();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
});

/// 编辑模式预填：GET /purchases/:id → 按 item_id+unit 匹配现有价格回填行
async function loadEdit() {
  try {
    const d = await request<{ happened_at: string; items: Array<Record<string, any>> }>(`/purchases/${editId.value}`, 'GET');
    date.value = String(d.happened_at || '').slice(0, 10);
    rows.value = [];
    for (const it of d.items) {
      const item = items.value.find((x) => x.id === it.item_id);
      const price = item?.prices.find((p) => p.unit === it.unit);
      if (!item || !price) continue;
      rows.value.push({
        itemId: item.id, itemName: item.name, prices: item.prices,
        priceId: price.id, priceLabel: `${price.unit}（进 ¥${price.purchase_price}·库存${price.stock ?? 0}）`, unit: price.unit,
        quantity: String(it.quantity), purchasePrice: String(it.purchase_price), countQty: it.count_qty ? String(it.count_qty) : '',
      });
    }
    if (rows.value.length === 0) {
      rows.value = [];
      addRow();
    }
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载单据失败', icon: 'none' });
  }
}

function todayLocal(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/// 复制上一笔进货单：读最近一单预填日期/明细（可修改后提交）
async function copyLast() {
  if (loading.value) return;
  loading.value = true;
  try {
    const d = await request<{ purchases: Array<{ happened_at: string; items: Array<Record<string, any>> }> }>('/purchases?limit=1', 'GET');
    const last = d.purchases?.[0];
    if (!last) {
      uni.showToast({ title: '暂无历史进货单', icon: 'none' });
      return;
    }
    date.value = String(last.happened_at || '').slice(0, 10);
    rows.value = [];
    for (const it of last.items || []) {
      const item = items.value.find((x) => x.id === it.item_id);
      const price = item?.prices.find((p) => p.unit === it.unit);
      if (!item || !price) continue;
      rows.value.push({
        itemId: item.id, itemName: item.name, prices: item.prices,
        priceId: price.id, priceLabel: `${price.unit}（¥${price.purchase_price}·库存${(price as any).stock ?? 0}）`, unit: price.unit,
        quantity: String(it.quantity), purchasePrice: String(it.purchase_price), countQty: it.count_qty ? String(it.count_qty) : '',
      });
    }
    if (rows.value.length === 0) addRow();
    uni.showToast({ title: '已复制上一笔，可修改后提交', icon: 'none' });
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '复制失败', icon: 'none' });
  } finally {
    loading.value = false;
  }
}

function onDate(e: { detail: { value: string } }) {
  date.value = e.detail.value;
}

function addRow() {
  rows.value.push({ itemId: '', itemName: '', prices: [], priceId: '', priceLabel: '', unit: '', quantity: '', purchasePrice: '', countQty: '' });
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
  row.priceLabel = `${p.unit}（进 ¥${p.purchase_price}·库存${p.stock ?? 0}）`;
  row.purchasePrice = String(p.purchase_price);
}

async function submit() {
  const valid = rows.value.filter((r) => r.itemId && r.priceId && Number(r.quantity) > 0);
  if (valid.length === 0) return uni.showToast({ title: '请填写完整的商品明细', icon: 'none' });
  saving.value = true;
  try {
    const body = {
      happened_at: date.value,
      items: valid.map((r) => ({ price_id: r.priceId, quantity: Number(r.quantity), count_qty: Number(r.countQty) > 0 ? Number(r.countQty) : null, purchase_price: Number(r.purchasePrice) || 0 })),
    };
    if (editId.value) {
      await request(`/purchases/${editId.value}`, 'PATCH', body);
      uni.showToast({ title: '已保存修改', icon: 'success' });
    } else {
      await request('/purchases', 'POST', body);
      uni.showToast({ title: `已提交 ¥${total.value.toFixed(2)}`, icon: 'success' });
      rows.value = [];
      addRow();
    }
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '提交失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.head-row { display: flex; gap: 12rpx; align-items: flex-start; margin-bottom: 16rpx; }
.head-row .field { flex: 1; background: #fff; border-radius: 12rpx; padding: 24rpx; }
.head-row .field-inner { flex-direction: column; align-items: flex-start; gap: 6rpx; }
.copy-btn { flex-shrink: 0; background: #fff; color: #409eff; border: 1rpx solid #409eff; border-radius: 12rpx; font-size: 26rpx; padding: 0 20rpx; height: 88rpx; line-height: 88rpx; }
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