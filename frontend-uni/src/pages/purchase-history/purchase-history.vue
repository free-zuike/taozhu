<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <!-- 月份 + 进货统计同一行（对齐 App：左年月两层 + 竖线 + 右三列：进货金额/天数/商品件数；列表全量，月份只影响统计） -->
    <view class="month-card">
      <view class="month-left" @click="pickMonth">
        <text class="month-y">{{ selYear }}年</text>
        <view class="month-row">
          <text class="month-m">{{ selMonth }}月</text>
          <text class="month-caret">▾</text>
        </view>
        <text class="month-tip">点击切换</text>
      </view>
      <view class="mdivider"></view>
      <view class="mcols3">
        <view class="mcol3"><text class="mv red">¥{{ fmt(mExpense) }}</text><text class="ml">进货金额</text></view>
        <view class="mcol3"><text class="mv">{{ mDays }}</text><text class="ml">天数</text></view>
        <view class="mcol3"><text class="mv">{{ mItems }}</text><text class="ml">商品件数</text></view>
      </view>
    </view>

    <scroll-view scroll-y class="flow" @scroll="onFlowScroll">
    <!-- 进货流水：按日期分组 + 行级卡片平铺（对齐 App 出货/进货流式列表） -->
    <view v-for="g in buyGroups" :key="g.date">
      <view class="day-bar">
        <text class="day-name">{{ g.week }}</text>
        <text class="day-total">{{ g.count }} 件 · 合计 ¥{{ fmt(g.amount) }}</text>
      </view>
      <view v-for="l in g.lines" :key="l.key" class="card-buy" @click="editBuyLine(l)" @longpress="deleteBuyLine(l)">
        <view class="head">
          <text class="name">{{ l.item_name }}</text>
          <text class="amt" style="color:#f59e0b">¥{{ fmt(l.amount) }}</text>
        </view>
        <view class="buy-line1">
          <text class="l2-tx">进价 ¥{{ fmt(l.purchase_price) }}<text v-if="l.quantity !== ''"> · ×{{ l.quantity }}{{ l.unit }}</text></text>
          <text class="l2-cat" v-if="l.category">{{ l.category }}</text>
        </view>
        <view v-if="l.note" class="buy-note">{{ l.note }}</view>
        <view class="ops">
          <view class="attach-entry" @click.stop="showAttach('purchase_item', l.itemId, 'purchase', l.orderId)">
            <image class="attach-ic" :src="attachIconSrc" mode="aspectFit" />
            <text v-if="attachOf(l) > 0" class="attach-cnt">{{ attachOf(l) }}</text>
          </view>
          <view class="attach-entry" @click.stop="showAttach('purchase', l.orderId)">
            <image class="attach-ic" :src="attachIconSrc" mode="aspectFit" />
            <text v-if="(attachCounts.purchase[l.orderId] || 0) > 0" class="attach-cnt">{{ attachCounts.purchase[l.orderId] }}</text>
          </view>
          <text class="tip-longpress" @click.stop>长按删除该商品</text>
        </view>
      </view>
    </view>
    <view v-if="buyGroups.length === 0" class="empty">该月暂无进货记录</view>
    </scroll-view>

    <!-- 附件弹层 -->
    <view v-if="attach.show" class="mask" @click="attach.show = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">凭证附件</view>
        <scroll-view scroll-y class="attach-scroll">
          <view v-for="(a, i) in attach.list" :key="a.key" class="attach-item">
            <image class="attach-img" :src="attachmentUrl(a.key)" mode="aspectFill" @click="previewAttach(i)" />
            <text class="attach-del" @click="removeAttach(a.key)">删除</text>
          </view>
          <view v-if="attach.list.length === 0" class="empty">暂无凭证，点下方添加</view>
        </scroll-view>
        <view class="attach-actions">
          <button class="btn-sub" @click="uploadAttach">+ 添加凭证（拍照/相册）</button>
          <button class="btn-save" @click="attach.show = false">完成</button>
        </view>
      </view>
    </view>

    <!-- 单商品编辑弹层 -->
    <view v-if="itemForm.show" class="mask" @click="itemForm.show = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">编辑「{{ itemForm.itemName }}」</view>
        <input class="ipt" v-model="itemForm.quantity" type="digit" placeholder="数量" />
        <input class="ipt" v-model="itemForm.unit" placeholder="单位（斤/件/箱…）" />
        <input class="ipt" v-model="itemForm.salePrice" type="digit" placeholder="进价（元）" />
        <input class="ipt" v-model="itemForm.date" placeholder="日期 YYYY-MM-DD" />
        <button class="btn-save" :disabled="saving" @click="saveItem">{{ saving ? '保存中…' : '保存' }}</button>
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
import { request, getToken, getAttachments, uploadAttachment, deleteAttachment, attachmentUrl } from '../../api';
import { attachIconSrc } from '../../attach-icon';

