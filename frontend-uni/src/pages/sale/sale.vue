<template>
  <view class="page">
    <!-- 头部：饭店 / 日期 / 复制上一笔 -->
    <view class="head-row">
      <picker class="field" mode="selector" :range="clientNames" @change="onClient">
        <view class="field-inner">
          <text class="label">饭店</text>
          <text :class="['value', { placeholder: !clientId }]">{{ clientId ? clientName : '请选择饭店' }}</text>
        </view>
      </picker>
      <picker class="field" mode="date" :value="date" @change="onDate">
        <view class="field-inner">
          <text class="label">日期</text>
          <text class="value">{{ date }}</text>
        </view>
      </picker>
      <button class="copy-btn" :disabled="loading" @click="copyLast">复制上一笔</button>
      <button class="ai-btn" :disabled="aiBusy" @click="aiMenu">AI 记账</button>
    </view>

    <!-- AI 识别状态（识别中 / 语音原文） -->
    <view v-if="aiBusy" class="ai-tip">{{ aiTip }}</view>

    <!-- 明细行 -->
    <view v-for="(row, i) in rows" :key="i" class="row">
      <picker class="picker" mode="selector" :range="itemNames" @change="(e) => onItem(i, e.detail.value)">
        <view class="mini-field">{{ row.itemName || '选商品' }}</view>
      </picker>
      <picker class="picker" mode="selector" :range="row.priceLabels" @change="(e) => onPrice(i, e.detail.value)">
        <view class="mini-field">{{ row.priceLabel || '单位' }}</view>
      </picker>
      <input class="num" type="digit" v-model="row.quantity" placeholder="数量" />
      <input class="num" type="digit" v-model="row.salePrice" placeholder="单价" />
      <text class="amt">¥{{ rowAmount(row) }}</text>
      <text class="del" @click="rows.splice(i, 1)">删</text>
    </view>

    <view class="footer">
      <button class="btn-add" @click="addRow">+ 添加商品</button>
      <text class="total">合计 <text class="total-num">¥{{ total }}</text></text>
    </view>
    <button class="btn-submit" :disabled="saving" @click="submit">{{ saving ? '提交中…' : (editId ? '保存修改' : '提交出货单') }}</button>
  </view>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue';
import { onLoad, onShow } from '@dcloudio/uni-app';
import { request, getToken, uploadAi } from '../../api';

interface Price { id: string; unit: string; sale_price: number; purchase_price: number }
interface Item { id: string; name: string; prices: Price[] }
interface Row {
  itemId: string; itemName: string; prices: Price[];
  priceId: string; priceLabel: string; unit: string;
  quantity: string; salePrice: string; countQty: string;
}

const clientId = ref('');
const clientName = ref('');
const clientNames = ref<string[]>([]);
const clients = ref<Array<{ id: string; name: string }>>([]);
const items = ref<Item[]>([]);
const itemNames = ref<string[]>([]);
const date = ref('');
const rows = ref<Row[]>([]);
const saving = ref(false);
const loading = ref(false);
const editId = ref(''); // 非空 = 编辑已有出货单（账本进入，提交走 PATCH）
const aiBusy = ref(false);
const aiTip = ref('');

onLoad((options) => {
  editId.value = options?.id || '';
  if (editId.value) uni.setNavigationBarTitle({ title: '编辑出货单' });
});

const total = computed(() =>
  rows.value.reduce((s, r) => s + (Number(r.quantity) || 0) * (Number(r.salePrice) || 0), 0),
);
const rowAmount = (r: Row) => ((Number(r.quantity) || 0) * (Number(r.salePrice) || 0)).toFixed(2);

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  date.value = todayLocal();
  // 加载饭店与商品（懒加载，进入页面即拉取）
  try {
    const [c, i] = await Promise.all([
      request<{ clients: Array<{ id: string; name: string }> }>('/clients', 'GET'),
      request<{ items: Item[] }>('/items/summary', 'GET'),
    ]);
    clients.value = c.clients;
    clientNames.value = c.clients.map((x) => x.name);
    items.value = i.items;
    itemNames.value = i.items.map((x) => x.name);
    if (rows.value.length === 0) addRow();
    if (editId.value) await loadEdit();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
});

