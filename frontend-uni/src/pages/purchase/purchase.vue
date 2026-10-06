<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="head-row">
      <picker v-if="!isDateRows" class="field" mode="date" :value="date" @change="onDate">
        <view class="field-inner">
          <text class="label">日期</text>
          <text class="value">{{ date }}</text>
        </view>
      </picker>
      <picker v-if="isDateRows" class="field" mode="date" :value="date" @change="onDate">
        <view class="field-inner">
          <text class="label">批量日期（全部行改期）</text>
          <text class="value">{{ date }}</text>
        </view>
      </picker>
      <button v-if="!isDateRows" class="copy-btn" :disabled="loading" @click="copyLast">复制上一笔</button>
      <button v-if="!isDateRows" class="ai-btn" :disabled="aiBusy" @click="aiMenu">AI 记账</button>
      <text v-if="isDateRows" class="batch-hint">该日 {{ rows.length }} 行 · 保存按原单分组提交</text>
    </view>

    <!-- AI 识别状态（识别中 / 语音原文） -->
    <view v-if="aiBusy" class="ai-tip">{{ aiTip }}</view>

    <view v-for="(row, i) in rows" :key="i" class="row">
      <view class="row-main">
        <picker class="picker" mode="selector" :range="itemNames" @change="(e) => onItem(i, e.detail.value)">
          <view class="mini-field">{{ row.itemName || '选商品' }}</view>
        </picker>
        <picker class="picker" mode="selector" :range="row.priceLabels" @change="(e) => onPrice(i, e.detail.value)">
          <view class="mini-field">{{ row.priceLabel || '单位' }}</view>
        </picker>
        <input class="num" type="digit" v-model="row.quantity" placeholder="数量" />
        <input class="num" type="digit" v-model="row.purchasePrice" placeholder="进价" />
        <input v-if="row.countUnit" class="num count" type="digit" v-model="row.countQty" :placeholder="`折${row.countUnit}`" />
        <picker class="date-pick" mode="date" :value="row.happenedAt || date" @change="(e) => (row.happenedAt = e.detail.value)">
          <view class="mini-field">{{ row.happenedAt ? row.happenedAt.slice(5) : '日期' }}</view>
        </picker>
        <text class="amt">¥{{ rowAmount(row) }}</text>
        <text class="del" @click="rows.splice(i, 1)">删</text>
      </view>
      <input class="row-note" v-model="row.note" placeholder="行备注（选填）" />
    </view>
    <input class="ipt-note" v-model="note" placeholder="整单备注（选填，如：供应商/送货单号…）" />

    <!-- 底部固定悬浮栏（对齐 App：合计+添加+提交固定在底部） -->
    <view class="bottom-bar">
      <view class="footer">
        <button class="btn-add" @click="addRow">+ 添加商品</button>
        <button class="btn-voucher" @click="pickVoucher">{{ pendingPhoto ? '✓ 凭证已选' : '📎 凭证' }}</button>
        <text class="total">合计 <text class="total-num">¥{{ fmtAmount(total) }}</text></text>
      </view>
      <button class="btn-submit" :disabled="saving" @click="submit">{{ saving ? '提交中…' : (isDateRows ? '保存该日修改' : (editId ? '保存修改' : '提交进货单')) }}</button>
    </view>

    <!-- 新商品入库弹窗（分类两级联动：先一级后二级，对齐 App；未匹配商品不静默丢弃） -->
    <view v-if="newItemDlg" class="mask" @click="newItemDlg = false">
      <view class="sheet" @click.stop>
        <text class="s-title">新商品入库</text>
        <text class="s-sub">「{{ newPending.join('、') }}」不在商品库，是否加入？</text>
        <picker class="pk" mode="selector" :range="newTopNames" :value="newTopIdx" @change="onNewTop">
          <view class="pk-inner">
            <text class="label">一级分类</text>
            <text :class="['value', { placeholder: newTopIdx === 0 }]">{{ newTopNames[newTopIdx] || '未分类' }}</text>
          </view>
        </picker>
        <picker v-if="newTopIdx > 0" class="pk" mode="selector" :range="newSubNames" :value="newSubIdx" @change="onNewSub">
          <view class="pk-inner">
            <text class="label">二级分类</text>
            <text :class="['value', { placeholder: newSubIdx === 0 }]">{{ newSubNames[newSubIdx] || '未分类' }}</text>
          </view>
        </picker>
        <view class="dlg-ops">
          <button class="btn-cancel" @click="newItemDlg = false; newItemResolve(false)">不加入</button>
          <button class="btn-ok" @click="doCreateNewItems()">加入商品库</button>
        </view>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { useThemeVars } from '../../theme';
