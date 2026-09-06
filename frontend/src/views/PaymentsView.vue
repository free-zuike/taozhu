<template>
  <div v-loading="loading">
    <el-card shadow="never" class="mb">
      <el-form inline>
        <el-form-item label="饭店">
          <el-select v-model="form.client_id" filterable placeholder="选择饭店" style="width: 200px">
            <el-option v-for="c in clients" :key="c.id" :label="`${c.name}（欠 ¥${fmt(c.debt)}）`" :value="c.id" />
          </el-select>
        </el-form-item>
        <el-form-item label="日期"><el-date-picker v-model="form.happened_at" type="date" value-format="YYYY-MM-DD" /></el-form-item>
        <el-form-item label="金额"><el-input-number v-model="form.amount" :min="0" :precision="2" :controls="false" placeholder="收款金额" style="width: 140px" /></el-form-item>
        <el-form-item label="方式"><el-input v-model="form.method" placeholder="现金/微信…" style="width: 110px" /></el-form-item>
        <el-button v-if="auth.isAdmin" type="primary" :loading="saving" @click="submit">登记收款</el-button>
      </el-form>
    </el-card>

    <el-card shadow="never">
      <template #header>收款历史（近 100 条）</template>
      <el-table :data="payments" border stripe size="small">
        <el-table-column prop="happened_at" label="日期" width="110" />
        <el-table-column prop="client_name" label="饭店" min-width="130" />
        <el-table-column prop="amount" label="金额" align="right" width="100">
          <template #default="{ row }"><span class="green">¥{{ fmt(row.amount) }}</span></template>
        </el-table-column>
        <el-table-column prop="method" label="方式" width="90" />
        <el-table-column prop="note" label="备注" min-width="120" />
        <el-table-column v-if="auth.isAdmin" label="操作" width="70" align="right">
          <template #default="{ row }">
            <el-popconfirm title="撤销这笔收款？" @confirm="remove(row.id)">
              <template #reference><el-button size="small" type="danger" link>撤销</el-button></template>
            </el-popconfirm>
          </template>
        </el-table-column>
      </el-table>
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue';
import { ElMessage } from 'element-plus';
import { api, errMsg } from '../api';
import { todayLocal } from '../utils';
import { useAuthStore } from '../stores/auth';

const auth = useAuthStore();
const loading = ref(false);
const saving = ref(false);
const clients = ref<Array<{ id: string; name: string; debt: number }>>([]);
const payments = ref<Array<{ id: string; client_name: string; happened_at: string; amount: number; method: string; note: string }>>([]);
const form = reactive({ client_id: '', happened_at: todayLocal(), amount: 0, method: '微信', note: '' });
const fmt = (n: number) => Number(n || 0).toFixed(2);

async function load() {
  loading.value = true;
  try {
    const [c, p] = await Promise.all([api.get('/clients'), api.get('/payments')]);
    clients.value = c.data.clients;
    payments.value = p.data.payments.slice(0, 100);
  } finally {
    loading.value = false;
  }
}
onMounted(load);

async function submit() {
  if (!form.client_id) return ElMessage.warning('请选择饭店');
  if (!(form.amount > 0)) return ElMessage.warning('请输入收款金额');
  saving.value = true;
  try {
    await api.post('/payments', { ...form, note: form.note.trim() });
    ElMessage.success('收款已登记');
    form.amount = 0;
    form.note = '';
    load();
  } catch (e) {
    ElMessage.error(errMsg(e));
  } finally {
    saving.value = false;
  }
}

async function remove(id: string) {
  try {
    await api.delete(`/payments/${id}`);
    ElMessage.success('已撤销');
    load();
  } catch (e) {
    ElMessage.error(errMsg(e));
  }
}
</script>

<style scoped>
.mb { margin-bottom: 16px; }
.green { color: #67c23a; }
</style>