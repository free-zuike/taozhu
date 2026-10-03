<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <input class="search" v-model="search" placeholder="搜索商品（名称关键字）" @input="onSearch" />

    <view v-for="it in items" :key="it.id" class="card">
      <view class="head">
        <text class="name">{{ it.name }}</text>
        <text class="cat">{{ it.category_name || it.category }}</text>
        <text class="op" @click="openEdit(it)">编辑</text>
        <text class="del" @click="remove(it.id)">删除</text>
      </view>
      <view v-for="p in it.prices" :key="p.id" class="price">{{ p.unit }}：进 ¥{{ p.purchase_price }} → 出 ¥{{ p.sale_price }}</view>
    </view>
    <view v-if="items.length === 0" class="empty">暂无商品</view>

    <!-- 新增/编辑弹层 -->
    <view v-if="showForm" class="mask" @click="showForm = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">{{ form.id ? '编辑商品' : '新增商品' }}</view>
        <input class="ipt" v-model="form.name" placeholder="商品名（必填）" />
        <picker class="cat-pk" mode="selector" :range="topNames" @change="onTopCat">
          <view class="pk-inner"><text class="label">一级分类</text><text :class="['value', { placeholder: !form.topName }]">{{ form.topName || '未分类（可手填下方）' }}</text></view>
        </picker>
        <picker v-if="subNames.length" class="cat-pk" mode="selector" :range="subNames" @change="onSubCat">
          <view class="pk-inner"><text class="label">二级分类</text><text :class="['value', { placeholder: !form.subName }]">{{ form.subName || '未分类' }}</text></view>
        </picker>
        <input class="ipt" v-model="form.category" placeholder="分类名（选分类后自动填，也可手动输入）" />
        <view v-for="(p, i) in form.prices" :key="i" class="price-row">
          <input class="ipt s" v-model="p.unit" placeholder="单位" />
          <input class="ipt s" v-model="p.purchase_price" type="digit" placeholder="进价" />
          <input class="ipt s" v-model="p.sale_price" type="digit" placeholder="售价" />
          <text class="del" @click="form.prices.splice(i, 1)">删</text>
        </view>
        <button class="btn-sub" @click="form.prices.push({ id: '', unit: '', purchase_price: '', sale_price: '' })">+ 加价格行（同菜多单位）</button>
        <button class="btn-save" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>
    <button v-if="!showForm" class="btn-add" @click="openAdd()">+ 新增商品</button>
  </view>
</template>

<script setup lang="ts">
import { onShow, onHide } from '@dcloudio/uni-app';
import { onWs, offWs } from '../../ws';

import { useThemeVars } from '../../theme';
const { tv, patternSrc } = useThemeVars();
import { ref } from 'vue';
;
;
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
  category_name?: string;
  prices: Price[];
}

const items = ref<Item[]>([]);
const search = ref('');
const showForm = ref(false);
const saving = ref(false);
const form = ref<{ id?: string; name: string; category: string; categoryId: string; topId: string; topName: string; subId: string; subName: string; prices: Price[] }>({
  id: undefined, name: '', category: '', categoryId: '', topId: '', topName: '', subId: '', subName: '', prices: [{ id: '', unit: '', purchase_price: '', sale_price: '' }],
});

// 两级商品分类（对齐 App items_page：一级+二级级联选择，type=item）
const itemsCats = ref<Array<{ id: string; name: string; parent_id: string | null }>>([]);
const topNames = ref<string[]>(['未分类']);
const subNames = ref<string[]>([]);
const topCats = () => itemsCats.value.filter((c) => !c.parent_id);
const subCatsOf = (topId: string) => itemsCats.value.filter((c) => c.parent_id === topId);

async function loadCats() {
  try {
    const d = await request<{ categories: Array<{ id: string; name: string; parent_id: string | null }> }>('/categories?type=item', 'GET').catch(() => null);
    itemsCats.value = d?.categories || [];
    topNames.value = ['未分类', ...topCats().map((c) => c.name)];
  } catch (e) {
    // 分类加载失败不阻塞（手动分类名仍可用）
  }
}

function onTopCat(e: { detail: { value: number } }) {
  const idx = e.detail.value;
  if (idx <= 0) {
    form.value.topId = ''; form.value.topName = ''; form.value.subId = ''; form.value.subName = '';
    form.value.categoryId = ''; form.value.category = '';
    subNames.value = [];
    return;
  }
  const t = topCats()[idx - 1];
  form.value.topId = t.id; form.value.topName = t.name;
  form.value.subId = ''; form.value.subName = '';
  form.value.categoryId = t.id; form.value.category = t.name;
  const subs = subCatsOf(t.id);
  subNames.value = ['未分类', ...subs.map((c) => c.name)];
}

function onSubCat(e: { detail: { value: number } }) {
  const idx = e.detail.value;
  if (idx <= 0) {
    form.value.subId = ''; form.value.subName = '';
    form.value.categoryId = form.value.topId; form.value.category = form.value.topName;
    return;
  }
  const s = subCatsOf(form.value.topId)[idx - 1];
  form.value.subId = s.id; form.value.subName = s.name;
  form.value.categoryId = s.id; form.value.category = s.name;
}

onShow(async () => {
  onWs('*', load);
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await Promise.all([load(), loadCats()]);
});