/// 编辑模式预填：GET /sales/:id → 按 item_id+unit 匹配现有价格回填行
async function loadEdit() {
  try {
    const d = await request<{ client_id: string; happened_at: string; items: Array<Record<string, any>> }>(`/sales/${editId.value}`, 'GET');
    const c = clients.value.find((x) => x.id === d.client_id);
    if (c) { clientId.value = c.id; clientName.value = c.name; }
    date.value = String(d.happened_at || '').slice(0, 10);
    rows.value = [];
    for (const it of d.items) {
      const item = items.value.find((x) => x.id === it.item_id);
      const price = item?.prices.find((p) => p.unit === it.unit);
      if (!item || !price) continue;
      rows.value.push({
        itemId: item.id, itemName: item.name, prices: item.prices,
        priceId: price.id, priceLabel: `${price.unit}（¥${price.sale_price}·库存${price.stock ?? 0}）`, unit: price.unit,
        quantity: String(it.quantity), salePrice: String(it.sale_price), countQty: it.count_qty ? String(it.count_qty) : '',
      });
    }
    if (rows.value.length === 0) {
      rows.value = [];
      addRow();
    }
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载单据失败', icon: 'none' });
  }
}

function todayLocal(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/// 复制上一笔出货单：读最近一单预填店铺/日期/明细（可修改后提交）
async function copyLast() {
  if (loading.value) return;
  loading.value = true;
  try {
    const d = await request<{ sales: Array<{ client_id: string; happened_at: string; items: Array<Record<string, any>> }> }>('/sales?limit=1', 'GET');
    const last = d.sales?.[0];
    if (!last) {
      uni.showToast({ title: '暂无历史出货单', icon: 'none' });
      return;
    }
    const c = clients.value.find((x) => x.id === last.client_id);
    if (c) { clientId.value = c.id; clientName.value = c.name; }
    date.value = String(last.happened_at || '').slice(0, 10);
    rows.value = [];
    for (const it of last.items || []) {
      const item = items.value.find((x) => x.id === it.item_id);
      const price = item?.prices.find((p) => p.unit === it.unit);
      if (!item || !price) continue;
      rows.value.push({
        itemId: item.id, itemName: item.name, prices: item.prices,
        priceId: price.id, priceLabel: `${price.unit}（¥${price.sale_price}·库存${price.stock ?? 0}）`, unit: price.unit,
        quantity: String(it.quantity), salePrice: String(it.sale_price), countQty: it.count_qty ? String(it.count_qty) : '',
      });
    }
    if (rows.value.length === 0) addRow();
    uni.showToast({ title: '已复制上一笔，可修改后提交', icon: 'none' });
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '复制失败', icon: 'none' });
  } finally {
    loading.value = false;
  }
}

function onClient(e: { detail: { value: number } }) {
  const c = clients.value[e.detail.value];
  if (c) { clientId.value = c.id; clientName.value = c.name; }
}

/// AI 记账三入口：拍照识别 / 文字记账 / 语音记账（后端 /ai/parse-*，返回商品草稿填行）
function aiMenu() {
  uni.showActionSheet({
    itemList: ['拍照识别单据', '文字记账', '语音记账'],
    success: (r) => {
      if (r.tapIndex === 0) aiPhoto();
      else if (r.tapIndex === 1) aiText();
      else aiVoice();
    },
    fail: () => {},
  });
}

/// 拍照识别：选图/拍照 → /ai/parse-photo（multipart photo）
function aiPhoto() {
  uni.chooseImage({
    count: 1,
    sizeType: ['compressed'],
    sourceType: ['camera', 'album'],
    success: async (res) => {
      const fp = res.tempFilePaths?.[0];
      if (!fp) return;
      aiBusy.value = true;
      aiTip.value = 'AI 识别中…';
      try {
        const d = await uploadAi<{ items?: Array<Record<string, any>> }>(`/ai/parse-photo?purpose=sale`, 'photo', fp);
        fillFromDrafts(d.items || []);
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '识别失败', icon: 'none' });
      } finally {
        aiBusy.value = false;
      }
    },
  });
}

