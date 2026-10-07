<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="seg">
      <view :class="['seg-item', { active: type === 'item' }]" @click="switchType('item')">商品分类</view>
      <view :class="['seg-item', { active: type === 'client' }]" @click="switchType('client')">店铺分类</view>
    </view>

    <button class="btn-add" @click="openForm()">+ 新增{{ type === 'item' ? '商品' : '店铺' }}分类</button>

    <view v-for="c in top" :key="c.id" class="card">
      <view class="head">
        <view class="cat-ic"><text class="mi">&#xe2c7;</text></view>
        <text class="name" @click="showCatItems(c)">{{ c.name }}</text>
        <text class="view-hint" @click="showCatItems(c)">查看</text>
        <text class="mi op-ic" @click="openForm(c.id, c.name)">&#xe145;</text>
        <text class="mi op-ic" @click="openRename(c)">&#xe3c9;</text>
        <text class="mi op-ic op-del" @click="remove(c)">&#xe92e;</text>
      </view>
      <view v-for="ch in childrenOf(c.id)" :key="ch.id" class="child">
        <text class="mi sub-ic">&#xe2c7;</text>
        <text class="ch-name" @click="showCatItems(ch)">{{ ch.name }}</text>
        <text class="mi op-ic" @click="openRename(ch)">&#xe3c9;</text>
        <text class="mi op-ic op-del" @click="remove(ch)">&#xe92e;</text>
      </view>
    </view>
    <view v-if="top.length === 0" class="empty">暂无分类，点上方新增</view>

    <!-- 分类下商品/店铺查看弹层（点分类名称） -->
    <view v-if="itemsDlg" class="mask" @click="itemsDlg = false">
      <view class="sheet" @click.stop>
        <text class="s-title">「{{ itemsTitle }}」分类{{ type === 'item' ? '商品' : '店铺' }}（{{ itemsList.length }}）</text>
        <scroll-view scroll-y class="items-scroll">
          <view v-for="(it, i) in itemsList" :key="i" class="it-row">
            <text class="it-name">{{ it.name }}</text>
            <text v-if="type === 'item' && it.priceLabel" class="it-price">{{ it.priceLabel }}</text>
          </view>
          <view v-if="itemsList.length === 0" class="empty">暂无{{ type === 'item' ? '商品' : '店铺' }}</view>
        </scroll-view>
        <button class="btn-save" @click="itemsDlg = false">关闭</button>
      </view>
    </view>

    <!-- 新增/重命名弹层 -->
    <view v-if="showForm" class="mask" @click="showForm = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">{{ form.title }}</view>
        <input class="ipt" v-model="form.name" placeholder="分类名称" />
        <button class="btn-save" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { useThemeVars } from '../../theme';
