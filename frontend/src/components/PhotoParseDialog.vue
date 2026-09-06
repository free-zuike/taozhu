<template>
  <el-dialog v-model="dialog" title="拍照识别" width="560px">
    <div class="toolbar">
      <input ref="fileInput" type="file" accept="image/*" capture="environment" class="hidden" @change="onFile" />
      <el-button type="primary" :loading="uploading" @click="fileInput?.click()">
        {{ uploading ? '识别中…' : '📷 选择/拍摄图片' }}
      </el-button>
      <span v-if="drafts.length === 0 && !uploading" class="tip">识别小票/价签/进货单上的商品清单，自动填入明细。</span>
    </div>

    <el-alert v-if="error" type="error" :closable="false" show-icon class="mb">{{ error }}</el-alert>

    <el-table v-if="drafts.length" :data="drafts" border size="small">
      <el-table-column label="商品" min-width="110">
        <template #default="{ row }">
          <span :class="{ unmatched: !row.matched }">{{ row.name }}</span>
          <el-tag v-if="!row.matched" type="danger" size="small">未入库</el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="unit" label="单位" width="70" />
      <el-table-column prop="quantity" label="数量" width="80" />
      <el-table-column prop="price" label="单价(元)" width="100" />
    </el-table>

    <template #footer>
      <el-button @click="dialog = false">取消</el-button>
      <el-button type="primary" :disabled="matchedCount === 0" @click="importMatched">
        导入已匹配（{{ matchedCount }}）
      </el-button>
    </template>
  </el-dialog>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue';
import { ElMessage } from 'element-plus';
import { api, errMsg } from '../api';
import type { ImportedRow } from '../types/ui';

interface DraftRow {
  name: string;
  unit: string;
  quantity: number;
  price: number;
  matched: boolean;
  itemId: string;
  priceId: string;
}

interface ItemOption {
  id: string;
  name: string;
  prices: Array<{ id: string; unit: string; purchase_price: number; sale_price: number }>;
}

const props = defineProps<{ items: ItemOption[]; purpose: 'sale' | 'purchase' }>();
const emit = defineEmits<{ (e: 'imported', rows: ImportedRow[]): void }>();

const dialog = ref(false);
const uploading = ref(false);
const fileInput = ref<HTMLInputElement | null>(null);
const drafts = ref<DraftRow[]>([]);
const error = ref('');

const priceOf = (p: ItemOption['prices'][number]) =>
  props.purpose === 'sale' ? p.sale_price : p.purchase_price;

const matchedCount = computed(() => drafts.value.filter((d) => d.matched).length);

function match(name: string, unit: string, qty: number, price: number): DraftRow {
  const item = props.items.find((i) => i.name.includes(name) || name.includes(i.name));
  if (!item) return { name, unit, quantity: qty, price, matched: false, itemId: '', priceId: '' };
  const priceRow = item.prices.find((p) => p.unit === unit) ?? item.prices[0];
  if (!priceRow) return { name, unit, quantity: qty, price, matched: false, itemId: '', priceId: '' };
  return {
    name: item.name, unit: priceRow.unit, quantity: qty,
    price: price > 0 ? price : priceOf(priceRow),
    matched: true, itemId: item.id, priceId: priceRow.id,
  };
}

async function onFile(ev: Event) {
  const input = ev.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = '';
  if (!file) return;
  uploading.value = true;
  error.value = '';
  try {
    const fd = new FormData();
    fd.append('photo', file);
    const { data } = await api.post('/ai/parse-photo', fd, { params: { purpose: props.purpose } });
    drafts.value = (data.items ?? []).map((d: { name: string; unit: string; quantity: number; price: number }) =>
      match(d.name ?? '', d.unit ?? '', Number(d.quantity) || 0, Number(d.price) || 0),
    );
    if (drafts.value.length === 0) {
      ElMessage.warning('未识别到商品，请换张更清晰的图片');
    } else if (matchedCount.value < drafts.value.length) {
      ElMessage.warning(`${drafts.value.length - matchedCount.value} 项不在商品库，请先在商品管理添加`);
    }
  } catch (e) {
    error.value = errMsg(e, '识别失败');
  } finally {
    uploading.value = false;
  }
}

function importMatched() {
  const rows = drafts.value
    .filter((d) => d.matched)
    .map((d) => ({ name: d.name, itemId: d.itemId, priceId: d.priceId, unit: d.unit, quantity: d.quantity, price: d.price }));
  if (rows.length === 0) return;
  emit('imported', rows);
  drafts.value = [];
  dialog.value = false;
  ElMessage.success(`已导入 ${rows.length} 项，请核对数量与单价`);
}

function open() {
  error.value = '';
  drafts.value = [];
  dialog.value = true;
}
defineExpose({ open });
</script>

<style scoped>
.hidden { display: none; }
.toolbar { display: flex; align-items: center; gap: 12px; margin-bottom: 12px; }
.tip { color: #909399; font-size: 13px; }
.unmatched { color: #f56c6c; }
.mb { margin-bottom: 12px; }
</style>