<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <!-- 顶部：搜索 + 新增（对齐 App：搜索框 + 新增图标按钮同一行） -->
    <view class="top-bar">
      <input class="search" v-model="query" placeholder="搜索店铺（名称关键字）" confirm-type="search" />
      <view class="add-btn" @click="openAdd"><text class="mi">&#xe145;</text><text class="add-tx">新增</text></view>
    </view>

    <view v-for="c in filteredClients" :key="c.id" class="card">
      <view class="head" @click="openEdit(c)">
        <view class="left">
          <view class="name-line">
            <text class="name">{{ c.name }}</text>
            <text v-if="c.category_name" class="cat">{{ c.category_name }}</text>
          </view>
          <text class="meta">{{ c.contact || '' }} {{ c.phone || '' }}</text>
        </view>
        <view class="head-ops" @click.stop>
          <!-- 编辑（对齐 App 行操作：编辑/导出/导入/删除 四个图标） -->
          <text class="op-ic" @click="openEdit(c)"><text class="mi">&#xe3c9;</text></text>
          <text class="op-ic" @click="exportClientTrades(c)"><text class="mi">&#xe2c4;</text></text>
          <text class="op-ic" @click="importClientTrades(c)"><text class="mi">&#xe2c6;</text></text>
          <text class="op-ic del" @click="remove(c.id)"><text class="mi">&#xe872;</text></text>
        </view>
      </view>
      <!-- 三格统计（对齐 App 店铺卡）：记账天数 / 欠款 / 周期 -->
      <view class="stat-row">
        <view class="stat">
          <text class="stat-num">{{ bookDays(c) }} 天</text>
          <text class="stat-label">记账天数</text>
        </view>
        <view class="stat-divider"></view>
        <view class="stat">
          <text class="stat-num" :class="Number(c.debt || 0) > 0 ? 'red' : 'green'">¥{{ fmtByUnit(c.debt, c.round_unit) }}</text>
          <text class="stat-label">欠款</text>
        </view>
        <view class="stat-divider"></view>
        <view class="stat">
          <text class="stat-num">{{ (Number(c.month_start_day) || 1) > 1 ? `每月 ${c.month_start_day} 日` : '自然月' }}</text>
          <text class="stat-label">周期</text>
        </view>
      </view>
      <text v-if="c.first_book_date" class="stat-start">记账起始 {{ c.first_book_date }}</text>
    </view>
    <view v-if="clients.length === 0" class="empty">暂无饭店，点上方新增</view>

    <!-- 新增/编辑弹层（对齐 App 编辑店铺对话框：居中弹窗、字段与选项文案一致，不做自由设计） -->
    <view v-if="showForm" class="mask" @click="showForm = false">
      <view class="dlg" @click.stop>
        <view class="dlg-title">{{ form.editId ? '编辑店铺' : '新增店铺' }}</view>
        <input class="ipt" v-model="form.name" placeholder="店铺名称 *" />
        <input class="ipt" v-model="form.monthStartDay" type="number" placeholder="每月起始日（1-28，1=自然月）" />
        <picker class="field" mode="selector" :range="topCatNames" @change="onTopCatChange">
          <view class="field-inner">
            <text class="label">分类（可选）</text>
            <text :class="['value', { placeholder: !form.topCatId }]">{{ form.topCatName || '选择分类' }}</text>
          </view>
        </picker>
        <picker v-if="subCatNames.length > 0" class="field" mode="selector" :range="subCatNames" @change="onSubCatChange">
          <view class="field-inner">
            <text class="label">子分类（可选）</text>
            <text :class="['value', { placeholder: !form.subCatId }]">{{ form.subCatName || '如 火锅店/中餐' }}</text>
          </view>
        </picker>
        <picker class="field" mode="selector" :range="stageNames" @change="onStageChange">
          <view class="field-inner">
            <text class="label">抹零方式</text>
            <text class="value">{{ stageLabel(form.roundStage) }}</text>
          </view>
        </picker>
        <!-- 不抹零=按实际金额显示，抹零精度不生效 → 置灰不可选（对齐 App） -->
        <picker class="field" mode="selector" :range="unitNames" :disabled="form.roundStage === 'none'" @change="onUnitChange">
          <view class="field-inner">
            <text class="label">抹零精度</text>
            <text class="value" :class="{ placeholder: form.roundStage === 'none' }">{{ form.roundStage === 'none' ? '不抹零=按实际金额显示（精度不生效）' : unitLabel(form.roundUnit) }}</text>
          </view>
        </picker>
        <picker class="field" mode="selector" :range="carryNames" @change="onCarryChange">
          <view class="field-inner">
            <text class="label">进位临界</text>
            <text class="value">{{ carryLabel(form.roundCarry) }}</text>
          </view>
        </picker>
        <picker class="field" mode="selector" :range="groupNames" @change="onGroupChange">
          <view class="field-inner">
            <text class="label">价格组（等级，可选）</text>
            <text :class="['value', { placeholder: !form.priceGroupId }]">{{ form.priceGroupName || '不设=按默认价' }}</text>
          </view>
        </picker>
        <view class="dlg-ops">
          <view class="dlg-btn" @click="showForm = false">取消</view>
          <view class="dlg-btn save" :class="{ disabled: saving }" @click="save">{{ saving ? '保存中…' : '保存' }}</view>
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
import { request, getToken, appLog } from '../../api';
import { fmtAmount, fmtByUnit } from '../../utils/money';