const { tv, patternSrc } = useThemeVars();
import { computed, ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

interface Cat { id: string; type: string; name: string; parent_id: string | null; sort: number }

const type = ref<'item' | 'client'>('item');
const cats = ref<Cat[]>([]);
const showForm = ref(false);
const saving = ref(false);
const form = ref<{ title: string; name: string; id?: string; parentId?: string; parentName: string }>({
  title: '', name: '', id: undefined, parentId: undefined, parentName: '',
});

const top = computed(() => cats.value.filter((c) => !c.parent_id));
const childrenOf = (id: string) => cats.value.filter((c) => c.parent_id === id);

// 分类下商品/店铺查看（点分类名称）：item=商品列表（名称+首价格）；client=店铺列表
const itemsDlg = ref(false);
const itemsTitle = ref('');
const itemsList = ref<Array<{ name: string; priceLabel?: string }>>([]);

async function showCatItems(c: Cat) {
  const ids = [c.id, ...childrenOf(c.id).map((x) => x.id)];
  itemsTitle.value = c.name;
  itemsDlg.value = true;
  itemsList.value = [];
  if (type.value === 'item') {
    try {
      const d = await request<{ items?: Array<{ id: string; name: string; category_id?: string | null; prices?: Array<{ unit: string; sale_price: number }> }> }>('/items', 'GET');
      const all = d.items || [];
      itemsList.value = all
          .filter((it) => ids.includes(String(it.category_id || '')))
          .map((it) => ({
            name: it.name,
            priceLabel: (it.prices || [])[0] ? `${(it.prices as Array<{ unit: string; sale_price: number }>)[0].unit}：售价 ¥${Number((it.prices as Array<{ unit: string; sale_price: number }>)[0].sale_price || 0).toFixed(2)}` : '',
          }));
    } catch (e) {
      uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
      itemsDlg.value = false;
    }
  } else {
    try {
      const d = await request<{ clients?: Array<{ id: string; name: string; category_id?: string | null }> }>('/clients', 'GET');
      itemsList.value = (d.clients || [])
          .filter((cl) => ids.includes(String(cl.category_id || '')))
          .map((cl) => ({ name: cl.name }));
    } catch (e) {
      uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
      itemsDlg.value = false;
    }
  }
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
    const d = await request<{ categories: Cat[] }>(`/categories?type=${type.value}`, 'GET');
    cats.value = d.categories;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function switchType(t: 'item' | 'client') {
  type.value = t;
  load();
}

function openForm(parentId?: string, parentName = '') {
  form.value = {
    title: parentId ? `在「${parentName}」下新增子分类` : `新增${type.value === 'item' ? '商品' : '店铺'}分类`,
    name: '', id: undefined, parentId, parentName,
  };
  showForm.value = true;
}

function openRename(c: Cat) {
  form.value = { title: '重命名分类', name: c.name, id: c.id, parentId: undefined, parentName: '' };
  showForm.value = true;
}

async function save() {
  const name = form.value.name.trim();
  if (!name) {
    uni.showToast({ title: '请填写分类名称', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    if (form.value.id) {
      await request(`/categories/${form.value.id}`, 'PATCH', { name });
    } else {
      await request('/categories', 'POST', { type: type.value, name, parent_id: form.value.parentId });
    }
    uni.showToast({ title: '已保存', icon: 'success' });
    showForm.value = false;
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

async function remove(c: Cat) {
  uni.showModal({
    title: '删除分类',
    content: `确定删除「${c.name}」吗？该分类下的商品/店铺将变为未分类。`,
    success: async (r) => {
      if (!r.confirm) return;
      try {
        await request(`/categories/${c.id}`, 'DELETE');
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
.page { min-height: 100vh;  background: var(--page-bg); }
.seg { display: flex; background: var(--card-bg); border-radius: 12rpx; margin-bottom: 20rpx; overflow: hidden; }
.seg-item { flex: 1; text-align: center; padding: 20rpx; font-size: 28rpx; color: var(--text-sub); }
.seg-item.active { color: var(--primary); font-weight: bold; background: var(--primary-soft); }
.btn-add { background: var(--primary); color: #fff; border-radius: 12rpx; margin-bottom: 20rpx; font-size: 30rpx; }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; align-items: center; margin-bottom: 12rpx; }
.cat-ic { width: 52rpx; height: 52rpx; border-radius: 14rpx; background: var(--primary-soft); display: flex; align-items: center; justify-content: center; margin-right: 14rpx; flex-shrink: 0; }
.cat-ic .mi { font-size: 28rpx; }
.name { font-size: 30rpx; font-weight: bold; flex: 1; min-width: 0; }
.view-hint { font-size: 22rpx; color: var(--primary); margin-right: 12rpx; flex-shrink: 0; }
.op-ic { font-size: 30rpx; color: var(--text-sub); margin-left: 20rpx; flex-shrink: 0; }
.op-ic.op-del { color: #f56c6c; }
.child { display: flex; align-items: center; padding: 10rpx 0 10rpx 14rpx; border-top: 1rpx solid var(--divider); }
.sub-ic { font-size: 26rpx; color: var(--text-sub); margin-right: 10rpx; flex-shrink: 0; }
.ch-name { font-size: 28rpx; flex: 1; min-width: 0; }
.empty { color: var(--text-sub); text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: var(--sheet-bg); border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.s-title { font-size: 30rpx; font-weight: 700; margin-bottom: 16rpx; display: block; }
.items-scroll { max-height: 60vh; }
.it-row { display: flex; align-items: center; justify-content: space-between; padding: 18rpx 8rpx; border-bottom: 1rpx solid var(--divider); }
.it-name { font-size: 28rpx; color: var(--text-main); }
.it-price { font-size: 24rpx; color: var(--text-sub); }
.ipt { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; }
</style>