const { tv, patternSrc } = useThemeVars();
import { computed, ref } from 'vue';
import { onLoad, onShow, onHide } from '@dcloudio/uni-app';
import { request, getToken, uploadAi, uploadAttachment } from '../../api';
import { fmtAmount, initRounding } from '../../utils/money';
import { onWs, offWs } from '../../ws';

interface Price { id: string; unit: string; sale_price: number; purchase_price: number; stock?: number }
interface Item { id: string; name: string; prices: Price[]; count_unit?: string }
interface Row {
  itemId: string; itemName: string; prices: Price[];
  priceId: string; priceLabel: string; unit: string;
  quantity: string; purchasePrice: string; countQty: string;
  countUnit: string; // 商品计数单位（袋/个…，有才显示折合计数输入框）
  happenedAt: string; // 行独立日期（缺省用单据日期；对齐 App 行级日期）
  note: string; // 行级备注（缺省空；对齐 App 行备注）
  rowId: string; // 原明细行 id（dateRows 批量编辑保留，保存时不换 id=附件不孤儿）
  orderId: string; // 原进货单 id（dateRows 按原单分组 PATCH）
}

const items = ref<Item[]>([]);
const itemNames = ref<string[]>([]);
const date = ref('');
const note = ref(''); // 整单备注（对齐 App：单据级备注，提交时挂各行）
const rows = ref<Row[]>([]);
const saving = ref(false);
const loading = ref(false);
const editId = ref(''); // 非空 = 编辑已有进货单（账本进入，提交走 PATCH）
const isDateRows = ref(false); // 批量直编模式=进货历史某日进入（该日全部行平铺，按原单分组 PATCH，对齐 App dateRows）
const aiBusy = ref(false);
const aiTip = ref('');
// 识别原图/手动凭证：暂存待提交后上传为本单凭证（服务器单据级 purchase/{id}，进货历史行级入口查空回退单据级可见）
const pendingPhoto = ref('');

// 新商品入库弹窗（两级分类联动，对齐 App：一级分类 → 二级分类）
const newItemDlg = ref(false);
const newPending = ref<string[]>([]);
const newCats = ref<Array<{ id: string; name: string; parent_id?: string }>>([]);
const newTopIdx = ref(0); // 0=未分类
const newSubIdx = ref(0);
let newItemResolve: (v: boolean) => void = () => {};
const newTopList = computed(() => newCats.value.filter((c) => !c.parent_id));
const newTopNames = computed(() => ['未分类', ...newTopList.value.map((c) => c.name)]);
const newSubList = computed(() => {
  const top = newTopList.value[newTopIdx.value - 1];
  return top ? newCats.value.filter((c) => c.parent_id === top.id) : [];
});
const newSubNames = computed(() => ['未分类', ...newSubList.value.map((c) => c.name)]);
function onNewTop(e: any) { newTopIdx.value = Number(e.detail.value); newSubIdx.value = 0; }
function onNewSub(e: any) { newSubIdx.value = Number(e.detail.value); }

onLoad((options) => {
  editId.value = options?.id || '';
  if (editId.value) uni.setNavigationBarTitle({ title: '编辑进货单' });
  // 批量直编（对齐 App dateRows）：进货历史日期栏进入，该日全部行平铺、按原单分组 PATCH
  if (options?.dateRows === '1' && options?.date) {
    isDateRows.value = true;
    date.value = options.date;
    uni.setNavigationBarTitle({ title: `批量编辑 ${options.date.slice(5)}` });
  }
});