interface Client {
  id: string;
  name: string;
  contact: string;
  phone: string;
  note: string;
  debt: number;
  category_id?: string;
  category_name?: string;
  first_book_date?: string;
  month_start_day?: number;
  round_stage?: string;
  round_unit?: string;
  round_carry?: string | number | null;
  price_group_id?: string;
}

const clients = ref<Client[]>([]);
const query = ref('');
// 搜索过滤（对齐 App：名称关键字，本地即时过滤）
const filteredClients = computed(() => {
  const q = query.value.trim().toLowerCase();
  if (!q) return clients.value;
  return clients.value.filter((c) => String(c.name || '').toLowerCase().includes(q));
});
const showForm = ref(false);
const saving = ref(false);
const form = ref({ name: '', editId: '', monthStartDay: '1', topCatId: '', topCatName: '', subCatId: '', subCatName: '', roundStage: 'none', roundUnit: 'yuan', roundCarry: '', priceGroupId: '', priceGroupName: '' });
// 金额显示按「我的 → 金额舍入」设置的位数/进位口径（对齐 App fmtMoney）
const fmt = (n: number) => fmtAmount(Number(n) || 0);

// 店铺结账抹零方式/精度（对齐 App 店铺编辑选项文案：none/txn/day/total + yuan/jiao/fen）
const stageNames = ['不抹零（按实际金额显示）', '每单抹零（每张出货单合计向下取整）', '按天抹零（每天合计向下取整）', '结账抹零（月末一次向下取整）'];
const stageValues = ['none', 'txn', 'day', 'total'];
const unitNames = ['元（账单金额不要小数）', '角（显示到 1 位小数）', '分（显示到 2 位小数）'];
const unitValues = ['yuan', 'jiao', 'fen'];
const stageLabel = (v: string) => stageNames[stageValues.indexOf(v)] ?? '不抹零（按实际金额显示）';
const unitLabel = (v: string) => unitNames[unitValues.indexOf(v)] ?? '元（账单金额不要小数）';

function onStageChange(e: { detail: { value: number } }) {
  form.value.roundStage = stageValues[e.detail.value] || 'none';
}

function onUnitChange(e: { detail: { value: number } }) {
  form.value.roundUnit = unitValues[e.detail.value] || 'yuan';
}

