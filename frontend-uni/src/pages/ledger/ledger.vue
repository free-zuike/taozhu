<template>
  <view class="page">
    <!-- 筛选栏：月份（点击切换，对齐 App 无左右箭头）+ 店铺筛选 -->
    <view class="filter-bar">
      <view class="month-nav" @click="pickMonth">
        <text class="month-label">{{ selYear }}年{{ selMonth }}月</text>
        <text class="month-caret">▾</text>
      </view>
      <picker class="client-picker" mode="selector" :range="clientNames" @change="onClientFilter">
        <view class="client-btn">{{ filterClientId ? filterClientName : '全部店铺' }} ▾</view>
      </picker>
    </view>

    <!-- 月度结余卡（四列，对齐 App：售出/收入/未回款/结余） -->
    <view class="month-card">
      <view class="mcol"><text class="ml">售出</text><text class="mv">¥{{ fmtNum(mSold) }}</text></view>
      <view class="mcol"><text class="ml">收入</text><text class="mv" :style="{ color: mIncome > 0 ? '#22c55e' : '#f59e0b' }">¥{{ fmtNum(mIncome) }}</text></view>
      <view class="mcol"><text class="ml">未回款</text><text class="mv" :style="{ color: mDebt > 0 ? '#f59e0b' : '#909399' }">¥{{ fmtNum(mDebt) }}</text></view>
      <view class="mcol"><text class="ml">结余</text><text class="mv" :style="{ color: mBalance >= 0 ? '#22c55e' : '#ef4444' }">¥{{ fmtNum(mBalance) }}</text></view>
    </view>

    <view class="seg">
      <view :class="['seg-item', { active: tab === 'sales' }]" @click="switchTab('sales')">出货</view>
      <view :class="['seg-item', { active: tab === 'purchases' }]" @click="switchTab('purchases')">进货</view>
      <view :class="['seg-item', { active: tab === 'payments' }]" @click="switchTab('payments')">收款</view>
    </view>

    <view v-if="tab === 'sales'">
      <!-- 商品明细行平铺卡片（对齐 App 流水行：每个商品一张卡，含店铺/日期/价格行/操作） -->
      <view v-for="s in sales" :key="s.id" class="card">
        <view class="head">
          <text class="name">{{ s.client_name }}</text>
          <text class="amt">¥{{ Number(s.total || 0).toFixed(2) }}</text>
        </view>
        <view class="sub">{{ s.happened_at }}</view>
        <view v-for="it in (s.items || [])" :key="it.id" class="line" @click="editSaleItem(s, it)">
          <view class="line-left">
            <text class="line-name">{{ it.item_name }}</text>
            <text class="line-meta">售价 ¥{{ Number(it.sale_price || 0).toFixed(2) }} · ×{{ it.quantity }}{{ it.unit }}<text v-if="it.note"> · {{ it.note }}</text></text>
          </view>
          <text class="line-amt">¥{{ Number(it.amount || 0).toFixed(2) }}</text>
        </view>
        <view v-if="(s.items || []).length === 0" class="line"><text class="line-name">备注行</text></view>
        <view class="ops">
          <text class="op" @click="showAttach('sale', s.id)">凭证</text>
          <text class="op" @click="editSale(s)">编辑整单</text>
          <text class="del" @click="removeSale(s)">删除</text>
        </view>
      </view>
      <view v-if="sales.length === 0" class="empty">暂无出货记录</view>
    </view>

    <view v-if="tab === 'purchases'">
      <view v-for="p in purchases" :key="p.id" class="card">
        <view class="head">
          <text class="name">{{ p.happened_at }} 进货</text>
          <text class="amt">¥{{ p.total }}</text>
        </view>
        <view v-for="it in (p.items || [])" :key="it.id" class="line" @click="editPurchaseItem(p, it)">
          <view class="line-left">
            <text class="line-name">{{ it.item_name }}</text>
            <text class="line-meta">进价 ¥{{ Number(it.purchase_price || it.price || 0).toFixed(2) }} · ×{{ it.quantity }}{{ it.unit }}<text v-if="it.note"> · {{ it.note }}</text></text>
          </view>
          <text class="line-amt">¥{{ Number(it.amount || 0).toFixed(2) }}</text>
        </view>
        <view v-if="(p.items || []).length === 0" class="line"><text class="line-name">备注行</text></view>
        <view class="ops">
          <text class="op" @click="showAttach('purchase', p.id)">凭证</text>
          <text class="op" @click="editPurchase(p)">编辑</text>
          <text class="del" @click="removePurchase(p)">删除</text>
        </view>
      </view>
      <view v-if="purchases.length === 0" class="empty">暂无进货记录</view>
    </view>

    <view v-if="tab === 'payments'">
      <view v-for="p in payments" :key="p.id" class="card">
        <view class="head">
          <text class="name">{{ p.client_name }}</text>
          <text class="amt" style="color:#67c23a">¥{{ p.amount }}</text>
        </view>
        <view class="sub">{{ p.happened_at }}<text v-if="p.method"> · {{ p.method }}</text></view>
        <view class="ops">
          <text class="op" @click="showAttach('payment', p.id)">凭证</text>
          <text class="op" @click="editPayment(p)">编辑</text>
          <text class="del" @click="removePayment(p)">删除</text>
        </view>
      </view>
      <view v-if="payments.length === 0" class="empty">暂无收款记录</view>
    </view>

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
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken, getAttachments, uploadAttachment, deleteAttachment, attachmentUrl } from '../../api';

const tab = ref<'sales' | 'purchases' | 'payments'>('sales');
const sales = ref<Array<Record<string, any>>>([]);
const purchases = ref<Array<Record<string, any>>>([]);
const payments = ref<Array<Record<string, any>>>([]);
const saving = ref(false);
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
      request<{ sales: any[] }>(`/sales?date_from=${from}&date_to=${to}&limit=200${cq}`, 'GET'),
      // 进货不分店（全店通用，与 App 端一致）：仅按月份过滤
      request<{ purchases: any[] }>(`/purchases?date_from=${from}&date_to=${to}&limit=200`, 'GET'),
      request<{ payments: any[] }>(`/payments?date_from=${from}&date_to=${to}&limit=200${cq}`, 'GET'),
      // 月度结余（对齐 App _loadMonthly 口径）：售出/收入/未回款/结余=毛利（售出−成本）
      request<Record<string, any>>(`/stats/summary?start=${from}&end=${to}${cq}`, 'GET').catch(() => null),
    ]);
    sales.value = results[0].sales;
    purchases.value = results[1].purchases;
    payments.value = results[2].payments;
    const sum = results[3];
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

function switchTab(t: 'sales' | 'purchases' | 'payments') {
  tab.value = t;
}

const confirm = (title: string, content: string) =>
  new Promise<boolean>((resolve) => {
    uni.showModal({ title, content, success: (r) => resolve(!!r.confirm) });
  });

function editSale(s: Record<string, any>) {
  uni.navigateTo({ url: `/pages/sale/sale?id=${s.id}` });
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
    uni.showToast({ title: '该行无独立明细，请用「编辑」整单修改', icon: 'none' });
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