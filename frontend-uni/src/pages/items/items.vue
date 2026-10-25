<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <input class="search" v-model="search" placeholder="搜索商品（名称关键字）" @input="onSearch" />
    <view class="bp-bar"><text class="op" @click="openBulkPrice">批量调价</text></view>

    <view v-for="it in items" :key="it.id" class="card">
      <view class="head">
        <text class="name">{{ it.name }}</text>
        <text class="cat">{{ it.category_name || it.category }}</text>
        <text class="op" @click="openEdit(it)">编辑</text>
        <text class="del" @click="remove(it.id)">删除</text>
      </view>
      <view v-for="p in it.prices" :key="p.id" class="price">{{ p.unit }}：进 ¥{{ p.purchase_price }} → 出 ¥{{ p.sale_price }}</view>
    </view>
    <view v-if="items.length === 0" class="empty">暂无商品</view>

    <!-- 新增/编辑弹层 -->
    <view v-if="showForm" class="mask" @click="showForm = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">{{ form.id ? '编辑商品' : '新增商品' }}</view>
        <input class="ipt" v-model="form.name" placeholder="商品名（必填）" />
        <picker class="cat-pk" mode="selector" :range="topNames" @change="onTopCat">
          <view class="pk-inner"><text class="label">一级分类</text><text :class="['value', { placeholder: !form.topName }]">{{ form.topName || '未分类（可手填下方）' }}</text></view>
        </picker>
        <picker v-if="subNames.length" class="cat-pk" mode="selector" :range="subNames" @change="onSubCat">
          <view class="pk-inner"><text class="label">二级分类</text><text :class="['value', { placeholder: !form.subName }]">{{ form.subName || '未分类' }}</text></view>
        </picker>
        <input class="ipt" v-model="form.category" placeholder="分类名（选分类后自动填，也可手动输入）" />
        <view v-for="(p, i) in form.prices" :key="i" class="price-row">
          <input class="ipt s" v-model="p.unit" placeholder="单位" />
          <input class="ipt s" v-model="p.purchase_price" type="digit" placeholder="进价" />
          <input class="ipt s" v-model="p.sale_price" type="digit" placeholder="售价" />
          <text class="del" @click="form.prices.splice(i, 1)">删</text>
        </view>
        <button class="btn-sub" @click="form.prices.push({ id: '', unit: '', purchase_price: '', sale_price: '', group_prices: {} })">+ 加价格行（同菜多单位）</button>
        <view v-if="priceGroups.length" class="gp-title">价格组售价（按店铺等级带出；留空=不设）</view>
        <view v-for="(p, i) in form.prices" :key="'gp-' + i" class="gp-block">
          <view v-if="priceGroups.length && form.prices[i].unit" class="gp-row" v-for="g in priceGroups" :key="'g' + g.id">
            <text class="gp-label">{{ g.name }}</text>
            <input class="ipt s" v-model="p.group_prices[g.id]" type="digit" placeholder="售价" />
          </view>
        </view>
        <button class="btn-save" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>
    <button v-if="!showForm" class="btn-add" @click="openAdd()">+ 新增商品</button>

    <!-- 批量调价弹层（选商品 → 规则 → 预览 → 执行；老板操作） -->
    <view v-if="showBulk" class="mask" @click="showBulk = false">
      <view class="sheet trace-sheet" @click.stop>
        <view class="sheet-title">{{ bulkStep === 0 ? '批量调价 · 选商品' : (bulkStep === 1 ? '批量调价 · 规则' : '批量调价 · 预览') }}</view>
        <template v-if="bulkStep === 0">
          <input class="ipt" v-model="bulkQ" placeholder="搜索商品（在当前列表内）" />
          <view class="bp-ops">
            <text class="op" @click="toggleAllBulk">{{ bulkAll ? '取消全选' : '全选' }}</text>
            <text class="bp-sel">已选 {{ bulkSel.length }} 个</text>
          </view>
          <scroll-view scroll-y class="trace-list">
            <view v-for="(it, i) in bulkFiltered" :key="it.id" class="bp-row" @click="toggleBulk(it.id)">
              <checkbox :checked="bulkSel.includes(it.id)" color="#409EFF" style="transform: scale(0.7)" />
              <text class="bp-name">{{ it.name }}</text>
              <text class="bp-price">{{ priceSummary(it) }}</text>
            </view>
            <view v-if="bulkFiltered.length === 0" class="empty">暂无商品</view>
          </scroll-view>
          <button class="btn-save" :disabled="bulkSel.length === 0" @click="bulkStep = 1">下一步：规则</button>
        </template>
        <template v-else-if="bulkStep === 1">
          <view class="bp-rule">
            <text class="bp-label">调价字段</text>
            <view class="seg">
              <text :class="['seg-item', { on: bulkField === 'sale_price' }]" @click="bulkField = 'sale_price'">售价</text>
              <text :class="['seg-item', { on: bulkField === 'purchase_price' }]" @click="bulkField = 'purchase_price'">进价</text>
              <text :class="['seg-item', { on: bulkField === 'both' }]" @click="bulkField = 'both'">都调</text>
            </view>
          </view>
          <view class="bp-rule">
            <text class="bp-label">调价方式</text>
            <view class="seg">
              <text :class="['seg-item', { on: bulkMode === 'percent' }]" @click="bulkMode = 'percent'">百分比 %</text>
              <text :class="['seg-item', { on: bulkMode === 'fixed' }]" @click="bulkMode = 'fixed'">固定值</text>
            </view>
          </view>
          <input class="ipt" v-model="bulkValue" type="digit" :placeholder="bulkMode === 'percent' ? '调整百分比（+上浮 / −下调）' : '调整金额（+加 / −减）'" />
          <view class="bp-rule switch-row" @click="bulkGroup = !bulkGroup">
            <text class="bp-label">价格组售价联动（零售/批发/VIP 同规则）</text>
            <switch :checked="bulkGroup" color="#409EFF" style="transform: scale(0.7)" />
          </view>
          <button class="btn-save" :disabled="bulkBusy" @click="doBulkPreview">{{ bulkBusy ? '预览中…' : '预览调价' }}</button>
        </template>
        <template v-else>
          <view class="form-item">共 {{ bulkPreviewRows.length }} 条价格行{{ bulkPreviewGroup.length ? ' + 价格组 ' + bulkPreviewGroup.length + ' 条' : '' }}，确认后执行（可点遮罩返回修改）</view>
          <scroll-view scroll-y class="trace-list">
            <view v-for="(r, i) in bulkPreviewRows" :key="'p' + i" class="t-row">
              <view class="t-body">
                <text class="t-name">{{ r.item_name }}（{{ r.unit }}）</text>
              </view>
              <text class="t-qty">¥{{ fmtAmount(bulkOldOf(r)) }} → <text class="q-in">¥{{ fmtAmount(bulkNewOf(r)) }}</text></text>
            </view>
            <view v-for="(g, i) in bulkPreviewGroup" :key="'g' + i" class="t-row">
              <view class="t-body"><text class="t-date">{{ g.item_name }}（{{ g.unit }}·{{ g.group_name }}）</text></view>
              <text class="t-qty">¥{{ fmtAmount(g.old) }} → ¥{{ fmtAmount(g.new) }}</text>
            </view>
          </scroll-view>
          <button class="btn-save" :disabled="bulkBusy" @click="doBulkExec">{{ bulkBusy ? '执行中…' : '确认执行' }}</button>
        </template>
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