/// 文字记账：弹框一句话 → /ai/parse-text（JSON {text}）
function aiText() {
  uni.showModal({
    title: '文字记账（一句话描述出货）',
    editable: true,
    placeholderText: '例：白菜50斤 3元一斤，土豆30斤 2元一斤',
    success: async (r) => {
      const text = (r.content || '').trim();
      if (!r.confirm || !text) return;
      aiBusy.value = true;
      aiTip.value = 'AI 解析中…';
      try {
        const d = await request<{ items?: Array<Record<string, any>> }>(`/ai/parse-text?purpose=sale`, 'POST', { text });
        fillFromDrafts(d.items || []);
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '识别失败', icon: 'none' });
      } finally {
        aiBusy.value = false;
      }
    },
  });
}

/// 语音记账：录音 → /ai/parse-voice（multipart audio，语音转文字后解析）
function aiVoice() {
  uni.authorize({
    scope: 'scope.record',
    success: () => startVoiceRecord(),
    fail: () => uni.showToast({ title: '需要麦克风权限才能语音记账', icon: 'none' }),
  });
}
function startVoiceRecord() {
  const rec = uni.getRecorderManager();
  rec.onStart(() => {
    aiBusy.value = true;
    aiTip.value = '录音中…点「停止」结束';
  });
  rec.onStop(async (res) => {
    const fp = (res as { tempFilePath?: string }).tempFilePath;
    if (!fp) {
      aiBusy.value = false;
      uni.showToast({ title: '录音失败', icon: 'none' });
      return;
    }
    aiTip.value = 'AI 识别中…';
    try {
      const d = await uploadAi<{ text?: string; items?: Array<Record<string, any>> }>(`/ai/parse-voice?purpose=sale`, 'audio', fp);
      if (d.text) uni.showToast({ title: `语音识别：${d.text}`, icon: 'none', duration: 2500 });
      fillFromDrafts(d.items || []);
    } catch (e) {
      uni.showToast({ title: (e as Error).message || '识别失败', icon: 'none' });
    } finally {
      aiBusy.value = false;
    }
  });
  rec.start({ format: 'mp3', duration: 60000 });
  uni.showModal({
    title: '正在录音',
    content: '开始说话描述出货，说完点「停止」',
    showCancel: false,
    confirmText: '停止',
    success: () => rec.stop(),
  });
}

/// AI 识别结果 → 匹配已有商品填行（拍照/文字/语音共用）
function fillFromDrafts(list: Array<Record<string, any>>) {
  if (!list || list.length === 0) {
    uni.showToast({ title: '未识别到商品，请手动填写', icon: 'none' });
    return;
  }
  let filled = 0;
  for (const raw of list) {
    const name = String(raw.name ?? '').trim();
    const qty = Number(raw.quantity) || 0;
    const price = Number(raw.price) || 0;
    const unit = String(raw.unit ?? '').trim();
    const match = items.value.find((it) => it.name === name || it.name.includes(name) || name.includes(it.name));
    if (!match) continue;
    const pr = (unit ? match.prices.find((p) => p.unit === unit) : undefined) || match.prices[0];
    if (!pr) continue;
    const row = rows.value.find((r) => !r.itemId) || rows.value[rows.value.length - 1];
    if (row.itemId) rows.value.push({ itemId: '', itemName: '', prices: [], priceId: '', priceLabel: '', unit: '', quantity: '', salePrice: '', countQty: '' });
    const target = row.itemId ? rows.value[rows.value.length - 1] : row;
    target.itemId = match.id;
    target.itemName = match.name;
    target.prices = match.prices;
    target.priceId = pr.id;
    target.unit = pr.unit;
    target.priceLabel = `${pr.unit}（¥${pr.sale_price}·库存${pr.stock ?? 0}）`;
    target.quantity = qty > 0 ? String(qty) : '1';
    target.salePrice = price > 0 ? String(price) : String(pr.sale_price);
    filled++;
  }
  uni.showToast({ title: filled > 0 ? `已导入 ${filled} 项商品，可修改后提交` : '识别结果未匹配到已有商品，请手动填写', icon: 'none' });
}
function onDate(e: { detail: { value: string } }) {
  date.value = e.detail.value;
}

function addRow() {
  rows.value.push({ itemId: '', itemName: '', prices: [], priceId: '', priceLabel: '', unit: '', quantity: '', salePrice: '', countQty: '' });
}

