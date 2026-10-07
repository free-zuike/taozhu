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
      <view v-if="isDateRows" class="batch-voucher" @click="showBatchAttach"><text class="mi">&#xe3f4;</text>整单凭证</view>
      <button v-if="isDateRows" class="ai-btn" :disabled="aiBusy" @click="aiMenu">AI 记账</button>
    </view>
    <text v-if="isDateRows" class="batch-hint">该日 {{ rows.length }} 行 · 保存按原单分组提交</text>

    <!-- AI 识别状态（识别中 / 语音原文） -->
    <view v-if="aiBusy" class="ai-tip">{{ aiTip }}</view>

    <view v-for="(row, i) in rows" :key="i">
      <view class="ins-bar" @click="insertRow(i)">
        <view class="ins-line"></view><text class="ins-tx">＋ 在此上方插入</text><view class="ins-line"></view>
      </view>
      <view class="row-card">
        <view class="head-row">
          <text class="idx">{{ i + 1 }}</text>
          <input class="goods-field" :class="{ ph: !row.itemName }" v-model="row.itemName" placeholder="选商品（可输入或选择）" @blur="onItemInput(i)" />
          <text v-if="row.rowId" class="att-btn" @click.stop="showAttach('purchase_item', row.rowId, 'purchase', row.orderId)"><text class="mi">&#xe3f4;</text></text>
          <text class="del mi" @click="rows.splice(i, 1)">&#xe872;</text>
        </view>
        <input class="unit-field" :class="{ ph: !row.unit }" v-model="row.unit" placeholder="单位（可手动填写）" @blur="onUnitBlur(i)" />
        <view class="price-hint" :class="{ ph: !row.priceLabel }">{{ row.priceLabel || '输入商品名自动带出单位与价格' }}</view>
        <picker class="date-pick" mode="date" :value="row.happenedAt || date" @change="(e: any) => (row.happenedAt = e.detail.value)">
          <view class="row-date">该行日期：{{ (row.happenedAt || date).slice(5) }}　点此修改</view>
        </picker>
        <view class="num-row">
          <view class="num-col">
            <text class="num-label">数量</text>
            <input class="num" type="digit" v-model="row.quantity" placeholder="0" />
          </view>
          <view class="num-col">
            <text class="num-label">进价（可直接改）</text>
            <input class="num" type="digit" v-model="row.purchasePrice" placeholder="0" />
          </view>
        </view>
        <input v-if="row.countUnit" class="num count" type="digit" v-model="row.countQty" :placeholder="`折合 ${row.countUnit} 数`" />
        <view class="amt-line">金额 <text class="amt">¥{{ rowAmount(row) }}</text></view>
        <input class="row-note" v-model="row.note" placeholder="行备注（选填）" />
      </view>
    </view>
    <input class="ipt-note" v-model="note" placeholder="整单备注（选填，如：供应商/送货单号…）" />

    <!-- 底部固定悬浮栏（对齐 App：合计+添加+提交同一行固定底部） -->
    <view class="bottom-bar">
      <view class="footer">
        <button class="btn-add" @click="addRow">+ 添加商品</button>
        <button v-if="!isDateRows" class="btn-voucher" @click="pickVoucher">{{ pendingPhoto ? '✓ 凭证已选' : '📎 凭证' }}</button>
        <text class="total">合计 <text class="total-num">¥{{ fmtAmount(total) }}</text></text>
        <button class="btn-submit" :disabled="saving" @click="submit">{{ saving ? '提交中…' : (isDateRows ? '保存该日修改' : (editId ? '保存修改' : '提交进货单')) }}</button>
      </view>
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

    <!-- 附件查看/上传/删除：全屏大图查看器（对齐 App：点击直接全屏，有图看大图，无图全屏空态可添加） -->
    <view v-if="attach.show" class="viewer" @click.stop>
      <swiper v-if="attach.list.length > 0" class="viewer-swiper" :current="attach.index" @change="onViewerChange">
        <swiper-item v-for="a in attach.list" :key="a.key">
          <image class="viewer-img" :src="attachmentUrl(a.key)" mode="aspectFit" @click.stop />
        </swiper-item>
      </swiper>
      <view v-else class="viewer-empty">
        <text class="viewer-empty-tx">暂无凭证，点上方「添加」上传</text>
      </view>
      <view class="viewer-top">
        <text class="viewer-close" @click="closeAttach">✕</text>
        <text class="viewer-count">{{ attach.list.length > 0 ? attach.index + 1 + '/' + attach.list.length : '' }}</text>
        <view class="viewer-ops">
          <text v-if="attach.canEdit" class="viewer-op" @click="uploadAttach">添加</text>
          <text v-if="attach.list.length > 0" class="viewer-op" @click="downloadAttach">下载</text>
          <text v-if="attach.list.length > 0 && attach.canEdit" class="viewer-op viewer-op-del" @click="removeAttach(attach.list[attach.index].key)">删除</text>
        </view>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { useThemeVars } from '../../theme';
