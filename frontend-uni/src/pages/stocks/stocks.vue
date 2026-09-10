<template>
  <view class="page">
    <view class="toolbar">
      <input class="search" v-model="q" placeholder="搜索商品" @input="onSearch" />
      <view :class="['pill', { active: belowOnly }]" @click="toggleBelow">只看预警</view>
    </view>

    <view v-if="totalLabel" class="total">{{ totalLabel }}</view>

    <view v-for="s in stocks" :key="s.id" class="card">
      <view class="head">
        <text class="name">{{ s.item_name }}</text>
        <text :class="['qty', { low: s.low }]">{{ s.quantity }}</text>
      </view>
      <view class="sub">单位 {{ s.unit }} · 阈值 {{ s.min_stock }}{{ s.low ? ' · 库存不足' : '' }}</view>
      <view class="ops">
        <text class="op" @click="edit(s)">调整</text>
      </view>
    </view>
    <view v-if="stocks.length === 0" class="empty">暂无库存记录（进货后自动入库，可点「调整」初始化）</view>

    <!-- 调整弹层 -->
    <view v-if="showForm" class="mask" @click="showForm = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">库存调整</view>
        <view class="form-item">{{ cur.item_name }}（{{ cur.unit }}）</view>
        <input class="ipt" v-model="formQty" type="digit" placeholder="库存数量" />
        <input class="ipt" v-model="formMin" type="digit" placeholder="低库存预警阈值" />
        <button class="btn-save" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

interface Stock { id: string; item_name: string; unit: string; quantity: number; min_stock: number; low: boolean }

const stocks = ref<Stock[]>([]);
const q = ref('');
const belowOnly = ref(false);
const totalLabel = ref('');
const showForm = ref(false);
const saving = ref(false);
const cur = ref<{ id: string; item_name: string; unit: string }>({ id: '', item_name: '', unit: '' });
const formQty = ref('');
const formMin = ref('');

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await load();
});

async function load() {
  try {
    const params: string[] = [];
    if (q.value.trim()) params.push(`q=${encodeURIComponent(q.value.trim())}`);
    if (belowOnly.value) params.push('below=1');
    const d = await request<{ stocks: Stock[] }>(`/stocks${params.length ? '?' + params.join('&') : ''}`, 'GET');
    stocks.value = d.stocks;
    if (!belowOnly.value && d.stocks.length) {
      const sum = d.stocks.reduce((s, x) => s + (Number(x.quantity) || 0) * (Number((x as any).cost_price) || 0), 0);
      totalLabel.value = `库存金额合计（按当前进价）¥${sum.toFixed(2)}`;
    } else {
      totalLabel.value = '';
    }
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function onSearch() {
  clearTimeout((onSearch as any)._t);
  (onSearch as any)._t = setTimeout(() => load(), 300);
}

function toggleBelow() {
  belowOnly.value = !belowOnly.value;
  load();
}

function edit(s: Stock) {
  cur.value = { id: s.id, item_name: s.item_name, unit: s.unit };
  formQty.value = String(s.quantity);
  formMin.value = String(s.min_stock);
  showForm.value = true;
}

async function save() {
  const qty = Number(formQty.value);
  const min = Number(formMin.value) || 0;
  if (!(qty >= 0)) {
    uni.showToast({ title: '数量须为非负数字', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    await request(`/stocks/${cur.value.id}`, 'PATCH', { quantity: qty, min_stock: min });
    uni.showToast({ title: '已保存', icon: 'success' });
    showForm.value = false;
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.toolbar { display: flex; align-items: center; gap: 16rpx; margin-bottom: 16rpx; }
.search { flex: 1; background: #fff; border-radius: 12rpx; padding: 16rpx 24rpx; font-size: 28rpx; }
.pill { padding: 12rpx 24rpx; background: #fff; border-radius: 24rpx; font-size: 26rpx; color: #909399; border: 1rpx solid #eee; }
.pill.active { color: #f56c6c; border-color: #f56c6c; background: #fef0f0; }
.total { font-size: 26rpx; color: #67c23a; font-weight: bold; margin-bottom: 12rpx; }
.card { background: #fff; border-radius: 12rpx; padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8rpx; }
.name { font-size: 30rpx; font-weight: bold; }
.qty { font-size: 32rpx; font-weight: bold; color: #67c23a; }
.qty.low { color: #f56c6c; }
.sub { font-size: 24rpx; color: #909399; margin-bottom: 8rpx; }
.ops { display: flex; justify-content: flex-end; }
.op { color: #409eff; font-size: 26rpx; }
.empty { color: #c0c4cc; text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: #fff; border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.form-item { font-size: 28rpx; color: #303133; margin-bottom: 16rpx; }
.ipt { background: #f5f7fa; border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: #409eff; color: #fff; border-radius: 12rpx; font-size: 30rpx; }
</style>