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

    <scroll-view scroll-y class="flow">
    <!-- 进货流水：按日期分组 + 行级卡片平铺（对齐 App 出货/进货流式列表） -->
    <view v-for="g in buyGroups" :key="g.date">
      <view class="day-bar" @click="openBuyBatch(g.date)">
        <text class="mi day-ic">&#xe742;</text>
        <text class="day-name">{{ g.week }}</text>
        <text class="day-total">{{ g.count }} 件 · 合计 ¥{{ fmt(g.amount) }}</text>
        <text class="mi day-arrow">&#xe5cc;</text>
      </view>
      <view v-for="l in g.lines" :key="l.key" class="card-buy" @click="editBuyLine(l)" @longpress="deleteBuyLine(l)">
        <view class="head">
          <text class="name">{{ l.item_name }}</text>
          <text class="amt" style="color:#f59e0b">¥{{ fmt(l.amount) }}</text>
        </view>
        <view class="buy-line1">
          <text class="l2-tx">进价 ¥{{ fmtPrice(l.purchase_price) }}<text v-if="l.quantity !== ''"> · ×{{ l.quantity }}{{ l.unit }}</text></text>
          <text class="l2-cat" v-if="l.category">{{ l.category }}</text>
        </view>
        <view v-if="l.note" class="buy-note">{{ l.note }}</view>
        <view class="ops">
          <!-- 单个附件入口（对齐 App：行级优先、空回退该单；无附件灰态，可点开添加） -->
          <view class="attach-entry" @click.stop="showAttach(l.itemId ? 'purchase_item' : 'purchase', l.itemId || l.orderId, 'purchase', l.orderId)">
            <image class="attach-ic" :class="{ 'attach-ic-off': attachOf(l) <= 0 }" :src="attachIconSrc" mode="aspectFit" />
            <text v-if="attachOf(l) > 0" class="attach-cnt">{{ attachOf(l) }}</text>
          </view>
          <text class="tip-longpress" @click.stop>长按删除该商品</text>
        </view>
      </view>
    </view>
    <view v-if="buyGroups.length === 0" class="empty">该月暂无进货记录</view>
    </scroll-view>

    <!-- 附件查看/上传/删除：全屏大图查看器（对齐 App：点击直接全屏，不再先弹小弹层；有图看大图，无图全屏空态可添加） -->
    <view v-if="attach.show" class="viewer" @click.stop>
      <!-- 有图：swiper 大图 -->
      <swiper v-if="attach.list.length > 0" class="viewer-swiper" :current="attach.index" @change="onViewerChange">
        <swiper-item v-for="a in attach.list" :key="a.key">
          <image class="viewer-img" :src="attachmentUrl(a.key)" mode="aspectFit" @click.stop />
        </swiper-item>
      </swiper>
      <!-- 无图：全屏空态（不再弹"凭证附件/完成"sheet，直接在全屏查看器里添加） -->
      <view v-else class="viewer-empty">
        <text class="viewer-empty-tx">暂无凭证，点上方「添加」上传</text>
      </view>
      <view class="viewer-top">
        <text class="viewer-close" @click="closeAttach">✕</text>
        <text class="viewer-count">{{ attach.list.length > 0 ? attach.index + 1 + '/' + attach.list.length : '' }}</text>
        <view class="viewer-ops">
          <text class="viewer-op" @click="uploadAttach">添加</text>
          <text v-if="attach.list.length > 0" class="viewer-op" @click="downloadAttach">下载</text>
          <text v-if="attach.list.length > 0" class="viewer-op viewer-op-del" @click="removeAttach(attach.list[attach.index].key)">删除</text>
        </view>
      </view>
    </view>

    <!-- 单商品编辑弹层（对齐 App 单行编辑：数量/单位/进价/折合计数/日期/该条凭证/备注/删除，保存走行级 PATCH） -->
    <view v-if="itemForm.show" class="mask" @click="itemForm.show = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">编辑「{{ itemForm.itemName }}」</view>
        <view class="form-row">
          <input class="ipt flex1" v-model="itemForm.quantity" type="digit" placeholder="数量" />
          <input class="ipt flex1" v-model="itemForm.unit" placeholder="单位" />
        </view>
        <view class="form-row">
          <input class="ipt flex1" v-model="itemForm.salePrice" type="digit" placeholder="进价（元）" />
          <input v-if="itemForm.countUnit" class="ipt flex1" v-model="itemForm.countQty" type="digit" :placeholder="'折' + itemForm.countUnit" />
        </view>
        <!-- 日期：picker 原生滚轮（对齐 App 行编辑 DateField，不可手输） -->
        <picker mode="date" :value="itemForm.date || today" @change="onFormDate">
          <view class="field-inner">
            <text class="label">日期</text>
            <text class="value" :class="{ placeholder: !itemForm.date }">{{ itemForm.date || '选择日期' }}</text>
          </view>
        </picker>
        <input class="ipt" v-model="itemForm.note" placeholder="备注（选填）" />
        <!-- 该条凭证附件（对齐 App 行编辑弹窗：查看/添加，点击直接全屏查看器） -->
        <view class="attach-row" @click="openFormAttach">
          <text class="label">该条凭证附件</text>
          <text class="value attach-go">查看/添加</text>
        </view>
        <view class="dlg-ops">
          <button class="btn-del" :disabled="saving" @click="deleteItem">删除该行</button>
          <button class="btn-save" :disabled="saving" @click="saveItem">{{ saving ? '保存中…' : '保存' }}</button>
        </view>
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
import { fmtAmount, fmtPrice } from '../../utils/money';

