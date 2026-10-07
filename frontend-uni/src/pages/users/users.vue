<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <!-- 分段：账号设置 / 账号管理（对齐 App 成员页 TabBar 双 tab） -->
    <view class="seg-tab">
      <view :class="['seg-tab-item', { active: tab === 'account' }]" @click="tab = 'account'">账号设置</view>
      <view :class="['seg-tab-item', { active: tab === 'users' }]" @click="tab = 'users'">账号管理</view>
    </view>

    <!-- 账号设置（对齐 App 成员页「账号设置」tab 内联：点 tab 直接查看，不再多点一层入口） -->
    <view v-if="tab === 'account'">
      <view class="avatar-card" @click="changeAvatar">
        <image v-if="avatarUrl" class="avatar-img" :src="avatarUrl" mode="aspectFill" />
        <view v-else class="avatar-ph">{{ (name || '陶').slice(0, 1) }}</view>
        <view class="avatar-info">
          <text class="a-name">{{ name }}</text>
          <text class="a-sub">{{ roleText }} · {{ account }}</text>
        </view>
        <text class="a-arrow">›</text>
      </view>

      <view class="group-title">账号设置</view>
      <view class="grp">
        <view class="s-row" @click="changeAvatar">
          <view class="r-ic ic-blue"><text class="ic-tx">🖼️</text></view><view class="r-body"><text class="r-tx">头像</text><text class="r-sub">拍照 / 从相册选择更换</text></view><text class="r-arrow">›</text>
        </view>
        <view class="s-row" @click="changeUsername">
          <view class="r-ic ic-green"><text class="ic-tx">✏️</text></view><view class="r-body"><text class="r-tx">用户名</text><text class="r-sub">显示用名称，1-30 字</text></view><text class="r-arrow">›</text>
        </view>
        <view class="s-row" @click="changePassword">
          <view class="r-ic ic-orange"><text class="ic-tx">🔑</text></view><view class="r-body"><text class="r-tx">修改密码</text><text class="r-sub">验证旧密码，新密码至少 6 位</text></view><text class="r-arrow">›</text>
        </view>
        <view class="s-row" @click="toggleTotp">
          <view class="r-ic ic-purple"><text class="ic-tx">🛡️</text></view><view class="r-body"><text class="r-tx">两步验证（2FA）</text><text class="r-sub">{{ totpOn ? '已开启，点击关闭' : '验证器扫码/密钥开启' }}</text></view>
          <text class="state-tag" :class="totpOn ? 'on' : 'off'">{{ totpOn ? '已开启' : '未开启' }}</text>
        </view>
      </view>
    </view>

    <!-- 账号管理（对齐 App UsersPage embed：顶部管理头行 + 用户列表） -->
    <template v-else>
      <view class="manage-head">
        <text class="mh-tx">成员管理（仅老板可操作）</text>
        <text class="mh-add" @click="openForm()">+ 新增账号</text>
      </view>

      <view v-for="u in users" :key="u.id" class="card">
        <view class="row">
          <!-- 头像圆（首字母，对齐 App UserAvatar） -->
          <view class="u-avatar" :style="{ background: avatarBg(u) }">
            <text class="u-avatar-tx">{{ (u.display_name || u.username || '陶').slice(0, 1) }}</text>
          </view>
          <view class="head">
            <view class="head-top">
              <text class="name">{{ u.display_name || u.username }}</text>
              <text :class="['role', { admin: u.role === 'admin' }]">{{ u.role === 'admin' ? '老板' : '店员' }}</text>
            </view>
            <text class="sub">登录 {{ u.username }}</text>
          </view>
          <view class="head-ops">
            <text class="op" @click="openForm(u)">编辑</text>
            <text class="del" @click="remove(u)">删除</text>
          </view>
        </view>
      </view>
      <view v-if="users.length === 0" class="empty">暂无账号</view>
    </template>

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
const { tv, patternSrc } = useThemeVars();
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken, getApiBase, getRole } from '../../api';

interface User { id: string; username: string; role: string; display_name?: string }

const users = ref<User[]>([]);
const showForm = ref(false);
const saving = ref(false);
// 页面分段：账号设置 / 账号管理（对齐 App 成员页双 Tab；默认账号管理=用户常看的列表）
const tab = ref<'account' | 'users'>('users');
const form = ref<{ id?: string; username: string; password: string; role: string }>({
  id: undefined, username: '', password: '', role: 'staff',
});

// 账号设置内联（对齐 App AccountSettingsPage embed：头像/用户名/密码/两步验证 4 行，点 tab 直接查看）
const name = ref('');
const account = ref('');
const roleText = ref('老板');
const totpOn = ref(false);
const avatarUrl = ref('');

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  roleText.value = getRole() === 'staff' ? '店员' : '老板';
  await Promise.all([load(), loadProfile()]);
});

