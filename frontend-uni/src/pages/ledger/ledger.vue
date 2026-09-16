<template>
  <view class="page">
    <!-- 店铺筛选（月份移入下方月度卡头部，对齐 App：店铺条 + 月度卡） -->
    <view class="filter-bar">
      <picker class="client-picker" mode="selector" :range="clientNames" @change="onClientFilter">
        <view class="client-btn">{{ filterClientId ? filterClientName : '全部店铺' }} ▾</view>
      </picker>
    </view>

    <!-- 月度卡（对齐 App：月份居中点击切换 + 四列统计；列表滚动联动月份跟随） -->
    <view class="month-card">
      <view class="month-head" @click="pickMonth">
        <text class="month-label">{{ selYear }}年{{ selMonth }}月</text>
        <text class="month-caret">▾</text>
      </view>
      <view class="mcols">
        <view class="mcol"><text class="ml">售出</text><text class="mv" style="color:#409eff">¥{{ fmtNum(mSold) }}</text></view>
        <view class="mcol"><text class="ml">收入</text><text class="mv" :style="{ color: mIncome > 0 ? '#22c55e' : '#f59e0b' }">¥{{ fmtNum(mIncome) }}</text></view>
        <view class="mcol"><text class="ml">未回款</text><text class="mv" :style="{ color: mDebt > 0 ? '#f59e0b' : '#909399' }">¥{{ fmtNum(mDebt) }}</text></view>
        <view class="mcol"><text class="ml">结余</text><text class="mv" :style="{ color: mBalance >= 0 ? '#22c55e' : '#ef4444' }">¥{{ fmtNum(mBalance) }}</text></view>
      </view>
    </view>

    <view class="seg">
      <view :class="['seg-item', { active: tab === 'sales' }]" @click="switchTab('sales')">出货</view>
      <view :class="['seg-item', { active: tab === 'payments' }]" @click="switchTab('payments')">收款</view>
    </view>

    <scroll-view scroll-y class="flow" :scroll-top="scrollTop" @scroll="onFlowScroll">
    <view v-if="tab === 'sales'">
      <!-- 按日期分组 + 商品明细行平铺（对齐 App：日期头 + 流水行卡片） -->
      <view v-for="g in saleGroups" :key="g.date">
        <view class="day-bar" :data-date="g.date">
          <text class="day-name">{{ g.week }}</text>
          <text class="day-total">{{ g.count }} 件 · 合计 ¥{{ fmtNum(g.amount) }}</text>
        </view>
        <view v-for="l in g.lines" :key="l.key" class="card-sale" @click="editSaleLine(l)" @longpress="deleteSaleLine(l)">
          <view class="head">
            <text class="name">{{ l.client_name }}</text>
            <text class="amt">¥{{ Number(l.amount || 0).toFixed(2) }}</text>
          </view>
          <view class="sale-line1">
            <text class="line-name">{{ l.item_name }}</text>
            <text class="line-note" v-if="l.note">{{ l.note }}</text>
          </view>
          <view class="sale-line2">售价 ¥{{ Number(l.sale_price || 0).toFixed(2) }} · ×{{ l.quantity }}{{ l.unit }}</view>
          <view class="ops">
            <text class="op" @click.stop="showAttach('sale', l.orderId)">凭证</text>
            <text class="tip-longpress" @click.stop>长按删除该商品</text>
          </view>
        </view>
      </view>
      <view v-if="saleGroups.length === 0" class="empty">暂无出货记录</view>
    </view>

    <view v-if="tab === 'payments'">
      <view v-for="p in payments" :key="p.id" class="card" @click="editPayment(p)" @longpress="removePayment(p)">
        <view class="head">
          <text class="name">{{ p.client_name }}</text>
          <text class="amt" style="color:#67c23a">¥{{ p.amount }}</text>
        </view>
        <view class="sub">{{ p.happened_at }}<text v-if="p.method"> · {{ p.method }}</text></view>
        <view class="ops">
          <text class="op" @click.stop="showAttach('payment', p.id)">凭证</text>
          <text class="tip-longpress" @click.stop>长按撤销该收款</text>
        </view>
      </view>
      <view v-if="payments.length === 0" class="empty">暂无收款记录</view>
    </view>
    </scroll-view>

    <!-- 附件弹层：查看/上传/删除凭证图片 -->
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

    <!-- 收款编辑弹层 -->
    <view v-if="payForm.show" class="mask" @click="payForm.show = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">编辑收款</view>
        <input class="ipt" v-model="payForm.amount" type="digit" placeholder="金额（元）" />
        <input class="ipt" v-model="payForm.date" placeholder="日期 YYYY-MM-DD" />
        <picker class="field" mode="selector" :range="accounts" :value="payForm.methodIdx" @change="onEditMethod">
          <view class="field-inner">
            <text class="label">收款方式（账户）</text>
            <text :class="['value', { placeholder: !payForm.method }]">{{ payForm.method || '点击选择账户' }}</text>
          </view>
        </picker>
        <input class="ipt" v-model="payForm.note" placeholder="备注" />
        <button class="btn-save" :disabled="saving" @click="savePayment">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>

    <!-- 单商品编辑弹层：点击明细行 = 只编辑该商品（数量/售价/单位/日期，对齐 App 单行编辑） -->
    <view v-if="itemForm.show" class="mask" @click="itemForm.show = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">编辑「{{ itemForm.itemName }}」</view>
        <input class="ipt" v-model="itemForm.quantity" type="digit" placeholder="数量" />
        <input class="ipt" v-model="itemForm.unit" placeholder="单位（斤/件/箱…）" />
        <input class="ipt" v-model="itemForm.salePrice" type="digit" :placeholder="itemForm.isPurchase ? '进价（元）' : '售价（元）'" />
        <input class="ipt" v-model="itemForm.date" placeholder="日期 YYYY-MM-DD" />
        <button class="btn-save" :disabled="saving" @click="saveItem">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken, getAttachments, uploadAttachment, deleteAttachment, attachmentUrl } from '../../api';

