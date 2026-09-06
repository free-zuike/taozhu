<template>
  <div v-loading="loading">
    <el-card shadow="never">
      <template #header>AI 拍照识别</template>
      <el-form label-width="120px" style="max-width: 560px">
        <el-form-item label="智谱 API Key">
          <el-input
            v-model="zhipuKey"
            type="password"
            show-password
            placeholder="open.bigmodel.cn 创建（免费模型 glm-4v-flash）"
          />
        </el-form-item>
        <el-form-item>
          <el-button type="primary" :loading="saving" @click="save">保存</el-button>
          <el-tag v-if="hasKey" type="success" effect="plain" class="ml">已配置</el-tag>
          <el-tag v-else type="info" effect="plain" class="ml">未配置（记单页拍照识别暂不可用）</el-tag>
        </el-form-item>
        <el-form-item>
          <div class="tip">
            <p>· 在智谱开放平台（open.bigmodel.cn）创建 API Key，免费模型「glm-4v-flash」拍照识别不收费。</p>
            <p>· 保存后，出货/进货记单页的「📷 拍照识别」即可使用：拍小票/价签 → 自动识别商品清单。</p>
            <p>· Key 仅保存在本系统数据库中，仅老板账号可查看与修改。</p>
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
const zhipuKey = ref('');

async function load() {
  loading.value = true;
  try {
    const { data } = await api.get('/settings/ai');
    hasKey.value = data.has_zhipu_key;
  } finally {
    loading.value = false;
  }
}
onMounted(load);

async function save() {
  saving.value = true;
  try {
    await api.put('/settings/ai', { zhipu_api_key: zhipuKey.value.trim() });
    hasKey.value = Boolean(zhipuKey.value.trim());
    zhipuKey.value = '';
    ElMessage.success(hasKey.value ? '已保存，拍照识别可用了' : '已清除配置');
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