// 金额舍入配置变更（其他端改设置）→ 先刷新本地口径再触发页面重渲（合计/行金额按新位数显示）
onShow(() => onWs('rounding', refreshRounding));
onHide(() => offWs('rounding', refreshRounding));
function refreshRounding() {
  rows.value = [...rows.value]; // 浅拷贝触发模板重渲（fmtAmount 读最新本地口径）
}

const total = computed(() =>
  rows.value.reduce((s, r) => s + (Number(r.quantity) || 0) * (Number(r.purchasePrice) || 0), 0),
);
const rowAmount = (r: Row) => fmtAmount((Number(r.quantity) || 0) * (Number(r.purchasePrice) || 0));

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  initRounding(); // 金额舍入口径（展示/本地预览按配置，服务器为最终权威）
  if (!isDateRows.value) date.value = todayLocal(); // dateRows 模式保持传入的批量日期
  try {
    const i = await request<{ items: Item[] }>('/items/summary', 'GET');
    items.value = i.items;
    itemNames.value = i.items.map((x) => x.name);
    if (rows.value.length === 0 && !isDateRows.value) addRow();
    if (isDateRows.value) {
      await loadDateRows();
    } else if (editId.value) {
      await loadEdit();
    }
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
});

/// 编辑模式预填：GET /purchases/:id → 按 item_id+unit 匹配现有价格回填行
async function loadEdit() {
  try {
    const d = await request<{ happened_at: string; items: Array<Record<string, any>> }>(`/purchases/${editId.value}`, 'GET');
    date.value = String(d.happened_at || '').slice(0, 10);
    rows.value = [];
    for (const it of d.items) {
      const item = items.value.find((x) => x.id === it.item_id);
      const price = item?.prices.find((p) => p.unit === it.unit);
      if (!item || !price) continue;
      rows.value.push({
        itemId: item.id, itemName: item.name, prices: item.prices,
        priceId: price.id, priceLabel: `${price.unit}（进 ¥${price.purchase_price}·库存${price.stock ?? 0}）`, unit: price.unit,
        quantity: String(it.quantity), purchasePrice: String(it.purchase_price), countQty: it.count_qty ? String(it.count_qty) : '',
        countUnit: String(item.count_unit || ''),
        happenedAt: String(it.happened_at || '').slice(0, 10), note: String(it.note || ''),
        rowId: '', orderId: '',
      });
    }
    if (rows.value.length === 0) {
      rows.value = [];
      addRow();
    }
    // 整单备注 = 首行备注（后端 MIN(note) 聚合语义）
    const first = d.items?.[0];
    if (first && first.note) note.value = String(first.note);
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载单据失败', icon: 'none' });
  }
}

function todayLocal(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/// 复制上一笔进货单：读最近一单预填日期/明细（可修改后提交）
async function copyLast() {
  if (loading.value) return;
  loading.value = true;
  try {
    const d = await request<{ purchases: Array<{ happened_at: string; items: Array<Record<string, any>> }> }>('/purchases?limit=1', 'GET');
    const last = d.purchases?.[0];
    if (!last) {
      uni.showToast({ title: '暂无历史进货单', icon: 'none' });
      return;
    }
    date.value = String(last.happened_at || '').slice(0, 10);
    rows.value = [];
    for (const it of last.items || []) {
      const item = items.value.find((x) => x.id === it.item_id);
      const price = item?.prices.find((p) => p.unit === it.unit);
      if (!item || !price) continue;
      rows.value.push({
        itemId: item.id, itemName: item.name, prices: item.prices,
        priceId: price.id, priceLabel: `${price.unit}（¥${price.purchase_price}·库存${(price as any).stock ?? 0}）`, unit: price.unit,
        quantity: String(it.quantity), purchasePrice: String(it.purchase_price), countQty: it.count_qty ? String(it.count_qty) : '',
        countUnit: String(item.count_unit || ''),
        happenedAt: String(it.happened_at || '').slice(0, 10), note: String(it.note || ''),
        rowId: '', orderId: '',
      });
    }
    if (rows.value.length === 0) addRow();
    const first = last.items?.[0];
    if (first && first.note) note.value = String(first.note);
    uni.showToast({ title: '已复制上一笔，可修改后提交', icon: 'none' });
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '复制失败', icon: 'none' });
  } finally {
    loading.value = false;
  }
}

