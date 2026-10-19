<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="card">
      <picker class="field" mode="selector" :range="clientNames" @change="onClient">
        <view class="field-inner">
          <text class="label">店铺</text>
          <text class="value">{{ clientName }}</text>
        </view>
      </picker>

      <view class="seg">
        <view :class="['seg-item', { active: period === 'month' }]" @click="applyPeriod('month')">本月</view>
        <view :class="['seg-item', { active: period === 'last' }]" @click="applyPeriod('last')">上月</view>
        <view v-if="msd > 1" :class="['seg-item', { active: period === 'cycle' }]" @click="applyPeriod('cycle')">账期本期</view>
        <view v-if="msd > 1" :class="['seg-item', { active: period === 'cycleLast' }]" @click="applyPeriod('cycleLast')">账期上期</view>
        <view :class="['seg-item', { active: period === 'custom' }]" @click="applyPeriod('custom')">自定义</view>
      </view>

      <!-- 自定义账期时才显示日期选择（对齐 App：本月/上月/账期本期/账期上期自动算起止） -->
      <view v-if="period === 'custom'" class="dates">
        <picker class="ipt" mode="date" fields="month" :value="from.slice(0, 7)" @change="onFrom">
          <view class="date-pick">{{ from.slice(0, 7) }}</view>
        </picker>
        <text class="to">至</text>
        <picker class="ipt" mode="date" fields="month" :value="to.slice(0, 7)" @change="onTo">
          <view class="date-pick">{{ to.slice(0, 7) }}</view>
        </picker>
      </view>

      <button class="btn-save" :disabled="loading" @click="load">{{ loading ? '生成中…' : '生成对账单' }}</button>

      <view v-if="loaded">
        <!-- 对账单样式（对齐 App：样式 chips 切换 + 排版工具条 标题对齐/字号） -->
        <view class="tpl-title">对账单样式</view>
        <view class="tpl-chips">
          <view v-for="t in tplList" :key="t.name" :class="['chip', { active: tpl === t.name }]" @click="setTpl(t.name)">{{ t.name }}</view>
        </view>
        <view class="toolbar">
          <text class="tb-label">标题：</text>
          <view class="tb-seg">
            <view :class="['tb-item', { active: titleAlign === 'left' }]" @click="titleAlign = 'left'">左对齐</view>
            <view :class="['tb-item', { active: titleAlign === 'center' }]" @click="titleAlign = 'center'">居中</view>
            <view :class="['tb-item', { active: titleAlign === 'right' }]" @click="titleAlign = 'right'">右对齐</view>
          </view>
          <text class="tb-label">字号：</text>
          <view class="tb-seg">
            <view :class="['tb-item', { active: fontSize === 10 }]" @click="fontSize = 10">小</view>
            <view :class="['tb-item', { active: fontSize === 12 }]" @click="fontSize = 12">中</view>
            <view :class="['tb-item', { active: fontSize === 14 }]" @click="fontSize = 14">大</view>
          </view>
        </view>
        <!-- 成品预览（按当前模板网格渲染：renderTemplateRows 行集合，view+flex 模拟表格——
        单元格横向合并 cs 宽度、底纹/加粗/对齐随模板；多列横向滚动） -->
        <view v-if="tplRows.length" class="card stmt-tbl">
          <scroll-view scroll-x class="tbl-scroll" enhanced :show-scrollbar="true">
            <view class="tbl tbl-gen">
              <view v-for="(row, ri) in tplRows" :key="'r'+ri" class="tbl-row">
                <view v-for="(cell, ci) in row" :key="'c'+ci"
                  :class="['tbl-cell', cell.g === 'grey' ? 'grey' : '', cell.b ? 'bold' : '']"
                  :style="genCellStyle(cell)">{{ cell.t }}</view>
              </view>
            </view>
          </scroll-view>
        </view>
        <!-- 统计卡（对齐 App：出货合计/收款合计 并排卡片 + 期末欠款卡片；金额纯数字不带 ¥，用户"不需要显示金额符号￥"） -->
        <view class="stat-row2">
          <view class="stat-card"><text class="stat-card-tx">出货合计</text><text class="stat-card-num red">{{ fmtAmount(saleTotal) }}（{{ sales.length }} 笔）</text></view>
          <view class="stat-card"><text class="stat-card-tx">收款合计（实收）</text><text class="stat-card-num green">{{ fmtAmount(payTotal) }}（{{ payments.length }} 笔）</text></view>
        </view>
        <view v-if="waivedTotal > 0" class="stat-card"><text class="stat-card-tx">减免合计（平账）</text><text class="stat-card-num orange">{{ fmtAmount(waivedTotal) }}</text></view>
        <view class="stat-card"><text class="stat-card-tx">期末欠款（累计）</text><text :class="['stat-card-num', debt > 0 ? 'red' : 'green']">{{ stmtFmt(debt) }}</text></view>
        <button class="btn-copy" @click="exportXlsx">导出 Excel（生成文件）</button>
        <button class="btn-copy" @click="openTpl">模板设置</button>
        <button class="btn-copy" @click="printStmt">打印（按当前模板）</button>
        <button class="btn-copy" @click="share">分享对账单（生成链接）</button>
        <button class="btn-copy" @click="manageShares">我的分享</button>
      </view>
    </view>

    <!-- 我的分享管理（对齐 App：列表 + 延期 + 删除） -->
    <view v-if="shareDlg" class="mask" @click="shareDlg = false">
      <view class="sheet" @click.stop>
        <text class="s-title">我的分享</text>
        <view v-if="shares.length === 0" class="empty">暂无分享</view>
        <scroll-view scroll-y class="share-list">
          <view v-for="s in shares" :key="s.token" class="share-row">
            <view class="share-info">
              <text class="share-url">{{ s.url }}</text>
              <text class="share-exp">过期：{{ s.expires_at || '永久' }}</text>
            </view>
            <text class="share-op" @click="extendShare(s)">延期</text>
            <text class="share-op del" @click="delShare(s)">删除</text>
          </view>
        </scroll-view>
      </view>
    </view>

    <!-- 图片打印用隐藏 canvas（2d；JS 里动态设尺寸，导出对账单图片） -->
    <canvas id="stmt-canvas" type="2d" class="stmt-canvas-hidden" />
  </view>