const { tv, patternSrc } = useThemeVars();
import { computed, ref } from 'vue';
import { onLoad, onShow, onHide, onBackPress } from '@dcloudio/uni-app';
import { request, getToken, uploadAi, uploadAttachment, getAttachments, deleteAttachment, attachmentUrl } from '../../api';
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

/// 在该行上方插入一行（补识别漏行/调整顺序与图片一致；对齐 App 行内插入）。
/// 弹「补录/新商品」二选一：补录=并入上方行原单（共享整单凭证），新商品=独立新单（附件单独挂）
function insertRow(i: number) {
  uni.showActionSheet({
    itemList: ['补录（并入上方原单）', '新商品（独立新单）'],
    success: (res) => {
      const row: Row = { itemId: '', itemName: '', prices: [], priceId: '', priceLabel: '', unit: '', quantity: '', purchasePrice: '', countQty: '', countUnit: '', happenedAt: '', note: '', rowId: `pi${Date.now()}${Math.floor(Math.random() * 0x7fffffff)}`, orderId: '' };
      // 补录：归入上方行原单（插入位置=提交位置，整单凭证挂原单时插入行同单可见）
      if (res.tapIndex === 0 && i > 0 && rows.value[i - 1].orderId) row.orderId = rows.value[i - 1].orderId;
      rows.value.splice(i, 0, row);
    },
  });
}

// ── 行级凭证附件（对齐 App 行头附件按钮：点击直接全屏查看器，可添加/下载/删除）──
const attach = ref<{ show: boolean; entity: string; id: string; list: Array<{ key: string }>; index: number; canEdit: boolean }>({
  show: false, entity: '', id: '', list: [], index: 0, canEdit: true,
});
// 安卓返回键/左滑返回：查看器开着先关查看器（对齐账本/进货历史根页行为）
onBackPress(() => {
  if (attach.value.show) {
    attach.value.show = false;
    return true;
  }
  return false;
});

/// 批量直编整单凭证：聚合该日全部原单的单据级附件（可添加/删除，挂第一张原单——对齐 App orderIds.first）
async function showBatchAttach() {
  const oids = Array.from(new Set(rows.value.map((r) => r.orderId).filter(Boolean)));
  attach.value = { show: true, entity: 'purchase', id: oids[0] || '', list: [], index: 0, canEdit: true };
  const list: Array<{ key: string }> = [];
  for (const oid of oids) {
    try {
      const d = await getAttachments('purchase', oid);
      list.push(...(d.attachments || []));
    } catch (_) {}
  }
  attach.value.list = list;
}