function addRow() {
  rows.value.push({ itemId: '', itemName: '', prices: [], priceId: '', priceLabel: '', unit: '', quantity: '', purchasePrice: '', countQty: '', countUnit: '', happenedAt: '', note: '', rowId: '', orderId: '' });
}

const skippedRef = ref(0); // dateRows 加载被跳过的商品行数（商品已删/停用）

/// 批量直编加载（对齐 App dateRows）：该日全部行平铺。行保留原行 id/原单 id：
/// 保存按原单分组 PATCH（items 带原 id 不换 id=行级附件不孤儿）；被删行=不提交即整体替换移除
async function loadDateRows() {
  try {
    const d = await request<{ purchase_items?: Array<Record<string, any>>; purchases?: Array<Record<string, any>> }>(
      `/purchases?date_from=${date.value}&date_to=${date.value}&limit=1000`, 'GET');
    const itemRows = d.purchase_items && d.purchase_items.length > 0 ? d.purchase_items : [];
    const nested = d.purchases || [];
    let lines: Array<Record<string, any>> = itemRows;
    if (lines.length === 0) {
      lines = [];
      for (const s of nested) {
        for (const it of ((s.items as Array<Record<string, any>>) || [])) {
          lines.push({ ...it, purchase_id: s.id, happened_at: it.happened_at || s.happened_at });
        }
      }
    }
    rows.value = [];
    for (const l of lines) {
      const rowId = String(l.id || '');
      const orderId = String(l.purchase_id || '');
      const item = items.value.find((x) => x.id === String(l.item_id || ''));
      const unit = String(l.unit || '');
      const price = item?.prices.find((p) => p.unit === unit) || item?.prices[0];
      if (!item || !price) { skippedRef.value++; continue; }
      rows.value.push({
        itemId: item.id, itemName: item.name, prices: item.prices,
        priceId: price.id, priceLabel: `${price.unit}（进 ¥${price.purchase_price}·库存${price.stock ?? 0}）`, unit: price.unit,
        quantity: String(l.quantity ?? ''), purchasePrice: String(l.purchase_price ?? price.purchase_price),
        countQty: l.count_qty ? String(l.count_qty) : '', countUnit: String(item.count_unit || ''),
        happenedAt: String(l.happened_at || '').slice(0, 10), note: String(l.note || ''),
        rowId, orderId,
      });
    }
    if (rows.value.length === 0) addRow();
    if (skippedRef.value > 0) {
      uni.showToast({ title: `有 ${skippedRef.value} 条商品已删除或价格停用，保存后将移除`, icon: 'none', duration: 2500 });
    }
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载当日记录失败', icon: 'none' });
  }
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
        const d = await uploadAi<{ items?: Array<Record<string, any>> }>(`/ai/parse-photo?purpose=purchase`, 'photo', fp);
        pendingPhoto.value = fp; // 识别原图：提交成功后才上传为本单凭证（对齐全量同步/进货历史单据级凭证）
        fillFromDrafts(d.items || [], String(d.date ?? ''));;
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
    title: '文字记账（一句话描述进货）',
    editable: true,
    placeholderText: '例：白菜50斤 3元一斤，土豆30斤 2元一斤',
    success: async (r) => {
      const text = (r.content || '').trim();
      if (!r.confirm || !text) return;
      aiBusy.value = true;
      aiTip.value = 'AI 解析中…';
      try {
        const d = await request<{ items?: Array<Record<string, any>> }>(`/ai/parse-text?purpose=purchase`, 'POST', { text });
        fillFromDrafts(d.items || [], String(d.date ?? ''));;
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
      const d = await uploadAi<{ text?: string; items?: Array<Record<string, any>> }>(`/ai/parse-voice?purpose=purchase`, 'audio', fp);
      if (d.text) uni.showToast({ title: `语音识别：${d.text}`, icon: 'none', duration: 2500 });
      fillFromDrafts(d.items || [], String(d.date ?? ''));;
    } catch (e) {
      uni.showToast({ title: (e as Error).message || '识别失败', icon: 'none' });
    } finally {
      aiBusy.value = false;
    }
  });
  rec.start({ format: 'mp3', duration: 60000 });
  uni.showModal({
    title: '正在录音',
    content: '开始说话描述进货，说完点「停止」',
    showCancel: false,
    confirmText: '停止',
    success: () => rec.stop(),
  });
}