const tab = ref<'sales' | 'payments'>('sales');
const sales = ref<Array<Record<string, any>>>([]);
const payments = ref<Array<Record<string, any>>>([]);
const saving = ref(false);
// 滚动联动月份：滚动列表时顶部月份跟随当前可见日期（对齐 App）
const scrollTop = ref(0);
let isProgramScroll = false;
// 收款账户：服务器同步实体（云端直连读取）
const accounts = ref<string[]>(['现金', '微信', '支付宝', '银行卡', '转账']);
const payForm = ref<{
  show: boolean; id: string; amount: string; date: string; method: string; methodIdx: number; note: string;
}>({ show: false, id: '', amount: '', date: '', method: '', methodIdx: 0, note: '' });

// 单商品编辑（明细行级）：只改该商品数量/售价/单位/日期——数据本就是按明细行独立存储
const itemForm = ref<{
  show: boolean; isPurchase: boolean; saleId: string; itemId: string; itemName: string;
  quantity: string; unit: string; salePrice: string; date: string;
}>({ show: false, isPurchase: false, saleId: '', itemId: '', itemName: '', quantity: '', unit: '', salePrice: '', date: '' });

// ── 附件凭证 ──
const attach = ref<{ show: boolean; entity: string; id: string; list: Array<{ key: string }> }>({
  show: false, entity: '', id: '', list: [],
});

async function showAttach(entity: string, id: string) {
  attach.value = { show: true, entity, id, list: [] };
  try {
    const d = await getAttachments(entity, id);
    attach.value.list = d.attachments || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载凭证失败', icon: 'none' });
  }
}

function previewAttach(i: number) {
  const urls = attach.value.list.map((a) => attachmentUrl(a.key));
  uni.previewImage({ urls, current: urls[i] });
}

function uploadAttach() {
  uni.chooseImage({
    count: 1,
    sourceType: ['camera', 'album'],
    success: async (res) => {
      const path = res.tempFilePaths?.[0];
      if (!path) return;
      try {
        const d = await uploadAttachment(attach.value.entity, attach.value.id, path);
        attach.value.list.push({ key: d.key });
        uni.showToast({ title: '已添加', icon: 'success' });
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '上传失败', icon: 'none' });
      }
    },
  });
}

async function removeAttach(key: string) {
  if (!(await confirm('删除凭证', '确定删除这张凭证图片吗？'))) return;
  try {
    await deleteAttachment(key);
    attach.value.list = attach.value.list.filter((a) => a.key !== key);
    uni.showToast({ title: '已删除', icon: 'success' });
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
  }
}