interface Price {
  id?: string;
  unit: string;
  purchase_price: string;
  sale_price: string;
  /// 价格组售价：group_id → 售价字符串（同单位多组；保存时组装 item_group_prices）
  group_prices: Record<string, string>;
}
interface Item {
  id: string;
  name: string;
  category: string;
  category_name?: string;
  prices: Price[];
}
interface GroupPrice {
  id: string;
  unit: string;
  group_id: string;
  sale_price: number;
}

const items = ref<Item[]>([]);
const search = ref('');
const showForm = ref(false);
const saving = ref(false);
const priceGroups = ref<Array<{ id: string; name: string }>>([]);
// 批量调价（v0.17.473）：选商品 → 规则（字段/百分比或固定值/价格组联动）→ 预览 → 执行
const showBulk = ref(false);
const bulkStep = ref(0);
const bulkQ = ref('');
const bulkSel = ref<string[]>([]);
const bulkField = ref('sale_price');
const bulkMode = ref('percent');
const bulkValue = ref('10');
const bulkGroup = ref(true);
const bulkBusy = ref(false);
const bulkPreviewRows = ref<Array<{ item_name: string; unit: string; old_sale: number; new_sale: number; old_purchase: number; new_purchase: number }>>([]);
const bulkPreviewGroup = ref<Array<{ item_name: string; unit: string; group_name: string; old: number; new: number }>>([]);
const bulkFiltered = computed<Item[]>(() => {
  const q2 = bulkQ.value.trim();
  return items.value.filter((it) => !q2 || it.name.includes(q2));
});
const bulkAll = computed(() => bulkFiltered.value.length > 0 && bulkFiltered.value.every((x) => bulkSel.value.includes(x.id)));
function toggleBulk(id: string) {
  const i = bulkSel.value.indexOf(id);
  if (i >= 0) bulkSel.value.splice(i, 1);
  else bulkSel.value.push(id);
}
function toggleAllBulk() {
  const ids = bulkFiltered.value.map((x) => x.id);
  if (bulkAll.value) {
    bulkSel.value = bulkSel.value.filter((x) => !ids.includes(x));
  } else {
    bulkSel.value = [...new Set([...bulkSel.value, ...ids])];
  }
}
function priceSummary(it: Item): string {
  return (it.prices || []).map((p) => `${p.unit} ¥${p.sale_price}`).join('、');
}
function bulkOldOf(r: { old_sale: number; old_purchase: number }): number {
  return bulkField.value === 'purchase_price' ? Number(r.old_purchase) || 0 : Number(r.old_sale) || 0;
}
function bulkNewOf(r: { new_sale: number; new_purchase: number }): number {
  return bulkField.value === 'purchase_price' ? Number(r.new_purchase) || 0 : Number(r.new_sale) || 0;
}
function openBulkPrice() {
  bulkStep.value = 0;
  bulkQ.value = '';
  bulkSel.value = [];
  bulkValue.value = '10';
  bulkField.value = 'sale_price';
  bulkMode.value = 'percent';
  bulkGroup.value = true;
  bulkPreviewRows.value = [];
  bulkPreviewGroup.value = [];
  showBulk.value = true;
}
async function doBulkPreview() {
  bulkBusy.value = true;
  try {
    const pv = await request<{ rows: typeof bulkPreviewRows.value; group_rows: typeof bulkPreviewGroup.value }>('/items/bulk-price/preview', 'POST', {
      item_ids: bulkSel.value, field: bulkField.value, mode: bulkMode.value,
      value: Number(bulkValue.value) || 0, apply_group_prices: bulkGroup.value,
    });
    bulkPreviewRows.value = pv?.rows || [];
    bulkPreviewGroup.value = pv?.group_rows || [];
    bulkStep.value = 2;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '预览失败', icon: 'none' });
  } finally {
    bulkBusy.value = false;
  }
}
async function doBulkExec() {
  bulkBusy.value = true;
  try {
    await request('/items/bulk-price', 'POST', {
      item_ids: bulkSel.value, field: bulkField.value, mode: bulkMode.value,
      value: Number(bulkValue.value) || 0, apply_group_prices: bulkGroup.value,
    });
    uni.showToast({ title: `批量调价完成（${bulkSel.value.length} 个商品）`, icon: 'success' });
    showBulk.value = false;
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '执行失败', icon: 'none' });
  } finally {
    bulkBusy.value = false;
  }
}
const form = ref<{ id?: string; name: string; category: string; categoryId: string; topId: string; topName: string; subId: string; subName: string; prices: Price[] }>({
  id: undefined, name: '', category: '', categoryId: '', topId: '', topName: '', subId: '', subName: '', prices: [{ id: '', unit: '', purchase_price: '', sale_price: '', group_prices: {} }],
});