async function loadProfile() {
  try {
    const d = await request<{ user?: { username?: string; display_name?: string; role?: string; avatar?: string | null; totp_enabled?: number } }>('/auth/me', 'GET');
    const u = d.user;
    if (!u) return;
    account.value = u.username || '';
    name.value = u.display_name || u.username || '';
    roleText.value = u.role === 'staff' ? '店员' : '老板';
    totpOn.value = (u.totp_enabled || 0) === 1;
    avatarUrl.value = u.avatar ? `${getApiBase()}/api/v1/auth/avatar?token=${getToken()}` : '';
  } catch (e) {
    // 拉取失败保留旧值
  }
}

/// 更换头像：选图上传 /auth/avatar（multipart photo + header token），刷新显示
function changeAvatar() {
  uni.showActionSheet({
    itemList: ['拍照', '从相册选择'],
    success: (r) => {
      const sourceType = r.tapIndex === 0 ? ['camera'] : ['album'];
      uni.chooseImage({
        count: 1,
        sizeType: ['compressed'],
        sourceType,
        success: (res) => {
          const file = res.tempFilePaths[0];
          if (!file) return;
          uni.showLoading({ title: '上传中' });
          uni.uploadFile({
            url: `${getApiBase()}/api/v1/auth/avatar`,
            filePath: file,
            name: 'photo',
            header: { Authorization: `Bearer ${getToken()}` },
            success: () => {
              uni.hideLoading();
              uni.showToast({ title: '头像已更新', icon: 'success' });
              avatarUrl.value = `${getApiBase()}/api/v1/auth/avatar?token=${getToken()}&v=${Date.now()}`;
            },
            fail: () => {
              uni.hideLoading();
              uni.showToast({ title: '上传失败', icon: 'none' });
            },
          });
        },
      });
    },
  });
}

/// 修改显示名：弹窗输入 → PATCH /auth/profile
function changeUsername() {
  uni.showModal({
    title: '修改用户名',
    editable: true,
    placeholderText: '用户名（显示用，1-30 字）',
    content: name.value,
    success: async (r) => {
      if (!r.confirm) return;
      const v = (r.content || '').trim();
      if (!v || v.length > 30) {
        uni.showToast({ title: '用户名长度需在 1-30 个字符', icon: 'none' });
        return;
      }
      try {
        await request('/auth/profile', 'PATCH', { display_name: v });
        name.value = v;
        uni.showToast({ title: '用户名已修改', icon: 'success' });
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '修改失败', icon: 'none' });
      }
    },
  });
}

/// 修改密码：旧密码 + 新密码 → PATCH /auth/profile
function changePassword() {
  let oldPw = '';
  let newPw = '';
  uni.showModal({
    title: '修改密码',
    editable: true,
    placeholderText: '当前密码',
    success: (r1) => {
      if (!r1.confirm) return;
      oldPw = (r1.content || '').trim();
      uni.showModal({
        title: '新密码（至少 6 位）',
        editable: true,
        placeholderText: '新密码',
        success: async (r2) => {
          if (!r2.confirm) return;
          newPw = (r2.content || '').trim();
          if (newPw.length < 6) {
            uni.showToast({ title: '新密码至少 6 位', icon: 'none' });
            return;
          }
          try {
            await request('/auth/profile', 'PATCH', { old_password: oldPw, password: newPw });
            uni.showToast({ title: '密码已修改', icon: 'success' });
          } catch (e) {
            uni.showToast({ title: (e as Error).message || '修改失败', icon: 'none' });
          }
        },
      });
    },
  });
}

/// 开启/关闭两步验证：setup 取密钥 → confirm 验证码开启；disable 验证码关闭
async function toggleTotp() {
  if (!totpOn.value) {
    try {
      const d = await request<{ secret: string; otpauth: string }>('/auth/totp/setup', 'GET');
      uni.showModal({
        title: '开启两步验证',
        editable: true,
        placeholderText: '输入验证器里的 6 位验证码',
        content: `密钥：${d.secret}\n\n用验证器 App 扫码或用密钥添加：\n${d.otpauth}`,
        confirmText: '开启',
        success: async (r) => {
          if (!r.confirm) return;
          const code = (r.content || '').trim();
          try {
            await request('/auth/totp/confirm', 'POST', { code });
            totpOn.value = true;
            uni.showToast({ title: '两步验证已开启', icon: 'success' });
          } catch (e) {
            uni.showToast({ title: (e as Error).message || '开启失败', icon: 'none' });
          }
        },
      });
    } catch (e) {
      uni.showToast({ title: (e as Error).message || '获取密钥失败', icon: 'none' });
    }
  } else {
    uni.showModal({
      title: '关闭两步验证',
      editable: true,
      placeholderText: '输入验证器里的 6 位验证码',
      confirmText: '关闭',
      success: async (r) => {
        if (!r.confirm) return;
        try {
          await request('/auth/totp/disable', 'POST', { code: (r.content || '').trim() });
          totpOn.value = false;
          uni.showToast({ title: '两步验证已关闭', icon: 'success' });
        } catch (e) {
          uni.showToast({ title: (e as Error).message || '关闭失败', icon: 'none' });
        }
      },
    });
  }
}

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

