<template>
  <view class="page">
    <button class="btn-add" @click="openAdd">+ 新增饭店</button>

    <view v-for="c in clients" :key="c.id" class="card">
      <view class="head">
        <view class="left">
          <text class="name">{{ c.name }}</text>
          <text class="meta">{{ c.contact || '' }} {{ c.phone || '' }}</text>
        </view>
        <text class="del" @click="remove(c.id)">删除</text>
      </view>
      <view class="debt">欠款 <text class="debt-num red">¥{{ fmt(c.debt) }}</text></view>
    </view>
    <view v-if="clients.length === 0" class="empty">暂无饭店，点上方新增</view>

    <!-- 新增弹层 -->
    <view v-if="showForm" class="mask" @click="showForm = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">新增饭店</view>
        <input class="ipt" v-model="form.name" placeholder="饭店名（必填）" />
        <input class="ipt" v-model="form.contact" placeholder="联系人" />
        <input class="ipt" v-model="form.phone" placeholder="电话" />
        <input class="ipt" v-model="form.note" placeholder="备注" />
        <button class="btn-save" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

interface Client {
  id: string;
  name: string;
  contact: string;
  phone: string;
  note: string;
  debt: number;
}

const clients = ref<Client[]>([]);
const showForm = ref(false);
const saving = ref(false);
const form = ref({ name: '', contact: '', phone: '', note: '' });
const fmt = (n: number) => Number(n || 0).toFixed(2);

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await load();
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
  form.value = { name: '', contact: '', phone: '', note: '' };
  showForm.value = true;
}

async function save() {
  if (!form.value.name.trim()) {
    uni.showToast({ title: '请填写饭店名', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    await request('/clients', 'POST', {
      name: form.value.name.trim(),
      contact: form.value.contact.trim(),
      phone: form.value.phone.trim(),
      note: form.value.note.trim(),
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
    await request(`/clients/${id}`, 'DELETE');
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
.head { display: flex; align-items: center; }
.left { flex: 1; min-width: 0; }
.name { font-size: 30rpx; font-weight: bold; display: block; }
.meta { font-size: 24rpx; color: #909399; display: block; margin-top: 6rpx; }
.del { color: #f56c6c; font-size: 26rpx; }
.debt { margin-top: 16rpx; font-size: 26rpx; color: #606266; }
.debt-num { font-weight: bold; font-size: 32rpx; }
.red { color: #f56c6c; }
.empty { color: #c0c4cc; text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0, 0, 0, 0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: #fff; border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: #f5f7fa; border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: #409eff; color: #fff; border-radius: 12rpx; font-size: 30rpx; }
</style>