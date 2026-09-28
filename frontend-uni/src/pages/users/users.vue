<template>
  <view class="page" :style="tv">
    <button class="btn-add" @click="openForm()">+ 新增账号</button>

    <view v-for="u in users" :key="u.id" class="card">
      <view class="head">
        <text class="name">{{ u.username }}</text>
        <text :class="['role', { admin: u.role === 'admin' }]">{{ u.role === 'admin' ? '老板' : '店员' }}</text>
        <text class="op" @click="openForm(u)">编辑</text>
        <text class="del" @click="remove(u)">删除</text>
      </view>
    </view>
    <view v-if="users.length === 0" class="empty">暂无账号</view>

    <!-- 新增/编辑弹层 -->
    <view v-if="showForm" class="mask" @click="showForm = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">{{ form.id ? '编辑账号' : '新增账号' }}</view>
        <input class="ipt" v-model="form.username" placeholder="登录名 *" />
        <input class="ipt" v-model="form.password" password placeholder="密码（新增必填，编辑留空不改）" />
        <view class="seg">
          <view :class="['seg-item', { active: form.role === 'staff' }]" @click="form.role = 'staff'">店员</view>
          <view :class="['seg-item', { active: form.role === 'admin' }]" @click="form.role = 'admin'">老板</view>
        </view>
        <button class="btn-save" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { useThemeVars } from '../../theme';
const tv = useThemeVars();
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

interface User { id: string; username: string; role: string }

const users = ref<User[]>([]);
const showForm = ref(false);
const saving = ref(false);
const form = ref<{ id?: string; username: string; password: string; role: string }>({
  id: undefined, username: '', password: '', role: 'staff',
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
    const d = await request<{ users: User[] }>('/users', 'GET');
    users.value = d.users;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败（仅老板可管理）', icon: 'none' });
  }
}

function openForm(u?: User) {
  form.value = u
    ? { id: u.id, username: u.username, password: '', role: u.role }
    : { id: undefined, username: '', password: '', role: 'staff' };
  showForm.value = true;
}

async function save() {
  const username = form.value.username.trim();
  const password = form.value.password;
  if (!username) {
    uni.showToast({ title: '请填写登录名', icon: 'none' });
    return;
  }
  if (password && password.length < 6) {
    uni.showToast({ title: '密码至少 6 位', icon: 'none' });
    return;
  }
  if (!form.value.id && !password) {
    uni.showToast({ title: '新账号需填写密码', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    const body: Record<string, unknown> = { username, role: form.value.role };
    if (password) body.password = password;
    if (form.value.id) {
      await request(`/users/${form.value.id}`, 'PATCH', body);
    } else {
      await request('/users', 'POST', body);
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

function remove(u: User) {
  uni.showModal({
    title: '删除账号',
    content: `确定删除「${u.username}」吗？`,
    success: async (r) => {
      if (!r.confirm) return;
      try {
        await request(`/users/${u.id}`, 'DELETE');
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
.page {
  background:
      radial-gradient(circle at 18% 12%, var(--primary-soft) 0 6rpx, transparent 10rpx),
      radial-gradient(circle at 75% 20%, var(--primary-soft) 0 9rpx, transparent 14rpx),
      radial-gradient(circle at 35% 42%, var(--primary-soft) 0 5rpx, transparent 9rpx),
      radial-gradient(circle at 65% 58%, var(--primary-soft) 0 11rpx, transparent 16rpx),
      radial-gradient(circle at 20% 75%, var(--primary-soft) 0 7rpx, transparent 12rpx),
      linear-gradient(180deg, var(--primary-fade) 0%, #f5f7fa 34%);; min-height: 100vh; }
.btn-add { background: var(--primary); color: #fff; border-radius: 12rpx; margin-bottom: 20rpx; font-size: 30rpx; }
.card { background: var(--card-bg); border-radius: 12rpx; padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; align-items: center; }
.name { font-size: 30rpx; font-weight: bold; }
.role { margin-left: 16rpx; font-size: 24rpx; color: var(--primary); background: #ecf5ff; border-radius: 8rpx; padding: 4rpx 12rpx; }
.role.admin { color: #f56c6c; background: #fef0f0; }
.op { margin-left: auto; color: var(--primary); font-size: 26rpx; }
.del { margin-left: 32rpx; color: #f56c6c; font-size: 26rpx; }
.empty { color: #c0c4cc; text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: var(--card-bg); border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: var(--input-bg); border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.seg { display: flex; background: var(--input-bg); border-radius: 12rpx; margin-bottom: 20rpx; overflow: hidden; }
.seg-item { flex: 1; text-align: center; padding: 16rpx; font-size: 26rpx; color: var(--text-sub); }
.seg-item.active { color: var(--primary); font-weight: bold; background: #ecf5ff; }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; }
</style>