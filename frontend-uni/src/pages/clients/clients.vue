<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <button class="btn-add" @click="openAdd">+ 新增饭店</button>

    <view v-for="c in clients" :key="c.id" class="card">
      <view class="head" @click="openEdit(c)">
        <view class="left">
          <view class="name-line">
            <text class="name">{{ c.name }}</text>
            <text v-if="c.category_name" class="cat">{{ c.category_name }}</text>
          </view>
          <text class="meta">{{ c.contact || '' }} {{ c.phone || '' }}</text>
        </view>
        <text class="del" @click.stop="remove(c.id)">删除</text>
      </view>
      <view class="debt">欠款 <text class="debt-num red">¥{{ fmt(c.debt) }}</text></view>
    </view>
    <view v-if="clients.length === 0" class="empty">暂无饭店，点上方新增</view>

    <!-- 新增/编辑弹层 -->
    <view v-if="showForm" class="mask" @click="showForm = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">{{ form.editId ? '编辑饭店' : '新增饭店' }}</view>
        <input class="ipt" v-model="form.name" placeholder="饭店名（必填）" />
        <picker class="field" mode="selector" :range="catNames" @change="onCatChange">
          <view class="field-inner">
            <text class="label">分类</text>
            <text :class="['value', { placeholder: !form.categoryId }]">{{ form.categoryName || '未分类（可后续在分类管理添加店铺分类）' }}</text>
          </view>
        </picker>
        <input class="ipt" v-model="form.contact" placeholder="联系人" />
        <input class="ipt" v-model="form.phone" placeholder="电话" />
        <input class="ipt" v-model="form.note" placeholder="备注" />
        <button class="btn-save" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>
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

interface Client {
  id: string;
  name: string;
  contact: string;
  phone: string;
  note: string;
  debt: number;
  category_id?: string;
  category_name?: string;
}

const clients = ref<Client[]>([]);
const showForm = ref(false);
const saving = ref(false);
const form = ref({ name: '', contact: '', phone: '', note: '', editId: '', categoryId: '', categoryName: '' });
const fmt = (n: number) => Number(n || 0).toFixed(2);

// 店铺分类（type=client，两级平铺；选项显示"一级/二级"）
const cats = ref<Array<{ id: string; name: string; parent_id: string | null }>>([]);
const catNames = ref<string[]>([]);
const catIds = ref<string[]>([]);

async function loadCats() {
  try {
    const d = await request<{ categories: Array<{ id: string; name: string; parent_id: string | null }> }>('/categories?type=client', 'GET').catch(() => null);
    cats.value = d?.categories || [];
    const nameOf = (id: string) => cats.value.find((c) => c.id === id)?.name || '';
    catNames.value = ['未分类'];
    catIds.value = [''];
    for (const c of cats.value) {
      if (!c.parent_id) {
        catNames.value.push(c.name);
        catIds.value.push(c.id);
      } else {
        catNames.value.push(`${nameOf(c.parent_id)}/${c.name}`);
        catIds.value.push(c.id);
      }
    }
  } catch (e) {
    // 分类加载失败不阻塞（未分类保存）
  }
}

function onCatChange(e: { detail: { value: number } }) {
  form.value.categoryId = catIds.value[e.detail.value] || '';
  form.value.categoryName = catNames.value[e.detail.value] || '';
}

onShow(async () => {
  onWs('*', load);
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await Promise.all([load(), loadCats()]);
});

async function load() {
  try {
    const d = await request<{ clients: Client[] }>('/clients', 'GET');
    clients.value = d.clients;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function openAdd() {
  form.value = { name: '', contact: '', phone: '', note: '', editId: '', categoryId: '', categoryName: '' };
  showForm.value = true;
}

function openEdit(c: Client) {
  form.value = {
    name: c.name || '',
    contact: c.contact || '',
    phone: c.phone || '',
    note: c.note || '',
    editId: c.id,
    categoryId: c.category_id || '',
    categoryName: (c.category_id ? (c.category_name || '') : ''),
  };
  showForm.value = true;
}

async function save() {
  if (!form.value.name.trim()) {
    uni.showToast({ title: '请填写饭店名', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    const body: Record<string, string> = {
      name: form.value.name.trim(),
      contact: form.value.contact.trim(),
      phone: form.value.phone.trim(),
      note: form.value.note.trim(),
      category_id: form.value.categoryId,
    };
    if (form.value.editId) {
      await request(`/clients/${form.value.editId}`, 'PATCH', body);
    } else {
      await request('/clients', 'POST', body);
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

async function remove(id: string) {
  try {
    await request(`/clients/${id}`, 'DELETE');
    uni.showToast({ title: '已删除', icon: 'success' });
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
  }
}

  onHide(() => { offWs('*', load); });
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh;  background: var(--page-bg); }
.btn-add { background: var(--primary); color: #fff; border-radius: 12rpx; margin-bottom: 20rpx; font-size: 30rpx; box-shadow: 0 6rpx 18rpx var(--primary-fade);}
.card { background: var(--card-bg); border-radius: 16rpx; padding: 24rpx; margin-bottom: 16rpx; box-shadow: var(--card-shadow);}
.head { display: flex; align-items: center; }
.left { flex: 1; min-width: 0; }
.name { font-size: 30rpx; font-weight: bold; display: block; }
.name-line { display: flex; align-items: center; gap: 12rpx; }
.cat { font-size: 20rpx; color: var(--primary); background: var(--primary-soft); border-radius: 6rpx; padding: 2rpx 10rpx; flex-shrink: 0; }
.meta { font-size: 24rpx; color: var(--text-sub); display: block; margin-top: 6rpx; }
.field { background: var(--input-bg); border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; }
.field-inner { display: flex; align-items: center; }
.label { font-size: 24rpx; color: var(--text-sub); margin-right: 20rpx; flex-shrink: 0; }
.value { flex: 1; font-size: 28rpx; color: var(--text-main); text-align: right; }
.value.placeholder { color: var(--text-sub); }
.del { color: #f56c6c; font-size: 26rpx; }
.debt { margin-top: 16rpx; font-size: 26rpx; color: var(--text-sub); }
.debt-num { font-weight: bold; font-size: 32rpx; }
.red { color: #f56c6c; }
.empty { color: var(--text-sub); text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0, 0, 0, 0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: var(--sheet-bg); border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; box-shadow: 0 6rpx 18rpx var(--primary-fade);}
</style>