async function showAttach(entity: string, id: string, fbEntity = '', fbId = '') {
  attach.value = { show: true, entity, id, list: [], index: 0, canEdit: true };
  let list: Array<{ key: string }> = [];
  try {
    const d = await getAttachments(entity, id);
    list = d.attachments || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载凭证失败', icon: 'none' });
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

function closeAttach() {
  attach.value.show = false;
}

function onViewerChange(e: { detail: { current: number } }) {
  attach.value.index = e.detail.current;
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

async function removeAttach(key: string) {
  uni.showModal({
    title: '删除凭证',
    content: '确定删除这张凭证图片吗？',
    success: async (r) => {
      if (!r.confirm) return;
      try {
        await deleteAttachment(key);
        const idx = attach.value.list.findIndex((a) => a.key === key);
        attach.value.list = attach.value.list.filter((a) => a.key !== key);
        if (idx >= 0 && attach.value.index >= idx && attach.value.index > 0) attach.value.index -= 1;
        uni.showToast({ title: '已删除', icon: 'success' });
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
      }
    },
  });
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
        const d = await uploadAi<{ items?: Array<Record<string, any>>; date?: string }>(`/ai/parse-photo?purpose=purchase`, 'photo', fp);
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
        const d = await request<{ items?: Array<Record<string, any>>; date?: string }>(`/ai/parse-text?purpose=purchase`, 'POST', { text });
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
      const d = await uploadAi<{ text?: string; items?: Array<Record<string, any>>; date?: string }>(`/ai/parse-voice?purpose=purchase`, 'audio', fp);
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
function fillFromDrafts(list: Array<Record<string, any>>, draftDate = '') {
  // 日期回填（识别出的单据日期 YYYY-MM-DD，进货无购货单位字段）
  if (draftDate && /^\d{4}-\d{2}-\d{2}$/.test(draftDate)) date.value = draftDate;
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

/// 商品名输入失焦：精确匹配到已有商品 → 关联并带出默认单位/进价（不覆盖已手填进价）；
/// 未匹配=自定义新商品名（itemId 留空，提交时可入库，对齐 App 名称输入关联）
function onItemInput(i: number) {
  const row = rows.value[i];
  const name = (row.itemName || '').trim();
  const match = items.value.find((x) => x.name === name);
  if (!match) return;
  row.itemId = match.id;
  row.prices = match.prices;
  row.itemName = match.name;
  row.countUnit = String(match.count_unit || '');
  if (!row.priceId) {
    const pr = match.prices.find((p) => p.unit === (row.unit || '')) || match.prices[0];
    if (pr) {
      row.priceId = pr.id;
      row.unit = pr.unit;
      row.priceLabel = `${pr.unit}（进 ¥${pr.purchase_price}·库存${pr.stock ?? 0}）`;
      if (!row.purchasePrice) row.purchasePrice = String(pr.purchase_price);
    }
  }
}

/// 单位输入失焦：匹配到该商品的价格组合 → 带出进价；自定义单位（商品无此单位）=进价手动填（对齐 App）
function onUnitBlur(i: number) {
  const row = rows.value[i];
  row.unit = (row.unit || '').trim();
  if (!row.unit) { row.priceLabel = ''; return; }
  const item = items.value.find((x) => x.id === row.itemId);
  const price = item?.prices.find((p) => p.unit === row.unit);
  if (price) {
    row.priceId = price.id;
    row.priceLabel = `${price.unit}（进 ¥${price.purchase_price}·库存${price.stock ?? 0}）`;
    if (!row.purchasePrice) row.purchasePrice = String(price.purchase_price);
  } else {
    row.priceId = ''; // 自定义单位：进价手动填
    row.priceLabel = `单位 ${row.unit}（自定义，进价请手动填写）`;
  }
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
          items: rowList.map((r, i) => ({
            id: r.rowId || undefined,
            price_id: r.priceId,
            quantity: Number(r.quantity),
            count_qty: Number(r.countQty) > 0 ? Number(r.countQty) : null,
            purchase_price: Number(r.purchasePrice) || 0,
            happened_at: r.happenedAt || date.value,
            note: r.note || '',
            sort: i, // 行序=展示/插入顺序（服务端按 sort 存储，插入行不排末尾）
          })),
        });
      }
      const newRows = valid.filter((r) => !r.orderId);
      if (newRows.length > 0) {
        await request('/purchases', 'POST', {
          happened_at: date.value,
          note: note.value.trim(),
          items: newRows.map((r, i) => ({ price_id: r.priceId, quantity: Number(r.quantity), count_qty: Number(r.countQty) > 0 ? Number(r.countQty) : null, purchase_price: Number(r.purchasePrice) || 0, happened_at: r.happenedAt || date.value, note: r.note || '', sort: i })),
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
.batch-hint { flex-shrink: 0; align-self: center; background: var(--violet-bg); color: #7c4dff; border-radius: 12rpx; font-size: 24rpx; padding: 12rpx 20rpx; display: block; margin: 0 0 12rpx 8rpx; }
.ai-btn { flex-shrink: 0; background: var(--card-bg); color: #7c4dff; border: 1rpx solid #7c4dff; border-radius: 12rpx; font-size: 26rpx; padding: 0 20rpx; height: 88rpx; line-height: 88rpx; }
.ai-tip { background: var(--violet-bg); color: #7c4dff; border-radius: 12rpx; padding: 16rpx 24rpx; margin-bottom: 16rpx; font-size: 26rpx; }
.field { background: var(--card-bg); border-radius: 12rpx; padding: 24rpx; margin-bottom: 16rpx; }
.field-inner { display: flex; justify-content: space-between; }
.label { color: var(--text-sub); }
.value { color: var(--text-main); }
.row {
  background: var(--card-bg); border-radius: 12rpx; padding: 16rpx; margin-bottom: 12rpx;
}
/* 行卡片（对齐 App purchase_page：商品名/单位/行日期/数量进价分行） */
.row-card { background: var(--card-bg); border-radius: 16rpx; padding: 18rpx 20rpx; margin-bottom: 14rpx; }
.head-row { display: flex; align-items: center; gap: 12rpx; }
.idx { width: 44rpx; height: 44rpx; border-radius: 12rpx; background: var(--primary-soft); color: var(--primary); font-size: 24rpx; font-weight: bold; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.goods-field { flex: 1; min-width: 0; background: var(--input-bg); border-radius: 10rpx; padding: 16rpx 18rpx; font-size: 28rpx; }
.goods-field.ph { color: var(--text-sub); }
.att-btn { color: #409EFF; padding: 6rpx; font-size: 34rpx; }
.unit-field { margin-top: 12rpx; width: 100%; box-sizing: border-box; background: var(--input-bg); border-radius: 10rpx; padding: 14rpx 18rpx; font-size: 26rpx; }
.unit-field.ph { color: var(--text-sub); }
.price-hint { margin-top: 8rpx; font-size: 22rpx; color: var(--primary); }
.price-hint.ph { color: var(--text-sub); }
.batch-voucher { flex-shrink: 0; display: flex; align-items: center; gap: 6rpx; background: var(--card-bg); color: var(--primary); border: 1rpx solid var(--primary); border-radius: 12rpx; font-size: 24rpx; padding: 16rpx 20rpx; }
.date-pick { margin-top: 12rpx; }
.row-date { background: var(--input-bg); border-radius: 10rpx; padding: 12rpx 16rpx; font-size: 24rpx; color: var(--primary); }
.num-row { display: flex; gap: 12rpx; margin-top: 12rpx; }
.num { flex: 1; background: var(--input-bg); border-radius: 10rpx; padding: 14rpx; font-size: 26rpx; text-align: center; }
.num.count { margin-top: 12rpx; }
.amt-line { display: flex; justify-content: space-between; align-items: center; margin-top: 10rpx; font-size: 24rpx; color: var(--text-sub); }
.amt { font-size: 30rpx; font-weight: bold; color: #f56c6c; }
.row-note { background: var(--input-bg); border-radius: 8rpx; padding: 10rpx 14rpx; font-size: 22rpx; margin-top: 10rpx; width: 100%; box-sizing: border-box; }
.ins-bar { display: flex; align-items: center; gap: 16rpx; padding: 8rpx 16rpx; }
.ins-line { flex: 1; height: 1rpx; background: var(--divider); }
.ins-tx { font-size: 22rpx; color: var(--primary); }
.ipt-note { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 26rpx; }
.del { color: #f56c6c; font-size: 36rpx; padding: 8rpx; flex-shrink: 0; line-height: 1; }
/* 全屏凭证查看器（对齐 App attachment_viewer） */
.viewer { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: #000; display: flex; flex-direction: column; z-index: 200; }
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
.footer { display: flex; align-items: center; gap: 16rpx; margin: 0; }
/* 底部固定悬浮栏（对齐 App 固定栏）：页面留白避免内容被栏遮挡 */
.bottom-bar { position: fixed; left: 0; right: 0; bottom: 0; padding: 16rpx 24rpx 20rpx; background: var(--page-bg); border-top: 1rpx solid var(--divider); z-index: 20; }
.page { padding-bottom: 220rpx; }
.btn-add { font-size: 26rpx; padding: 0 16rpx; height: 72rpx; line-height: 72rpx; flex-shrink: 0; }
.btn-voucher { font-size: 24rpx; background: var(--card-bg); color: #22c55e; border: 1rpx solid #22c55e; border-radius: 12rpx; padding: 0 16rpx; height: 72rpx; line-height: 72rpx; flex-shrink: 0; }
.total { flex: 1; text-align: right; font-size: 28rpx; }
.total-num { color: #f56c6c; font-weight: bold; font-size: 34rpx; }
/* 进货记单按钮用成功绿（对齐 App purchase_page：提交/加行 success 色系） */
.btn-submit { flex-shrink: 0; background: #22c55e; color: #fff; border-radius: 12rpx; font-size: 30rpx; height: 80rpx; line-height: 80rpx; padding: 0 32rpx; }
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