const selYear = ref(new Date().getFullYear());
const selMonth = ref(new Date().getMonth() + 1);
const purchases = ref<Array<Record<string, any>>>([]);
const mExpense = ref(0);
const mDays = ref(0);
const mItems = ref(0);
const saving = ref(false);
const fmt = (n: number) => Number(n || 0).toFixed(2);

// ── 进货流水：展开为明细行并按日期分组（对齐 App：日期头 + 明细行卡片，非整单嵌套）──
type BuyLine = {
  key: string; date: string; week: string; item_name: string; note: string;
  purchase_price: number; quantity: string | number; unit: string; amount: number;
  category: string; itemId: string; orderId: string; order: Record<string, any>;
};
type BuyGroup = { date: string; week: string; count: number; amount: number; lines: BuyLine[] };
const buyGroups = computed<BuyGroup[]>(() => {
  const map = new Map<string, BuyGroup>();
  const WEEKS = ['日', '一', '二', '三', '四', '五', '六'];
  const pushLine = (line: BuyLine) => {
    const g = map.get(line.date) || { date: line.date, week: '', count: 0, amount: 0, lines: [] };
    const d = new Date(`${line.date}T00:00:00`);
    g.week = `${line.date.slice(0, 4)}年${line.date.slice(5, 7)}月${line.date.slice(8, 10)}日 周${WEEKS[d.getDay()]}`;
    g.count += 1;
    g.amount += Number(line.amount || 0);
    g.lines.push(line);
    map.set(line.date, g);
  };
  for (const p of purchases.value) {
    const orderDate = String(p.happened_at || '').slice(0, 10);
    const items = ((p.items as Array<Record<string, any>>) || []);
    if (items.length === 0) {
      pushLine({
        key: `o-${p.id}`, date: orderDate, week: '', item_name: '备注行', note: String(p.note || ''),
        purchase_price: 0, quantity: '', unit: '', amount: Number(p.total || 0),
        category: '', itemId: '', orderId: String(p.id), order: p,
      });
      continue;
    }
    for (const it of items) {
      const d = String(it.happened_at || orderDate).slice(0, 10);
      pushLine({
        key: `${p.id}-${it.id}`, date: d || orderDate, week: '',
        item_name: String(it.item_name || ''), note: String(it.note || ''),
        purchase_price: Number(it.purchase_price || it.price || 0),
        quantity: it.quantity ?? '', unit: String(it.unit || ''), amount: Number(it.amount || 0),
        category: String(it.category_name || it.category || ''),
        itemId: String(it.id || ''), orderId: String(p.id), order: p,
      });
    }
  }
  return [...map.values()].sort((a, b) => (a.date > b.date ? -1 : a.date < b.date ? 1 : 0));
});

const itemForm = ref<{
  show: boolean; orderId: string; itemId: string; itemName: string;
  quantity: string; unit: string; salePrice: string; date: string;
}>({ show: false, orderId: '', itemId: '', itemName: '', quantity: '', unit: '', salePrice: '', date: '' });