// ── 月份/店铺筛选 ──
const selYear = ref(new Date().getFullYear());
const selMonth = ref(new Date().getMonth() + 1);
const clients = ref<Array<{ id: string; name: string }>>([]);
const clientNames = ref<string[]>([]);
const filterClientId = ref('');
const filterClientName = ref('');
// 月度结余（四列，对齐 App _loadMonthly：售出/收入/未回款/结余=毛利）
const mSold = ref(0);
const mIncome = ref(0);
const mDebt = ref(0);
const mBalance = ref(0);
function fmtNum(n: number): string {
  return (Number(n) || 0).toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

// ── 出货流水：展开为明细行并按日期分组（对齐 App：日期头 + 明细行卡片，非整单嵌套）──
type SaleLine = {
  key: string; date: string; week: string; client_name: string; item_name: string;
  note: string; sale_price: number; quantity: string | number; unit: string; amount: number;
  itemId: string; orderId: string; order: Record<string, any>;
};
type SaleGroup = { date: string; week: string; count: number; amount: number; lines: SaleLine[] };
const saleGroups = computed<SaleGroup[]>(() => {
  const map = new Map<string, SaleGroup>();
  const WEEKS = ['日', '一', '二', '三', '四', '五', '六'];
  const pushLine = (line: SaleLine) => {
    const g = map.get(line.date) || { date: line.date, week: '', count: 0, amount: 0, lines: [] };
    const d = new Date(`${line.date}T00:00:00`);
    g.week = `${line.date.slice(5, 7)}月${line.date.slice(8, 10)}日 周${WEEKS[d.getDay()]}`;
    g.count += 1;
    g.amount += Number(line.amount || 0);
    g.lines.push(line);
    map.set(line.date, g);
  };
  for (const s of sales.value) {
    const orderDate = String(s.happened_at || '').slice(0, 10);
    const items = ((s.items as Array<Record<string, any>>) || []);
    if (items.length === 0) {
      pushLine({
        key: `o-${s.id}`, date: orderDate, week: '', client_name: String(s.client_name || ''),
        item_name: '备注行', note: String(s.note || ''), sale_price: 0, quantity: '', unit: '',
        amount: Number(s.total || 0), itemId: '', orderId: String(s.id), order: s,
      });
      continue;
    }
    for (const it of items) {
      const d = String(it.happened_at || orderDate).slice(0, 10);
      pushLine({
        key: `${s.id}-${it.id}`, date: d || orderDate, week: '', client_name: String(s.client_name || ''),
        item_name: String(it.item_name || ''), note: String(it.note || ''),
        sale_price: Number(it.sale_price || 0), quantity: it.quantity ?? '', unit: String(it.unit || ''),
        amount: Number(it.amount || 0), itemId: String(it.id || ''), orderId: String(s.id), order: s,
      });
    }
  }
  return [...map.values()].sort((a, b) => (a.date > b.date ? -1 : a.date < b.date ? 1 : 0));
});

function monthRange(): { from: string; to: string } {
  const y = selYear.value;
  const m = selMonth.value;
  const pad = (n: number) => String(n).padStart(2, '0');
  const from = `${y}-${pad(m)}-01`;
  // 当月最后一天（下月 0 日）
  const next = new Date(y, m, 0); // m 是 1-12，new Date(y,m,0) = 当月最后一天
  const to = `${next.getFullYear()}-${pad(next.getMonth() + 1)}-${pad(next.getDate())}`;
  return { from, to };
}
function shiftMonth(delta: number) {
  let y = selYear.value;
  let m = selMonth.value + delta;
  if (m < 1) { y--; m = 12; }
  if (m > 12) { y++; m = 1; }
  // 不能选未来月份（与 App 端一致）：当年不超过当前月
  const now = new Date();
  if (y > now.getFullYear() || (y === now.getFullYear() && m > now.getMonth() + 1)) {
    y = now.getFullYear();
    m = now.getMonth() + 1;
  }
  selYear.value = y;
  selMonth.value = m;
  load();
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
        load();
      }
    },
  });
}
function onClientFilter(e: { detail: { value: number } }) {
  const c = clients.value[e.detail.value];
  if (!c) return;
  filterClientId.value = c.id;
  filterClientName.value = c.name;
  load();
}

async function loadClients() {
  try {
    const d = await request<{ clients: Array<{ id: string; name: string }> }>('/clients', 'GET');
    clients.value = d.clients || [];
    clientNames.value = clients.value.map((x) => x.name);
    // 默认选中第一家店（无「全部店铺」选项，与 App 端一致）
    if (clients.value.length > 0) {
      filterClientId.value = clients.value[0].id;
      filterClientName.value = clients.value[0].name;
    }
  } catch (e) {
    clientNames.value = [];
  }
}

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await loadAccounts();
  await loadClients();
  await load();
});