async function load(q = '') {
  try {
    const url = q ? `/items?q=${encodeURIComponent(q)}` : '/items';
    const d = await request<{ items: Item[] }>(url, 'GET');
    items.value = d.items;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function onSearch() {
  const q = search.value.trim();
  // 输入即查（简单防抖：300ms）
  clearTimeout((onSearch as any)._t);
  (onSearch as any)._t = setTimeout(() => load(q), 300);
}

function openAdd() {
  form.value = { id: undefined, name: '', category: '', categoryId: '', topId: '', topName: '', subId: '', subName: '', prices: [{ id: '', unit: '', purchase_price: '', sale_price: '' }] };
  subNames.value = [];
  showForm.value = true;
}

function openEdit(it: Item) {
  form.value = {
    id: it.id,
    name: it.name,
    category: it.category_name || it.category || '',
    categoryId: (it as any).category_id || '',
    topId: '', topName: '', subId: '', subName: '',
    prices: (it.prices || []).map((p) => ({
      id: p.id || '', unit: p.unit,
      purchase_price: String(p.purchase_price ?? ''),
      sale_price: String(p.sale_price ?? ''),
    })),
  };
  // 回填分类选择器（按 id 定位一级/二级）
  const cid = (it as any).category_id || '';
  if (cid) {
    const cat = itemsCats.value.find((c) => c.id === cid);
    const top = cat?.parent_id ? itemsCats.value.find((c) => c.id === cat.parent_id) : cat;
    if (cat && !cat.parent_id) {
      form.value.topId = cat.id; form.value.topName = cat.name;
      const subs = subCatsOf(cat.id);
      subNames.value = ['未分类', ...subs.map((c) => c.name)];
    } else if (cat && top) {
      form.value.topId = top.id; form.value.topName = top.name;
      form.value.subId = cat.id; form.value.subName = cat.name;
      const subs = subCatsOf(top.id);
      subNames.value = ['未分类', ...subs.map((c) => c.name)];
    }
  } else {
    subNames.value = [];
  }
  if (form.value.prices.length === 0) {
    form.value.prices = [{ id: '', unit: '', purchase_price: '', sale_price: '' }];
  }
  showForm.value = true;
}

async function save() {
  if (!form.value.name.trim()) {
    uni.showToast({ title: '请填写商品名', icon: 'none' });
    return;
  }
  const rows = form.value.prices.filter((p) => p.unit.trim());
  if (rows.length === 0) {
    uni.showToast({ title: '请至少填写一个单位价格', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    const num = (v: string) => Number(v) || 0;
    if (form.value.id) {
      const id = form.value.id;
      await request(`/items/${id}`, 'PATCH', { name: form.value.name.trim(), category: form.value.category.trim(), category_id: form.value.categoryId });
      // 既有价格更新 / 新增价格
      for (const p of rows) {
        const body = { unit: p.unit.trim(), purchase_price: num(p.purchase_price), sale_price: num(p.sale_price) };
        if (p.id) await request(`/items/item-prices/${p.id}`, 'PATCH', body);
        else await request(`/items/${id}/prices`, 'POST', body);
      }
      // 被移除的既有价格 → 停用
      const nowIds = new Set(rows.map((p) => p.id).filter(Boolean));
      const orig = items.value.find((x) => x.id === id);
      for (const p of orig?.prices || []) {
        if (p.id && !nowIds.has(p.id)) await request(`/items/item-prices/${p.id}`, 'DELETE');
      }
    } else {
      await request('/items', 'POST', {
        name: form.value.name.trim(),
        category: form.value.category.trim(),
        category_id: form.value.categoryId,
        prices: rows.map((p) => ({ unit: p.unit.trim(), purchase_price: num(p.purchase_price), sale_price: num(p.sale_price) })),
      });
    }
    uni.showToast({ title: '已保存', icon: 'success' });
    showForm.value = false;
    await load(search.value.trim());
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

async function remove(id: string) {
  uni.showModal({
    title: '删除商品',
    content: '确定删除该商品吗？相关历史记录不受影响。',
    success: async (r) => {
      if (!r.confirm) return;
      try {
        await request(`/items/${id}`, 'DELETE');
        uni.showToast({ title: '已删除', icon: 'success' });
        await load(search.value.trim());
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
      }
    },
  });
}

  onHide(() => { offWs('*', load); });
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh;  background: var(--page-bg); }
.search { background: var(--card-bg); border-radius: 12rpx; padding: 18rpx 24rpx; margin-bottom: 20rpx; font-size: 28rpx; }
.btn-add { background: var(--primary); color: #fff; border-radius: 12rpx; margin-bottom: 20rpx; font-size: 30rpx; }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; align-items: center; margin-bottom: 12rpx; }
.name { font-size: 30rpx; font-weight: bold; }
.cat { margin-left: 16rpx; font-size: 24rpx; color: var(--text-sub); }
.op { margin-left: auto; color: var(--primary); font-size: 26rpx; }
.del { margin-left: 32rpx; color: #f56c6c; font-size: 26rpx; }
.price { font-size: 26rpx; color: var(--text-sub); margin-top: 6rpx; }
.empty { color: var(--text-sub); text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0, 0, 0, 0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: var(--sheet-bg); border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.cat-pk { background: var(--input-bg); border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; }
.pk-inner { display: flex; align-items: center; }
.pk-inner .label { font-size: 24rpx; color: var(--text-sub); margin-right: 20rpx; flex-shrink: 0; }
.pk-inner .value { flex: 1; font-size: 28rpx; color: var(--text-main); text-align: right; }
.pk-inner .value.placeholder { color: var(--text-sub); }
.price-row { display: flex; gap: 12rpx; align-items: center; }
.price-row .s { flex: 1; min-width: 0; }
.btn-sub { background: var(--card-bg); border: 1rpx solid var(--primary); color: var(--primary); border-radius: 10rpx; font-size: 26rpx; margin-bottom: 16rpx; }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; }
</style>