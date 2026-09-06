<template>
  <div v-loading="loading">
    <div class="toolbar">
      <el-input v-model="query" placeholder="搜索商品名" clearable class="q" @keyup.enter="load" />
      <el-button v-if="auth.isAdmin" type="primary" @click="openCreate">新增商品</el-button>
    </div>
    <el-table :data="items" border stripe>
      <el-table-column prop="name" label="名称" min-width="120" />
      <el-table-column prop="category" label="分类" width="100" />
      <el-table-column label="单位价格（进价 → 出价）" min-width="260">
        <template #default="{ row }">
          <el-tag v-for="p in row.prices" :key="p.id" class="price-tag" type="info" effect="plain">
            {{ p.unit }}：{{ p.purchase_price }} → {{ p.sale_price }}
          </el-tag>
        </template>
      </el-table-column>
      <el-table-column v-if="auth.isAdmin" label="操作" width="140" align="right">
        <template #default="{ row }">
          <el-button size="small" type="primary" link @click="openEdit(row)">编辑</el-button>
          <el-popconfirm title="删除该商品？" @confirm="remove(row.id)">
            <template #reference><el-button size="small" type="danger" link>删除</el-button></template>
          </el-popconfirm>
        </template>
      </el-table-column>
    </el-table>

    <el-dialog v-model="dialog" :title="editing ? '编辑商品' : '新增商品'" width="520px">
      <el-form label-width="80px">
        <el-form-item label="名称"><el-input v-model="form.name" placeholder="如 白菜" /></el-form-item>
        <el-form-item label="分类"><el-input v-model="form.category" placeholder="如 蔬菜" /></el-form-item>
        <el-form-item label="价格组合">
          <div class="prices">
            <div v-for="(p, i) in form.prices" :key="i" class="price-row">
              <el-input v-model="p.unit" placeholder="单位(斤/袋…)" style="width:110px" />
              <el-input-number v-model="p.purchase_price" :min="0" :precision="2" :controls="false" placeholder="进价" style="width:100px" />
              <el-input-number v-model="p.sale_price" :min="0" :precision="2" :controls="false" placeholder="出价" style="width:100px" />
              <el-button type="danger" link @click="form.prices.splice(i, 1)">删</el-button>
            </div>
            <el-button size="small" @click="form.prices.push({ unit: '', purchase_price: 0, sale_price: 0 })">+ 加一行（同菜不同单位/价格）</el-button>
          </div>
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
import { onMounted, reactive, ref } from 'vue';
import { ElMessage } from 'element-plus';
import { api, errMsg } from '../api';
import { useAuthStore } from '../stores/auth';

const auth = useAuthStore();

interface PriceRow { id?: string; unit: string; purchase_price: number; sale_price: number }
interface ItemRow { id: string; name: string; category: string; prices: PriceRow[] }

const loading = ref(false);
const saving = ref(false);
const query = ref('');
const items = ref<ItemRow[]>([]);
const dialog = ref(false);
const editing = ref(false);
const editingId = ref('');
const form = reactive<{ name: string; category: string; prices: PriceRow[] }>({ name: '', category: '', prices: [{ unit: '', purchase_price: 0, sale_price: 0 }] });

async function load() {
  loading.value = true;
  try {
    const { data } = await api.get('/items', { params: { q: query.value || undefined } });
    items.value = data.items;
  } finally {
    loading.value = false;
  }
}
onMounted(load);

function openCreate() {
  editing.value = false;
  editingId.value = '';
  form.name = '';
  form.category = '';
  form.prices = [{ unit: '', purchase_price: 0, sale_price: 0 }];
  dialog.value = true;
}

function openEdit(row: ItemRow) {
  editing.value = true;
  editingId.value = row.id;
  form.name = row.name;
  form.category = row.category;
  form.prices = row.prices.map((p) => ({ ...p }));
  dialog.value = true;
}

async function save() {
  if (!form.name.trim()) return ElMessage.warning('请填写名称');
  if (editing.value) {
    await api.patch(`/items/${editingId.value}`, { name: form.name, category: form.category });
  } else {
    const prices = form.prices.filter((p) => p.unit.trim());
    await api.post('/items', { name: form.name, category: form.category, prices });
  }
  ElMessage.success('已保存');
  dialog.value = false;
  load();
}

async function remove(id: string) {
  try {
    await api.delete(`/items/${id}`);
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
.price-tag { margin: 2px 6px 2px 0; }
.prices { width: 100%; }
.price-row { display: flex; gap: 8px; align-items: center; margin-bottom: 8px; }
</style>