</template>

<script setup lang="ts">
import { onShow, onHide } from '@dcloudio/uni-app';
import { onWs, offWs } from '../../ws';

import { useThemeVars } from '../../theme';
const { tv, patternSrc } = useThemeVars();
import { ref, computed, getCurrentInstance } from 'vue';
;
;
import { request, getToken, appLog } from '../../api';
import { renderTemplateRows, xlsCfgFromJson, defaultStdTemplate, defaultMultiTemplate, type XlsCfg, type TemplateData, type GridCell } from '../../utils/stmt-tmpl';
import { roundAmount, fmtAmount, fmtByUnit, initRounding } from '../../utils/money';
// @ts-ignore 定点样式版（xlsx-js-style：官方 xlsx 0.18.5 写入端不支持 cell.s 样式——合并居中/底色全部丢失，
// 用户"小程序的 excel 全部都没有合并居中"根因；换 xlsx-js-style 后样式可写，与 App 导出一致）
import * as XLSX from 'xlsx-js-style';

const clients = ref<Array<{ id: string; name: string; round_stage?: string; round_unit?: string; month_start_day?: number }>>([]);
const clientNames = ref<string[]>(['全部店铺']);
const clientName = ref('全部店铺');
let clientId = '';

// 对账单模板（云端同步列表：App 设计器保存的模板自动出现；旧值 std/multi → 标准/多栏 兼容）
function normalizeTplName(v: string): string {
  if (v === 'std') return '标准';
  if (v === 'multi') return '多栏';
  return v;
}
const tpl = ref<string>(normalizeTplName(String(uni.getStorageSync('taozhu_stmt_tpl') || '标准')));
const tplList = ref<XlsCfg[]>([]);

/// 拉云端模板列表（无云端/离线回退内置标准/多栏）；当前选中名不在列表回退第一条
async function loadTplList() {
  try {
    const d = await request<{ templates?: Array<Record<string, any>> }>('/stmt-templates', 'GET');
    const cloud = (d?.templates ?? []).map((j) => xlsCfgFromJson(j)).filter((t) => t.name);
    tplList.value = cloud.length > 0 ? cloud : [defaultStdTemplate(), defaultMultiTemplate()];
  } catch (_) {
    tplList.value = [defaultStdTemplate(), defaultMultiTemplate()];
  }
  if (!tplList.value.some((t) => t.name === tpl.value)) tpl.value = tplList.value[0]?.name ?? '标准';
}

function setTpl(name: string) {
  tpl.value = name;
  uni.setStorageSync('taozhu_stmt_tpl', name);
  appLog('op', `对账单模板 切换：「${name}」`, 'info');
}

/// 当前选中模板（缺省第一条/内置标准）
const curTpl = computed<XlsCfg>(() => tplList.value.find((t) => t.name === tpl.value) || tplList.value[0] || defaultStdTemplate());

/// 渲染输入（对齐 App TemplateData：roundMode 固定逐笔舍入；displayUnit 跟随店铺抹零精度）
const tplData = computed<TemplateData>(() => ({
  sales: sales.value,
  payments: payments.value,
  from: from.value,
  to: to.value,
  clientName: clientName.value,
  debtEnd: debt.value,
  debtUnit: roundUnit.value || '',
  roundMode: true,
  displayUnit: roundUnit.value || 'fen',
}));

/// 当前模板成品行集合（预览/图片打印用；导出用 evalSum=false 保公式）
const tplRows = computed<GridCell[][]>(() => (curTpl.value ? renderTemplateRows(curTpl.value, tplData.value, true) : []));

/// 预览单元格样式：横向合并宽度 + 对齐
function genCellStyle(cell: GridCell) {
  return { flex: cell.cs, textAlign: cell.a as 'left' | 'center' | 'right' };
}

/// 模板设置（对齐 App「模板设置」按钮 → 独立页：选择/查看/恢复默认）
function openTpl() {
  uni.navigateTo({ url: '/pages/statement/statement-template' });
}

/// 当前店铺抹零显示精度：只有选了抹零（每单/按天/结账）才按精度；不抹零=实际金额（全局口径）
const roundUnit = computed(() => {
  const c = clients.value.find((x) => x.id === clientId);
  const stage = String(c?.round_stage || 'none');
  if (stage !== 'txn' && stage !== 'day' && stage !== 'total') return '';
  return String(c?.round_unit || '');
});

/// 对账单金额显示（对齐 App 按店铺抹零方式：不抹零=fmtAmount；抹零=fmtByUnit）
const stmtFmt = (v: number) => (roundUnit.value ? fmtByUnit(v, roundUnit.value) : fmtAmount(v));

const period = ref<'month' | 'last' | 'cycle' | 'cycleLast' | 'custom'>('month');
const from = ref('');
const to = ref('');
const loading = ref(false);
const loaded = ref(false);
const sales = ref<Array<Record<string, any>>>([]);
const payments = ref<Array<Record<string, any>>>([]);
const debt = ref(0);