async function loadPriceGroups() {
  try {
    const d = await request<{ price_groups: Array<{ id: string; name: string }> }>('/price-groups', 'GET').catch(() => null);
    priceGroups.value = d?.price_groups || [];
  } catch (e) {
    // 价格组加载失败不阻塞（组价区域隐藏，商品仍可保存）
  }
}

// 两级商品分类（对齐 App items_page：一级+二级级联选择，type=item）
const itemsCats = ref<Array<{ id: string; name: string; parent_id: string | null }>>([]);
const topNames = ref<string[]>(['未分类']);
const subNames = ref<string[]>([]);
const topCats = () => itemsCats.value.filter((c) => !c.parent_id);
const subCatsOf = (topId: string) => itemsCats.value.filter((c) => c.parent_id === topId);

async function loadCats() {
  try {
    const d = await request<{ categories: Array<{ id: string; name: string; parent_id: string | null }> }>('/categories?type=item', 'GET').catch(() => null);
    itemsCats.value = d?.categories || [];
    topNames.value = ['未分类', ...topCats().map((c) => c.name)];
  } catch (e) {
    // 分类加载失败不阻塞（手动分类名仍可用）
  }
}

function onTopCat(e: { detail: { value: number } }) {
  const idx = e.detail.value;
  if (idx <= 0) {
    form.value.topId = ''; form.value.topName = ''; form.value.subId = ''; form.value.subName = '';
    form.value.categoryId = ''; form.value.category = '';
    subNames.value = [];
    return;
  }
  const t = topCats()[idx - 1];
  form.value.topId = t.id; form.value.topName = t.name;
  form.value.subId = ''; form.value.subName = '';
  form.value.categoryId = t.id; form.value.category = t.name;
  const subs = subCatsOf(t.id);
  subNames.value = ['未分类', ...subs.map((c) => c.name)];
}