function onItem(i: number, idx: number) {
  const it = items.value[idx];
  const row = rows.value[i];
  if (!it) return;
  row.itemId = it.id;
  row.itemName = it.name;
  row.prices = it.prices;
  row.priceId = '';
  row.priceLabel = '';
  row.unit = '';
  row.salePrice = '';
}
function onPrice(i: number, idx: number) {
  const p = rows.value[i].prices[idx];
  if (!p) return;
  const row = rows.value[i];
  row.priceId = p.id;
  row.unit = p.unit;
  row.priceLabel = `${p.unit}（¥${p.sale_price}·库存${p.stock ?? 0}）`;
  row.salePrice = String(p.sale_price);
}

async function submit() {
  if (!clientId.value) return uni.showToast({ title: '请选择饭店', icon: 'none' });
  const valid = rows.value.filter((r) => r.itemId && r.priceId && Number(r.quantity) > 0);
  if (valid.length === 0) return uni.showToast({ title: '请填写完整的商品明细', icon: 'none' });
  saving.value = true;
  try {
    const body = {
      client_id: clientId.value,
      happened_at: date.value,
      items: valid.map((r) => ({ price_id: r.priceId, quantity: Number(r.quantity), count_qty: Number(r.countQty) > 0 ? Number(r.countQty) : null, sale_price: Number(r.salePrice) || 0 })),
    };
    if (editId.value) {
      await request(`/sales/${editId.value}`, 'PATCH', body);
      uni.showToast({ title: '已保存修改', icon: 'success' });
    } else {
      await request('/sales', 'POST', body);
      uni.showToast({ title: `已提交 ¥${total.value.toFixed(2)}`, icon: 'success' });
      rows.value = [];
      addRow();
    }
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '提交失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}
</script>

<style>
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.head-row { display: flex; gap: 12rpx; align-items: flex-start; margin-bottom: 16rpx; }
.head-row .field { flex: 1; background: #fff; border-radius: 12rpx; padding: 24rpx; }
.head-row .field-inner { flex-direction: column; align-items: flex-start; gap: 6rpx; }
.copy-btn { flex-shrink: 0; background: #fff; color: #409eff; border: 1rpx solid #409eff; border-radius: 12rpx; font-size: 26rpx; padding: 0 20rpx; height: 88rpx; line-height: 88rpx; }
.ai-btn { flex-shrink: 0; background: #fff; color: #7c4dff; border: 1rpx solid #7c4dff; border-radius: 12rpx; font-size: 26rpx; padding: 0 20rpx; height: 88rpx; line-height: 88rpx; }
.ai-tip { background: #f0ecff; color: #7c4dff; border-radius: 12rpx; padding: 16rpx 24rpx; margin-bottom: 16rpx; font-size: 26rpx; }
.field { background: #fff; border-radius: 12rpx; padding: 24rpx; margin-bottom: 16rpx; }
.field-inner { display: flex; justify-content: space-between; }
.label { color: #909399; }
.value { color: #303133; }
.placeholder { color: #c0c4cc; }
.row {
  display: flex; align-items: center; gap: 12rpx;
  background: #fff; border-radius: 12rpx; padding: 16rpx; margin-bottom: 12rpx;
}
.picker { flex: 1; min-width: 0; }
.mini-field {
  background: #f5f7fa; border-radius: 8rpx; padding: 12rpx; font-size: 24rpx; text-align: center;
  overflow: hidden; white-space: nowrap; text-overflow: ellipsis;
}
.num { width: 90rpx; background: #f5f7fa; border-radius: 8rpx; padding: 12rpx; font-size: 24rpx; text-align: center; }
.amt { width: 110rpx; font-size: 24rpx; color: #f56c6c; }
.del { color: #f56c6c; font-size: 24rpx; padding: 8rpx; }
.footer { display: flex; justify-content: space-between; align-items: center; margin: 20rpx 0; }
.btn-add { font-size: 28rpx; }
.total { font-size: 28rpx; }
.total-num { color: #f56c6c; font-weight: bold; font-size: 34rpx; }
.btn-submit { background: #409eff; color: #fff; border-radius: 12rpx; font-size: 32rpx; }
</style>