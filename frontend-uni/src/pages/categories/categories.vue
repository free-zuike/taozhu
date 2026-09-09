<template>
  <view class="page">
    <view class="seg">
      <view :class="['seg-item', { active: type === 'item' }]" @click="switchType('item')">商品分类</view>
      <view :class="['seg-item', { active: type === 'client' }]" @click="switchType('client')">店铺分类</view>
    </view>

    <button class="btn-add" @click="openForm()">+ 新增{{ type === 'item' ? '商品' : '店铺' }}分类</button>

    <view v-for="c in top" :key="c.id" class="card">
      <view class="head">
        <text class="name">{{ c.name }}</text>
        <text class="op" @click="openForm(c.id, c.name)">加子类</text>
        <text class="op" @click="openRename(c)">改名</text>
        <text class="del" @click="remove(c)">删除</text>
      </view>
      <view v-for="ch in childrenOf(c.id)" :key="ch.id" class="child">
        <text class="ch-name">{{ ch.name }}</text>
        <text class="op" @click="openRename(ch)">改名</text>
        <text class="del" @click="remove(ch)">删除</text>
      </view>
    </view>
    <view v-if="top.length === 0" class="empty">暂无分类，点上方新增</view>

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
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.seg { display: flex; background: #fff; border-radius: 12rpx; margin-bottom: 20rpx; overflow: hidden; }
.seg-item { flex: 1; text-align: center; padding: 20rpx; font-size: 28rpx; color: #909399; }
.seg-item.active { color: #409eff; font-weight: bold; background: #ecf5ff; }
.btn-add { background: #409eff; color: #fff; border-radius: 12rpx; margin-bottom: 20rpx; font-size: 30rpx; }
.card { background: #fff; border-radius: 12rpx; padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; align-items: center; margin-bottom: 12rpx; }
.name { font-size: 30rpx; font-weight: bold; }
.child { display: flex; align-items: center; padding: 10rpx 0 10rpx 32rpx; border-top: 1rpx solid #f5f7fa; }
.ch-name { font-size: 28rpx; }
.op { margin-left: 24rpx; color: #409eff; font-size: 26rpx; }
.del { margin-left: 24rpx; color: #f56c6c; font-size: 26rpx; }
.empty { color: #c0c4cc; text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: #fff; border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: #f5f7fa; border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: #409eff; color: #fff; border-radius: 12rpx; font-size: 30rpx; }
</style>