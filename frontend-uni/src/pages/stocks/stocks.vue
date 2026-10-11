<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="toolbar">
      <input class="search" v-model="q" placeholder="搜索商品" @input="onSearch" />
      <view :class="['pill', { active: belowOnly }]" @click="toggleBelow">只看预警</view>
    </view>

    <view v-if="totalLabel" class="total">{{ totalLabel }}</view>

    <view v-for="s in merged" :key="'m' + s.item_id" class="card" @click="viewTrace(s)">
      <view class="head">
        <text class="name">{{ s.item_name }}</text>
        <text :class="['qty', { low: s.low }]">{{ fmtQty(s.quantity) }} {{ s.unit }}</text>
      </view>
      <view class="sub">还剩 {{ fmtQty(s.quantity) }} {{ s.unit }} · 阈值 {{ fmtQty(s.min_stock) }} {{ s.unit }}{{ s.low ? ' · 库存不足' : '' }}</view>
      <view v-if="s._others && s._others.length" class="sub">另有 {{ othersText(s._others) }}</view>
      <view class="ops">
        <text class="op" @click.stop="edit(s)">调整</text>
        <text class="op" @click.stop="viewTrace(s)">来源</text>
      </view>
    </view>
    <view v-if="merged.length === 0" class="empty">暂无库存记录（进货后自动入库，可点「调整」初始化）</view>

    <!-- 调整弹层 -->
    <view v-if="showForm" class="mask" @click="showForm = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">库存调整</view>
        <view class="form-item">{{ cur.item_name }}（{{ cur.unit }}）</view>
        <input class="ipt" v-model="formQty" type="digit" placeholder="库存数量" />
        <input class="ipt" v-model="formMin" type="digit" placeholder="低库存预警阈值" />
        <button class="btn-save" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>

    <!-- 进货/出货来源弹层 -->
    <view v-if="showTrace" class="mask" @click="showTrace = false">
      <view class="sheet trace-sheet" @click.stop>
        <view class="sheet-title">{{ cur.item_name }} · 进货/出货来源</view>
        <scroll-view scroll-y class="trace-list">
          <view v-if="traceRows.length === 0" class="empty">暂无进货/出货记录（数量可能来自盘点初始化）</view>
          <view v-for="(r, i) in traceRows" :key="i" class="t-row">
            <text :class="['t-kind', r.kind === 'in' ? 'k-in' : 'k-out']">{{ r.kind === 'in' ? '进货' : '出货' }}</text>
            <view class="t-body">
              <text class="t-date">{{ r.happened_at }}</text>
              <text v-if="r.note" class="t-note">{{ r.note }}</text>
            </view>
            <text :class="['t-qty', r.kind === 'in' ? 'q-in' : 'q-out']">
              {{ r.kind === 'in' ? '+' : '−' }}{{ fmtQty(r.quantity) }}{{ r.unit }}
              <template v-if="(r.count_qty ?? 0) > 0 && r.count_qty != r.quantity && r.quantity > 0">
                （折 {{ fmtQty(r.eff_qty) }}{{ convertUnit(r) }}）
              </template>
            </text>
          </view>
        </scroll-view>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { onShow, onHide } from '@dcloudio/uni-app';
import { onWs, offWs } from '../../ws';

import { useThemeVars } from '../../theme';
const { tv, patternSrc } = useThemeVars();
import { ref, computed } from 'vue';
;
;
import { request, getToken } from '../../api';
import { fmtAmount } from '../../utils/money';

interface Stock { id: string; item_id: string; item_name: string; unit: string; quantity: number; min_stock: number; low: boolean; count_unit?: string; _others?: Stock[] }

const stocks = ref<Stock[]>([]);
const q = ref('');
const belowOnly = ref(false);
const totalLabel = ref('');
const showForm = ref(false);
const saving = ref(false);
const cur = ref<{ id: string; item_id: string; item_name: string; unit: string; count_unit?: string }>({ id: '', item_id: '', item_name: '', unit: '' });
const formQty = ref('');
const formMin = ref('');
const showTrace = ref(false);
const traceRows = ref<Array<{ kind: string; happened_at: string; quantity: number; unit: string; eff_qty: number; count_qty: number | null; note: string | null }>>([]);

/** 数量显示：整数不显示小数（后端已舍入两位），小数最多两位去尾 0（防 1.7000000000000002 斤） */
function fmtQty(v: number | string | null | undefined): string {
  const n = Number(v) || 0;
  if (n === Math.round(n)) return String(n);
  return String(n.toFixed(2)).replace(/0+$/, '').replace(/\.$/, '');
}

/** 按商品合并：主单位=出货单位（count_unit 行），其余单位折叠为 _others（同 App） */
const merged = computed<Stock[]>(() => {
  const byItem = new Map<string, Stock[]>();
  for (const s of stocks.value) {
    const arr = byItem.get(s.item_id) || [];
    arr.push(s);
    byItem.set(s.item_id, arr);
  }
  const out: Stock[] = [];
  for (const list of byItem.values()) {
    if (!list.length) continue;
    let mainUnit = '';
    for (const s of list) {
      if ((s.count_unit || '') && s.unit === s.count_unit) { mainUnit = s.unit; break; }
    }
    let main = mainUnit ? (list.find((s) => s.unit === mainUnit) || list[0]) : list[0];
    const others = list.filter((s) => s !== main);
    if (others.length) main = { ...main, _others: others };
    out.push(main);
  }
  out.sort((a, b) => (a.item_name || '').localeCompare(b.item_name || ''));
  return out;
});