const attach = ref<{ show: boolean; entity: string; id: string; list: Array<{ key: string }> }>({ show: false, entity: 'purchase', id: '', list: [] });
// 附件计数（行级 purchase_item / 单据级 purchase）
const attachCounts = ref<Record<string, Record<string, number>>>({ purchase_item: {}, purchase: {} });

/** 行级附件数：有行 id 按 purchase_item 查，行级空回退该单（识别原图挂首个商品行，其他行共用）；
 *  无明细（备注占位行）直接按单据级 purchase 查 */
function attachOf(l: { itemId: string; orderId: string }): number {
  const m = attachCounts.value;
  if (!l.itemId) return m.purchase[l.orderId] || 0;
  const line = m.purchase_item[l.itemId] || 0;
  return line > 0 ? line : (m.purchase[l.orderId] || 0);
}

onShow(async () => {
  onWs('*', load);
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await load();
});

function monthRange(): { from: string; to: string } {
  const y = selYear.value;
  const m = selMonth.value;
  const pad = (n: number) => String(n).padStart(2, '0');
  const from = `${y}-${pad(m)}-01`;
  const next = new Date(y, m, 0);
  const to = `${next.getFullYear()}-${pad(next.getMonth() + 1)}-${pad(next.getDate())}`;
  return { from, to };
}

function shiftMonth(delta: number) {
  let y = selYear.value;
  let m = selMonth.value + delta;
  if (m < 1) { y--; m = 12; }
  if (m > 12) { y++; m = 1; }
  const now = new Date();
  if (y > now.getFullYear() || (y === now.getFullYear() && m > now.getMonth() + 1)) {
    y = now.getFullYear();
    m = now.getMonth() + 1;
  }
  selYear.value = y;
  selMonth.value = m;
  calcMonthly();
}

function pickMonth() {
  uni.showActionSheet({
    itemList: ['上一月', '下一月', '回到本月'],
    success: (r) => {
      if (r.tapIndex === 0) shiftMonth(-1);
      else if (r.tapIndex === 1) shiftMonth(1);
      else if (r.tapIndex === 2) {
        selYear.value = new Date().getFullYear();
        selMonth.value = new Date().getMonth() + 1;
        calcMonthly();
      }
    },
  });
}

// 列表滚动 → 顶部月份跟随当前可见日期（对齐 App：滚动到哪月统计卡显示哪月）
function onFlowScroll() {
  if (buyGroups.value.length === 0) return;
  const first = buyGroups.value[0];
  if (!first || !first.date) return;
  const m = parseInt(first.date.slice(5, 7), 10);
  const y = parseInt(first.date.slice(0, 4), 10);
  if (y && m && (y !== selYear.value || m !== selMonth.value)) {
    selYear.value = y;
    selMonth.value = m;
    calcMonthly();
  }
}