const selYear = ref(new Date().getFullYear());
const selMonth = ref(new Date().getMonth() + 1);
/// 用户是否手动切换过月份（手动后不自动跳最后记录月份；默认=最后一条有记录的月份）
let userPickedMonth = false;
const purchases = ref<Array<Record<string, any>>>([]);
const mExpense = ref(0);
const mDays = ref(0);
const mItems = ref(0);
const saving = ref(false);
// 金额显示按「我的 → 金额舍入」设置的位数/进位口径（对齐 App fmtMoney；列表/统计/合计统一）
const fmt = (n: number) => fmtAmount(Number(n) || 0);

// ── 进货流水：展开为明细行并按日期分组（对齐 App：日期头 + 明细行卡片，非整单嵌套）──
type BuyLine = {
  key: string; date: string; week: string; item_name: string; note: string;
  purchase_price: number; quantity: string | number; unit: string; amount: number;
  category: string; itemId: string; orderId: string; order: Record<string, any>;
  count_qty?: number | null; count_unit?: string; // 折合计数（对齐 App 行编辑）
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
        count_qty: it.count_qty ?? null, count_unit: String(it.count_unit || ''),
      });
    }
  }
  return [...map.values()].sort((a, b) => (a.date > b.date ? -1 : a.date < b.date ? 1 : 0));
});

const itemForm = ref<{
  show: boolean; orderId: string; itemId: string; itemName: string;
  quantity: string; unit: string; salePrice: string; countQty: string; countUnit: string; date: string; note: string;
  category: string;
}>({ show: false, orderId: '', itemId: '', itemName: '', quantity: '', unit: '', salePrice: '', countQty: '', countUnit: '', date: '', note: '', category: '' });

const today = new Date().toISOString().slice(0, 10);

function onFormDate(e: { detail: { value: string } }) {
  itemForm.value.date = e.detail.value;
}

// 打开该条凭证（行级优先、单据级回退，直接全屏查看器）
function openFormAttach() {
  const f = itemForm.value;
  if (!f.orderId) return;
  showAttach('purchase_item', f.itemId, 'purchase', f.orderId);
}

const attach = ref<{ show: boolean; entity: string; id: string; list: Array<{ key: string }>; index: number }>({ show: false, entity: 'purchase', id: '', list: [], index: 0 });
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
  userPickedMonth = true; // 手动切月后不自动跳最后记录月份
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
  userPickedMonth = true; // 手动切月后不自动跳最后记录月份
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

