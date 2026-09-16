<template>
  <view class="page">
    <!-- 月份（点击切换）+ 月度支出卡（对齐 App 进货页：仅支出统计） -->
    <view class="month-card">
      <view class="month-head" @click="pickMonth">
        <text class="month-label">{{ selYear }}年{{ selMonth }}月</text>
        <text class="month-caret">▾</text>
      </view>
      <view class="mexpense">
        <text class="ml">本月进货支出</text>
        <text class="mv red">¥{{ fmt(mExpense) }}</text>
      </view>
    </view>

    <view v-for="p in purchases" :key="p.id" class="card">
      <view class="head">
        <text class="name">{{ p.happened_at }} 进货</text>
        <text class="amt">¥{{ Number(p.total || 0).toFixed(2) }}</text>
      </view>
      <view v-for="it in (p.items || [])" :key="it.id" class="line" @click="editPurchaseItem(p, it)" @longpress="deletePurchaseLine(p, it)">
        <view class="line-left">
          <text class="line-name">{{ it.item_name }}</text>
          <text class="line-meta">进价 ¥{{ Number(it.purchase_price || it.price || 0).toFixed(2) }} · ×{{ it.quantity }}{{ it.unit }}<text v-if="it.note"> · {{ it.note }}</text></text>
        </view>
        <text class="line-amt">¥{{ Number(it.amount || 0).toFixed(2) }}</text>
      </view>
      <view v-if="(p.items || []).length === 0" class="line"><text class="line-name">备注行</text></view>
      <view class="ops">
        <text class="op" @click="showAttach(p.id)">凭证</text>
        <text class="tip-longpress">长按删除该商品</text>
      </view>
    </view>
    <view v-if="purchases.length === 0" class="empty">该月暂无进货记录</view>

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
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken, getAttachments, uploadAttachment, deleteAttachment, attachmentUrl } from '../../api';

const selYear = ref(new Date().getFullYear());
const selMonth = ref(new Date().getMonth() + 1);
const purchases = ref<Array<Record<string, any>>>([]);
const mExpense = ref(0);
const saving = ref(false);
const fmt = (n: number) => Number(n || 0).toFixed(2);

const itemForm = ref<{
  show: boolean; orderId: string; itemId: string; itemName: string;
  quantity: string; unit: string; salePrice: string; date: string;
}>({ show: false, orderId: '', itemId: '', itemName: '', quantity: '', unit: '', salePrice: '', date: '' });

const attach = ref<{ show: boolean; id: string; list: Array<{ key: string }> }>({ show: false, id: '', list: [] });

onShow(async () => {
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

async function load() {
  try {
    const { from, to } = monthRange();
    const results = await Promise.all([
      request<{ purchases: any[]; purchase_items?: any[] }>(`/purchases?date_from=${from}&date_to=${to}&limit=200`, 'GET'),
      request<Record<string, any>>(`/stats/summary?start=${from}&end=${to}`, 'GET').catch(() => null),
    ]);
    // 去单据化主结构：优先行级 purchase_items（每条商品一行），否则整单嵌套兼容
    const purchaseItems = results[0].purchase_items;
    purchases.value = (purchaseItems && purchaseItems.length > 0)
        ? assembleFromRows(purchaseItems)
        : (results[0].purchases || []);
    const sum = results[1];
    if (sum) mExpense.value = Number(sum.purchase_total || 0);
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
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
    meta.set(oid, { id: oid, happened_at: r.happened_at || '', note: r.note || '' });
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

async function showAttach(id: string) {
  attach.value = { show: true, id, list: [] };
  try {
    const d = await getAttachments('purchase', id);
    attach.value.list = d.attachments || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载附件失败', icon: 'none' });
  }
}

function previewAttach(i: number) {
  const urls = attach.value.list.map((a) => attachmentUrl(a.key));
  uni.previewImage({ urls, current: urls[i] });
}

async function uploadAttach() {
  const id = attach.value.id;
  uni.chooseImage({
    count: 1,
    success: async (r) => {
      const path = r.tempFilePaths[0];
      try {
        await uploadAttachment('purchase', id, path);
        uni.showToast({ title: '已上传', icon: 'success' });
        const d = await getAttachments('purchase', id);
        attach.value.list = d.attachments || [];
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
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
  }
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.month-card { background: #fff; border-radius: 16rpx; padding: 20rpx 24rpx; margin-bottom: 20rpx; border: 1rpx solid #ebeef5; }
.month-head { display: flex; align-items: center; justify-content: center; margin-bottom: 14rpx; }
.month-label { font-size: 30rpx; font-weight: bold; color: #303133; }
.month-caret { font-size: 22rpx; color: #909399; margin-left: 6rpx; }
.mexpense { display: flex; justify-content: space-between; align-items: center; }
.ml { font-size: 24rpx; color: #909399; }
.mv { font-size: 34rpx; font-weight: bold; }
.red { color: #f56c6c; }
.card { background: #fff; border-radius: 12rpx; padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8rpx; }
.name { font-size: 30rpx; font-weight: bold; }
.amt { font-size: 30rpx; font-weight: bold; color: #f56c6c; }
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
.btn-save { background: #409eff; color: #fff; border-radius: 12rpx; font-size: 30rpx; }
.attach-scroll { max-height: 600rpx; margin-bottom: 16rpx; }
.attach-item { display: flex; align-items: center; gap: 16rpx; padding: 12rpx 0; border-bottom: 1rpx solid #f0f0f0; }
.attach-img { width: 120rpx; height: 120rpx; border-radius: 8rpx; flex-shrink: 0; }
.attach-del { color: #f56c6c; font-size: 26rpx; margin-left: auto; }
.attach-actions { display: flex; gap: 16rpx; }
.attach-actions .btn-sub { flex: 1; }
.attach-actions .btn-save { flex: 1; }
</style>