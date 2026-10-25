<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="toolbar">
      <input class="search" v-model="q" placeholder="搜索商品" @input="onSearch" />
      <view class="pill" @click="openCount">盘点</view>
      <view :class="['pill', { active: belowOnly }]" @click="toggleBelow">只看预警</view>
    </view>
    <view class="toolbar sub-toolbar">
      <view class="pill" @click="openLossList">损耗记录</view>
      <view class="pill" @click="openAdjustList">盘点调整</view>
    </view>

    <view v-if="totalLabel" class="total">{{ totalLabel }}</view>

    <view v-for="s in merged" :key="'m' + s.item_id" class="card" @click="viewTrace(s)">
      <view class="head">
        <text class="name">{{ s.item_name }}</text>
        <text :class="['qty', { low: s.low }]">{{ fmtQty(s.quantity) }} {{ s.unit }}</text>
      </view>
      <view class="sub">还剩 {{ fmtQty(s.quantity) }} {{ s.unit }} · 阈值 {{ fmtQty(s.min_stock) }} {{ s.unit }}{{ s.low ? ' · 库存不足' : '' }}{{ expiryOf(s) ? ' · ⚠' + expiryOf(s) + ' 到期（临期）' : '' }}</view>
      <view v-if="s._others && s._others.length" class="sub">另有 {{ othersText(s._others) }}</view>
      <view class="ops">
        <text class="op" @click.stop="loss(s)">报损</text>
        <text class="op" @click.stop="edit(s)">调整</text>
        <text class="op" @click.stop="viewTrace(s)">来源</text>
      </view>
    </view>
    <view v-if="merged.length === 0" class="empty">暂无库存记录（进货后自动入库，可点「调整」初始化）</view>

    <!-- 报损弹层 -->
    <view v-if="showLoss" class="mask" @click="showLoss = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">报损：{{ cur.item_name }}</view>
        <view class="form-item">当前库存 {{ fmtQty(curQuantity) }} {{ cur.unit }}（从最早进货批次扣减，损耗不计入毛利）</view>
        <picker v-if="lossUnits.length > 1" :range="lossUnits" :value="lossUnitIndex" @change="onLossUnit">
          <view class="ipt picker">单位：{{ lossUnits[lossUnitIndex] }}</view>
        </picker>
        <input class="ipt" v-model="lossQty" type="digit" placeholder="损耗数量" />
        <input class="ipt" v-model="lossNote" placeholder="备注（可选，如：菜叶损坏）" />
        <button class="btn-save" :disabled="saving" @click="submitLoss">{{ saving ? '提交中…' : '确认报损' }}</button>
      </view>
    </view>

    <!-- 损耗记录弹层 -->
    <view v-if="showLossList" class="mask" @click="showLossList = false">
      <view class="sheet trace-sheet" @click.stop>
        <view class="sheet-title">损耗记录（共 {{ lossRows.length }} 笔 · 合计 {{ fmtQty(lossTotalQty) }}）</view>
        <view v-if="lossCostVisible" class="form-item">损耗金额合计 ¥{{ fmtAmount(lossTotalAmount) }}</view>
        <scroll-view scroll-y class="trace-list">
          <view v-if="lossRows.length === 0" class="empty">暂无损耗记录（库存页点「报损」登记）</view>
          <view v-for="(r, i) in lossRows" :key="i" class="t-row">
            <view class="t-body">
              <text class="t-name">{{ r.item_name }}（{{ r.unit }}）</text>
              <text class="t-date">{{ r.happened_at }}{{ r.note ? ' · ' + r.note : '' }}</text>
            </view>
            <text class="t-qty q-out">−{{ fmtQty(r.qty) }}{{ lossCostVisible ? ' · ¥' + fmtAmount(r.amount) : '' }}</text>
          </view>
        </scroll-view>
      </view>
    </view>

    <!-- 调整弹层（仅预警阈值；库存=流水自动计算，数量不再手填） -->
    <view v-if="showForm" class="mask" @click="showForm = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">预警阈值</view>
        <view class="form-item">{{ cur.item_name }}（{{ cur.unit }}）· 当前库存 {{ fmtQty(curQuantity) }}</view>
        <input class="ipt" v-model="formMin" type="digit" placeholder="低库存预警阈值" />
        <button class="btn-save" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>

    <!-- 盘点弹层：全部商品×单位，填实际数（差异=盘盈/盘亏自动调整）+ 可顺手设阈值 -->
    <view v-if="showCount" class="mask" @click="showCount = false">
      <view class="sheet trace-sheet" @click.stop>
        <view class="sheet-title">库存盘点（填实际数，差异自动调整）</view>
        <view class="form-item count-hint">盘盈（实际＞账面）/ 盘亏（实际＜账面）自动记调整流水</view>
        <scroll-view scroll-y class="trace-list">
          <view v-if="countRows.length === 0" class="empty">暂无商品，请先添加商品与价格</view>
          <view v-for="(r, i) in countRows" :key="i" class="count-row">
            <view class="count-info">
              <text class="t-name">{{ r.item_name }}（{{ r.unit }}）</text>
              <text class="t-date">账面 {{ fmtQty(r.quantity) }}</text>
            </view>
            <input class="count-ipt" v-model="r.actual" type="digit" placeholder="实际数" />
            <input class="count-ipt" v-model="r.min" type="digit" placeholder="阈值" />
          </view>
        </scroll-view>
        <button class="btn-save" :disabled="saving" @click="submitCount">{{ saving ? '提交中…' : '保存盘点' }}</button>
      </view>
    </view>

    <!-- 盘点调整记录弹层 -->
    <view v-if="showAdjustList" class="mask" @click="showAdjustList = false">
      <view class="sheet trace-sheet" @click.stop>
        <view class="sheet-title">盘点调整记录（共 {{ adjustRows.length }} 笔）</view>
        <view class="form-item">盘盈 {{ fmtQty(adjustSurplusQty) }} · 盘亏 {{ fmtQty(adjustShortageQty) }}</view>
        <scroll-view scroll-y class="trace-list">
          <view v-if="adjustRows.length === 0" class="empty">暂无盘点调整（库存页点「盘点」按实际数量校对）</view>
          <view v-for="(r, i) in adjustRows" :key="i" class="t-row">
            <view class="t-body">
              <text class="t-name">{{ r.item_name }}（{{ r.unit }}）</text>
              <text class="t-date">{{ r.happened_at }}{{ r.note ? ' · ' + r.note : '' }}</text>
            </view>
            <text :class="['t-qty', Number(r.qty) > 0 ? 'q-in' : 'q-out']">
              {{ Number(r.qty) > 0 ? '+' : '−' }}{{ fmtQty(Math.abs(Number(r.qty))) }}{{ adjustCostVisible && Number(r.amount) ? ' · ¥' + fmtAmount(r.amount) : '' }}
            </text>
          </view>
        </scroll-view>
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
/// 临期映射（key: item_id\u0000unit → 最早到期日；来自 /stocks/alerts）
const expiryMap = ref<Record<string, string>>({});
function expiryOf(s: Stock): string {
  return expiryMap.value[`${s.item_id}\u0000${s.unit}`] || '';
}
const q = ref('');
const belowOnly = ref(false);
const totalLabel = ref('');
const showForm = ref(false);
const saving = ref(false);
const cur = ref<{ id: string; item_id: string; item_name: string; unit: string; count_unit?: string }>({ id: '', item_id: '', item_name: '', unit: '' });
const formMin = ref('');
const curQuantity = ref(0);
const showTrace = ref(false);
const traceRows = ref<Array<{ kind: string; happened_at: string; quantity: number; unit: string; eff_qty: number; count_qty: number | null; note: string | null }>>([]);
const showLoss = ref(false);
const lossQty = ref('');
const lossNote = ref('');
const lossUnits = ref<string[]>([]);
const lossUnitIndex = ref(0);
const showLossList = ref(false);
const lossRows = ref<Array<{ item_name: string; unit: string; qty: number; amount: number; happened_at: string; note: string; cost_visible?: boolean }>>([]);
const lossTotalQty = ref(0);
const lossTotalAmount = ref(0);
const lossCostVisible = ref(true);
// 盘点（v0.17.473）：全商品×单位填实际数，差异=盘盈/盘亏自动调整；可顺手设阈值
const showCount = ref(false);
const countRows = ref<Array<{ item_id: string; item_name: string; unit: string; quantity: number; min_stock: number; actual: string; min: string }>>([]);
const showAdjustList = ref(false);
const adjustRows = ref<Array<{ item_name: string; unit: string; qty: number; amount: number; happened_at: string; note: string; cost_visible?: boolean }>>([]);
const adjustSurplusQty = ref(0);
const adjustShortageQty = ref(0);
const adjustCostVisible = ref(true);

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
    // 临期映射（批次到期 ≤7 天；同商品+单位取最早到期日）
    try {
      const a = await request<{ expiring: Array<{ item_id: string; unit: string; expiry_date: string }> }>('/stocks/alerts?days=7', 'GET');
      const m: Record<string, string> = {};
      for (const e of (a?.expiring || [])) m[`${e.item_id}\u0000${e.unit}`] = e.expiry_date;
      expiryMap.value = m;
    } catch (_) {}
    if (!belowOnly.value && d.stocks.length) {
      let sum = 0;
      for (const s of merged.value) {
        sum += (Number(s.quantity) || 0) * (Number((s as any).cost_price) || 0);
        for (const o of (s._others || [])) sum += (Number(o.quantity) || 0) * (Number((o as any).cost_price) || 0);
      }
      // 金额合计按「我的 → 金额舍入」设置的位数（对齐 App fmtMoney）
      totalLabel.value = `库存金额合计（按剩余批次成本）¥${fmtAmount(sum)}`;
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
  curQuantity.value = Number(s.quantity) || 0;
  formMin.value = String(s.min_stock);
  showForm.value = true;
}

