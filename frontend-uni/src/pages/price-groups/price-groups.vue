<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="tip">店铺按价格组分级，记单时自动带出该等级的售价（识别价 → 最近成交 → 等级价 → 商品库兜底）。</view>

    <view v-for="g in groups" :key="g.id" class="card">
      <view class="head">
        <text class="name">{{ g.name }}</text>
        <text class="op" @click="rename(g)">改名</text>
        <text class="del" @click="remove(g.id, g.name)">删除</text>
      </view>
    </view>
    <view v-if="groups.length === 0" class="empty">暂无价格组，点上方新增</view>

    <button class="btn-add" @click="openAdd">+ 新增价格组</button>
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

interface Group {
  id: string;
  name: string;
  sort: number;
}

const groups = ref<Group[]>([]);

onShow(async () => {
  onWs('*', load);
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await load();
});

async function load() {
  try {
    const d = await request<{ price_groups: Group[] }>('/price-groups', 'GET');
    groups.value = d.price_groups || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function openAdd() {
  uni.showModal({
    title: '新增价格组',
    editable: true,
    placeholderText: '如 零售/批发/VIP',
    success: async (r) => {
      if (!r.confirm || !r.content) return;
      const name = r.content.trim();
      if (!name) {
        uni.showToast({ title: '请填写价格组名称', icon: 'none' });
        return;
      }
      try {
        await request('/price-groups', 'POST', { name });
        uni.showToast({ title: '已添加', icon: 'success' });
        await load();
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '添加失败', icon: 'none' });
      }
    },
  });
}

function rename(g: Group) {
  uni.showModal({
    title: '重命名价格组',
    editable: true,
    content: g.name,
    success: async (r) => {
      if (!r.confirm || !r.content) return;
      const name = r.content.trim();
      if (!name || name === g.name) return;
      try {
        await request(`/price-groups/${g.id}`, 'PATCH', { name });
        uni.showToast({ title: '已保存', icon: 'success' });
        await load();
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
      }
    },
  });
}

function remove(id: string, name: string) {
  uni.showModal({
    title: '删除价格组',
    content: `确定删除「${name}」吗？引用该价格组的店铺将变为未分级。`,
    success: async (r) => {
      if (!r.confirm) return;
      try {
        await request(`/price-groups/${id}`, 'DELETE');
        uni.showToast({ title: '已删除', icon: 'success' });
        await load();
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
.tip { font-size: 24rpx; color: var(--text-sub); margin-bottom: 16rpx; }
.btn-add { background: var(--primary); color: #fff; border-radius: 12rpx; margin-bottom: 20rpx; font-size: 30rpx; }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; align-items: center; }
.name { font-size: 30rpx; font-weight: bold; }
.op { margin-left: auto; color: var(--primary); font-size: 26rpx; }
.del { margin-left: 32rpx; color: #f56c6c; font-size: 26rpx; }
.empty { color: var(--text-sub); text-align: center; padding: 60rpx 0; font-size: 26rpx; }
</style>
