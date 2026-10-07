<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <!-- 头像：点击更换（对齐 App 账号设置页） -->
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
      <view class="row" @click="changeAvatar">
        <view class="r-ic ic-blue"><text class="mi ic-tx">&#xe853;</text></view><view class="r-body"><text class="r-tx">头像</text><text class="r-sub">拍照 / 从相册选择更换</text></view><text class="r-arrow">›</text>
      </view>
      <view class="row" @click="changeUsername">
        <view class="r-ic ic-blue"><text class="mi ic-tx">&#xe3c9;</text></view><view class="r-body"><text class="r-tx">用户名</text><text class="r-sub">显示用名称，1-30 字</text></view><text class="r-arrow">›</text>
      </view>
      <view class="row" @click="changePassword">
        <view class="r-ic ic-blue"><text class="mi ic-tx">&#xe899;</text></view><view class="r-body"><text class="r-tx">修改密码</text><text class="r-sub">验证旧密码，新密码至少 6 位</text></view><text class="r-arrow">›</text>
      </view>
      <view class="row" @click="toggleTotp">
        <view class="r-ic ic-blue"><text class="mi ic-tx">&#xe832;</text></view><view class="r-body"><text class="r-tx">两步验证（2FA）</text><text class="r-sub">{{ totpOn ? '已开启，点击关闭' : '验证器扫码/密钥开启' }}</text></view>
        <text class="state-tag" :class="totpOn ? 'on' : 'off'">{{ totpOn ? '已开启' : '未开启' }}</text>
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
  await loadProfile();
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
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh; padding: 24rpx 24rpx 60rpx; box-sizing: border-box; background: var(--page-bg); }
.avatar-card { display: flex; align-items: center; gap: 24rpx; background: transparent; border: var(--card-border); border-radius: 32rpx; padding: 28rpx 24rpx; margin-bottom: 24rpx; }
.avatar-img { width: 120rpx; height: 120rpx; border-radius: 50%; flex-shrink: 0; }
.avatar-ph { width: 120rpx; height: 120rpx; border-radius: 50%; background: var(--primary-soft); color: var(--primary); font-size: 56rpx; font-weight: bold; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.avatar-info { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 6rpx; }
.a-name { font-size: 32rpx; font-weight: bold; color: var(--text-main); }
.a-sub { font-size: 24rpx; color: var(--text-sub); }
.a-arrow { font-size: 36rpx; color: var(--text-sub); }
.group-title { font-size: 26rpx; font-weight: 600; color: var(--text-sub); margin: 8rpx 8rpx 16rpx; }
.grp { background: var(--card-bg); border: var(--card-border); border-radius: 32rpx; margin-bottom: 24rpx; overflow: hidden; }
.row { display: flex; align-items: center; padding: 24rpx; border-bottom: 1rpx solid var(--divider); }
.row:last-child { border-bottom: none; }
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