// 排版工具条（对齐 App：标题对齐 + 字号；标题字号 = 正文 +2）
const titleAlign = ref<'left' | 'center' | 'right'>('center');
const fontSize = ref<10 | 12 | 14>(12);
const titleStyle = computed(() => ({
  textAlign: titleAlign.value,
  fontSize: `${(fontSize.value + 2) * 2}rpx`,
}));

/// 选中店铺的每月起始日（1=自然月，对齐 App _msd）
const msd = computed(() => {
  if (clientId) {
    const c = clients.value.find((x) => x.id === clientId);
    const v = Number(c?.month_start_day || 0);
    if (v >= 1 && v <= 28) return v;
  }
  return 1;
});

/// 结账周期（按起始日）：[起始日, 次月起始日-1]；起始日=1 时按自然月（对齐 App _cyclePeriod）
function cyclePeriod(startDay: number, anchor: Date): [string, string] {
  const p = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  if (startDay <= 1) {
    return [
      p(new Date(anchor.getFullYear(), anchor.getMonth(), 1)),
      p(new Date(anchor.getFullYear(), anchor.getMonth() + 1, 0)),
    ];
  }
  const thisStart = new Date(anchor.getFullYear(), anchor.getMonth(), startDay);
  const [s, e] = anchor.getDate() >= startDay
      ? [thisStart, new Date(anchor.getFullYear(), anchor.getMonth() + 1, startDay)]
      : [new Date(anchor.getFullYear(), anchor.getMonth() - 1, startDay), thisStart];
  return [p(s), p(new Date(e.getTime() - 86400000))];
}

const saleTotal = ref(0);
const payTotal = ref(0);

/// 减免合计（平账）：收款里 waive 部分（对齐 App _waivedTotal）
const waivedTotal = computed(() =>
  payments.value.reduce((s, p) => s + roundAmount(Number(p.waived || 0)), 0));

onShow(async () => {
  onWs('*', load);
  initRounding(); // 进入先刷新本地舍入配置（防服务器已舍入值被本地旧配置二次进位）
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  applyPeriod('month');
  try {
    const d = await request<{ clients: Array<{ id: string; name: string }> }>('/clients', 'GET');
    clients.value = d.clients;
    clientNames.value = ['全部店铺', ...d.clients.map((c) => c.name)];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
});

function today(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/// 年月直接选择（对齐"直接选年月"）：开始月=该月 1 号，结束月=该月最后一天
function onFrom(e: { detail: { value: string } }) {
  const v = e.detail.value; // YYYY-MM
  if (!v) return;
  from.value = `${v}-01`;
  const end = monthEnd(v);
  if (!to.value || to.value.slice(0, 7) < v) to.value = end;
  period.value = 'custom';
}
function onTo(e: { detail: { value: string } }) {
  const v = e.detail.value;
  if (!v) return;
  to.value = monthEnd(v);
  if (!from.value || from.value.slice(0, 7) > v) from.value = `${v}-01`;
  period.value = 'custom';
}
function monthEnd(ym: string): string {
  const [y, m] = ym.split('-').map(Number);
  const last = new Date(y, m, 0).getDate();
  return `${y}-${String(m).padStart(2, '0')}-${String(last).padStart(2, '0')}`;
}

function applyPeriod(p: 'month' | 'last' | 'cycle' | 'cycleLast' | 'custom') {
  period.value = p;
  const now = new Date();
  const p2 = (n: number) => String(n).padStart(2, '0');
  if (p === 'last') {
    const first = new Date(now.getFullYear(), now.getMonth() - 1, 1);
    const last = new Date(now.getFullYear(), now.getMonth(), 0);
    from.value = `${first.getFullYear()}-${p2(first.getMonth() + 1)}-${p2(first.getDate())}`;
    to.value = `${last.getFullYear()}-${p2(last.getMonth() + 1)}-${p2(last.getDate())}`;
  } else if (p === 'cycle' || p === 'cycleLast') {
    // 按店铺结账周期（month_start_day）：本期/上期（对齐 App _applyPeriod）
    const anchor = p === 'cycle' ? now : new Date(now.getFullYear(), now.getMonth() - 1, Math.min(now.getDate(), 28));
    const [s, e] = cyclePeriod(msd.value, anchor);
    from.value = s;
    to.value = e;
  } else if (p === 'month') {
    from.value = `${now.getFullYear()}-${p2(now.getMonth() + 1)}-01`;
    to.value = today();
  }
  // custom：保留当前起止日期，由用户改日期（对齐 App：自定义时才显示日期选择）
  // 切换账期后立即重新生成（对齐 App _applyPeriod 末尾 _load）
  if (loaded.value) load();
}

function onClient(e: { detail: { value: number } }) {
  const idx = e.detail.value;
  if (idx <= 0) { clientId = ''; clientName.value = '全部店铺'; } else {
    const c = clients.value[idx - 1];
    if (c) { clientId = c.id; clientName.value = c.name; }
  }
  // 切换店铺立即按新店铺重新生成（对齐 App onChanged 切店即 _load——之前切换后仍显示旧店铺数据）
  load();
}

function onClientPick() {
  void 0; // 占位（picker @change 走 onClient）
}

async function load() {
  if (!from.value || !to.value) {
    uni.showToast({ title: '请选择起止日期', icon: 'none' });
    return;
  }
  await loadTplList(); // 生成前刷新云端模板列表（App 设计器改的模板即时可用）
  loading.value = true;
  try {
    const cid = clientId ? `&client_id=${clientId}` : '';
    const results = await Promise.all([
      request<{ sales: any[]; sale_items?: any[] }>(`/sales?date_from=${from.value}&date_to=${to.value}&limit=1000${cid}`, 'GET'),
      request<{ payments: any[] }>(`/payments?date_from=${from.value}&date_to=${to.value}&limit=1000${cid}`, 'GET'),
      request<{ debt: number }>(`/stats/summary?start=${from.value}&end=${to.value}${cid}`, 'GET'),
    ]);
    // 去单据化主结构：优先行级 sale_items（每条商品一行，出货明细=商品行），否则整单嵌套兼容
    const saleItems = results[0].sale_items;
    sales.value = (saleItems && saleItems.length > 0) ? saleItems : (results[0].sales || []);
    payments.value = results[1].payments;
    debt.value = Number(results[2].debt || 0);
    saleTotal.value = sales.value.reduce((s, x) => s + roundAmount(Number((x.amount ?? x.total) || 0)), 0);
    payTotal.value = payments.value.reduce((s, x) => s + roundAmount(Number(x.amount || 0)), 0);
    loaded.value = true;
    appLog('op', `生成对账单：${clientName.value} ${from.value} 至 ${to.value}（出货 ${sales.value.length} 笔 / 收款 ${payments.value.length} 笔）`, 'info');
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '生成失败', icon: 'none' });
  } finally {
    loading.value = false;
  }
}