function onSubCat(e: { detail: { value: number } }) {
  const idx = e.detail.value;
  if (idx <= 0) {
    form.value.subId = ''; form.value.subName = '';
    form.value.categoryId = form.value.topId; form.value.category = form.value.topName;
    return;
  }
  const s = subCatsOf(form.value.topId)[idx - 1];
  form.value.subId = s.id; form.value.subName = s.name;
  form.value.categoryId = s.id; form.value.category = s.name;
}

onShow(async () => {
  onWs('*', load);
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await Promise.all([load(), loadCats(), loadPriceGroups()]);
});

async function load(q = '') {
  try {
    const url = q ? `/items?q=${encodeURIComponent(q)}` : '/items';
    const d = await request<{ items: Item[] }>(url, 'GET');
    items.value = d.items;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function onSearch() {
  const q = search.value.trim();
  // 输入即查（简单防抖：300ms）
  clearTimeout((onSearch as any)._t);
  (onSearch as any)._t = setTimeout(() => load(q), 300);
}

function openAdd() {
  form.value = { id: undefined, name: '', category: '', categoryId: '', topId: '', topName: '', subId: '', subName: '', prices: [{ id: '', unit: '', purchase_price: '', sale_price: '', group_prices: {} }] };
  subNames.value = [];
  showForm.value = true;
}

function openEdit(it: Item) {
  form.value = {
    id: it.id,
    name: it.name,
    category: it.category_name || it.category || '',
    categoryId: (it as any).category_id || '',
    topId: '', topName: '', subId: '', subName: '',
    prices: (it.prices || []).map((p) => {
      // 组价回填：该单位全部 group_prices（group_id → 售价）
      const gps: Record<string, string> = {};
      const orig = ((it as any).group_prices || []) as GroupPrice[];
      for (const g of orig) {
        if (g.unit === p.unit) gps[g.group_id] = String(g.sale_price ?? '');
      }
      return {
        id: p.id || '', unit: p.unit,
        purchase_price: String(p.purchase_price ?? ''),
        sale_price: String(p.sale_price ?? ''),
        group_prices: gps,
      };
    }),
  };
  // 回填分类选择器（按 id 定位一级/二级）
  const cid = (it as any).category_id || '';
  if (cid) {
    const cat = itemsCats.value.find((c) => c.id === cid);
    const top = cat?.parent_id ? itemsCats.value.find((c) => c.id === cat.parent_id) : cat;
    if (cat && !cat.parent_id) {
      form.value.topId = cat.id; form.value.topName = cat.name;
      const subs = subCatsOf(cat.id);
      subNames.value = ['未分类', ...subs.map((c) => c.name)];
    } else if (cat && top) {
      form.value.topId = top.id; form.value.topName = top.name;
      form.value.subId = cat.id; form.value.subName = cat.name;
      const subs = subCatsOf(top.id);
      subNames.value = ['未分类', ...subs.map((c) => c.name)];
    }
  } else {
    subNames.value = [];
  }
  if (form.value.prices.length === 0) {
    form.value.prices = [{ id: '', unit: '', purchase_price: '', sale_price: '', group_prices: {} }];
  }
  showForm.value = true;
}

/// 收集该单位的价格组售价：{unit, group_id, sale_price}（售价>0 才算有效）
function groupRowsOf(p: Price) {
  const out: Array<{ unit: string; group_id: string; sale_price: number }> = [];
  for (const g of priceGroups.value) {
    const v = Number(p.group_prices[g.id] || 0);
    if (v > 0) out.push({ unit: p.unit.trim(), group_id: g.id, sale_price: v });
  }
  return out;
}

async function save() {
  if (!form.value.name.trim()) {
    uni.showToast({ title: '请填写商品名', icon: 'none' });
    return;
  }
  const rows = form.value.prices.filter((p) => p.unit.trim());
  if (rows.length === 0) {
    uni.showToast({ title: '请至少填写一个单位价格', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    const num = (v: string) => Number(v) || 0;
    if (form.value.id) {
      const id = form.value.id;
      await request(`/items/${id}`, 'PATCH', { name: form.value.name.trim(), category: form.value.category.trim(), category_id: form.value.categoryId });
      // 既有价格更新 / 新增价格
      for (const p of rows) {
        const body = { unit: p.unit.trim(), purchase_price: num(p.purchase_price), sale_price: num(p.sale_price) };
        if (p.id) await request(`/items/item-prices/${p.id}`, 'PATCH', body);
        else await request(`/items/${id}/prices`, 'POST', body);
      }
      // 被移除的既有价格 → 停用
      const nowIds = new Set(rows.map((p) => p.id).filter(Boolean));
      const orig = items.value.find((x) => x.id === id);
      for (const p of orig?.prices || []) {
        if (p.id && !nowIds.has(p.id)) await request(`/items/item-prices/${p.id}`, 'DELETE');
      }
      // 价格组售价差量：新增/更新/删除（对齐 App：新增行 POST /items/:id/group-prices、已有 PATCH /item-group-prices/:id、被移除 DELETE）
      const origGps = ((orig as any)?.group_prices || []) as GroupPrice[];
      const wantGps: GroupPrice[] = [];
      for (const p of rows) {
        for (const g of groupRowsOf(p)) {
          const existing = origGps.find((x) => x.unit === g.unit && x.group_id === g.group_id);
          wantGps.push({ id: existing?.id || '', unit: g.unit, group_id: g.group_id, sale_price: g.sale_price });
        }
      }
      for (const g of wantGps) {
        const body = { unit: g.unit, group_id: g.group_id, sale_price: g.sale_price };
        if (g.id) await request(`/items/item-group-prices/${g.id}`, 'PATCH', body);
        else await request(`/items/${id}/group-prices`, 'POST', body);
      }
      const wantKeys = new Set(wantGps.filter((g) => g.id).map((g) => g.id));
      for (const g of origGps) {
        if (g.id && !wantKeys.has(g.id)) await request(`/items/item-group-prices/${g.id}`, 'DELETE');
      }
    } else {
      const gps: Array<{ unit: string; group_id: string; sale_price: number }> = [];
      for (const p of rows) gps.push(...groupRowsOf(p));
      await request('/items', 'POST', {
        name: form.value.name.trim(),
        category: form.value.category.trim(),
        category_id: form.value.categoryId,
        prices: rows.map((p) => ({ unit: p.unit.trim(), purchase_price: num(p.purchase_price), sale_price: num(p.sale_price) })),
        group_prices: gps,
      });
    }
    uni.showToast({ title: '已保存', icon: 'success' });
    showForm.value = false;
    await load(search.value.trim());
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

async function remove(id: string) {
  uni.showModal({
    title: '删除商品',
    content: '确定删除该商品吗？相关历史记录不受影响。',
    success: async (r) => {
      if (!r.confirm) return;
      try {
        await request(`/items/${id}`, 'DELETE');
        uni.showToast({ title: '已删除', icon: 'success' });
        await load(search.value.trim());
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
      }
    },
  });
}

  onHide(() => { offWs('*', load); });
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh;  background: var(--page-bg); }
.search { background: var(--card-bg); border-radius: 12rpx; padding: 18rpx 24rpx; margin-bottom: 20rpx; font-size: 28rpx; }
.btn-add { background: var(--primary); color: #fff; border-radius: 12rpx; margin-bottom: 20rpx; font-size: 30rpx; }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; align-items: center; margin-bottom: 12rpx; }
.name { font-size: 30rpx; font-weight: bold; }
.cat { margin-left: 16rpx; font-size: 24rpx; color: var(--text-sub); }
.op { margin-left: auto; color: var(--primary); font-size: 26rpx; }
.del { margin-left: 32rpx; color: #f56c6c; font-size: 26rpx; }
.price { font-size: 26rpx; color: var(--text-sub); margin-top: 6rpx; }
.empty { color: var(--text-sub); text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.bp-bar { display: flex; justify-content: flex-end; margin-bottom: 16rpx; }
.bp-ops { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12rpx; }
.bp-sel { font-size: 24rpx; color: var(--text-sub); }
.bp-row { display: flex; align-items: center; gap: 12rpx; padding: 14rpx 0; border-bottom: 1rpx solid var(--divider); }
.bp-row:last-child { border-bottom: none; }
.bp-name { flex: 1; font-size: 28rpx; }
.bp-price { font-size: 24rpx; color: var(--text-sub); max-width: 50%; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.bp-rule { display: flex; align-items: center; justify-content: space-between; margin-bottom: 16rpx; }
.bp-label { font-size: 28rpx; }
.switch-row { justify-content: space-between; }
.seg { display: flex; background: var(--input-bg); border-radius: 12rpx; padding: 6rpx; }
.seg-item { padding: 10rpx 24rpx; font-size: 26rpx; border-radius: 10rpx; color: var(--text-sub); }
.seg-item.on { background: var(--primary); color: #fff; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0, 0, 0, 0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: var(--sheet-bg); border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.cat-pk { background: var(--input-bg); border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; }
.pk-inner { display: flex; align-items: center; }
.pk-inner .label { font-size: 24rpx; color: var(--text-sub); margin-right: 20rpx; flex-shrink: 0; }
.pk-inner .value { flex: 1; font-size: 28rpx; color: var(--text-main); text-align: right; }
.pk-inner .value.placeholder { color: var(--text-sub); }
.price-row { display: flex; gap: 12rpx; align-items: center; }
.price-row .s { flex: 1; min-width: 0; }
.btn-sub { background: var(--card-bg); border: 1rpx solid var(--primary); color: var(--primary); border-radius: 10rpx; font-size: 26rpx; margin-bottom: 16rpx; }
.gp-title { font-size: 26rpx; color: var(--text-sub); margin: 8rpx 0 4rpx; }
.gp-block { margin-bottom: 12rpx; }
.gp-row { display: flex; align-items: center; gap: 12rpx; margin-bottom: 8rpx; }
.gp-label { font-size: 24rpx; color: var(--text-sub); width: 120rpx; flex-shrink: 0; }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; }
.trace-sheet { padding-bottom: 40rpx; max-height: 75vh; display: flex; flex-direction: column; }
.trace-list { max-height: 60vh; }
.t-row { display: flex; align-items: center; gap: 16rpx; padding: 16rpx 0; border-bottom: 1rpx solid var(--divider); }
.t-row:last-child { border-bottom: none; }
.t-body { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.t-name { font-size: 26rpx; font-weight: bold; }
.t-date { font-size: 24rpx; color: var(--text-sub); }
.t-qty { font-size: 26rpx; font-weight: bold; flex-shrink: 0; }
.q-in { color: #16a34a; }
.form-item { font-size: 28rpx; color: var(--text-main); margin-bottom: 16rpx; }
</style>