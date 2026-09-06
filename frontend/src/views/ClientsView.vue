<template>
  <div v-loading="loading">
    <div class="toolbar">
      <el-input v-model="query" placeholder="搜索饭店" clearable class="q" @keyup.enter="load" />
      <el-button v-if="auth.isAdmin" type="primary" @click="openCreate">新增饭店</el-button>
    </div>
    <el-table :data="clients" border stripe>
      <el-table-column prop="name" label="饭店" min-width="140" />
      <el-table-column prop="contact" label="联系人" width="100" />
      <el-table-column prop="phone" label="电话" width="130" />
      <el-table-column prop="sales_total" label="累计出货" align="right" width="100">
        <template #default="{ row }">¥{{ fmt(row.sales_total) }}</template>
      </el-table-column>
      <el-table-column prop="paid_total" label="累计收款" align="right" width="100">
        <template #default="{ row }">¥{{ fmt(row.paid_total) }}</template>
      </el-table-column>
      <el-table-column prop="debt" label="欠款" align="right" width="100">
        <template #default="{ row }"><span class="red">¥{{ fmt(row.debt) }}</span></template>
      </el-table-column>
      <el-table-column v-if="auth.isAdmin" label="操作" width="140" align="right">
        <template #default="{ row }">
          <el-button size="small" type="primary" link @click="openEdit(row)">编辑</el-button>
          <el-popconfirm title="删除该饭店？(历史账目保留)" @confirm="remove(row.id)">
            <template #reference><el-button size="small" type="danger" link>删除</el-button></template>
          </el-popconfirm>
        </template>
      </el-table-column>
    </el-table>

    <el-dialog v-model="dialog" :title="editing ? '编辑饭店' : '新增饭店'" width="440px">
      <el-form label-width="70px">
        <el-form-item label="名称"><el-input v-model="form.name" placeholder="饭店名（必填）" /></el-form-item>
        <el-form-item label="联系人"><el-input v-model="form.contact" /></el-form-item>
        <el-form-item label="电话"><el-input v-model="form.phone" /></el-form-item>
        <el-form-item label="备注"><el-input v-model="form.note" type="textarea" :rows="2" /></el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="dialog = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="save">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue';
import { ElMessage } from 'element-plus';
import { api, errMsg } from '../api';
import { useAuthStore } from '../stores/auth';

const auth = useAuthStore();

interface ClientRow {
  id: string; name: string; contact: string; phone: string; note: string;
  sales_total: number; paid_total: number; debt: number;
}

const loading = ref(false);
const saving = ref(false);
const query = ref('');
const clients = ref<ClientRow[]>([]);
const dialog = ref(false);
const editing = ref(false);
const editingId = ref('');
const form = reactive({ name: '', contact: '', phone: '', note: '' });
const fmt = (n: number) => Number(n || 0).toFixed(2);

async function load() {
  loading.value = true;
  try {
    const { data } = await api.get('/clients', { params: { q: query.value || undefined } });
    clients.value = data.clients;
  } finally {
    loading.value = false;
  }
}
onMounted(load);

function openCreate() {
  editing.value = false;
  editingId.value = '';
  Object.assign(form, { name: '', contact: '', phone: '', note: '' });
  dialog.value = true;
}

function openEdit(row: ClientRow) {
  editing.value = true;
  editingId.value = row.id;
  Object.assign(form, { name: row.name, contact: row.contact, phone: row.phone, note: row.note });
  dialog.value = true;
}

async function save() {
  if (!form.name.trim()) return ElMessage.warning('请填写名称');
  saving.value = true;
  try {
    if (editing.value) await api.patch(`/clients/${editingId.value}`, form);
    else await api.post('/clients', form);
    ElMessage.success('已保存');
    dialog.value = false;
    load();
  } catch (e) {
    ElMessage.error(errMsg(e));
  } finally {
    saving.value = false;
  }
}

async function remove(id: string) {
  try {
    await api.delete(`/clients/${id}`);
    ElMessage.success('已删除');
    load();
  } catch (e) {
    ElMessage.error(errMsg(e));
  }
}
</script>

<style scoped>
.toolbar { display: flex; gap: 12px; margin-bottom: 12px; }
.q { width: 220px; }
.red { color: #f56c6c; }
</style>