async function save() {
  const min = Number(formMin.value) || 0;
  if (!(min >= 0)) {
    uni.showToast({ title: '阈值须为非负数字', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    if (cur.value.id) {
      await request(`/stocks/${cur.value.id}`, 'PATCH', { min_stock: min });
    } else {
      // 未配置过阈值的商品（计算型列表无 stocks 行）→ 批量端点按商品+单位创建阈值
      await request('/stocks', 'PUT', { rows: [{ item_id: cur.value.item_id, unit: cur.value.unit, min_stock: min }] });
    }
    uni.showToast({ title: '已保存', icon: 'success' });
    showForm.value = false;
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

/** 盘点弹层：全部商品×单位，填实际数（差异=盘盈/盘亏自动调整）+ 阈值可顺手修改 */
async function openCount() {
  try {
    const [itemsD, stocksD] = await Promise.all([
      request<{ items: Array<{ id: string; name: string; prices: Array<{ unit: string }> }> }>('/items', 'GET'),
      request<{ stocks: Array<{ item_id: string; unit: string; quantity: number; min_stock: number }> }>('/stocks', 'GET'),
    ]);
    const stockMap = new Map<string, { quantity: number; min_stock: number }>();
    for (const s of (stocksD?.stocks || [])) stockMap.set(`${s.item_id}/${s.unit}`, s);
    const rows: Array<{ item_id: string; item_name: string; unit: string; quantity: number; min_stock: number; actual: string; min: string }> = [];
    for (const it of (itemsD?.items || [])) {
      for (const p of (it.prices || [])) {
        const cur2 = stockMap.get(`${it.id}/${p.unit}`);
        rows.push({
          item_id: it.id, item_name: it.name, unit: p.unit,
          quantity: Number(cur2?.quantity) || 0,
          min_stock: Number(cur2?.min_stock) || 0,
          actual: '', min: String(Number(cur2?.min_stock) || 0),
        });
      }
    }
    if (!rows.length) {
      uni.showToast({ title: '暂无商品，请先添加商品与价格', icon: 'none' });
      return;
    }
    countRows.value = rows;
    showCount.value = true;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

/** 保存盘点：差异≠0 的实际数 → POST /stocks/adjust；阈值变化 → PUT /stocks；防连点 */
async function submitCount() {
  const adjustRows2: Array<{ item_id: string; unit: string; actual_qty: number }> = [];
  const thresholdRows: Array<{ item_id: string; unit: string; min_stock: number }> = [];
  for (const r of countRows.value) {
    const v = Number(r.actual);
    if (r.actual.trim() !== '' && v >= 0 && Math.abs(v - r.quantity) > 0.001) {
      adjustRows2.push({ item_id: r.item_id, unit: r.unit, actual_qty: v });
    }
    const m = Number(r.min);
    if (!isNaN(m) && m >= 0 && Math.abs(m - r.min_stock) > 0.001) {
      thresholdRows.push({ item_id: r.item_id, unit: r.unit, min_stock: m });
    }
  }
  if (!adjustRows2.length && !thresholdRows.length) {
    uni.showToast({ title: '没有变化，无需保存', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    let msg = '';
    if (adjustRows2.length) {
      const r = await request<{ adjusted: number; surplus: number; shortage: number }>('/stocks/adjust', 'POST', {
        id: 'c' + Date.now() + Math.floor(Math.random() * 9000 + 1000),
        rows: adjustRows2,
        happened_at: new Date().toISOString().slice(0, 10),
      });
      msg = `调整 ${r?.adjusted ?? adjustRows2.length} 项`
        + (Number(r?.surplus) ? `，盘盈 ${fmtQty(r!.surplus)}` : '')
        + (Number(r?.shortage) ? `，盘亏 ${fmtQty(r!.shortage)}` : '');
    }
    if (thresholdRows.length) {
      await request('/stocks', 'PUT', { rows: thresholdRows });
    }
    uni.showToast({ title: msg ? `已保存：${msg}` : '阈值已保存', icon: 'success' });
    showCount.value = false;
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

/** 盘点调整记录：GET /stocks/adjustments 列表 + 盘盈/盘亏汇总（金额/单价仅老板可见） */
async function openAdjustList() {
  try {
    const d = await request<{ rows: Array<{ item_name: string; unit: string; qty: number; amount: number; happened_at: string; note: string; cost_visible: boolean }>; surplus_qty: number; shortage_qty: number }>('/stocks/adjustments', 'GET');
    adjustRows.value = d?.rows || [];
    adjustSurplusQty.value = Number(d?.surplus_qty) || 0;
    adjustShortageQty.value = Number(d?.shortage_qty) || 0;
    adjustCostVisible.value = adjustRows.value.length ? adjustRows.value[0].cost_visible !== false : true;
    showAdjustList.value = true;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function convertUnit(r: { unit: string }): string {
  return (cur.value.count_unit || '') ? cur.value.count_unit! : r.unit;
}

/** 报损弹层：单位取该商品全部单位（主 + _others），默认主单位（出货单位） */
function loss(s: Stock) {
  const units = new Set<string>([s.unit || '']);
  for (const o of (s._others || [])) {
    if (o.unit) units.add(o.unit);
  }
  const list = [...units].filter((u) => !!u);
  if (!list.length) {
    uni.showToast({ title: '缺少单位信息，无法报损', icon: 'none' });
    return;
  }
  cur.value = { id: s.id, item_id: s.item_id, item_name: s.item_name, unit: s.unit, count_unit: s.count_unit };
  curQuantity.value = Number(s.quantity) || 0;
  lossUnits.value = list;
  lossUnitIndex.value = Math.max(0, list.indexOf(s.unit));
  lossQty.value = '';
  lossNote.value = '';
  showLoss.value = true;
}

function onLossUnit(e: any) {
  lossUnitIndex.value = Number(e.detail.value) || 0;
}

async function submitLoss() {
  const qty = Number(lossQty.value);
  if (!(qty > 0)) {
    uni.showToast({ title: '损耗数量须大于 0', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    await request('/stocks/loss', 'POST', {
      item_id: cur.value.item_id,
      unit: lossUnits.value[lossUnitIndex.value],
      qty,
      note: lossNote.value.trim(),
    });
    uni.showToast({ title: `已报损 ${fmtQty(qty)}${lossUnits.value[lossUnitIndex.value]}`, icon: 'success' });
    showLoss.value = false;
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '报损失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

/** 损耗记录：GET /stocks/loss 列表 + 汇总（金额/单价仅老板可见，店员打码） */
async function openLossList() {
  try {
    const d = await request<{ rows: Array<{ item_name: string; unit: string; qty: number; amount: number; happened_at: string; note: string; cost_visible: boolean }>; total_qty: number; total_amount: number }>('/stocks/loss', 'GET');
    lossRows.value = d?.rows || [];
    lossTotalQty.value = Number(d?.total_qty) || 0;
    lossTotalAmount.value = Number(d?.total_amount) || 0;
    lossCostVisible.value = lossRows.value.length ? lossRows.value[0].cost_visible !== false : true;
    showLossList.value = true;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
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
.sub-toolbar { margin-top: -8rpx; margin-bottom: 20rpx; }
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
.t-name { font-size: 26rpx; font-weight: bold; }
.t-date { font-size: 24rpx; color: var(--text-sub); }
.t-note { font-size: 22rpx; color: var(--text-sub); overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.t-qty { font-size: 26rpx; font-weight: bold; flex-shrink: 0; }
.q-in { color: #16a34a; }
.q-out { color: #dc2626; }
.count-hint { font-size: 24rpx; color: var(--text-sub); }
.count-row { display: flex; align-items: center; gap: 12rpx; padding: 12rpx 0; border-bottom: 1rpx solid var(--divider); }
.count-row:last-child { border-bottom: none; }
.count-info { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.count-ipt { width: 150rpx; background: var(--input-bg); border-radius: 10rpx; padding: 10rpx 12rpx; font-size: 26rpx; }
</style>