function copy() {
  if (!loaded.value) {
    uni.showToast({ title: '请先生成对账单', icon: 'none' });
    return;
  }
  const lines: string[] = [
    '【陶朱对账单】',
    `客户：${clientName.value}`,
    `周期：${from.value} 至 ${to.value}`,
    `出货合计：¥${fmtAmount(saleTotal.value)}（${sales.value.length} 笔）`,
    `收款合计：¥${fmtAmount(payTotal.value)}（${payments.value.length} 笔）`,
    `期末欠款：¥${fmtAmount(debt.value)}`,
    '—— 出货明细 ——',
  ];
  for (const s of sales.value) lines.push(`${s.happened_at} ${s.item_name || '出货'} ¥${fmtAmount(Number((s.amount ?? s.total) || 0))}`);
  lines.push('—— 收款明细 ——');
  for (const p of payments.value) {
    lines.push(`${p.happened_at}${p.method ? ' ' + p.method : ''} ¥${fmtAmount(Number(p.amount || 0))}`);
  }
  uni.setClipboardData({ data: lines.join('\n') });
  uni.showToast({ title: '对账文本已复制', icon: 'success' });
}

/// CSV 字段转义：含逗号/引号/换行的加引号包裹
function csv(v: unknown): string {
  const s = String(v ?? '');
  return s.includes(',') || s.includes('"') || s.includes('\n') ? `"${s.replaceAll('"', '""')}"` : s;
}

function copyCsv() {
  if (!loaded.value) {
    uni.showToast({ title: '请先生成对账单', icon: 'none' });
    return;
  }
  const lines: string[] = ['\uFEFF类型,日期,店铺,金额,明细'];
  for (const s of sales.value) {
    const rowAmount = Number((s.amount ?? s.total) || 0);
    const rowDetail = s.item_name
        ? `${s.item_name}${s.quantity ?? ''}${s.unit ?? ''}`
        : ((s.items || []).map((it: Record<string, any>) => `${it.item_name}${it.quantity}${it.unit}`).join(';'));
    lines.push(`出货,${csv(s.happened_at)},${csv(s.client_name)},${csv(rowAmount)},${csv(rowDetail)}`);
  }
  for (const p of payments.value) {
    lines.push(`收款,${csv(p.happened_at)},${csv(p.client_name)},${csv(p.amount)},${csv(p.method)}`);
  }
  uni.setClipboardData({ data: lines.join('\n') });
  uni.showToast({ title: 'CSV 已复制（带表头）', icon: 'success' });
}

