<template>
  <div v-loading="loading">
    <el-card shadow="never" class="mb">
      <template #header>按店统计（出货/收款/欠款/毛利）</template>
      <el-table :data="byClient" border stripe size="small">
        <el-table-column prop="name" label="饭店" min-width="130" />
        <el-table-column prop="sales_total" label="出货" align="right"><template #default="{ row }">¥{{ fmt(row.sales_total) }}</template></el-table-column>
        <el-table-column prop="paid_total" label="收款" align="right"><template #default="{ row }">¥{{ fmt(row.paid_total) }}</template></el-table-column>
        <el-table-column prop="debt" label="欠款" align="right"><template #default="{ row }"><span class="red">¥{{ fmt(row.debt) }}</span></template></el-table-column>
        <el-table-column prop="gross_profit" label="毛利" align="right"><template #default="{ row }"><span class="green">¥{{ fmt(row.gross_profit) }}</span></template></el-table-column>
      </el-table>
    </el-card>

    <el-card shadow="never">
      <template #header>
        <div class="monthly-header">
          <span>{{ year }} 年月度统计</span>
          <el-select v-model="year" style="width: 100px" @change="loadMonthly">
            <el-option v-for="y in years" :key="y" :label="`${y} 年`" :value="y" />
          </el-select>
        </div>
      </template>
      <el-table :data="monthly" border stripe size="small">
        <el-table-column label="月份" width="120">
          <template #default="{ row }">{{ monthLabel(row.month) }}</template>
        </el-table-column>
        <el-table-column prop="sales_total" label="出货" align="right"><template #default="{ row }">¥{{ fmt(row.sales_total) }}</template></el-table-column>
        <el-table-column prop="gross_profit" label="毛利" align="right"><template #default="{ row }"><span class="green">¥{{ fmt(row.gross_profit) }}</span></template></el-table-column>
        <el-table-column prop="paid_total" label="收款" align="right"><template #default="{ row }">¥{{ fmt(row.paid_total) }}</template></el-table-column>
      </el-table>
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { onMounted, ref } from 'vue';
import { api } from '../api';

const loading = ref(false);
const byClient = ref<Array<{ name: string; sales_total: number; paid_total: number; debt: number; gross_profit: number }>>([]);
const monthly = ref<Array<{ month: string; sales_total: number; gross_profit: number; paid_total: number }>>([]);
const currentYear = new Date().getUTCFullYear();
const year = ref(currentYear);
const years = ref<number[]>([currentYear]);
const fmt = (n: number) => Number(n || 0).toFixed(2);
/** "2026-09" → "9月" */
const monthLabel = (m: string) => (m?.length >= 7 ? `${Number(m.slice(5, 7))}月` : m);

async function loadAll() {
  loading.value = true;
  try {
    const [c, m, y] = await Promise.all([
      api.get('/stats/clients'),
      api.get('/stats/monthly', { params: { year: year.value } }),
      api.get('/stats/years'),
    ]);
    byClient.value = c.data.clients;
    monthly.value = m.data.months;
    // 有数据年份：从最早有账的年份到当前年；无数据用当前年
    const list = (y.data.years as number[]).filter((n) => n <= currentYear);
    if (list.length) {
      years.value = list;
      if (!list.includes(year.value)) year.value = list[list.length - 1];
    }
  } finally {
    loading.value = false;
  }
}
onMounted(loadAll);

function loadMonthly() {
  api.get('/stats/monthly', { params: { year: year.value } }).then(({ data }) => {
    monthly.value = data.months;
  });
}
</script>

<style scoped>
.mb { margin-bottom: 16px; }
.red { color: #f56c6c; }
.green { color: #67c23a; }
.monthly-header { display: flex; justify-content: space-between; align-items: center; }
</style>