/// AI 识别结果 → 匹配已有商品填行（拍照/文字/语音共用）
function fillFromDrafts(list: Array<Record<string, any>>, date = '') {
  // 日期回填（识别出的单据日期 YYYY-MM-DD，进货无购货单位字段）
  if (date && /^\d{4}-\d{2}-\d{2}$/.test(date)) date.value = date;
  if (!list || list.length === 0) {
    uni.showToast({ title: '未识别到商品，请手动填写', icon: 'none' });
    return;
  }
  let filled = 0;
  let unmatched = 0;
  for (const raw of list) {
    const name = String(raw.name ?? '').trim();
    const qty = Number(raw.quantity) || 0;
    const price = Number(raw.price) || 0;
    const unit = String(raw.unit ?? '').trim();
    const match = items.value.find((it) => it.name === name || it.name.includes(name) || name.includes(it.name));
    let row = rows.value.find((r) => !r.itemId && !r.itemName);
    if (!row) {
      rows.value.push({ itemId: '', itemName: '', prices: [], priceId: '', priceLabel: '', unit: '', quantity: '', purchasePrice: '', countQty: '', countUnit: '', happenedAt: '', note: '', rowId: '', orderId: '' });
      row = rows.value[rows.value.length - 1];
    }
    if (match) {
      const pr = (unit ? match.prices.find((p) => p.unit === unit) : undefined) || match.prices[0];
      if (pr) {
        row.itemId = match.id;
        row.itemName = match.name;
        row.prices = match.prices;
        row.countUnit = String(match.count_unit || '');
        row.priceId = pr.id;
        row.unit = pr.unit;
        row.priceLabel = `${pr.unit}（进 ¥${pr.purchase_price}·库存${pr.stock ?? 0}）`;
        row.quantity = qty > 0 ? String(qty) : '1';
        row.purchasePrice = price > 0 ? String(price) : String(pr.purchase_price);
        filled++;
        continue;
      }
    }
    // 未匹配商品库（或单位无匹配）：名称/单位/数量/单价照填（是否入库由用户提交时决定，不自动建）
    unmatched++;
    row.itemId = '';
    row.itemName = name;
    row.unit = unit;
    row.quantity = qty > 0 ? String(qty) : '1';
    row.purchasePrice = price > 0 ? String(price) : '';
  }
  uni.showToast({ title: filled > 0 ? `已导入 ${filled} 项商品${unmatched > 0 ? `（${unmatched} 项不在商品库，名称已填入待确认）` : ''}，可修改后提交` : (unmatched > 0 ? `已填入 ${unmatched} 项商品名称（不在商品库），可修改后提交` : '识别结果未匹配到已有商品，请手动填写'), icon: 'none' });
}

function onDate(e: { detail: { value: string } }) {
  date.value = e.detail.value;
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
  row.purchasePrice = '';
}
function onPrice(i: number, idx: number) {
  const p = rows.value[i].prices[idx];
  if (!p) return;
  const row = rows.value[i];
  row.priceId = p.id;
  row.unit = p.unit;
  row.priceLabel = `${p.unit}（进 ¥${p.purchase_price}·库存${p.stock ?? 0}）`;
  row.purchasePrice = String(p.purchase_price);
  row.countUnit = String(rows.value[i].itemName ? (items.value.find((it) => it.name === row.itemName)?.count_unit || '') : '');
}

