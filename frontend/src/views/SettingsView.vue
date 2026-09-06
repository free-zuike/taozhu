<template>
  <div v-loading="loading">
    <el-card shadow="never">
      <template #header>AI 拍照识别（OpenAI 兼容，配置由您完全自定）</template>
      <el-form label-width="130px" style="max-width: 640px">
        <el-form-item label="API 地址">
          <el-input v-model="baseUrl" placeholder="如 https://open.bigmodel.cn/api/paas/v4" />
        </el-form-item>
        <el-form-item label="API Key">
          <el-input v-model="apiKey" type="password" show-password placeholder="智谱开放平台创建" />
        </el-form-item>
        <el-form-item label="模型名">
          <el-input v-model="model" placeholder="如 glm-4v-flash（免费视觉模型）" />
        </el-form-item>
        <el-form-item>
          <el-button type="primary" :loading="saving" @click="save">保存</el-button>
          <el-tag v-if="hasKey" type="success" effect="plain" class="ml">已配置（当前：{{ model }}）</el-tag>
          <el-tag v-else type="info" effect="plain" class="ml">未配置（记单页拍照识别暂不可用）</el-tag>
        </el-form-item>
        <el-form-item>
          <div class="tip">
            <p>· 默认指向智谱（免费模型 glm-4v-flash，拍照识别不收费）；也支持任意 OpenAI 兼容接口，改地址+模型即可。</p>
            <p>· 保存后，出货/进货记单页的「📷 拍照识别」即可使用：拍小票/价签 → 自动识别商品清单。</p>
            <p>· 配置仅保存在本系统数据库，仅老板账号可查看与修改，Key 不回显明文。</p>
          </div>
        </el-form-item>
      </el-form>
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { onMounted, ref } from 'vue';
import { ElMessage } from 'element-plus';
import { api, errMsg } from '../api';

const loading = ref(false);
const saving = ref(false);
const hasKey = ref(false);
const baseUrl = ref('');
const apiKey = ref('');
const model = ref('');

async function load() {
  loading.value = true;
  try {
    const { data } = await api.get('/settings/ai');
    hasKey.value = data.has_key;
    baseUrl.value = data.base_url;
    model.value = data.model;
  } finally {
    loading.value = false;
  }
}
onMounted(load);

async function save() {
  saving.value = true;
  try {
    await api.put('/settings/ai', { api_key: apiKey.value.trim(), base_url: baseUrl.value.trim(), model: model.value.trim() });
    ElMessage.success('已保存');
    apiKey.value = '';
    load();
  } catch (e) {
    ElMessage.error(errMsg(e));
  } finally {
    saving.value = false;
  }
}
</script>

<style scoped>
.ml { margin-left: 8px; }
.tip { color: #909399; font-size: 13px; line-height: 1.8; }
</style>