/// 导出对账单为真正的 Excel 文件（用户要求，替代剪贴板 CSV）：SheetJS 生成 .xlsx →
/// 微信端写临时文件分享到聊天/文件、H5 端浏览器直接下载。
/// 内容=当前模板成品（对齐 App「导出 Excel」：导出用当前选中模板渲染）——
/// 标准=标题+日期/营业额 1..月末逐日（无交易日期也显示 0）+合计；多栏=每栏「日期|营业额」+小计+总计。
async function exportXlsx() {
  if (!loaded.value) {
    uni.showToast({ title: '请先生成对账单', icon: 'none' });
    return;
  }
  try {
    // Excel 金额一律纯数字（去 ¥/￥/千分位逗号/空格，防任何带符号残留；用户"不需要显示金额符号￥"）
    const toNum = (v: unknown) => {
      const n = Number(String(v ?? '').replace(/[¥￥,，\s]/g, ''));
      return Number.isFinite(n) ? n : 0;
    };
    // 内容=当前模板成品（对齐 App 导出：renderTemplateRows evalSum=false 保留 =sum 公式原文 →
    // 公式格写 cell.f；预览/打印用 evalSum=true 显示求值结果）；日期点分带年、金额纯数字由模板渲染完成
    const trows = renderTemplateRows(curTpl.value, tplData.value, false);
    const aoa: Array<Array<string | number>> = trows.map((row) => row.map((c) => c.t));
    const wb = XLSX.utils.book_new();
    const ws = XLSX.utils.aoa_to_sheet(aoa);
    // 全表样式统一（用户"excel 和打印页不是一套/字体字号格式不一致/金额不居中/表头不居中"：对齐 App：
    // 宋体 + 细边框（打印页 td 1px #666）+ 标题合并居中加粗 + 表头加粗 + 金额/日期一律居中）
    const border = { top: { style: 'thin' }, bottom: { style: 'thin' }, left: { style: 'thin' }, right: { style: 'thin' } };
    const ref = ws['!ref'] || 'A1';
    const rng = XLSX.utils.decode_range(ref);
    for (let rr = rng.s.r; rr <= rng.e.r; rr++) {
      for (let cc = rng.s.c; cc <= rng.e.c; cc++) {
        const addr = XLSX.utils.encode_cell({ r: rr, c: cc });
        const cell = ws[addr];
        if (!cell) continue;
        if (rr === 0) {
          // 标题行：居中加粗大字（合并跨整行）
          cell.s = { font: { name: '宋体', bold: true, sz: 14 }, alignment: { horizontal: 'center', vertical: 'center' }, border };
        } else if (rr === 1) {
          // 表头（日期/营业额）：加粗居中，无底色（用户"日期营业额那栏不要背景颜色"）
          cell.s = { font: { name: '宋体', bold: true, sz: 12 }, alignment: { horizontal: 'center', vertical: 'center' }, border };
        } else {
          // 正文（日期/金额/小计/合计/总计）：居中（用户"金额那里不居中，第一栏金额和第二栏日期挨着"）
          cell.s = { font: { name: '宋体', sz: 11 }, alignment: { horizontal: 'center', vertical: 'center' }, border };
        }
      }
    }
    // 总列数（展开 colSpan；列宽压缩判断用）
    const colN = trows.reduce((m, r) => {
      let w = 0;
      for (const c of r) w += c.cs < 1 ? 1 : c.cs;
      return w > m ? w : m;
    }, 0);
    // 合并 colSpan/rowSpan 区（标题跨列居中——Excel 与打印/预览一致）
    const merges: Array<{ s: { r: number; c: number }; e: { r: number; c: number } }> = [];
    for (let ri = 0; ri < trows.length; ri++) {
      let col = 0;
      for (const c of trows[ri]) {
        if (c.cs > 1 || c.rs > 1) {
          merges.push({
            s: { r: ri, c: col },
            e: { r: ri + (c.rs > 1 ? c.rs - 1 : 0), c: col + (c.cs > 1 ? c.cs - 1 : 0) },
          });
        }
        col += c.cs < 1 ? 1 : c.cs;
      }
    }
    if (merges.length > 0) ws['!merges'] = merges;
    // 合计/小计/总计公式格（对齐 App 模板 =sum(...)：不是死数字，改动自动重算）——
    // 公式文本不带 = 前缀（SheetJS 原样写入 <f>，带 = 会变成 ==SUM 非法公式——openpyxl 验证）
    for (let ri = 0; ri < trows.length; ri++) {
      let col = 0;
      for (const c of trows[ri]) {
        const t = c.t.trim();
        if (t.startsWith('=')) {
          const cell = ws[XLSX.utils.encode_cell({ r: ri, c: col })];
          if (cell) cell.f = t.slice(1);
        }
        col += c.cs < 1 ? 1 : c.cs;
      }
    }
    XLSX.utils.book_append_sheet(wb, ws, '对账单');
    // 列宽：多栏（≥6 列）压缩到一页打印（用户"31号那2栏和之前的不在一页，要一页打印"）——
    // 8 列总宽 = 4*8 + 4*10 = 72 字符不超 A4；标准 2 列维持宽松
    const ws2 = wb.Sheets['对账单'];
    const widths: Array<{ wch: number }> = [];
    const compact = colN >= 6;
    for (let c = 0; c < colN; c++) widths.push({ wch: compact ? (c % 2 === 0 ? 8 : 10) : (c % 2 === 0 ? 12 : 14) });
    if (ws2) ws2['!cols'] = widths;
    // cellStyles: 保留标题/表头/边框样式
    const out = XLSX.write(wb, { bookType: 'xlsx', type: 'array', cellStyles: true }) as ArrayBuffer;
    const fileName = `${clientName.value.replace(/\s+/g, '')}-对账单.xlsx`;
    // #ifdef MP-WEIXIN
    try {
      const fs = uni.getFileSystemManager();
      const filePath = `${((uni as any).env?.USER_DATA_PATH) || ''}/${fileName}`;
      fs.writeFileSync(filePath, out);
      (globalThis as any).wx?.shareFileMessage?.({
        filePath,
        fileName,
        success: () => uni.showToast({ title: `已分享「${fileName}」`, icon: 'success' }),
        fail: () => uni.showToast({ title: '分享失败', icon: 'none' }),
      });
      appLog('op', `导出对账单 Excel：${clientName.value} ${from.value} 至 ${to.value}`, 'info');
      return;
    } catch (e2) {
      uni.showToast({ title: '生成 Excel 失败', icon: 'none' });
      return;
    }
    // #endif
    // H5/其他端：浏览器直接下载
    XLSX.writeFile(wb, fileName);
    appLog('op', `导出对账单 Excel：${clientName.value} ${from.value} 至 ${to.value}`, 'info');
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '生成 Excel 失败', icon: 'none' });
  }
}