// 进位临界（欠款/结账逐笔按该店进位；空=跟随全局）：0.5 四舍五入 / 0.6 5舍6入（对齐 App 文案）
const carryNames = ['跟随全局', '四舍五入（尾数≥5 进）', '5舍6入（尾数 5 舍、≥6 进）'];
const carryValues = ['', '0.5', '0.6'];
const carryLabel = (v: string) => (v ? (v === '0.5' ? '四舍五入（尾数≥5 进）' : '5舍6入（尾数 5 舍、≥6 进）') : '跟随全局');

function onCarryChange(e: { detail: { value: number } }) {
  form.value.roundCarry = carryValues[e.detail.value] || '';
}

// 价格组（店铺等级→取价档；记单按等级带出该商品组价）
const priceGroups = ref<Array<{ id: string; name: string }>>([]);
const groupNames = ref<string[]>(['不设']);
const groupIds = ref<string[]>(['']);

async function loadPriceGroups() {
  try {
    const d = await request<{ price_groups: Array<{ id: string; name: string }> }>('/price-groups', 'GET').catch(() => null);
    priceGroups.value = d?.price_groups || [];
    groupNames.value = ['不设', ...priceGroups.value.map((g) => g.name)];
    groupIds.value = ['', ...priceGroups.value.map((g) => g.id)];
  } catch (e) {
    // 价格组加载失败不阻塞（未分级保存）
  }
}

function onGroupChange(e: { detail: { value: number } }) {
  form.value.priceGroupId = groupIds.value[e.detail.value] || '';
  form.value.priceGroupName = groupNames.value[e.detail.value] || '';
}

/// 记账天数：首记日 → 今天（含当天，对齐 App _bookDays）
function bookDays(c: Client): number {
  const f = new Date(String(c.first_book_date || 'T00:00:00').slice(0, 10) + 'T00:00:00');
  if (isNaN(f.getTime())) return 0;
  const now = new Date();
  const d = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() - f.getTime();
  const days = Math.floor(d / 86400000) + 1;
  return days < 1 ? 1 : days;
}

// 店铺分类（type=client，两级：先选一级，再选子分类——对齐 App 编辑对话框两级下拉）
const cats = ref<Array<{ id: string; name: string; parent_id: string | null }>>([]);
const topCatNames = ref<string[]>([]);
const topCatIds = ref<string[]>([]);
const subCatNames = ref<string[]>([]);
const subCatIds = ref<string[]>([]);

function subCatsOf(topId: string): Array<{ id: string; name: string }> {
  return cats.value.filter((c) => c.parent_id === topId).map((c) => ({ id: c.id, name: c.name }));
}

function refreshSubCats() {
  const subs = form.value.topCatId ? subCatsOf(form.value.topCatId) : [];
  subCatNames.value = subs.map((s) => s.name);
  subCatIds.value = subs.map((s) => s.id);
}

async function loadCats() {
  try {
    const d = await request<{ categories: Array<{ id: string; name: string; parent_id: string | null }> }>('/categories?type=client', 'GET').catch(() => null);
    cats.value = d?.categories || [];
    const tops = cats.value.filter((c) => !c.parent_id);
    topCatNames.value = ['不设分类', ...tops.map((c) => c.name)];
    topCatIds.value = ['', ...tops.map((c) => c.id)];
    refreshSubCats();
  } catch (e) {
    // 分类加载失败不阻塞（未分类保存）
  }
}

function onTopCatChange(e: { detail: { value: number } }) {
  form.value.topCatId = topCatIds.value[e.detail.value] || '';
  form.value.topCatName = topCatNames.value[e.detail.value] || '';
  form.value.subCatId = '';
  form.value.subCatName = '';
  refreshSubCats();
}

function onSubCatChange(e: { detail: { value: number } }) {
  form.value.subCatId = subCatIds.value[e.detail.value] || '';
  form.value.subCatName = subCatNames.value[e.detail.value] || '';
}