/// 头像底色（按名字确定性取色，对齐 App UserAvatar 的色板风格）
function avatarBg(u: User): string {
  const palettes = ['#409EFF', '#67C23A', '#E6A23C', '#F56C6C', '#909399', '#9C27B0'];
  let hash = 0;
  const s = u.display_name || u.username || '陶';
  for (let i = 0; i < s.length; i++) hash = (hash * 31 + s.charCodeAt(i)) >>> 0;
  return palettes[hash % palettes.length];
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
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh;  background: var(--page-bg); }
.page { min-height: 100vh;  background: var(--page-bg); padding-top: 24rpx; box-sizing: border-box; }
.seg-tab { display: flex; background: var(--card-bg); border: var(--card-border); border-radius: 12rpx; margin-bottom: 20rpx; overflow: hidden; }
.seg-tab-item { flex: 1; text-align: center; padding: 20rpx; font-size: 28rpx; color: var(--text-sub); }
.seg-tab-item.active { color: var(--primary); font-weight: bold; background: var(--primary-soft); }
.manage-head { display: flex; align-items: center; justify-content: space-between; margin: 4rpx 8rpx 16rpx; }
.mh-tx { font-size: 24rpx; color: var(--text-sub); }
.mh-add { font-size: 28rpx; color: var(--primary); font-weight: 600; }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 24rpx; margin-bottom: 16rpx; }
.row { display: flex; align-items: center; }
.u-avatar { width: 72rpx; height: 72rpx; border-radius: 50%; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.u-avatar-tx { color: #fff; font-size: 32rpx; font-weight: bold; }
.head { flex: 1; min-width: 0; margin-left: 20rpx; display: flex; flex-direction: column; gap: 4rpx; }
.head-top { display: flex; align-items: center; }
.name { font-size: 30rpx; font-weight: bold; }
.role { margin-left: 12rpx; font-size: 22rpx; color: var(--primary); background: var(--primary-soft); border-radius: 8rpx; padding: 2rpx 12rpx; }
.role.admin { color: #f56c6c; background: var(--danger-bg); }
.sub { font-size: 23rpx; color: var(--text-sub); }
.head-ops { display: flex; align-items: center; margin-left: 8rpx; flex-shrink: 0; }
.op { color: var(--primary); font-size: 26rpx; }
.del { margin-left: 28rpx; color: #f56c6c; font-size: 26rpx; }
.empty { color: var(--text-sub); text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: var(--sheet-bg); border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.seg { display: flex; background: var(--input-bg); border-radius: 12rpx; margin-bottom: 20rpx; overflow: hidden; }
.seg-item { flex: 1; text-align: center; padding: 16rpx; font-size: 26rpx; color: var(--text-sub); }
.seg-item.active { color: var(--primary); font-weight: bold; background: var(--primary-soft); }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; }

/* 账号设置 tab 内联样式（迁自 account.vue；s-row 避开列表卡 .row） */
.avatar-card { display: flex; align-items: center; gap: 24rpx; background: transparent; border: var(--card-border); border-radius: 32rpx; padding: 28rpx 24rpx; margin-bottom: 24rpx; }
.avatar-img { width: 120rpx; height: 120rpx; border-radius: 50%; flex-shrink: 0; }
.avatar-ph { width: 120rpx; height: 120rpx; border-radius: 50%; background: var(--primary-soft); color: var(--primary); font-size: 56rpx; font-weight: bold; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.avatar-info { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 6rpx; }
.a-name { font-size: 32rpx; font-weight: bold; color: var(--text-main); }
.a-sub { font-size: 24rpx; color: var(--text-sub); }
.a-arrow { font-size: 36rpx; color: var(--text-sub); }
.group-title { font-size: 26rpx; font-weight: 600; color: var(--text-sub); margin: 8rpx 8rpx 16rpx; }
.grp { background: var(--card-bg); border: var(--card-border); border-radius: 32rpx; margin-bottom: 24rpx; overflow: hidden; }
.s-row { display: flex; align-items: center; padding: 24rpx; border-bottom: 1rpx solid var(--divider); }
.s-row:last-child { border-bottom: none; }
.r-ic { width: 64rpx; height: 64rpx; border-radius: 20rpx; margin-right: 24rpx; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.ic-blue { background: var(--primary-soft); } .ic-green { background: var(--ok-bg); }
.ic-orange { background: var(--warn-bg); } .ic-purple { background: var(--violet-bg); }
.ic-tx { font-size: 32rpx; line-height: 1; }
.r-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4rpx; }
.r-tx { font-size: 30rpx; color: var(--text-main); }
.r-sub { font-size: 24rpx; color: var(--text-sub); }
.r-arrow { font-size: 36rpx; color: var(--text-sub); }
.state-tag { font-size: 22rpx; border-radius: 8rpx; padding: 4rpx 14rpx; }
.state-tag.on { color: #22c55e; background: var(--ok-bg); }
.state-tag.off { color: var(--text-sub); background: var(--input-bg); }
</style>