/// 图片打印对账单（对齐 App 图片打印：所见即所得）：把模板行集合绘制成 PNG 图片——
/// 微信端保存相册（可打印）+ 预览；H5 端新窗口打开图片（浏览器可打印/右键保存）。
/// 不再生成 .html 文件分享（用户"打印生成的 html 不好用，改成生成图片"）。
async function printStmt() {
  if (!loaded.value) {
    uni.showToast({ title: '请先生成对账单', icon: 'none' });
    return;
  }
  // 模板行集合 [文本, 对齐, 加粗, 底纹, rowspan, colspan]（与 App 模板渲染行集合同构；类型见 drawStmtImage 上方）
  const trows: PrintCell[][] = renderTemplateRows(curTpl.value, tplData.value, true).map((row) =>
      row.map((c) => [c.t, c.a, c.b, c.g, c.rs, c.cs] as PrintCell));
  let colN = 0;
  for (const r of trows) {
    let w = 0;
    for (const c of r) w += (c[5] || 1);
    colN = w > colN ? w : colN;
  }
  // #ifdef MP-WEIXIN
  try {
    const canvas = await drawStmtImage(trows, colN);
    (uni.canvasToTempFilePath as any)({
      canvas,
      success: (r: { tempFilePath: string }) => {
        const fp = r.tempFilePath;
        uni.saveImageToPhotosAlbum({
          filePath: fp,
          success: () => {
            uni.previewImage({ urls: [fp] });
            uni.showToast({ title: '对账单图片已保存到相册（可打印）', icon: 'success' });
          },
          fail: () => {
            uni.previewImage({ urls: [fp] });
            uni.showToast({ title: '图片已生成，请长按保存到相册', icon: 'none' });
          },
        });
      },
      fail: () => uni.showToast({ title: '生成图片失败', icon: 'none' }),
    });
    appLog('op', `图片打印对账单：${clientName.value} ${from.value} 至 ${to.value}`, 'info');
    return;
  } catch (e2) {
    uni.showToast({ title: '生成图片失败', icon: 'none' });
    return;
  }
  // #endif
  // H5/其他端：canvas 生成图片 → 新窗口打开（浏览器可直接打印/右键保存）
  try {
    const canvas = await drawStmtImage(trows, colN);
    const dataUrl = (canvas as any).toDataURL('image/png');
    window.open(dataUrl, '_blank');
    appLog('op', `图片打印对账单：${clientName.value} ${from.value} 至 ${to.value}`, 'info');
  } catch (e) {
    uni.showToast({ title: '生成图片失败', icon: 'none' });
  }
}

/// 模板行集合 [文本, 对齐, 加粗, 底纹, rowspan, colspan]（与 App 模板渲染行集合同构）
type PrintCell = [string, string, boolean, string, number, number];

/// 把模板行集合绘制到隐藏 canvas（2d）并返回 canvas 节点：
/// 列宽按内容自适应（measureText 实测每列最大宽），标题行加粗大字，全格细边框 + 浅灰底纹，
/// 金额/日期居中、小计/合计加粗——与页面成品预览一致（所见即所得）。
function drawStmtImage(trows: PrintCell[][], colN: number): Promise<any> {
  return new Promise((resolve, reject) => {
    const inst = getCurrentInstance();
    const query = inst ? uni.createSelectorQuery().in(inst.proxy) : uni.createSelectorQuery();
    query.select('#stmt-canvas').fields({ node: true, size: true }, (res) => {
      const canvas = (res as any[])?.[0]?.node;
      if (!canvas) {
        reject(new Error('canvas 初始化失败'));
        return;
      }
      const ctx = canvas.getContext('2d');
      const fs = 13, padX = 10, rowH = 34, headH = 46;
      ctx.font = `${fs}px sans-serif`;
      const widths: number[] = new Array(colN).fill(0);
      trows.forEach((row) => {
        let ci = 0;
        row.forEach((cell: PrintCell) => {
          const span = cell[5] || 1;
          const per = (ctx.measureText(cell[0]).width + padX * 2) / span;
          for (let k = 0; k < span; k++) widths[ci + k] = Math.max(widths[ci + k], per);
          ci += span;
        });
      });
      const W = Math.max(1, Math.round(widths.reduce((a, b) => a + b, 0)));
      const H = headH + (trows.length - 1) * rowH;
      canvas.width = W;
      canvas.height = H;
      ctx.font = `${fs}px sans-serif`;
      ctx.textBaseline = 'middle';
      let y = 0;
      trows.forEach((row, ri) => {
        const rh = ri === 0 ? headH : rowH;
        let x = 0;
        let ci = 0;
        row.forEach((cell: PrintCell) => {
          const span = cell[5] || 1;
          const cw = widths.slice(ci, ci + span).reduce((a, b) => a + b, 0);
          if (cell[3] === 'grey') {
            ctx.fillStyle = '#f2f2f2';
            ctx.fillRect(x, y, cw, rh);
          }
          ctx.strokeStyle = '#666';
          ctx.lineWidth = 1;
          ctx.strokeRect(x, y, cw, rh);
          ctx.fillStyle = '#000';
          ctx.font = `${cell[2] ? 'bold ' : ''}${ri === 0 ? fs + 3 : fs}px sans-serif`;
          const tw = ctx.measureText(cell[0]).width;
          let tx = x + padX;
          if (cell[1] === 'center') tx = x + (cw - tw) / 2;
          else if (cell[1] === 'right') tx = x + cw - padX - tw;
          ctx.fillText(cell[0], tx, y + rh / 2);
          x += cw;
          ci += span;
        });
        y += rh;
      });
      resolve(canvas);
    });
  });
}

type ShareItem = { token: string; url?: string; expires_at?: string; created_at?: string };
const shares = ref<ShareItem[]>([]);
const shareDlg = ref(false);

