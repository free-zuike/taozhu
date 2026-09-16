<template>
  <view class="page">
    <view class="brand">陶朱<text class="ver"> v{{ APP_VERSION }}</text></view>

    <view class="form">
      <input class="ipt" v-model="baseUrl" placeholder="服务器地址（留空=当前网页；App/小程序填 https://xxx.workers.dev）" />
      <input class="ipt" v-model="username" placeholder="登录名" />
      <input class="ipt" v-model="password" type="password" placeholder="密码" />
      <input v-if="needTotp" class="ipt" v-model="code" type="number" placeholder="两步验证码（验证器 6 位数字）" />
      <button class="btn" :disabled="loading" @click="submit">{{ loading ? '登录中…' : (initialized ? '登录' : '创建账号并登录') }}</button>
      <view v-if="!initialized" class="tip">首次使用：以上为老板账号，创建后即可登录</view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onLoad } from '@dcloudio/uni-app';
import { request, getApiBase, setApiBase, setToken, setRole, getToken } from '../../api';
import { APP_VERSION } from '../../version';

const baseUrl = ref(getApiBase());
const username = ref('');
const password = ref('');
const code = ref('');
const loading = ref(false);
const initialized = ref(true);
const needTotp = ref(false); // 该账号已开启两步验证，等待输入验证码

onLoad(async () => {
  // 已有 token：直接进入交易 tab（对齐 App 首项即交易页）；失效由 api 401 统一踢回登录页
  if (getToken()) {
    uni.switchTab({ url: '/pages/ledger/ledger' });
    return;
  }
  try {
    const s = await request<{ initialized: boolean }>('/auth/bootstrap/status', 'GET');
    initialized.value = s.initialized;
  } catch {
    initialized.value = true;
  }
});

async function submit() {
  if (!username.value.trim() || !password.value) {
    uni.showToast({ title: '请输入登录名和密码', icon: 'none' });
    return;
  }
  if (needTotp.value && !code.value.trim()) {
    uni.showToast({ title: '请输入两步验证码', icon: 'none' });
    return;
  }
  setApiBase(baseUrl.value);
  loading.value = true;
  try {
    const body: Record<string, unknown> = { username: username.value.trim(), password: password.value };
    if (needTotp.value) body.code = code.value.trim();
    if (initialized.value) {
      const d = await request<{ token: string; need_totp?: boolean; user?: { role?: string } }>('/auth/login', 'POST', body);
      // 两步验证：密码正确但缺少/错误验证码 → need_totp 让用户补输入（参照 App 端流程）
      if ((d as { need_totp?: boolean }).need_totp) {
        needTotp.value = true;
        uni.showToast({ title: '该账号已开启两步验证，请输入验证码', icon: 'none' });
        return;
      }
      setToken((d as { token: string }).token);
      setRole((d.user?.role as string) || '');
      uni.setStorageSync('taozhu_username', username.value.trim());
    } else {
      const d = await request<{ token: string; user?: { role?: string } }>('/auth/bootstrap', 'POST', body);
      setToken(d.token);
      setRole((d.user?.role as string) || '');
      uni.setStorageSync('taozhu_username', username.value.trim());
    }
    // 对齐 App 底部导航：登录后进「交易」tab（App 首项即交易页）
    uni.switchTab({ url: '/pages/ledger/ledger' });
  } catch (e) {
    const msg = (e as Error).message || '登录失败';
    uni.showToast({ title: msg, icon: 'none' });
  } finally {
    loading.value = false;
  }
}
</script>

<style>
.page {
  min-height: 100vh;
  background: #f5f7fa;
  display: flex;
  flex-direction: column;
  align-items: center;
  padding-top: 120rpx;
}
.brand {
  font-size: 48rpx;
  font-weight: bold;
  margin-bottom: 60rpx;
}
.ver {
  font-size: 24rpx;
  color: #909399;
  font-weight: normal;
}
.form {
  width: 600rpx;
}
.ipt {
  background: #fff;
  border-radius: 12rpx;
  padding: 20rpx 24rpx;
  margin-bottom: 24rpx;
  font-size: 28rpx;
}
.btn {
  margin-top: 12rpx;
  background: #409eff;
  color: #fff;
  border-radius: 12rpx;
  font-size: 32rpx;
}
.tip {
  display: block;
  margin-top: 20rpx;
  color: #e6a23c;
  font-size: 24rpx;
}
</style>