async function load() {
  try {
    // 列表始终显示全部数据（对齐 App：月份切换只影响顶部统计，列表不按月过滤）
    const results = await Promise.all([
      request<{ purchases: any[]; purchase_items?: any[] }>(`/purchases?limit=500`, 'GET'),
      request<Record<string, any>>(`/stats/years`, 'GET').catch(() => null),
    ]);
    // 去单据化主结构：优先行级 purchase_items（每条商品一行），否则整单嵌套兼容
    const purchaseItems = results[0].purchase_items;
    purchases.value = (purchaseItems && purchaseItems.length > 0)
        ? assembleFromRows(purchaseItems)
        : (results[0].purchases || []);
    // 当月统计（行级口径：金额/天数/件数按行日期归月度，对齐 App _filterByRange）
    calcMonthly();
    loadAttachCounts();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

/// 当月进货统计（列表全量，按所选月份计算三列：进货金额/天数/商品件数）
function calcMonthly() {
  const { from, to } = monthRange();
  const daySet = new Set<string>();
  let expense = 0;
  let itemCount = 0;
  for (const p of purchases.value) {
    const orderDate = String(p.happened_at || '').slice(0, 10);
    const items = (p.items as Array<Record<string, any>>) || [];
    if (items.length === 0) {
      if (orderDate && orderDate >= from && orderDate <= to) {
        daySet.add(orderDate);
        expense += Number(p.total || 0);
        itemCount += 1;
      }
      continue;
    }
    for (const it of items) {
      const d = String(it.happened_at || orderDate).slice(0, 10);
      if (!d || d < from || d > to) continue;
      daySet.add(d);
      expense += Number(it.amount || 0);
      itemCount += 1;
    }
  }
  mExpense.value = Math.round(expense * 100) / 100;
  mDays.value = daySet.size;
  mItems.value = itemCount;
}

// 行级商品记录 → 假整单数组（同 purchase_id 归并；渲染代码零改动）
function assembleFromRows(rows: Array<Record<string, any>>): Array<Record<string, any>> {
  const byOrder = new Map<string, Array<Record<string, any>>>();
  const meta = new Map<string, Record<string, any>>();
  for (const r of rows) {
    const oid = String(r.purchase_id || '');
    if (!oid) continue;
    if (!byOrder.has(oid)) byOrder.set(oid, []);
    byOrder.get(oid)!.push(r);
    // 整单日期 = 行最大日期（与 Web/App 及服务器聚合口径一致，避免同单多行日期不同时两端对不上）
    const prev = meta.get(oid);
    const h = String(r.happened_at || '');
    meta.set(oid, {
      id: oid,
      happened_at: prev && String(prev.happened_at || '') >= h ? prev.happened_at : h,
      note: r.note || (prev?.note || ''),
    });
  }
  return [...byOrder.entries()].map(([oid, items]) => {
    const m = meta.get(oid)!;
    const total = items.reduce((s, it) => s + (Number(it.amount) || 0), 0);
    return { ...m, total, items };
  });
}

const confirm = (title: string, content: string) =>
  new Promise<boolean>((resolve) => {
    uni.showModal({ title, content, success: (r) => resolve(!!r.confirm) });
  });

function editPurchase(p: Record<string, any>) {
  uni.navigateTo({ url: `/pages/purchase/purchase?id=${p.id}` });
}

async function removePurchase(p: Record<string, any>) {
  if (!(await confirm('删除进货单', `确定删除 ${p.happened_at} 的进货单（¥${p.total}）吗？`))) return;
  try {
    await request(`/purchases/${p.id}`, 'DELETE');
    uni.showToast({ title: '已删除', icon: 'success' });
    load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
  }
}

function editPurchaseItem(p: Record<string, any>, it: Record<string, any>) {
  itemForm.value = {
    show: true,
    orderId: String(p.id),
    itemId: String(it.id || ''),
    itemName: String(it.item_name || ''),
    quantity: String(it.quantity ?? ''),
    unit: String(it.unit || ''),
    salePrice: String(it.purchase_price ?? it.price ?? ''),
    date: String(it.happened_at || p.happened_at || '').slice(0, 10),
  };
}

// 流式行点击编辑（流水行字段与接口行字段命名不同：itemId/date → id/happened_at）
function editBuyLine(l: BuyLine) {
  editPurchaseItem(l.order, { ...l, id: l.itemId, happened_at: l.date });
}

// 明细行长按 → 只删除该商品行（与出货侧对称；不再整单删除）
async function deletePurchaseLine(p: Record<string, any>, it: Record<string, any>) {
  if (!it.id) {
    uni.showToast({ title: '该行无独立明细，无法单独删除', icon: 'none' });
    return;
  }
  if (!(await confirm('删除商品', `确定删除「${it.item_name}」这一行吗？仅删除该商品，库存自动回滚。`))) return;
  try {
    await request(`/purchases/items/${it.id}`, 'DELETE');
    uni.showToast({ title: '已删除该商品', icon: 'success' });
    load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
  }
}

// 流式行长按删除（流水行字段适配）
function deleteBuyLine(l: BuyLine) {
  deletePurchaseLine(l.order, { ...l, id: l.itemId, happened_at: l.date });
}

async function saveItem() {
  const qty = Number(itemForm.value.quantity);
  if (!qty || qty <= 0) {
    uni.showToast({ title: '请输入有效数量', icon: 'none' });
    return;
  }
  if (!itemForm.value.itemId) {
    uni.showToast({ title: '该行无独立明细，请用「编辑」修改该条记录', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    await request(`/purchases/items/${itemForm.value.itemId}`, 'PATCH', {
      quantity: qty,
      unit: itemForm.value.unit,
      purchase_price: Number(itemForm.value.salePrice) || 0,
      happened_at: itemForm.value.date,
    });
    uni.showToast({ title: '已保存', icon: 'success' });
    itemForm.value.show = false;
    load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

async function showAttach(entity: string, id: string, fbEntity = '', fbId = '') {
  attach.value = { show: true, entity, id, list: [] };
  let list: Array<{ key: string }> = [];
  try {
    const d = await getAttachments(entity, id);
    list = d.attachments || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载附件失败', icon: 'none' });
    return;
  }
  if (list.length === 0 && fbEntity && fbId) {
    try {
      const d = await getAttachments(fbEntity, fbId);
      list = d.attachments || [];
    } catch (_) {}
  }
  attach.value.list = list;
}

function previewAttach(i: number) {
  const urls = attach.value.list.map((a) => attachmentUrl(a.key));
  uni.previewImage({ urls, current: urls[i] });
}

async function uploadAttach() {
  const entity = attach.value.entity;
  const id = attach.value.id;
  uni.chooseImage({
    count: 1,
    success: async (r) => {
      const path = r.tempFilePaths[0];
      try {
        await uploadAttachment(entity, id, path);
        uni.showToast({ title: '已上传', icon: 'success' });
        const d = await getAttachments(entity, id);
        attach.value.list = d.attachments || [];
        loadAttachCounts();
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '上传失败', icon: 'none' });
      }
    },
  });
}

async function removeAttach(key: string) {
  if (!(await confirm('删除凭证', '确定删除这张凭证吗？'))) return;
  try {
    await deleteAttachment(key);
    attach.value.list = attach.value.list.filter((a) => a.key !== key);
    uni.showToast({ title: '已删除', icon: 'success' });
    loadAttachCounts();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
  }
}

/// 批量拉当前页附件数（行级 purchase_item + 单据级 purchase）
async function loadAttachCounts() {
  const lineIds = [
    ...new Set(
      purchases.value.flatMap((p) => ((p.items as Array<Record<string, any>>) || []).map((it) => String(it.id || '')).filter(Boolean)),
    ),
  ];
  const orderIds = [...new Set(purchases.value.map((p) => String(p.id || '')).filter(Boolean))];
  const fetch = async (entity: string, ids: string[]) => {
    if (ids.length === 0) return;
    try {
      const d = await request<{ counts: Record<string, number> }>('/attachments/counts', 'POST', { entity, ids });
      for (const [id, n] of Object.entries(d.counts || {})) {
        if (n > 0) attachCounts.value[entity][id] = n;
      }
    } catch (_) {}
  };
  await fetch('purchase_item', lineIds);
  await fetch('purchase', orderIds);
}

  onHide(() => { offWs('*', load); });
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh;  background: var(--page-bg); }
.month-card { display: flex; align-items: center; background: transparent; border: none; border-radius: 0; padding: 4rpx 0 12rpx; margin-bottom: 4rpx; }
.month-left { display: flex; flex-direction: column; align-items: center; justify-content: center; padding-right: 20rpx; }
.month-y { font-size: 24rpx; font-weight: 600; color: var(--text-sub); line-height: 1.3; }
.month-row { display: flex; align-items: center; gap: 4rpx; }
.month-m { font-size: 40rpx; font-weight: 800; color: var(--primary); line-height: 1.2; }
.month-caret { font-size: 22rpx; color: var(--text-sub); }
.month-tip { font-size: 20rpx; color: var(--text-sub); }
.mdivider { width: 1rpx; height: 80rpx; background: var(--divider); }
.mcols3 { flex: 1; display: flex; margin-left: 20rpx; }
.mcol3 { flex: 1; display: flex; flex-direction: column; align-items: flex-start; gap: 4rpx; padding-right: 8rpx; }
.ml { font-size: 20rpx; color: var(--text-sub); }
.mv { font-size: 30rpx; font-weight: 800; color: var(--text-main); max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.red { color: #f56c6c; }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 24rpx; margin-bottom: 16rpx; }
/* 进货流水：日期头 + 行级卡片（对齐 App 流式列表；与出货流水同构） */
.flow { height: calc(100vh - 260rpx); }
.day-bar { display: flex; justify-content: space-between; align-items: center; padding: 16rpx 8rpx 10rpx; }
.day-name { font-size: 27rpx; font-weight: bold; color: var(--text-main); }
.day-total { font-size: 23rpx; color: var(--text-sub); }
.card-buy { background: var(--card-bg); border: var(--card-border); border-radius: 10rpx; padding: 20rpx 22rpx; margin-bottom: 12rpx; box-shadow: none; }
.buy-line1 { display: flex; align-items: baseline; gap: 14rpx; margin-bottom: 6rpx; }
.l2-tx { font-size: 23rpx; color: var(--text-sub); }
.l2-cat { font-size: 20rpx; color: var(--primary); background: var(--primary-soft); border-radius: 6rpx; padding: 2rpx 10rpx; }
.buy-note { font-size: 22rpx; color: var(--text-sub); margin-bottom: 6rpx; }
.head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8rpx; }
.name { font-size: 30rpx; font-weight: bold; }
.amt { font-size: 30rpx; font-weight: bold; color: #f56c6c; }
.line { display: flex; justify-content: space-between; align-items: center; padding: 10rpx 0; border-top: 1rpx solid var(--divider); }
.line-left { flex: 1; min-width: 0; }
.line-name-row { display: flex; align-items: center; gap: 12rpx; }
.op-attach { font-size: 22rpx; color: var(--primary); flex-shrink: 0; padding: 4rpx 12rpx; background: var(--primary-fade); border-radius: 8rpx; }
.line-name { font-size: 27rpx; color: var(--text-main); display: block; }
.line-meta { font-size: 22rpx; color: var(--text-sub); margin-top: 2rpx; display: block; }
.line-amt { font-size: 27rpx; font-weight: bold; color: #f56c6c; margin-left: 16rpx; }
.ops { display: flex; align-items: center; justify-content: flex-end; gap: 20rpx; margin-top: 8rpx; }
.op { color: var(--primary); font-size: 26rpx; }
.del { color: #f56c6c; font-size: 26rpx; }
.attach-entry { display: flex; align-items: center; gap: 2rpx; padding: 2rpx; }
.attach-ic { width: 28rpx; height: 28rpx; }
.attach-cnt { font-size: 20rpx; color: var(--primary); font-weight: 600; }
.tip-longpress { color: var(--text-sub); font-size: 22rpx; margin-left: auto; }
.empty { color: var(--text-sub); text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: var(--sheet-bg); border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; }
.attach-scroll { max-height: 600rpx; margin-bottom: 16rpx; }
.attach-item { display: flex; align-items: center; gap: 16rpx; padding: 12rpx 0; border-bottom: 1rpx solid var(--divider); }
.attach-img { width: 120rpx; height: 120rpx; border-radius: 8rpx; flex-shrink: 0; }
.attach-del { color: #f56c6c; font-size: 26rpx; margin-left: auto; }
.attach-actions { display: flex; gap: 16rpx; }
.attach-actions .btn-sub { flex: 1; }
.attach-actions .btn-save { flex: 1; }
</style>