/// 手动添加凭证：选图暂存，提交成功随单上传（对齐 App「整单凭证」）
function pickVoucher() {
  uni.chooseImage({
    count: 1,
    sizeType: ['compressed'],
    sourceType: ['camera', 'album'],
    success: (res) => {
      const fp = res.tempFilePaths?.[0];
      if (!fp) return;
      pendingPhoto.value = fp;
      uni.showToast({ title: '凭证已选，提交后上传', icon: 'none' });
    },
  });
}

/// 新商品入库：识别/手输未匹配名称提交时弹窗（不静默丢弃，对齐 App）。
/// 弹窗带两级分类选择（对齐 App：一级分类 → 二级分类），不再硬编码无分类（修"items 页分类空白"）。
async function ensureNewItems(): Promise<boolean> {
  const newNames = [
    ...new Set(
      rows.value.filter((r) => r.itemName?.trim() && !r.itemId).map((r) => r.itemName.trim()),
    ),
  ];
  if (newNames.length === 0) return true;
  const me = await request<{ user?: { role?: string } }>('/auth/me', 'GET').catch(() => null);
  if (me?.user?.role === 'staff') {
    uni.showToast({ title: `「${newNames.join('、')}」不在商品库，请让老板先添加`, icon: 'none' });
    return false;
  }
  // 加载商品分类目录（两级；失败不阻塞，未分类也可入库）
  try {
    const d = await request<{ categories: Array<{ id: string; name: string; parent_id?: string }> }>('/categories?type=item', 'GET');
    newCats.value = (d.categories || []).filter((c) => c.name && c.name.trim());
  } catch (_) {
    newCats.value = [];
  }
  newTopIdx.value = 0;
  newSubIdx.value = 0;
  newPending.value = newNames;
  newItemDlg.value = true;
  return await new Promise<boolean>((resolve) => { newItemResolve = resolve; });
}

/// 弹窗"加入商品库"：按所选一级/二级分类创建商品（category=名称快照、category_id=id 关联）
async function doCreateNewItems() {
  const top = newTopList.value[newTopIdx.value - 1];
  const sub = newSubList.value[newSubIdx.value - 1];
  const catId = sub?.id || top?.id || '';
  const catName = sub?.name || top?.name || '';
  try {
    for (const r of rows.value) {
      const name = r.itemName?.trim();
      if (!name || r.itemId) continue;
      const d = await request<{ id: string; prices?: unknown[] | string[] }>('/items', 'POST', {
        name,
        category: catName,
        category_id: catId,
        prices: [{ unit: r.unit || '件', purchase_price: Number(r.purchasePrice) || 0, sale_price: 0 }],
      });
      const pid = (d.prices as string[] | undefined)?.[0] || ((d.prices as unknown[] | undefined) as Array<{ id: string }> | undefined)?.[0]?.id || '';
      r.itemId = d.id;
      r.priceId = pid as string;
      items.value.push({ id: d.id, name, prices: [{ id: pid as string, unit: r.unit || '件', purchase_price: Number(r.purchasePrice) || 0, sale_price: 0 }] });
      itemNames.value.push(name);
    }
    newItemDlg.value = false;
    newItemResolve(true);
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '创建商品失败', icon: 'none' });
    newItemResolve(false);
  }
}