onShow(async () => {
  onWs('*', load);
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await Promise.all([load(), loadCats(), loadPriceGroups()]);
});

async function load() {
  try {
    const d = await request<{ clients: Client[] }>('/clients', 'GET');
    clients.value = d.clients;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function openAdd() {
  form.value = { name: '', editId: '', monthStartDay: '1', topCatId: '', topCatName: '', subCatId: '', subCatName: '', roundStage: 'none', roundUnit: 'yuan', roundCarry: '', priceGroupId: '', priceGroupName: '' };
  refreshSubCats();
  showForm.value = true;
}

function openEdit(c: Client) {
  // 反推一级/子分类（对齐 App：curId 有父级 → 一级=父、子=cur；否则一级=cur）
  const cur = cats.value.find((x) => x.id === c.category_id);
  const top = cur && cur.parent_id ? cats.value.find((x) => x.id === cur.parent_id) : cur;
  form.value = {
    name: c.name || '',
    editId: c.id,
    monthStartDay: String(Number(c.month_start_day) || 1),
    topCatId: top?.id || '',
    topCatName: top?.name || '',
    subCatId: cur && cur.parent_id ? cur.id : '',
    subCatName: cur && cur.parent_id ? cur.name : '',
    roundStage: c.round_stage || 'none',
    roundUnit: c.round_unit || 'yuan',
    roundCarry: c.round_carry != null ? String(c.round_carry) : '',
    priceGroupId: c.price_group_id || '',
    priceGroupName: (c.price_group_id ? priceGroups.value.find((g) => g.id === c.price_group_id)?.name || '' : ''),
  };
  refreshSubCats();
  showForm.value = true;
}

async function save() {
  if (!form.value.name.trim()) {
    uni.showToast({ title: '请填写店铺名称', icon: 'none' });
    return;
  }
  const msd = Number(form.value.monthStartDay);
  if (!Number.isInteger(msd) || msd < 1 || msd > 28) {
    uni.showToast({ title: '每月起始日须为 1-28 的整数', icon: 'none' });
    return;
  }
  saving.value = true;
  try {
    const categoryId = form.value.subCatId || form.value.topCatId;
    const body: Record<string, string | number | null> = {
      name: form.value.name.trim(),
      month_start_day: msd,
      category_id: categoryId,
      round_stage: form.value.roundStage,
      round_unit: form.value.roundUnit,
      round_carry: form.value.roundCarry ? Number(form.value.roundCarry) : null,
      price_group_id: form.value.priceGroupId,
    };
    if (form.value.editId) {
      await request(`/clients/${form.value.editId}`, 'PATCH', body);
      appLog('op', `店铺 保存：「${form.value.name.trim()}」`, 'info');
    } else {
      await request('/clients', 'POST', body);
      appLog('op', `店铺 新增：「${form.value.name.trim()}」`, 'info');
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

async function remove(id: string) {
  try {
    const c = clients.value.find((x) => x.id === id);
    await request(`/clients/${id}`, 'DELETE');
    if (c) appLog('op', `店铺 删除：「${c.name}」`, 'info');
    uni.showToast({ title: '已删除', icon: 'success' });
    await load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
  }
}

// ── 店铺级交易导入/导出（对齐 App：按店铺，不是全部；CSV 格式 类型,日期,店铺,商品,数量,单位,单价,金额,备注）──

function csvField(v: unknown): string {
  const s = String(v ?? '');
  return /[,"\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}

/// 导出该店交易：拉该店出货+收款 → 组装 CSV → **保存文件并分享到微信**（用户：复制没用，要文件）
async function exportClientTrades(c: Client) {
  uni.showLoading({ title: '生成中…' });
  try {
    const cq = `&client_id=${c.id}`;
    const results = await Promise.all([
      request<{ sale_items?: Array<Record<string, any>>; sales?: Array<Record<string, any>> }>(`/sales?limit=1000${cq}`, 'GET'),
      request<{ payments: Array<Record<string, any>> }>(`/payments?limit=1000${cq}`, 'GET'),
    ]);
    const saleItems = results[0].sale_items && results[0].sale_items.length > 0 ? results[0].sale_items : [];
    const payments = results[1].payments;
    const lines = ['\uFEFF类型,日期,店铺,商品,数量,单位,单价,金额,备注'];
    for (const it of saleItems) {
      lines.push(['出货', csvField(String(it.happened_at || '').slice(0, 10)), csvField(c.name),
        csvField(it.item_name), csvField(it.quantity), csvField(it.unit), csvField(it.sale_price), csvField(it.amount), csvField(it.note)].join(','));
    }
    for (const p of payments) {
      lines.push(['收款', csvField(String(p.happened_at || '').slice(0, 10)), csvField(c.name),
        '', '', '', '', csvField(p.amount), csvField(p.method)].join(','));
    }
    uni.hideLoading();
    const fileName = `${c.name}-交易.csv`;
    // #ifdef MP-WEIXIN
    // 微信：存临时文件 → 分享文件到聊天（wx.shareFileMessage 基础库 2.16+）
    try {
      const fs = uni.getFileSystemManager();
      const filePath = `${((uni as any).env?.USER_DATA_PATH || '')}/${fileName}`;
      fs.writeFileSync(filePath, lines.join('\n'), 'utf8');
      (globalThis as any).wx?.shareFileMessage?.({
        filePath,
        fileName,
        success: () => uni.showToast({ title: `已分享「${c.name}」交易文件`, icon: 'success' }),
        fail: () => {
          fs.saveFile({ tempFilePath: filePath, success: () => uni.showToast({ title: `已保存「${c.name}」交易 CSV`, icon: 'success' }), fail: () => uni.showToast({ title: '保存失败', icon: 'none' }) });
        },
      });
      return;
    } catch (e2) {
      uni.showToast({ title: '导出失败', icon: 'none' });
      return;
    }
    // #endif
    // 其他端（H5/App）：复制剪贴板兜底
    uni.setClipboardData({
      data: lines.join('\n'),
      success: () => uni.showToast({ title: `「${c.name}」交易 CSV 已复制`, icon: 'success' }),
    });
  } catch (e) {
    uni.hideLoading();
    uni.showToast({ title: (e as Error).message || '导出失败', icon: 'none' });
  }
}

/// 导入该店交易：选择 CSV 文件（对齐 App file_picker）→ 出货走 /sales 行创建（匹配商品库带价格）、收款走 /payments
async function importClientTrades(c: Client) {
  let data = '';
  // #ifdef H5
  data = await new Promise<string>((resolve) => {
    const input = document.createElement('input') as HTMLInputElement;
    input.type = 'file';
    input.accept = '.csv,.txt,.json,text/csv,text/plain';
    input.onchange = () => {
      const f = input.files?.[0];
      if (!f) { resolve(''); return; }
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result || ''));
      reader.onerror = () => resolve('');
      reader.readAsText(f);
    };
    input.click();
  });
  // #endif
  // #ifndef H5
  // #ifdef MP-WEIXIN
  // 微信：从聊天记录选文件（uni.chooseFile 微信端不可用=之前"导入点击没用"根因）
  data = await new Promise<string>((resolve) => {
    uni.chooseMessageFile({
      count: 1,
      type: 'file',
      extension: ['csv', 'txt', 'json'],
      success: (res: any) => {
        const fp = res.tempFiles?.[0]?.path as string | undefined;
        if (!fp) { resolve(''); return; }
        uni.getFileSystemManager().readFile({
          filePath: fp,
          encoding: 'utf8',
          success: (r: any) => resolve(String(r.data || '')),
          fail: () => resolve(''),
        });
      },
      fail: () => resolve(''),
    });
  });
  // #endif
  // #ifndef MP-WEIXIN
  data = await new Promise<string>((resolve) => {
    uni.chooseFile({
      count: 1,
      extension: ['csv', 'txt', 'json'],
      success: (res) => {
        const files = (res as any).tempFiles as Array<{ path?: string }> | undefined;
        const fp = files?.[0]?.path || (res as any).tempFilePaths?.[0] as string;
        if (!fp) { resolve(''); return; }
        uni.getFileSystemManager().readFile({
          filePath: fp,
          encoding: 'utf8',
          success: (r) => resolve(String((r as any).data || '')),
          fail: () => resolve(''),
        });
      },
      fail: () => resolve(''),
    });
  });
  // #endif
  // #endif
  if (!data.trim()) {
    uni.showToast({ title: '未选择文件', icon: 'none' });
    return;
  }
  uni.showLoading({ title: '导入中…' });
  try {
    const lines = data.split('\n').filter((l) => l.trim());
    if (lines.length < 2) {
      uni.hideLoading();
      uni.showToast({ title: '文件没有 CSV 数据', icon: 'none' });
      return;
    }
    // 匹配商品库（出货行需 item_id/price_id 才能建行）
    const items = await request<{ items: Array<{ id: string; name: string; prices: Array<{ id: string; unit: string; sale_price: number; purchase_price: number }> }> }>('/items', 'GET');
    let ok = 0;
    let skip = 0;
    const BOM = '\uFEFF';
    for (const raw of lines.slice(1)) {
      const line = raw.replace(BOM, '');
      // 简易 CSV 解析（支持引号包裹字段）
      const cells: string[] = [];
      let cur = ''; let inQ = false;
      for (let i = 0; i < line.length; i++) {
        const ch = line[i];
        if (inQ) {
          if (ch === '"') { if (line[i + 1] === '"') { cur += '"'; i++; } else inQ = false; }
          else cur += ch;
        } else if (ch === '"') inQ = true;
        else if (ch === ',') { cells.push(cur); cur = ''; }
        else cur += ch;
      }
      cells.push(cur);
      if (cells.length < 5) { skip++; continue; }
      const type = cells[0].trim();
      const date = (cells[1] || '').trim();
      const itemName = (cells[3] || '').trim();
      const qty = Number(cells[4]);
      if (!qty || qty <= 0) { skip++; continue; }
      if (type === '收款' || type === 'payment') {
        await request('/payments', 'POST', {
          client_id: c.id, happened_at: date, amount: Number(cells[7] || cells[6] || 0),
          method: (cells[8] || '').trim(), note: '',
        }).catch(() => null);
        ok++;
        continue;
      }
      // 出货：匹配商品库名称
      const match = items.items.find((it) => it.name === itemName || it.name.includes(itemName) || itemName.includes(it.name));
      if (!match) { skip++; continue; }
      const unit = (cells[5] || '').trim() || match.prices[0]?.unit || '';
      const price = match.prices.find((p) => p.unit === unit) || match.prices[0];
      if (!price) { skip++; continue; }
      const salePrice = Number(cells[6]) || price.sale_price;
      await request('/sales', 'POST', {
        client_id: c.id, happened_at: date, note: (cells[8] || '').trim(),
        items: [{ price_id: price.id, quantity: qty, sale_price: salePrice }],
      }).catch(() => null);
      ok++;
    }
    uni.hideLoading();
    uni.showToast({ title: `已导入到「${c.name}」：新增 ${ok} 条，跳过 ${skip} 条`, icon: 'none', duration: 2500 });
    await load();
  } catch (e) {
    uni.hideLoading();
    uni.showToast({ title: (e as Error).message || '导入失败', icon: 'none' });
  }
}

  onHide(() => { offWs('*', load); });
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh;  background: var(--page-bg); }
/* 顶部：搜索 + 新增（对齐 App：搜索框 + 新增图标按钮同一行） */
.top-bar { display: flex; align-items: center; gap: 16rpx; margin-bottom: 20rpx; }
.search { flex: 1; min-width: 0; background: var(--card-bg); border: var(--card-border); border-radius: 12rpx; padding: 14rpx 24rpx; font-size: 26rpx; height: 76rpx; box-sizing: border-box; }
.add-btn { display: flex; align-items: center; gap: 6rpx; background: var(--primary); color: #fff; border-radius: 12rpx; padding: 0 28rpx; height: 76rpx; flex-shrink: 0; }
.add-btn .mi { font-size: 34rpx; }
.add-tx { font-size: 26rpx; font-weight: 600; }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; align-items: center; }
.left { flex: 1; min-width: 0; }
/* 头部操作：导出/导入/删除图标（对齐 App：行内图标按钮同一行） */
.head-ops { display: flex; align-items: center; gap: 8rpx; flex-shrink: 0; }
.op-ic { width: 60rpx; height: 60rpx; display: flex; align-items: center; justify-content: center; border-radius: 50%; background: var(--primary-soft); color: var(--primary); }
.op-ic .mi { font-size: 30rpx; }
.op-ic.del { background: var(--danger-bg); color: #f56c6c; }
.name { font-size: 30rpx; font-weight: bold; display: block; }
.name-line { display: flex; align-items: center; gap: 12rpx; }
.cat { font-size: 20rpx; color: var(--primary); background: var(--primary-soft); border-radius: 6rpx; padding: 2rpx 10rpx; flex-shrink: 0; }
.meta { font-size: 24rpx; color: var(--text-sub); display: block; margin-top: 6rpx; }
.field { background: var(--input-bg); border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; }
.field-inner { display: flex; align-items: center; }
.label { font-size: 24rpx; color: var(--text-sub); margin-right: 20rpx; flex-shrink: 0; }
.value { flex: 1; font-size: 28rpx; color: var(--text-main); text-align: right; }
.value.placeholder { color: var(--text-sub); }
.del { color: #f56c6c; font-size: 26rpx; }
.debt { margin-top: 16rpx; font-size: 26rpx; color: var(--text-sub); }
.debt-num { font-weight: bold; font-size: 32rpx; }
.red { color: #f56c6c; }
.green { color: #22c55e; }
/* 三格统计（对齐 App 店铺卡：记账天数/欠款/周期 + 分隔线） */
.stat-row { display: flex; align-items: center; margin-top: 18rpx; border-top: 1rpx solid var(--divider); padding-top: 16rpx; }
.stat { flex: 1; display: flex; flex-direction: column; align-items: center; gap: 4rpx; }
.stat-num { font-size: 28rpx; font-weight: bold; color: var(--text-main); }
.stat-label { font-size: 22rpx; color: var(--text-sub); }
.stat-divider { width: 1rpx; height: 36rpx; background: var(--divider); }
.stat-start { display: block; margin-top: 12rpx; font-size: 22rpx; color: var(--text-sub); }
.empty { color: var(--text-sub); text-align: center; padding: 60rpx 0; font-size: 26rpx; }
/* 编辑弹层（对齐 App 编辑对话框：居中卡片） */
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0, 0, 0, 0.45); display: flex; align-items: center; justify-content: center; z-index: 100; }
.dlg { width: 640rpx; max-width: 90%; max-height: 82vh; overflow-y: auto; background: var(--sheet-bg); border-radius: 24rpx; padding: 36rpx 32rpx; box-sizing: border-box; }
.dlg-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.dlg-ops { display: flex; gap: 20rpx; margin-top: 8rpx; }
.dlg-btn { flex: 1; text-align: center; padding: 20rpx 0; border-radius: 12rpx; font-size: 30rpx; background: var(--input-bg); color: var(--text-main); }
.dlg-btn.save { background: var(--primary); color: #fff; }
.dlg-btn.disabled { opacity: 0.6; }
.ipt { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
</style>