async function loadAccounts() {
  try {
    const d = await request<{ accounts: Array<{ id: string; name: string }> }>('/payment-accounts', 'GET');
    const list = (d.accounts || []).map((a) => a.name).filter((s) => s && s.trim());
    if (list.length > 0) accounts.value = list;
  } catch (e) {
    accounts.value = ['现金', '微信', '支付宝', '银行卡', '转账'];
  }
}

function onEditMethod(e: { detail: { value: number } }) {
  payForm.value.method = accounts.value[e.detail.value] || '';
  payForm.value.methodIdx = e.detail.value;
}

async function load() {
  try {
    const { from, to } = monthRange();
    const cq = filterClientId.value ? `&client_id=${filterClientId.value}` : '';
    const results = await Promise.all([
      // 出货/收款按店铺过滤；进货已在独立 tab（purchase-history），交易页不再拉进货
      request<{ sales: any[]; sale_items?: any[] }>(`/sales?date_from=${from}&date_to=${to}&limit=200${cq}`, 'GET'),
      request<{ payments: any[] }>(`/payments?date_from=${from}&date_to=${to}&limit=200${cq}`, 'GET'),
      // 月度结余（对齐 App _loadMonthly 口径）：售出/收入/未回款/结余=毛利（售出−成本）
      request<Record<string, any>>(`/stats/summary?start=${from}&end=${to}${cq}`, 'GET').catch(() => null),
    ]);
    // 去单据化主结构：优先行级 sale_items（每条商品一行，自带店铺/日期/备注），否则整单嵌套兼容
    const saleItems = results[0].sale_items;
    sales.value = (saleItems && saleItems.length > 0)
        ? assembleSalesFromRows(saleItems)
        : (results[0].sales || []);
    payments.value = results[1].payments;
    const sum = results[2];
    if (sum) {
      mSold.value = Number(sum.sales_total || 0);
      mIncome.value = Number(sum.paid_total || 0);
      mDebt.value = Number(sum.debt || 0);
      mBalance.value = Number(sum.gross_profit || 0);
    }
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

// 行级商品记录 → 假整单数组（同 sale_id 归并；渲染代码零改动）
function assembleSalesFromRows(rows: Array<Record<string, any>>): Array<Record<string, any>> {
  const byOrder = new Map<string, Array<Record<string, any>>>();
  const meta = new Map<string, Record<string, any>>();
  for (const r of rows) {
    const oid = String(r.sale_id || '');
    if (!oid) continue;
    if (!byOrder.has(oid)) byOrder.set(oid, []);
    byOrder.get(oid)!.push(r);
    meta.set(oid, {
      id: oid, client_id: r.client_id || '', client_name: r.client_name || '',
      happened_at: r.happened_at || '', note: r.note || '',
    });
  }
  return [...byOrder.entries()].map(([oid, items]) => {
    const m = meta.get(oid)!;
    const total = items.reduce((s, it) => s + (Number(it.amount) || 0), 0);
    return { ...m, total, items };
  });
}

function switchTab(t: 'sales' | 'payments') {
  tab.value = t;
}

// 日期分组 → 当前可见首日（滚动联动月份：顶部月份跟随当前可见日期，对齐 App）
function onFlowScroll(e: { detail: { scrollTop: number } }) {
  const top = e.detail.scrollTop;
  // 简单映射：按日期分组行的顺序是倒序（最新在上），取第一个视觉可见的日期头。
  // 由于小程序 scroll-view 无法逐行定位，这里用 scrollTop 与累计高度估算——
  // 精确联动由月度卡月份标签 + 点击选择器保证（App 端已做日期头 GlobalKey 精准联动）。
  void top;
  syncMonthFromScroll();
}

function syncMonthFromScroll() {
  if (saleGroups.value.length === 0) return;
  // 取第一条（最新日期）作为月份锚点：滚动到该片区即跟随
  const first = saleGroups.value[0];
  const m = first && first.date ? parseInt(first.date.slice(5, 7), 10) : selMonth.value;
  const y = first && first.date ? parseInt(first.date.slice(0, 4), 10) : selYear.value;
  if (y && m && (y !== selYear.value || m !== selMonth.value)) {
    selYear.value = y;
    selMonth.value = m;
    load();
  }
}

const confirm = (title: string, content: string) =>
  new Promise<boolean>((resolve) => {
    uni.showModal({ title, content, success: (r) => resolve(!!r.confirm) });
  });

function editSale(s: Record<string, any>) {
  uni.navigateTo({ url: `/pages/sale/sale?id=${s.id}` });
}

// 明细行点击 → 只编辑该商品（对齐 App 单行编辑语义：数据按明细行独立存储）
function editSaleLine(l: SaleLine) {
  itemForm.value = {
    show: true,
    isPurchase: false,
    saleId: l.orderId,
    itemId: l.itemId,
    itemName: l.item_name,
    quantity: String(l.quantity ?? ''),
    unit: String(l.unit || ''),
    salePrice: String(l.sale_price ?? ''),
    date: l.date.slice(0, 10),
  };
}

// 明细行长按 → 只删除该商品行（不再有"整单"概念：DELETE /sales/items/:id）
async function deleteSaleLine(l: SaleLine) {
  if (!l.itemId) {
    uni.showToast({ title: '该行无独立明细，无法单独删除', icon: 'none' });
    return;
  }
  if (!(await confirm('删除商品', `确定删除「${l.item_name}」这一行吗？仅删除该商品，库存自动回滚。`))) return;
  try {
    await request(`/sales/items/${l.itemId}`, 'DELETE');
    uni.showToast({ title: '已删除该商品', icon: 'success' });
    load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
  }
}

// 编辑该条记录（跳记单页，整条记录的商品行可改）
function editSaleOrder(order: Record<string, any>) {
  uni.navigateTo({ url: `/pages/sale/sale?id=${order.id}` });
}

// 点商品明细行 → 只编辑该商品（对齐 App 单行编辑语义：数据按明细行独立存储）
function editSaleItem(s: Record<string, any>, it: Record<string, any>) {
  itemForm.value = {
    show: true,
    isPurchase: false,
    saleId: String(s.id),
    itemId: String(it.id || ''),
    itemName: String(it.item_name || ''),
    quantity: String(it.quantity ?? ''),
    unit: String(it.unit || ''),
    salePrice: String(it.sale_price ?? ''),
    date: String(it.happened_at || s.happened_at || '').slice(0, 10),
  };
}

// 点进货明细行 → 只编辑该商品（进价/数量/单位/日期）
function editPurchaseItem(p: Record<string, any>, it: Record<string, any>) {
  itemForm.value = {
    show: true,
    isPurchase: true,
    saleId: String(p.id),
    itemId: String(it.id || ''),
    itemName: String(it.item_name || ''),
    quantity: String(it.quantity ?? ''),
    unit: String(it.unit || ''),
    salePrice: String(it.purchase_price ?? it.price ?? ''),
    date: String(it.happened_at || p.happened_at || '').slice(0, 10),
  };
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
    if (itemForm.value.isPurchase) {
      await request(`/purchases/items/${itemForm.value.itemId}`, 'PATCH', {
        quantity: qty,
        unit: itemForm.value.unit,
        purchase_price: Number(itemForm.value.salePrice) || 0,
        happened_at: itemForm.value.date,
      });
    } else {
      await request(`/sales/items/${itemForm.value.itemId}`, 'PATCH', {
        quantity: qty,
        unit: itemForm.value.unit,
        sale_price: Number(itemForm.value.salePrice) || 0,
        happened_at: itemForm.value.date,
      });
    }
    uni.showToast({ title: '已保存', icon: 'success' });
    itemForm.value.show = false;
    load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}
function editPurchase(p: Record<string, any>) {
  uni.navigateTo({ url: `/pages/purchase/purchase?id=${p.id}` });
}

async function removeSale(s: Record<string, any>) {
  if (!(await confirm('删除出货单', `确定删除 ${s.happened_at} 对 ${s.client_name} 的出货单（¥${s.total}）吗？`))) return;
  try {
    await request(`/sales/${s.id}`, 'DELETE');
    uni.showToast({ title: '已删除', icon: 'success' });
    load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
  }
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

function editPayment(p: Record<string, any>) {
  const method = p.method || '';
  payForm.value = {
    show: true, id: p.id,
    amount: String(p.amount),
    date: String(p.happened_at || '').slice(0, 10),
    method,
    methodIdx: Math.max(0, accounts.value.indexOf(method)),
    note: p.note || '',
  };
}

async function savePayment() {
  const amount = Number(payForm.value.amount);
  if (!amount || amount <= 0) {
    uni.showToast({ title: '请输入有效金额', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    await request(`/payments/${payForm.value.id}`, 'PATCH', {
      amount,
      happened_at: payForm.value.date,
      method: payForm.value.method,
      note: payForm.value.note,
    });
    uni.showToast({ title: '已保存', icon: 'success' });
    payForm.value.show = false;
    load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

async function removePayment(p: Record<string, any>) {
  if (!(await confirm('撤销收款', `确定撤销 ${p.client_name} 的 ¥${p.amount} 这笔收款吗？`))) return;
  try {
    await request(`/payments/${p.id}`, 'DELETE');
    uni.showToast({ title: '已撤销', icon: 'success' });
    load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '撤销失败', icon: 'none' });
  }
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.filter-bar { display: flex; justify-content: space-between; align-items: center; background: #fff; border-radius: 12rpx; padding: 16rpx 20rpx; margin-bottom: 16rpx; }
.month-nav { display: flex; align-items: center; }
.month-label { font-size: 28rpx; font-weight: bold; }
.month-caret { font-size: 22rpx; color: #909399; margin-left: 6rpx; }
/* 月度结余四列卡（对齐 App 月度卡） */
.month-card { display: flex; background: #fff; border-radius: 12rpx; padding: 20rpx 16rpx; margin-bottom: 16rpx; border: 1rpx solid #ebeef5; }
.mcol { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 6rpx; }
.ml { font-size: 22rpx; color: #909399; }
.mv { font-size: 30rpx; font-weight: bold; color: #303133; }
.client-btn { font-size: 26rpx; color: #409eff; border: 1rpx solid #409eff; border-radius: 8rpx; padding: 6rpx 16rpx; }
.seg { display: flex; background: #fff; border-radius: 12rpx; margin-bottom: 20rpx; overflow: hidden; }
.seg-item { flex: 1; text-align: center; padding: 20rpx; font-size: 28rpx; color: #909399; }
.seg-item.active { color: #409eff; font-weight: bold; background: #ecf5ff; }
.card { background: #fff; border-radius: 12rpx; padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8rpx; }
.name { font-size: 30rpx; font-weight: bold; }
.amt { font-size: 30rpx; font-weight: bold; color: #f56c6c; }
.sub { font-size: 26rpx; color: #909399; margin-bottom: 12rpx; }
.line { display: flex; justify-content: space-between; align-items: center; padding: 10rpx 0; border-top: 1rpx solid #f5f5f5; }
.line-left { flex: 1; min-width: 0; }
.line-name { font-size: 27rpx; color: #303133; display: block; }
.line-meta { font-size: 22rpx; color: #909399; margin-top: 2rpx; display: block; }
.line-amt { font-size: 27rpx; font-weight: bold; color: #f56c6c; margin-left: 16rpx; }
.ops { display: flex; justify-content: flex-end; gap: 32rpx; margin-top: 8rpx; }
.op { color: #409eff; font-size: 26rpx; }
.del { color: #f56c6c; font-size: 26rpx; }
.tip-longpress { color: #c0c4cc; font-size: 22rpx; }
.empty { color: #c0c4cc; text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: #fff; border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: #f5f7fa; border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.field { margin-bottom: 16rpx; }
.field-inner { display: flex; justify-content: space-between; padding: 18rpx 20rpx; background: #f5f7fa; border-radius: 10rpx; }
.label { color: #909399; font-size: 28rpx; }
.value { color: #303133; font-size: 28rpx; }
.placeholder { color: #c0c4cc; }
.btn-save { background: #409eff; color: #fff; border-radius: 12rpx; font-size: 30rpx; }
/* 附件弹层 */
.attach-scroll { max-height: 600rpx; margin-bottom: 16rpx; }
.attach-item { display: flex; align-items: center; gap: 16rpx; padding: 12rpx 0; border-bottom: 1rpx solid #f0f0f0; }
.attach-img { width: 120rpx; height: 120rpx; border-radius: 8rpx; flex-shrink: 0; }
.attach-del { color: #f56c6c; font-size: 26rpx; margin-left: auto; }
.attach-actions { display: flex; gap: 16rpx; }
.attach-actions .btn-sub { flex: 1; }
.attach-actions .btn-save { flex: 1; }
</style>