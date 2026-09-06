<template>
  <div v-loading="loading">
    <div class="toolbar">
      <el-button type="primary" @click="openCreate">新增账号</el-button>
    </div>
    <el-table :data="users" border stripe>
      <el-table-column prop="username" label="登录名" min-width="140" />
      <el-table-column prop="role" label="角色" width="90">
        <template #default="{ row }">
          <el-tag :type="row.role === 'admin' ? 'danger' : 'info'">{{ row.role === 'admin' ? '老板' : '店员' }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="created_at" label="创建时间" width="180" />
      <el-table-column label="操作" width="200" align="right">
        <template #default="{ row }">
          <el-button size="small" type="primary" link @click="openEdit(row)">改密码/角色</el-button>
          <el-popconfirm v-if="row.id !== me?.id" title="删除该账号？" @confirm="remove(row.id)">
            <template #reference><el-button size="small" type="danger" link>删除</el-button></template>
          </el-popconfirm>
        </template>
      </el-table-column>
    </el-table>

    <el-dialog v-model="dialog" :title="editing ? '修改账号' : '新增账号'" width="400px">
      <el-form label-width="80px">
        <el-form-item label="登录名"><el-input v-model="form.username" :disabled="editing" /></el-form-item>
        <el-form-item :label="editing ? '新密码' : '密码'">
          <el-input v-model="form.password" type="password" show-password :placeholder="editing ? '留空则不修改' : '至少 6 位'" />
        </el-form-item>
        <el-form-item label="角色">
          <el-select v-model="form.role" style="width: 100%">
            <el-option label="店员（记单/查看）" value="staff" />
            <el-option label="老板（全部权限）" value="admin" />
          </el-select>
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="dialog = false">取消</el-button>
        <el-button type="primary" :loading="saving" @click="save">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue';
import { ElMessage } from 'element-plus';
import { api, errMsg } from '../api';
import { useAuthStore } from '../stores/auth';

const auth = useAuthStore();
const me = computed(() => auth.user);
const loading = ref(false);
const saving = ref(false);
const users = ref<Array<{ id: string; username: string; role: 'admin' | 'staff'; created_at: string }>>([]);
const dialog = ref(false);
const editing = ref(false);
const editingId = ref('');
const form = reactive({ username: '', password: '', role: 'staff' as 'admin' | 'staff' });

async function load() {
  loading.value = true;
  try {
    const { data } = await api.get('/users');
    users.value = data.users;
  } finally {
    loading.value = false;
  }
}
onMounted(load);

function openCreate() {
  editing.value = false;
  editingId.value = '';
  Object.assign(form, { username: '', password: '', role: 'staff' });
  dialog.value = true;
}

function openEdit(row: { id: string; username: string; role: 'admin' | 'staff' }) {
  editing.value = true;
  editingId.value = row.id;
  Object.assign(form, { username: row.username, password: '', role: row.role });
  dialog.value = true;
}

async function save() {
  if (!form.username.trim()) return ElMessage.warning('请填写登录名');
  if (!editing.value && form.password.length < 6) return ElMessage.warning('密码至少 6 位');
  saving.value = true;
  try {
    const payload: Record<string, string> = { username: form.username.trim(), role: form.role };
    if (form.password) payload.password = form.password;
    if (editing.value) await api.patch(`/users/${editingId.value}`, payload);
    else await api.post('/users', payload);
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
    await api.delete(`/users/${id}`);
    ElMessage.success('已删除');
    load();
  } catch (e) {
    ElMessage.error(errMsg(e));
  }
}
</script>

<style scoped>
.toolbar { margin-bottom: 12px; }
</style>