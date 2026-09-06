<template>
  <div class="login-page">
    <el-card class="login-card">
      <h2 class="title">{{ APP_NAME }} <span class="ver">v{{ APP_VERSION }}</span></h2>
      <el-alert v-if="!initialized" type="warning" :closable="false" class="mb" title="首次使用：请先创建老板账号" show-icon />
      <el-form label-position="top" @submit.prevent="submit">
        <el-form-item label="服务器地址（留空 = 当前网页地址，App 请填服务器域名）">
          <el-input v-model="serverUrl" placeholder="如 https://xxx.workers.dev" />
        </el-form-item>
        <el-form-item label="登录名">
          <el-input v-model="form.username" placeholder="登录名" autocomplete="username" />
        </el-form-item>
        <el-form-item label="密码">
          <el-input v-model="form.password" type="password" placeholder="密码" show-password autocomplete="current-password" @keyup.enter="submit" />
        </el-form-item>
        <el-button type="primary" class="w-full" :loading="loading" native-type="submit">
          {{ initialized ? '登录' : '创建账号并登录' }}
        </el-button>
      </el-form>
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue';
import { ElMessage } from 'element-plus';
import { useRouter } from 'vue-router';
import { useAuthStore } from '../stores/auth';
import { errMsg, getApiBase, setApiBase } from '../api';
import { APP_NAME, APP_VERSION } from '../version';

const auth = useAuthStore();
const router = useRouter();
const initialized = ref(true);
const loading = ref(false);
const form = reactive({ username: '', password: '' });
const serverUrl = ref(getApiBase());

onMounted(async () => {
  try {
    initialized.value = await auth.initStatus();
  } catch {
    initialized.value = true;
  }
});

async function submit() {
  if (!form.username.trim() || !form.password) {
    ElMessage.warning('请输入登录名和密码');
    return;
  }
  // 登录前应用服务器地址（App/自托管各端可手动指定）
  setApiBase(serverUrl.value);
  loading.value = true;
  try {
    if (initialized.value) await auth.login(form.username.trim(), form.password);
    else await auth.bootstrap(form.username.trim(), form.password);
    router.push('/');
  } catch (e) {
    ElMessage.error(errMsg(e));
  } finally {
    loading.value = false;
  }
}
</script>

<style scoped>
.login-page {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #f5f7fa;
}
.login-card {
  width: 360px;
}
.title {
  text-align: center;
  margin: 0 0 16px;
}
.ver {
  font-size: 12px;
  color: #909399;
  font-weight: normal;
}
.w-full {
  width: 100%;
}
.mb {
  margin-bottom: 12px;
}
</style>