/// 分享对账单：选失效时间 → POST /share 生成链接 → 复制（对齐 App：对方浏览器打开即可查看）
async function share() {
  if (!loaded.value) {
    uni.showToast({ title: '请先生成对账单', icon: 'none' });
    return;
  }
  const ttlOptions: Array<[string, number]> = [['3 天', 72], ['7 天', 168], ['1 个月', 720], ['永久', 0]];
  uni.showActionSheet({
    itemList: ttlOptions.map((o) => o[0]),
    success: async (r) => {
      const ttl = ttlOptions[r.tapIndex]?.[1] ?? 0;
      const payload = JSON.stringify({
        client: clientName.value,
        from: from.value,
        to: to.value,
        debt: debt.value,
        sales: sales.value.map((s) => ({
          date: s.happened_at,
          name: s.client_name || clientName.value,
          items: s.item_name
            ? `${s.item_name}${s.quantity ?? ''}${s.unit ?? ''}`
            : ((s.items || []).map((it: Record<string, any>) => `${it.item_name} ×${it.quantity}${it.unit}`).join('、')),
          amount: Number((s.amount ?? s.total) || 0),
        })),
        payments: payments.value.map((p) => ({
          date: p.happened_at,
          method: p.method || '',
          amount: Number(p.amount || 0),
          waived: Number(p.waived || 0),
        })),
      });
      uni.showLoading({ title: '生成分享链接…' });
      try {
        const d = await request<{ url?: string; expires_at?: string }>('/share', 'POST', { payload, ttl_hours: ttl });
        uni.hideLoading();
        const url = d?.url || '';
        if (!url) throw new Error('empty url');
        uni.showModal({
          title: '分享链接已生成',
          content: `对方用浏览器打开即可查看对账单：\n\n${url}\n\n链接在选定时间后自动失效。`,
          confirmText: '复制链接',
          cancelText: '好',
          success: (m) => {
            if (m.confirm) {
              uni.setClipboardData({ data: url });
              uni.showToast({ title: '链接已复制', icon: 'success' });
            }
          },
        });
      } catch (e) {
        uni.hideLoading();
        uni.showToast({ title: '生成分享失败', icon: 'none' });
      }
    },
  });
}

/// 我的分享列表（admin 才可用；staff 被拒静默）
async function manageShares() {
  try {
    const d = await request<{ shares?: ShareItem[] }>('/share', 'GET');
    shares.value = d?.shares || [];
  } catch (_) {
    shares.value = [];
  }
  shareDlg.value = true;
}

async function extendShare(s: ShareItem) {
  try {
    await request(`/share/${s.token}`, 'PATCH', { ttl_hours: 720 });
    uni.showToast({ title: '已延期 1 个月', icon: 'success' });
    manageShares();
  } catch (e) {
    uni.showToast({ title: '延期失败', icon: 'none' });
  }
}

