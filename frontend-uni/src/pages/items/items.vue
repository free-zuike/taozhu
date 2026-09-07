<template>
  <view class="page">
    <button class="btn-add" @click="openAdd">+ 新增商品</button>

    <view v-for="it in items" :key="it.id" class="card">
      <view class="head">
        <text class="name">{{ it.name }}</text>
        <text class="cat">{{ it.category }}</text>
        <text class="del" @click="remove(it.id)">删除</text>
      </view>
      <view v-for="p in it.prices" :key="p.id" class="price">{{ p.unit }}：进 ¥{{ p.purchase_price }} → 出 ¥{{ p.sale_price }}</view>
    </view>
    <view v-if="items.length === 0" class="empty">暂无商品，点上方新增</view>

    <!-- 新增弹层 -->
    <view v-if="showForm" class="mask" @click="showForm = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">新增商品</view>
        <input class="ipt" v-model="form.name" placeholder="商品名（必填）" />
        <input class="ipt" v-model="form.category" placeholder="分类（如 蔬菜）" />
        <view v-for="(p, i) in form.prices" :key="i" class="price-row">
          <input class="ipt s" v-model="p.unit" placeholder="单位" />
          <input class="ipt s" v-model="p.purchase_price" type="digit" placeholder="进价" />
          <input class="ipt s" v-model="p.sale_price" type="digit" placeholder="出价" />
          <text class="del" @click="form.prices.splice(i, 1)">删</text>
        </view>
        <button class="btn-sub" @click="form.prices.push({ unit: '', purchase_price: '', sale_price: '' })">+ 加价格行（同菜多单位）</button>
        <button class="btn-save" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

interface Price {
  id?: string;
  unit: string;
  purchase_price: string;
  sale_price: string;
}
interface Item {
  id: string;
  name: string;
  category: string;
  prices: Price[];
}

const items = ref<Item[]>([]);
const showForm = ref(false);
const saving = ref(false);
const form = ref<{ name: string; category: string; prices: Price[] }>({
  name: '',
  category: '',
  prices: [{ unit: '', purchase_price: '', sale_price: '' }],
});

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await load();
});

async function load() {
  try {
    const d = await request<{ items: Item[] }>('/items', 'GET');
    items.value = d.items;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function openAdd() {
  form.value = { name: '', category: '', prices: [{ unit: '', purchase_price: '', sale_price: '' }] };
  showForm.value = true;
}

async function save() {
  if (!form.value.name.trim()) {
    uni.showToast({ title: '请填写商品名', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    const prices = form.value.prices
      .filter((p) => p.unit.trim())
      .map((p) => ({
        unit: p.unit.trim(),
        purchase_price: Number(p.purchase_price) || 0,
        sale_price: Number(p.sale_price) || 0,
      }));
    await request('/items', 'POST', {
      name: form.value.name.trim(),
      category: form.value.category.trim(),
      prices,
    });
    uni.showToast({ title: '已保存', icon: 'success' });
    showForm.value = false;
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

async function remove(id: string) {
  try {
    await request(`/items/${id}`, 'DELETE');
    uni.showToast({ title: '已删除', icon: 'success' });
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
  }
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.btn-add { background: #409eff; color: #fff; border-radius: 12rpx; margin-bottom: 20rpx; font-size: 30rpx; }
.card { background: #fff; border-radius: 12rpx; padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; align-items: center; margin-bottom: 12rpx; }
.name { font-size: 30rpx; font-weight: bold; }
.cat { margin-left: 16rpx; font-size: 24rpx; color: #909399; }
.del { margin-left: auto; color: #f56c6c; font-size: 26rpx; }
.price { font-size: 26rpx; color: #606266; margin-top: 6rpx; }
.empty { color: #c0c4cc; text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0, 0, 0, 0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: #fff; border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: #f5f7fa; border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.price-row { display: flex; gap: 12rpx; align-items: center; }
.price-row .s { flex: 1; min-width: 0; }
.btn-sub { background: #fff; border: 1rpx solid #409eff; color: #409eff; border-radius: 10rpx; font-size: 26rpx; margin-bottom: 16rpx; }
.btn-save { background: #409eff; color: #fff; border-radius: 12rpx; font-size: 30rpx; }
</style>