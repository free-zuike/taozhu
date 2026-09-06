<template>
  <view class="page">
    <view class="brand">陶朱<text class="ver"> v{{ APP_VERSION }}</text></view>

    <view class="form">
      <input class="ipt" v-model="baseUrl" placeholder="服务器地址（留空=当前网页；App/小程序填 https://xxx.workers.dev）" />
      <input class="ipt" v-model="username" placeholder="登录名" />
      <input class="ipt" v-model="password" type="password" placeholder="密码" />
      <button class="btn" :disabled="loading" @click="submit">{{ loading ? '登录中…' : (initialized ? '登录' : '创建账号并登录') }}</button>
      <view v-if="!initialized" class="tip">首次使用：以上为老板账号，创建后即可登录</view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onLoad } from '@dcloudio/uni-app';
import { request, getApiBase, setApiBase, setToken } from '../../api';

const APP_VERSION = '0.1.0.0';

const baseUrl = ref(getApiBase());
const username = ref('');
const password = ref('');
const loading = ref(false);
const initialized = ref(true);

onLoad(async () => {
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
  setApiBase(baseUrl.value);
  loading.value = true;
  try {
    if (initialized.value) {
      const d = await request<{ token: string }>('/auth/login', 'POST', { username: username.value.trim(), password: password.value });
      setToken(d.token);
    } else {
      const d = await request<{ token: string }>('/auth/bootstrap', 'POST', { username: username.value.trim(), password: password.value });
      setToken(d.token);
    }
    uni.switchTab({ url: '/pages/dashboard/dashboard' });
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