async function submit() {
  if (!(await ensureNewItems())) return;
  const valid = rows.value.filter((r) => r.itemId && r.priceId && Number(r.quantity) > 0);
  if (valid.length === 0) return uni.showToast({ title: '请填写完整的商品明细', icon: 'none' });
  saving.value = true;
  try {
    if (isDateRows.value) {
      // 批量直编（对齐 App dateRows）：按原单分组 PATCH（items 带原行 id 不换 id=行级附件不孤儿）；
      // 不传整单 note（防清空）；进货无店铺维度（无 client_id）
      const byOrder = new Map<string, Array<Row>>();
      for (const r of valid) {
        const oid = r.orderId || '';
        if (!oid) continue;
        const list = byOrder.get(oid);
        if (list) list.push(r);
        else byOrder.set(oid, [r]);
      }
      const submittedIds = new Set(valid.map((r) => r.rowId).filter(Boolean));
      const origIds = new Set<string>();
      for (const oid of byOrder.keys()) {
        const d = await request<{ purchase_items?: Array<Record<string, any>>; purchases?: Array<Record<string, any>> }>(`/purchases/${oid}`, 'GET');
        const lines = ((d.purchase_items?.length ?? 0) > 0 ? d.purchase_items : (d.purchases?.[0]?.items || [])) as Array<Record<string, any>>;
        for (const l of lines) {
          const lid = String(l.id || '');
          if (lid) origIds.add(lid);
        }
      }
      for (const [oid, rowList] of byOrder.entries()) {
        await request(`/purchases/${oid}`, 'PATCH', {
          happened_at: date.value,
          items: rowList.map((r) => ({
            id: r.rowId || undefined,
            price_id: r.priceId,
            quantity: Number(r.quantity),
            count_qty: Number(r.countQty) > 0 ? Number(r.countQty) : null,
            purchase_price: Number(r.purchasePrice) || 0,
            happened_at: r.happenedAt || date.value,
            note: r.note || '',
          })),
        });
      }
      const newRows = valid.filter((r) => !r.orderId);
      if (newRows.length > 0) {
        await request('/purchases', 'POST', {
          happened_at: date.value,
          note: note.value.trim(),
          items: newRows.map((r) => ({ price_id: r.priceId, quantity: Number(r.quantity), count_qty: Number(r.countQty) > 0 ? Number(r.countQty) : null, purchase_price: Number(r.purchasePrice) || 0, happened_at: r.happenedAt || date.value, note: r.note || '' })),
        });
      }
      for (const lid of origIds) {
        if (!submittedIds.has(lid)) {
          try { await request(`/purchases/items/${lid}`, 'DELETE'); } catch (_) {}
        }
      }
      uni.showToast({ title: '已保存该日全部修改', icon: 'success' });
      await new Promise((r) => setTimeout(r, 300));
      uni.navigateBack();
      return;
    }
    const body = {
      happened_at: date.value,
      note: note.value.trim(),
      items: valid.map((r) => ({ price_id: r.priceId, quantity: Number(r.quantity), count_qty: Number(r.countQty) > 0 ? Number(r.countQty) : null, purchase_price: Number(r.purchasePrice) || 0, happened_at: r.happenedAt || date.value, note: r.note || note.value.trim() })),
    };
    let savedId = editId.value;
    if (editId.value) {
      await request(`/purchases/${editId.value}`, 'PATCH', body);
      uni.showToast({ title: '已保存修改', icon: 'success' });
    } else {
      const d = await request<{ id: string }>('/purchases', 'POST', body);
      savedId = d.id;
      uni.showToast({ title: `已提交 ¥${fmtAmount(total.value)}`, icon: 'success' });
      rows.value = [];
      addRow();
    }
    // 识别原图/手动凭证随单上传（单据级 purchase/{savedId}；失败不阻断提交）
    if (pendingPhoto.value && savedId) {
      try {
        await uploadAttachment('purchase', savedId, pendingPhoto.value);
        pendingPhoto.value = '';
      } catch (_) {}
    }
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '提交失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh;  background: var(--page-bg); }
.head-row { display: flex; gap: 12rpx; align-items: flex-start; margin-bottom: 16rpx; }
.head-row .field { flex: 1; background: var(--card-bg); border-radius: 12rpx; padding: 24rpx; }
.head-row .field-inner { flex-direction: column; align-items: flex-start; gap: 6rpx; }
.copy-btn { flex-shrink: 0; background: var(--card-bg); color: var(--primary); border: 1rpx solid var(--primary); border-radius: 12rpx; font-size: 26rpx; padding: 0 20rpx; height: 88rpx; line-height: 88rpx; }
.batch-hint { flex-shrink: 0; align-self: center; background: var(--violet-bg); color: #7c4dff; border-radius: 12rpx; font-size: 24rpx; padding: 12rpx 20rpx; }
.ai-btn { flex-shrink: 0; background: var(--card-bg); color: #7c4dff; border: 1rpx solid #7c4dff; border-radius: 12rpx; font-size: 26rpx; padding: 0 20rpx; height: 88rpx; line-height: 88rpx; }
.ai-tip { background: var(--violet-bg); color: #7c4dff; border-radius: 12rpx; padding: 16rpx 24rpx; margin-bottom: 16rpx; font-size: 26rpx; }
.field { background: var(--card-bg); border-radius: 12rpx; padding: 24rpx; margin-bottom: 16rpx; }
.field-inner { display: flex; justify-content: space-between; }
.label { color: var(--text-sub); }
.value { color: var(--text-main); }
.row {
  background: var(--card-bg); border-radius: 12rpx; padding: 16rpx; margin-bottom: 12rpx;
}
.row-main { display: flex; align-items: center; gap: 12rpx; }
.row-note { background: var(--input-bg); border-radius: 8rpx; padding: 10rpx 14rpx; font-size: 22rpx; margin-top: 10rpx; width: 100%; box-sizing: border-box; }
.picker { flex: 1; min-width: 0; }
.date-pick { width: 96rpx; flex-shrink: 0; }
.mini-field {
  background: var(--input-bg); border-radius: 8rpx; padding: 12rpx; font-size: 24rpx; text-align: center;
  overflow: hidden; white-space: nowrap; text-overflow: ellipsis;
}
.num { width: 90rpx; background: var(--input-bg); border-radius: 8rpx; padding: 12rpx; font-size: 24rpx; text-align: center; }
.num.count { width: 110rpx; }
.ipt-note { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 26rpx; }
.amt { width: 110rpx; font-size: 24rpx; color: #f56c6c; }
.del { color: #f56c6c; font-size: 24rpx; padding: 8rpx; }
.footer { display: flex; justify-content: space-between; align-items: center; margin: 20rpx 0; }
/* 底部固定悬浮栏（对齐 App 固定栏）：页面留白避免内容被栏遮挡 */
.bottom-bar { position: fixed; left: 0; right: 0; bottom: 0; padding: 16rpx 24rpx 20rpx; background: var(--page-bg); border-top: 1rpx solid var(--divider); z-index: 20; }
.page { padding-bottom: 220rpx; }
.btn-add { font-size: 28rpx; }
.btn-voucher { font-size: 26rpx; background: var(--card-bg); color: #22c55e; border: 1rpx solid #22c55e; border-radius: 12rpx; padding: 0 20rpx; height: 76rpx; line-height: 76rpx; }
.total { font-size: 28rpx; }
.total-num { color: #f56c6c; font-weight: bold; font-size: 34rpx; }
/* 进货记单按钮用成功绿（对齐 App purchase_page：提交/加行 success 色系） */
.btn-submit { background: #22c55e; color: #fff; border-radius: 12rpx; font-size: 32rpx; }
/* 新商品入库弹窗（对齐其他页 mask/sheet 弹层） */
.mask { position: fixed; left: 0; top: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.45); z-index: 100; display: flex; align-items: center; justify-content: center; }
.sheet { width: 84%; background: var(--card-bg); border: var(--card-border); border-radius: 20rpx; padding: 28rpx 24rpx; }
.s-title { display: block; font-size: 32rpx; font-weight: 600; color: var(--text-main); margin-bottom: 12rpx; }
.s-sub { display: block; font-size: 26rpx; color: var(--text-sub); margin-bottom: 20rpx; }
.pk { background: var(--input-bg); border-radius: 12rpx; padding: 20rpx; margin-bottom: 16rpx; }
.pk-inner { display: flex; justify-content: space-between; align-items: center; }
.dlg-ops { display: flex; justify-content: flex-end; gap: 20rpx; margin-top: 12rpx; }
.btn-cancel { background: var(--card-bg); color: var(--text-sub); border: 1rpx solid var(--divider); border-radius: 12rpx; font-size: 28rpx; padding: 0 28rpx; height: 80rpx; line-height: 80rpx; }
.btn-ok { background: #22c55e; color: #fff; border-radius: 12rpx; font-size: 28rpx; padding: 0 28rpx; height: 80rpx; line-height: 80rpx; }
</style>