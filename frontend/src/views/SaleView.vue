<template>
  <div v-loading="loading">
    <el-card shadow="never">
      <el-form inline>
        <el-form-item label="饭店">
          <el-select v-model="clientId" filterable placeholder="选择饭店" style="width: 200px">
            <el-option v-for="c in clients" :key="c.id" :label="c.name" :value="c.id" />
          </el-select>
        </el-form-item>
        <el-form-item label="日期">
          <el-date-picker v-model="happenedAt" type="date" value-format="YYYY-MM-DD" placeholder="选择日期" />
        </el-form-item>
        <el-form-item label="备注"><el-input v-model="note" placeholder="如 早班送菜" style="width: 160px" /></el-form-item>
      </el-form>

      <el-table :data="rows" border>
        <el-table-column label="商品" min-width="200">
          <template #default="{ row }">
            <el-select v-model="row.itemId" filterable placeholder="选商品" @change="onItemChange(row)">
              <el-option v-for="it in items" :key="it.id" :label="it.name" :value="it.id" />
            </el-select>
          </template>
        </el-table-column>
        <el-table-column label="单位/出价" width="220">
          <template #default="{ row }">
            <el-select v-model="row.priceId" placeholder="选单位" @change="onPriceChange(row)">
              <el-option v-for="p in row.prices" :key="p.id" :label="`${p.unit}（¥${p.sale_price}）`" :value="p.id" />
            </el-select>
          </template>
        </el-table-column>
        <el-table-column label="数量" width="140">
          <template #default="{ row }">
            <el-input-number v-model="row.quantity" :min="0" :precision="2" :controls="false" style="width: 100%" />
          </template>
        </el-table-column>
        <el-table-column label="单价" width="130">
          <template #default="{ row }">
            <el-input-number v-model="row.salePrice" :min="0" :precision="2" :controls="false" style="width: 100%" />
          </template>
        </el-table-column>
        <el-table-column label="金额" width="100" align="right">
          <template #default="{ row }">¥{{ rowAmount(row) }}</template>
        </el-table-column>
        <el-table-column width="60" align="center">
          <template #default="{ $index }">
            <el-button type="danger" link @click="rows.splice($index, 1)">删</el-button>
          </template>
        </el-table-column>
      </el-table>

      <div class="footer">
        <div>
          <el-button @click="addRow">+ 添加商品</el-button>
          <el-button type="success" plain @click="photoDlg?.open()">📷 拍照识别</el-button>
        </div>
        <div class="total">合计：<span class="total-num">¥{{ total.toFixed(2) }}</span></div>
      </div>
      <el-button type="primary" size="large" class="submit" :loading="saving" @click="submit">提交出货单</el-button>

      <PhotoParseDialog ref="photoDlg" :items="items" purpose="sale" @imported="importDrafts" />
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue';
import { ElMessage } from 'element-plus';
import { api, errMsg } from '../api';
import PhotoParseDialog from '../components/PhotoParseDialog.vue';
import type { ImportedRow } from '../types/ui';

interface PriceOption { id: string; unit: string; sale_price: number; purchase_price: number }
interface ItemOption { id: string; name: string; prices: PriceOption[] }
interface Row { itemId: string; priceId: string; prices: PriceOption[]; quantity: number; salePrice: number }

const loading = ref(false);
const saving = ref(false);
const clients = ref<Array<{ id: string; name: string }>>([]);
const items = ref<ItemOption[]>([]);
const clientId = ref('');
const happenedAt = ref(new Date().toISOString().slice(0, 10));
const note = ref('');
const rows = reactive<Row[]>([]);
const photoDlg = ref<{ open: () => void } | null>(null);

const total = computed(() => rows.reduce((s, r) => s + r.quantity * r.salePrice, 0));
const rowAmount = (r: Row) => (r.quantity * r.salePrice).toFixed(2);

function addRow(): Row {
  const row = { itemId: '', priceId: '', prices: [], quantity: 0, salePrice: 0 };
  rows.push(row);
  return row;
}

function onItemChange(row: Row) {
  const item = items.value.find((i) => i.id === row.itemId);
  row.prices = item?.prices ?? [];
  row.priceId = '';
  row.salePrice = 0;
}

function onPriceChange(row: Row) {
  const price = row.prices.find((p) => p.id === row.priceId);
  if (price) row.salePrice = price.sale_price;
}

/** 拍照识别导入：相同商品+单位合并数量，否则新增行 */
function importDrafts(list: ImportedRow[]) {
  for (const r of list) {
    const existing = rows.find((x) => x.itemId === r.itemId && x.priceId === r.priceId);
    if (existing) {
      existing.quantity += r.quantity;
      existing.salePrice = r.price;
    } else {
      const item = items.value.find((i) => i.id === r.itemId);
      rows.push({ itemId: r.itemId, priceId: r.priceId, prices: item?.prices ?? [], quantity: r.quantity, salePrice: r.price });
    }
  }
}

async function load() {
  loading.value = true;
  try {
    const [c, i] = await Promise.all([api.get('/clients'), api.get('/items/summary')]);
    clients.value = c.data.clients;
    items.value = i.data.items;
  } finally {
    loading.value = false;
  }
}
onMounted(load);

async function submit() {
  if (!clientId.value) return ElMessage.warning('请选择饭店');
  if (rows.length === 0) return ElMessage.warning('请添加商品');
  const items2 = rows.filter((r) => r.itemId && r.priceId && r.quantity > 0);
  if (items2.length === 0) return ElMessage.warning('请填写完整的商品明细');
  saving.value = true;
  try {
    await api.post('/sales', {
      client_id: clientId.value,
      happened_at: happenedAt.value,
      note: note.value.trim(),
      items: items2.map((r) => ({ price_id: r.priceId, quantity: r.quantity, sale_price: r.salePrice })),
    });
    ElMessage.success(`出货单已提交，合计 ¥${total.value.toFixed(2)}`);
    rows.splice(0, rows.length);
    note.value = '';
  } catch (e) {
    ElMessage.error(errMsg(e));
  } finally {
    saving.value = false;
  }
}
</script>

<style scoped>
.footer { display: flex; align-items: center; justify-content: space-between; margin-top: 12px; }
.total-num { color: #f56c6c; font-size: 20px; font-weight: 700; }
.submit { margin-top: 12px; }
</style>