function othersText(others: Stock[]): string {
  return others.map((o) => `${fmtQty(o.quantity)} ${o.unit}`).join('、');
}

onShow(async () => {
  onWs('*', load);
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await load();
});

async function load() {
  try {
    const params: string[] = [];
    if (q.value.trim()) params.push(`q=${encodeURIComponent(q.value.trim())}`);
    if (belowOnly.value) params.push('below=1');
    const d = await request<{ stocks: Stock[] }>(`/stocks${params.length ? '?' + params.join('&') : ''}`, 'GET');
    stocks.value = d.stocks;
    if (!belowOnly.value && d.stocks.length) {
      let sum = 0;
      for (const s of merged.value) {
        sum += (Number(s.quantity) || 0) * (Number((s as any).cost_price) || 0);
        for (const o of (s._others || [])) sum += (Number(o.quantity) || 0) * (Number((o as any).cost_price) || 0);
      }
      // 金额合计按「我的 → 金额舍入」设置的位数（对齐 App fmtMoney）
      totalLabel.value = `库存金额合计（按当前进价）¥${fmtAmount(sum)}`;
    } else {
      totalLabel.value = '';
    }
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function onSearch() {
  clearTimeout((onSearch as any)._t);
  (onSearch as any)._t = setTimeout(() => load(), 300);
}

function toggleBelow() {
  belowOnly.value = !belowOnly.value;
  load();
}

function edit(s: Stock) {
  cur.value = { id: s.id, item_id: s.item_id, item_name: s.item_name, unit: s.unit, count_unit: s.count_unit };
  formQty.value = String(s.quantity);
  formMin.value = String(s.min_stock);
  showForm.value = true;
}

async function save() {
  const qty = Number(formQty.value);
  const min = Number(formMin.value) || 0;
  if (!(qty >= 0)) {
    uni.showToast({ title: '数量须为非负数字', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    await request(`/stocks/${cur.value.id}`, 'PATCH', { quantity: qty, min_stock: min });
    uni.showToast({ title: '已保存', icon: 'success' });
    showForm.value = false;
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

function convertUnit(r: { unit: string }): string {
  return (cur.value.count_unit || '') ? cur.value.count_unit! : r.unit;
}

async function viewTrace(s: Stock) {
  cur.value = { id: s.id, item_id: s.item_id, item_name: s.item_name, unit: s.unit, count_unit: s.count_unit };
  showTrace.value = true;
  traceRows.value = [];
  try {
    const d = await request<{ rows: Array<{ kind: string; happened_at: string; quantity: number; unit: string; eff_qty: number; count_qty: number | null; note: string | null }> }>(`/stocks/trace?item_id=${s.item_id}`, 'GET');
    traceRows.value = d?.rows || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

  onHide(() => { offWs('*', load); });
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh;  background: var(--page-bg); }
.toolbar { display: flex; align-items: center; gap: 16rpx; margin-bottom: 16rpx; }
.search { flex: 1; background: var(--card-bg); border-radius: 12rpx; padding: 16rpx 24rpx; font-size: 28rpx; }
.pill { padding: 12rpx 24rpx; background: var(--card-bg); border-radius: 24rpx; font-size: 26rpx; color: var(--text-sub); border: 1rpx solid var(--divider); }
.pill.active { color: #f56c6c; border-color: #f56c6c; background: var(--danger-bg); }
.total { font-size: 26rpx; color: #67c23a; font-weight: bold; margin-bottom: 12rpx; }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8rpx; }
.name { font-size: 30rpx; font-weight: bold; }
.qty { font-size: 32rpx; font-weight: bold; color: #67c23a; }
.qty.low { color: #f56c6c; }
.sub { font-size: 24rpx; color: var(--text-sub); margin-bottom: 8rpx; }
.ops { display: flex; justify-content: flex-end; gap: 24rpx; }
.op { color: var(--primary); font-size: 26rpx; }
.empty { color: var(--text-sub); text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: var(--sheet-bg); border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.form-item { font-size: 28rpx; color: var(--text-main); margin-bottom: 16rpx; }
.ipt { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; }
.trace-sheet { padding-bottom: 40rpx; max-height: 75vh; display: flex; flex-direction: column; }
.trace-list { max-height: 60vh; }
.t-row { display: flex; align-items: center; gap: 16rpx; padding: 16rpx 0; border-bottom: 1rpx solid var(--divider); }
.t-row:last-child { border-bottom: none; }
.t-kind { font-size: 22rpx; font-weight: bold; padding: 4rpx 12rpx; border-radius: 8rpx; flex-shrink: 0; }
.k-in { background: rgba(34,197,94,0.14); color: #16a34a; }
.k-out { background: rgba(239,68,68,0.14); color: #dc2626; }
.t-body { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.t-date { font-size: 24rpx; color: var(--text-sub); }
.t-note { font-size: 22rpx; color: var(--text-sub); overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.t-qty { font-size: 26rpx; font-weight: bold; flex-shrink: 0; }
.q-in { color: #16a34a; }
.q-out { color: #dc2626; }
</style>