// 月份只由顶部月份选择器控制（pickMonth），滚动不再联动切月（对齐交易页 0.17.317；
// 原实现 onFlowScroll 按列表首组日期强制切月并重算=滚动时顶部月份乱跳，已删除）

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
    // 默认月份 = 最后一条有记录的月份（用户未手动切月时；当前月无数据不显示空统计）
    if (!userPickedMonth) {
      let latest = '';
      for (const p of purchases.value) {
        const od = String(p.happened_at || '').slice(0, 10);
        const items = (p.items as Array<Record<string, any>>) || [];
        if (items.length === 0) {
          if (od && od > latest) latest = od;
          continue;
        }
        for (const it of items) {
          const d = String(it.happened_at || od).slice(0, 10);
          if (d && d > latest) latest = d;
        }
      }
      if (latest.length >= 7) {
        const ny = parseInt(latest.slice(0, 4), 10);
        const nm = parseInt(latest.slice(5, 7), 10);
        if (ny && nm && (ny !== selYear.value || nm !== selMonth.value)) {
          selYear.value = ny;
          selMonth.value = nm;
        }
      }
    }
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

// 日期栏点击 → 批量直编该日全部行（对齐 App dateRows：purchase.vue dateRows=1&date=xxx）
function openBuyBatch(date: string) {
  uni.navigateTo({ url: `/pages/purchase/purchase?dateRows=1&date=${date}` });
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
    countQty: it.count_qty ? String(it.count_qty) : '',
    countUnit: String(it.count_unit || ''),
    date: String(it.happened_at || p.happened_at || '').slice(0, 10),
    note: String(it.note ?? ''),
    category: String(it.category || it.category_name || ''),
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
    const countQty = Number(itemForm.value.countQty) > 0 ? Number(itemForm.value.countQty) : null;
    await request(`/purchases/items/${itemForm.value.itemId}`, 'PATCH', {
      quantity: qty,
      unit: itemForm.value.unit,
      purchase_price: Number(itemForm.value.salePrice) || 0,
      count_qty: countQty,
      happened_at: itemForm.value.date,
      note: itemForm.value.note,
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

// 弹窗内删除该行（对齐 App 单行编辑「删除」按钮：DELETE 行级接口）
async function deleteItem() {
  if (!itemForm.value.itemId) {
    uni.showToast({ title: '该行无独立明细，无法单独删除', icon: 'none' });
    return;
  }
  if (!(await confirm('删除商品', `确定删除「${itemForm.value.itemName}」这一行吗？仅删除该商品，库存自动回滚。`))) return;
  saving.value = true;
  try {
    const id = itemForm.value.itemId;
    await request(`/purchases/items/${id}`, 'DELETE');
    uni.showToast({ title: '已删除该商品', icon: 'success' });
    itemForm.value.show = false;
    load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

async function showAttach(entity: string, id: string, fbEntity = '', fbId = '') {
  attach.value = { show: true, entity, id, list: [], index: 0 };
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
  // 全屏查看器直接打开（有图看大图；无图显示空态可添加）
}

function closeAttach() {
  attach.value.show = false;
}

function onViewerChange(e: { detail: { current: number } }) {
  attach.value.index = e.detail.current;
}

function downloadAttach() {
  const it = attach.value.list[attach.value.index];
  if (!it) return;
  uni.showLoading({ title: '下载中…' });
  uni.downloadFile({
    url: attachmentUrl(it.key),
    success(res) {
      if (res.statusCode !== 200) {
        uni.hideLoading();
        uni.showToast({ title: '下载失败', icon: 'none' });
        return;
      }
      uni.saveImageToPhotosAlbum({
        filePath: res.tempFilePath,
        success() {
          uni.hideLoading();
          uni.showToast({ title: '已保存到相册', icon: 'success' });
        },
        fail(e) {
          uni.hideLoading();
          uni.showToast({ title: e.errMsg?.includes('auth') ? '需要相册权限' : '保存失败', icon: 'none' });
        },
      });
    },
    fail() {
      uni.hideLoading();
      uni.showToast({ title: '下载失败', icon: 'none' });
    },
  });
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
    const idx = attach.value.list.findIndex((a) => a.key === key);
    attach.value.list = attach.value.list.filter((a) => a.key !== key);
    if (idx >= 0 && attach.value.index >= idx && attach.value.index > 0) attach.value.index -= 1;
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
.day-ic { color: var(--primary); font-size: 28rpx; margin-right: 8rpx; }
.day-name { font-size: 27rpx; font-weight: bold; color: var(--text-main); flex: 1; }
.day-total { font-size: 23rpx; color: var(--text-sub); }
.day-arrow { color: var(--text-sub); font-size: 30rpx; margin-left: 8rpx; }
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
.attach-ic { width: 30rpx; height: 30rpx; }
.attach-ic-off { filter: grayscale(1); opacity: 0.45; }
.attach-cnt { font-size: 20rpx; color: var(--primary); font-weight: 600; }
.tip-longpress { color: var(--text-sub); font-size: 22rpx; margin-left: auto; }
.empty { color: var(--text-sub); text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: var(--sheet-bg); border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.field-inner { display: flex; justify-content: space-between; padding: 18rpx 20rpx; background: var(--input-bg); border-radius: 10rpx; margin-bottom: 16rpx; }
.label { color: var(--text-sub); font-size: 28rpx; }
.value { color: var(--text-main); font-size: 28rpx; }
.placeholder { color: var(--text-sub); }
.form-row { display: flex; gap: 16rpx; }
.form-row .ipt { flex: 1; }
.flex1 { flex: 1; }
.btn-del { background: var(--card-bg); color: #f56c6c; border: 1rpx solid #f56c6c; border-radius: 12rpx; font-size: 30rpx; }
.dlg-ops { display: flex; gap: 20rpx; margin-top: 8rpx; }
.dlg-ops .btn-save, .dlg-ops .btn-del { flex: 1; }
.attach-row { display: flex; justify-content: space-between; align-items: center; padding: 18rpx 20rpx; background: var(--input-bg); border-radius: 10rpx; margin-bottom: 16rpx; }
.attach-go { color: var(--primary); }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; }
.attach-scroll { max-height: 600rpx; margin-bottom: 16rpx; }
.attach-item { display: flex; align-items: center; gap: 16rpx; padding: 12rpx 0; border-bottom: 1rpx solid var(--divider); }
.attach-img { width: 200rpx; height: 200rpx; border-radius: 12rpx; flex-shrink: 0; }
.attach-del { color: #f56c6c; font-size: 26rpx; margin-left: auto; }
.attach-actions { display: flex; gap: 16rpx; }
.attach-actions .btn-sub { flex: 1; }
.attach-actions .btn-save { flex: 1; }
/* 全屏凭证查看器（对齐 App attachment_viewer：大图 + 上边操作按钮） */
.viewer { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: #000; display: flex; flex-direction: column; }
.viewer-swiper { flex: 1; width: 100%; }
.viewer-img { width: 100%; height: 100%; }
.viewer-top { position: absolute; left: 0; right: 0; top: 0; display: flex; align-items: center; justify-content: space-between; padding: 24rpx 28rpx; background: linear-gradient(rgba(0,0,0,0.5), transparent); box-sizing: border-box; }
.viewer-close { color: #fff; font-size: 40rpx; line-height: 1; padding: 8rpx; }
.viewer-count { color: rgba(255,255,255,0.85); font-size: 26rpx; }
.viewer-ops { display: flex; gap: 28rpx; }
.viewer-op { color: #fff; font-size: 28rpx; background: rgba(255,255,255,0.18); border-radius: 28rpx; padding: 10rpx 26rpx; }
.viewer-op-del { color: #ff6d6d; }
.viewer-empty { flex: 1; display: flex; align-items: center; justify-content: center; }
.viewer-empty-tx { color: rgba(255,255,255,0.7); font-size: 28rpx; }
</style>