async function delShare(s: ShareItem) {
  uni.showModal({
    title: '删除分享',
    content: '删除后链接立即失效，确认？',
    success: async (r) => {
      if (!r.confirm) return;
      try {
        await request(`/share/${s.token}`, 'DELETE', {});
        uni.showToast({ title: '已删除', icon: 'success' });
        manageShares();
      } catch (e) {
        uni.showToast({ title: '删除失败', icon: 'none' });
      }
    },
  });
}

  onHide(() => { offWs('*', load); });
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh;  background: var(--page-bg); }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 24rpx; margin-bottom: 20rpx; }
.field { margin-bottom: 20rpx; }
.field-inner { display: flex; justify-content: space-between; }
.label { color: var(--text-sub); font-size: 26rpx; }
.value { font-size: 28rpx; }
.seg { display: flex; background: var(--input-bg); border-radius: 12rpx; margin-bottom: 20rpx; overflow: hidden; }
.seg-item { flex: 1; text-align: center; padding: 16rpx; font-size: 26rpx; color: var(--text-sub); }
.seg-item.active { color: var(--primary); font-weight: bold; background: var(--primary-soft); }
.dates { display: flex; align-items: center; gap: 12rpx; margin-bottom: 20rpx; }
.ipt { flex: 1; background: var(--input-bg); border-radius: 12rpx; padding: 16rpx 20rpx; font-size: 26rpx; }
.date-pick { color: var(--text-main); }
.to { color: var(--text-sub); }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; margin-bottom: 20rpx; }
.btn-copy { background: var(--card-bg); border: 1rpx solid var(--primary); color: var(--primary); border-radius: 12rpx; font-size: 28rpx; margin-top: 12rpx; }
.stat { display: flex; justify-content: space-between; padding: 12rpx 0; font-size: 28rpx; }
.red { color: #f56c6c; }
.green { color: #67c23a; }
/* 对账单表格（对齐 App 标准模板形态） */
.stmt-tbl { padding: 0; overflow: hidden; }
.t-title { font-size: 32rpx; font-weight: bold; text-align: center; padding: 24rpx 24rpx 4rpx; color: var(--text-main); }
.t-sub { font-size: 24rpx; color: var(--text-sub); text-align: center; padding: 0 24rpx 16rpx; }
.t-head, .t-row { display: flex; align-items: center; padding: 12rpx 24rpx; }
/* 表头无底色（对齐 App：用户"日期营业额那行文字有底部颜色要去掉"） */
.t-head { font-size: 24rpx; color: var(--text-sub); font-weight: 600; border-bottom: 1rpx solid var(--divider); }
.t-row { border-bottom: 1rpx solid var(--divider); font-size: 26rpx; color: var(--text-main); }
/* 对账单样式 chips（对齐 App ChoiceChip：胶囊、选中主题色） */
.tpl-title { font-size: 30rpx; font-weight: 600; margin: 24rpx 0 12rpx; color: var(--text-main); }
.tpl-chips { display: flex; gap: 16rpx; margin-bottom: 16rpx; }
.chip { padding: 10rpx 30rpx; border-radius: 999rpx; font-size: 24rpx; color: var(--text-sub); background: var(--card-bg); border: 1rpx solid var(--divider); }
.chip.active { color: #fff; background: var(--primary); border-color: var(--primary); }
/* 排版工具条（对齐 App：标题对齐 + 字号） */
.toolbar { display: flex; align-items: center; flex-wrap: wrap; gap: 12rpx; margin-bottom: 16rpx; }
.tb-label { font-size: 24rpx; color: var(--text-sub); }
.tb-seg { display: flex; background: var(--input-bg); border-radius: 10rpx; overflow: hidden; }
.tb-item { padding: 8rpx 20rpx; font-size: 24rpx; color: var(--text-sub); }
.tb-item.active { background: var(--primary); color: #fff; }
/* 统计卡（对齐 App _statCard：圆角卡片、标签在上金额在下） */
.stat-row2 { display: flex; gap: 16rpx; margin-top: 20rpx; }
.stat-card { flex: 1; background: var(--card-bg); border: var(--card-border); border-radius: 16rpx; padding: 20rpx 24rpx; display: flex; flex-direction: column; gap: 8rpx; margin-top: 16rpx; }
.stat-row2 .stat-card { margin-top: 16rpx; }
.stat-card-tx { font-size: 24rpx; color: var(--text-sub); }
.stat-card-num { font-size: 30rpx; font-weight: 700; color: var(--text-main); }
.orange { color: #f59e0b; }
/* 成品预览卡片（对齐 App：白卡 + 边框含预览表格） */
.preview-card { background: var(--card-bg); border: var(--card-border); border-radius: 16rpx; padding: 16rpx; margin-top: 16rpx; }
/* 成品表格（view+flex 模拟，小程序不支持 table 语义；每格四边浅灰线、金额右对齐纯数字，对齐 App） */
.tbl { margin-top: 8rpx; border-top: 1rpx solid #d9d9d9; border-left: 1rpx solid #d9d9d9; }
.tbl-row { display: flex; }
.tbl-cell { flex: 1; min-width: 0; border-right: 1rpx solid #d9d9d9; border-bottom: 1rpx solid #d9d9d9; padding: 8rpx 6rpx; text-align: center; font-size: 24rpx; color: var(--text-main); }
.tbl-cell.grey { background: #f0f2f5; }
.tbl-cell.bold { font-weight: 700; }
.tbl-gen .tbl-cell { min-width: 150rpx; }
.tbl-cell.amt { text-align: right; }
.tbl-head .tbl-cell { font-weight: 600; color: var(--text-sub); }
.tbl-foot .tbl-cell { font-weight: 700; color: var(--text-main); }
/* 多栏（8 列）横向滚动容器：内容按固定格宽扩展，Scroll 可全部看到（对齐 App SingleChildScrollView；31 号不挤） */
.tbl-scroll { width: 100%; white-space: nowrap; }
.tbl-multi .tbl-cell { flex: none; width: 110rpx; min-width: 110rpx; white-space: nowrap; }
.tbl-multi .tbl-cell.amt { width: 130rpx; min-width: 130rpx; }
/* 模板切换（标准/多栏） */
.tpl-seg { margin-bottom: 20rpx; }
/* 多栏月账单（寻牛记式：每栏 日期+营业额 双列） */
.m-row { display: flex; border-bottom: 1rpx solid var(--divider); }
/* 多栏表头无底色（对齐 App 表头去底） */
.m-head { font-weight: 600; color: var(--text-sub); font-size: 22rpx; }
.m-col { flex: 1; display: flex; flex-direction: column; align-items: center; padding: 10rpx 2rpx; border-left: 1rpx solid var(--divider); }
.m-col:first-child { border-left: none; }
.m-date { font-size: 20rpx; color: var(--text-sub); }
.m-amt { font-size: 24rpx; color: var(--text-main); }
.m-amt.bold { font-weight: 700; }
.m-sub { background: var(--primary-soft); }
.m-total { display: flex; justify-content: space-between; padding: 14rpx 24rpx; font-weight: 700; font-size: 26rpx; border-top: 1rpx solid var(--divider); }
.c-date { width: 110rpx; flex-shrink: 0; font-size: 24rpx; color: var(--text-sub); }
.c-detail { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.c-amt { width: 150rpx; flex-shrink: 0; text-align: right; }
.t-pay { color: #67c23a; }
.t-group { border-bottom: 1rpx solid var(--divider); }
.t-day { display: flex; justify-content: space-between; align-items: center; padding: 14rpx 24rpx; background: var(--primary-soft); }
.t-day-label { font-size: 26rpx; font-weight: 600; color: var(--text-main); }
.t-day-total { font-size: 24rpx; color: var(--text-sub); }
.t-total { display: flex; justify-content: space-between; padding: 12rpx 24rpx; font-size: 26rpx; font-weight: 600; border-bottom: 1rpx solid var(--divider); color: var(--text-main); }
.t-total:last-child { border-bottom: none; }
.empty { color: var(--text-sub); text-align: center; padding: 24rpx 0; font-size: 26rpx; }
/* 我的分享弹层 */
.mask { position: fixed; left: 0; top: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.45); z-index: 100; display: flex; align-items: flex-end; }
.sheet { width: 100%; background: var(--page-bg); border-radius: 28rpx 28rpx 0 0; padding: 28rpx 24rpx calc(28rpx + env(safe-area-inset-bottom)); max-height: 75vh; display: flex; flex-direction: column; }
.s-title { font-size: 32rpx; font-weight: bold; text-align: center; margin-bottom: 20rpx; color: var(--text-main); }
.share-list { flex: 1; min-height: 0; max-height: 50vh; }
.share-row { display: flex; align-items: center; gap: 12rpx; padding: 16rpx 0; border-bottom: 1rpx solid var(--divider); }
.share-info { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 4rpx; }
.share-url { font-size: 22rpx; color: var(--text-main); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.share-exp { font-size: 20rpx; color: var(--text-sub); }
.share-op { font-size: 24rpx; color: var(--primary); padding: 8rpx 16rpx; flex-shrink: 0; }
.share-op.del { color: #f56c6c; }
/* 图片打印隐藏 canvas：移到屏幕外，尺寸由 JS 按内容动态设置 */
.stmt-canvas-hidden { position: fixed; left: -9999rpx; top: 0; width: 300px; height: 300px; }
</style>