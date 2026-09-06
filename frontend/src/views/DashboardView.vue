<template>
  <div v-loading="loading">
    <!-- 今日卡片 -->
    <el-row :gutter="16" class="cards">
      <el-col :span="4"><el-card shadow="hover"><div class="card-label">今日出货</div><div class="card-value">¥{{ fmt(today.sales_total) }}</div></el-card></el-col>
      <el-col :span="4"><el-card shadow="hover"><div class="card-label">今日毛利</div><div class="card-value green">¥{{ fmt(today.gross_profit) }}</div></el-card></el-col>
      <el-col :span="4"><el-card shadow="hover"><div class="card-label">今日收款</div><div class="card-value">¥{{ fmt(today.paid_total) }}</div></el-card></el-col>
      <el-col :span="4"><el-card shadow="hover"><div class="card-label">今日进货</div><div class="card-value red">¥{{ fmt(today.purchase_total) }}</div></el-card></el-col>
      <el-col :span="4"><el-card shadow="hover"><div class="card-label">今日单数</div><div class="card-value">{{ today.sales_count }}</div></el-card></el-col>
    </el-row>
    <el-row :gutter="16" class="cards">
      <el-col :span="4"><el-card shadow="hover"><div class="card-label">累计出货</div><div class="card-value">¥{{ fmt(totals.all_sales) }}</div></el-card></el-col>
      <el-col :span="4"><el-card shadow="hover"><div class="card-label">累计收款</div><div class="card-value">¥{{ fmt(totals.all_paid) }}</div></el-card></el-col>
      <el-col :span="4"><el-card shadow="hover"><div class="card-label red-text">总欠款</div><div class="card-value red">¥{{ fmt(totals.debt) }}</div></el-card></el-col>
      <el-col :span="4"><el-card shadow="hover"><div class="card-label">饭店数</div><div class="card-value">{{ totals.client_count }}</div></el-card></el-col>
      <el-col :span="4"><el-card shadow="hover"><div class="card-label">商品数</div><div class="card-value">{{ totals.item_count }}</div></el-card></el-col>
    </el-row>

    <!-- 欠款排行 -->
    <el-card shadow="never" class="mt">
      <template #header>欠款排行（前 5）</template>
      <el-table :data="topDebt" size="small">
        <el-table-column prop="name" label="饭店" />
        <el-table-column prop="sales_total" label="累计出货" align="right">
          <template #default="{ row }">¥{{ fmt(row.sales_total) }}</template>
        </el-table-column>
        <el-table-column prop="paid_total" label="累计收款" align="right">
          <template #default="{ row }">¥{{ fmt(row.paid_total) }}</template>
        </el-table-column>
        <el-table-column prop="debt" label="欠款" align="right">
          <template #default="{ row }">
            <span class="red">{{ fmt(row.debt) }}</span>
          </template>
        </el-table-column>
      </el-table>
    </el-card>
  </div>
</template>

<script setup lang="ts">
import { onMounted, ref } from 'vue';
import { api } from '../api';

const loading = ref(false);
const today = ref({ sales_total: 0, sales_count: 0, gross_profit: 0, paid_total: 0, purchase_total: 0 });
const totals = ref({ all_sales: 0, all_paid: 0, debt: 0, client_count: 0, item_count: 0 });
const topDebt = ref<Array<{ name: string; sales_total: number; paid_total: number; debt: number }>>([]);

const fmt = (n: number) => Number(n || 0).toFixed(2);

async function load() {
  loading.value = true;
  try {
    const { data } = await api.get('/stats/overview');
    today.value = data.today;
    totals.value = data.totals;
    topDebt.value = data.top_debt_clients;
  } finally {
    loading.value = false;
  }
}
onMounted(load);
</script>

<style scoped>
.cards {
  margin-bottom: 16px;
}
.card-label {
  color: #909399;
  font-size: 13px;
  margin-bottom: 6px;
}
.card-value {
  font-size: 22px;
  font-weight: 700;
}
.green { color: #67c23a; }
.red { color: #f56c6c; }
.red-text { color: #f56c6c; font-size: 13px; }
.mt { margin-top: 16px; }
</style>