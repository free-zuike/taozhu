<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <!-- 店铺筛选（缩窄，与搜索同一行——对齐 App：店铺选择+搜索同行，不单独占一行） -->
    <view class="filter-bar">
      <picker class="client-picker" mode="selector" :range="clientNames" @change="onClientFilter">
        <view class="client-btn">{{ filterClientId ? filterClientName : '全部店铺' }} ▾</view>
      </picker>
      <input class="search" v-model="searchQ" placeholder="搜索商品 / 店铺 / 备注" confirm-type="search" />
    </view>

    <!-- 月度卡（对齐 App：左侧年月两层点击切换 + 竖线 + 右侧四列统计；列表全量，月份只影响统计卡） -->
    <view class="month-card">
      <picker class="month-left" mode="date" fields="month" :value="monthVal" @change="onPickMonth">
        <text class="month-y">{{ selYear }}年</text>
        <view class="month-row">
          <text class="month-m">{{ selMonth }}月</text>
          <text class="month-caret">▾</text>
        </view>
        <text class="month-tip">点击切换</text>
      </picker>
      <view class="mdivider"></view>
      <view class="mcols">
        <view class="mcol"><text class="ml">售出</text><text class="mv" style="color:var(--primary)">¥{{ fmtNum(mSold) }}</text></view>
        <view class="mcol"><text class="ml">未回款</text><text class="mv" :style="{ color: mDebt > 0 ? '#f59e0b' : '#909399' }">¥{{ fmtNum(mDebt) }}</text></view>
        <view class="mcol"><text class="ml">结余</text><text class="mv" :style="{ color: mBalance >= 0 ? '#22c55e' : '#ef4444' }">¥{{ fmtNum(mBalance) }}</text></view>
      </view>
    </view>

    <view class="seg">
      <view :class="['seg-item', { active: tab === 'sales' }]" @click="switchTab('sales')">出货</view>
      <view :class="['seg-item', { active: tab === 'payments' }]" @click="switchTab('payments')">收款</view>
    </view>

    <scroll-view scroll-y class="flow" @scroll="onFlowScroll">
    <view v-if="tab === 'sales'">
      <!-- 按日期分组 + 商品明细行平铺（对齐 App：日期头 + 流水行卡片） -->
      <view v-for="g in saleGroups" :key="g.date">
        <view class="day-bar" :data-date="g.date" @click="openSaleBatch(g.date)">
          <text class="mi day-ic">&#xe742;</text>
          <text class="day-name">{{ g.week }}</text>
          <text class="day-total">{{ g.count }} 件 · 合计 ¥{{ fmtNum(g.amount) }}</text>
          <text class="mi day-arrow">&#xe5cc;</text>
        </view>
        <view v-for="l in g.lines" :key="l.key" class="card-sale" :class="profitClass(l)" @click="editSaleLine(l)" @longpress="deleteSaleLine(l)">
          <view class="line-top">
            <view class="store-ic"><text class="mi st-tx">&#xeA12;</text></view>
            <view class="line-main">
              <!-- ① 商品名+备注（全店视图才前缀店名，选中店铺不显示——对齐 App） -->
              <text class="line-name">{{ filterClientId ? l.item_name : (l.client_name ? l.client_name + ' · ' + l.item_name : l.item_name) }}<text class="line-note" v-if="l.note">  {{ l.note }}</text></text>
              <!-- ② 分类 + 凭证（图片图标，对齐 App Icons.image_outlined） -->
              <view class="line-subrow">
                <text class="l2-cat">{{ l.category || '未分类' }}</text>
                <view class="attach-entry" @click.stop="showAttach(l.itemId ? 'sale_item' : 'sale', l.itemId || l.orderId, 'sale', l.orderId)">
                  <image class="attach-ic" :class="{ 'attach-ic-off': attachOf(l) <= 0 }" :src="attachIconSrc" mode="aspectFit" />
                  <text v-if="attachOf(l) > 0" class="attach-cnt">{{ attachOf(l) }}</text>
                </view>
              </view>
            </view>
            <text class="amt">¥{{ fmtNum(l.amount) }}</text>
          </view>
          <!-- ③ 进价 · 重量 × 售价（用户定稿：重量带「重量」标签在前，× 连接售价在后；老板看进价） -->
          <view class="line-bottom">
            <text v-if="isAdmin && l.cost_price > 0" class="l2-tx">进价 ¥{{ fmtPrice(l.cost_price) }} · </text>
            <text v-if="l.quantity !== ''" class="l2-tx">重量{{ l.quantity }}{{ l.unit }} × </text>
            <text class="l2-tx">售价 ¥{{ fmtPrice(l.sale_price || 0) }}</text>
            <text v-if="isAdmin && l.cost_price > 0" class="l2-profit" :class="profitText(l)">{{ profitText(l) }}</text>
          </view>
        </view>
      </view>
      <view v-if="saleGroups.length === 0" class="empty">暂无出货记录</view>
    </view>

    <view v-if="tab === 'payments'">
      <view v-for="p in filteredPayments" :key="p.id" class="card" @click="editPayment(p)" @longpress="removePayment(p)">
        <view class="head">
          <text class="name">{{ p.client_name }}</text>
          <text class="amt" style="color:#67c23a">¥{{ fmtNum(p.amount) }}</text>
        </view>
        <view class="sub">{{ p.happened_at }}<text v-if="p.method"> · {{ p.method }}</text></view>
        <view class="ops">
          <!-- 收款附件入口（对齐 App：有附件才显示图标+数量，点开查看/添加） -->
          <view v-if="(attachCounts.payment[p.id] || 0) > 0" class="attach-entry" @click.stop="showAttach('payment', p.id)">
            <image class="attach-ic" :src="attachIconSrc" mode="aspectFit" />
            <text class="attach-cnt">{{ attachCounts.payment[p.id] }}</text>
          </view>
          <text class="tip-longpress" @click.stop>长按撤销该收款</text>
        </view>
      </view>
      <view v-if="filteredPayments.length === 0" class="empty">暂无收款记录</view>
    </view>
    </scroll-view>

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

    <!-- 单商品编辑弹层：竖排字段对齐 App sale_line_edit（数量/单位/折合/售价/日期/分类/附件/备注） -->
    <view v-if="itemForm.show" class="mask" @click="itemForm.show = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">编辑「{{ itemForm.itemName }}」</view>
        <view class="sheet-body">
        <scroll-view scroll-y class="sheet-body-scroll">
        <view class="form-row v">
          <text class="f-label">数量</text>
          <input class="ipt" v-model="itemForm.quantity" type="digit" placeholder="0" />
        </view>
        <view class="form-row v">
          <text class="f-label">单位（斤/件/箱…）</text>
          <input class="ipt" v-model="itemForm.unit" placeholder="斤/件/箱…" />
        </view>
        <view v-if="itemForm.countUnit" class="form-row v">
          <text class="f-label">折合 {{ itemForm.countUnit }} 数（可选）</text>
          <input class="ipt" v-model="itemForm.countQty" type="digit" placeholder="0" />
        </view>
        <view class="form-row v">
          <text class="f-label">{{ itemForm.isPurchase ? '进价（元）' : '售价（元）' }}</text>
          <input class="ipt" v-model="itemForm.salePrice" type="digit" placeholder="0" />
        </view>
        <!-- 日期：picker 原生滚轮（对齐 App 行编辑 DateField，不可手输） -->
        <picker class="form-row v" mode="date" :value="itemForm.date || today" @change="onFormDate">
          <view class="f-pick">
            <text class="label">日期</text>
            <text class="value" :class="{ placeholder: !itemForm.date }">{{ itemForm.date || '选择日期' }}</text>
          </view>
        </picker>
        <!-- 商品分类（商品级，全局生效）：点击「修改分类」选择后即时保存（对齐 App changeCategory） -->
        <view class="form-row v">
          <view class="f-info">
            <text class="label">商品分类</text>
            <text class="value" :class="{ placeholder: !itemForm.category }">{{ itemForm.category || '未分类' }}</text>
          </view>
          <text class="f-act" @click="changeItemCategory">修改分类</text>
        </view>
        <!-- 该条凭证附件（对齐 App 行编辑弹窗：查看/添加，点击直接全屏查看器） -->
        <view class="attach-row" @click="openFormAttach">
          <text class="label">该条凭证附件</text>
          <text class="value attach-go">查看/添加</text>
        </view>
        <view class="form-row v">
          <text class="f-label">备注（该条商品，可留空）</text>
          <input class="ipt" v-model="itemForm.note" placeholder="备注（选填）" />
        </view>
        </scroll-view>
        </view>
        <view class="dlg-ops">
          <button class="btn-del" :disabled="saving" @click="deleteItem">删除该行</button>
          <button class="btn-save" :disabled="saving" @click="saveItem">{{ saving ? '保存中…' : '保存' }}</button>
        </view>
      </view>
    </view>
  <!-- 修改商品分类弹层（两级目录：一级加粗、二级缩进，对齐 App changeCategory SimpleDialog） -->
    <view v-if="catDlg" class="mask" @click="catDlg = false">
      <view class="sheet cat-sheet" @click.stop>
        <text class="s-title">选择商品分类</text>
        <scroll-view scroll-y class="cat-scroll">
          <view class="cat-opt" @click="pickCategory('')">无分类</view>
          <view v-for="p in catParents" :key="p.id">
            <view class="cat-opt cat-opt-p" @click="pickCategory(p.id)">{{ p.name }}</view>
            <view v-for="ch in catChildrenOf(p.id)" :key="ch.id" class="cat-opt cat-opt-c" @click="pickCategory(ch.id)">{{ ch.name }}</view>
          </view>
        </scroll-view>
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
import { request, getToken, getRole } from '../../api';
import { attachIconSrc } from '../../attach-icon';
import { fmtAmount, roundAmount, fmtPrice } from '../../utils/money';

const tab = ref<'sales' | 'payments'>('sales');
// 老板才显示行级盈亏（进价=毛利敏感数据，店员隐藏；对齐 App 仅老板可见毛利）
const isAdmin = ref(getRole() !== 'staff');
const sales = ref<Array<Record<string, any>>>([]);
const payments = ref<Array<Record<string, any>>>([]);
// 搜索关键词（按 商品名/店铺名/备注 本地过滤出货+收款——对齐 App 前端行级过滤零网络）
const searchQ = ref('');
const saving = ref(false);
// 月份只由顶部月度卡选择器控制（pickMonth），滚动不再联动改月份（0.17.317 已移除联动）
// 收款账户：服务器同步实体（云端直连读取）
const accounts = ref<string[]>(['现金', '微信', '支付宝', '银行卡', '转账']);
const payForm = ref<{
  show: boolean; id: string; amount: string; date: string; method: string; methodIdx: number; note: string;
}>({ show: false, id: '', amount: '', date: '', method: '', methodIdx: 0, note: '' });

// 单商品编辑（明细行级）：只改该商品数量/单位/折合计数/售价/日期/备注/分类（对齐 App 单行编辑）
const itemForm = ref<{
  show: boolean; isPurchase: boolean; saleId: string; itemId: string; goodsId: string; itemName: string;
  quantity: string; unit: string; salePrice: string; countQty: string; countUnit: string; date: string; note: string;
  category: string; categoryId: string; // 当前分类名/id（修改分类行显示与保存）
}>({ show: false, isPurchase: false, saleId: '', itemId: '', goodsId: '', itemName: '', quantity: '', unit: '', salePrice: '', countQty: '', countUnit: '', date: '', note: '', category: '', categoryId: '' });

const today = new Date().toISOString().slice(0, 10);

// 日期选择（picker mode=date，对齐 App 行编辑滚轮，不可手输）
function onFormDate(e: { detail: { value: string } }) {
  itemForm.value.date = e.detail.value;
}

// 打开该条凭证（行级优先、单据级回退，直接全屏查看器）
function openFormAttach() {
  const f = itemForm.value;
  if (!f.saleId) return;
  showAttach(f.isPurchase ? 'purchase_item' : 'sale_item', f.itemId, f.isPurchase ? 'purchase' : 'sale', f.saleId);
}

// ── 附件凭证 ──
const attachCounts = ref<Record<string, Record<string, number>>>({ sale_item: {}, sale: {}, payment: {} });
// 附件变更（独立查看器页内增删后）→ 回本页刷新计数
uni.$on('attach-changed', () => { loadAttachCounts(); });

/** 行级附件数：有行 id 按 sale_item 查，行级空回退该单（识别原图挂首个商品行，其他行共用）；
 *  无明细（备注占位行）直接按单据级 sale 查 */
function attachOf(l: SaleLine): number {
  const m = attachCounts.value;
  if (!l.itemId) return m.sale[l.orderId] || 0;
  const line = m.sale_item[l.itemId] || 0;
  return line > 0 ? line : (m.sale[l.orderId] || 0);
}

/** 批量拉当前页附件数（POST /attachments/counts，一个实体一次） */
async function loadAttachCounts() {
  const saleLineIds = [...new Set(sales.value.flatMap((s) => ((s.items as Array<Record<string, any>>) || []).map((it) => String(it.id || '')).filter(Boolean)))];
  const saleOrderIds = [...new Set(sales.value.map((s) => String(s.id || '')).filter(Boolean))];
  const payIds = [...new Set(payments.value.map((p) => String(p.id || '')).filter(Boolean))];
  const fetch = async (entity: string, ids: string[]) => {
    if (ids.length === 0) return;
    try {
      const d = await request<{ counts: Record<string, number> }>('/attachments/counts', 'POST', { entity, ids });
      for (const [id, n] of Object.entries(d.counts || {})) {
        if (n > 0) attachCounts.value[entity][id] = n;
      }
    } catch (_) {}
  };
  await Promise.all([fetch('sale_item', saleLineIds)]);
  if (saleOrderIds.length > 0) await fetch('sale', saleOrderIds);
  if (payIds.length > 0) await fetch('payment', payIds);
}

/** 打开凭证：navigateTo 独立查看器页（对齐 App attachment_viewer）。
 *  独立子页面：安卓返回键/全面屏侧滑手势只 pop 查看器，不会退出小程序（此前页内遮罩会退出）。
 *  行级空附件时回退单据级（fbEntity/fbId）由查看器页内处理。 */
function showAttach(entity: string, id: string, fbEntity = '', fbId = '') {
  uni.navigateTo({
    url: `/pages/attach-viewer/attach-viewer?entity=${entity}&id=${id}${fbEntity ? `&fbEntity=${fbEntity}&fbId=${fbId}` : ''}`,
  });
}

// ── 月份/店铺筛选 ──
const selYear = ref(new Date().getFullYear());
const selMonth = ref(new Date().getMonth() + 1);
const pad = (n: number) => String(n).padStart(2, '0');
const monthVal = computed(() => `${selYear.value}-${pad(selMonth.value)}`);
// 年月直接选择（对齐对账单 fields=month 原生选择器；不提供未来月，无需钳制）
function onPickMonth(e: { detail: { value: string } }) {
  const [y, m] = e.detail.value.split('-').map(Number);
  if (y && m >= 1 && m <= 12) {
    selYear.value = y;
    selMonth.value = m;
    loadMonthly();
  }
}
const clients = ref<Array<{ id: string; name: string }>>([]);
const clientNames = ref<string[]>([]);
const filterClientId = ref('');
const filterClientName = ref('');
// 月度结余（三列，对齐 App：售出/未回款/结余=毛利；App 已去「收入」列，小程序同步）
const mSold = ref(0);
const mDebt = ref(0);
const mBalance = ref(0);
// 金额显示按「我的 → 金额舍入」设置的位数/进位口径（对齐 App fmtMoney；月度卡/行金额/盈亏统一）
function fmtNum(n: number): string {
  return fmtAmount(Number(n) || 0);
}

// 行级盈亏 = (售价 − 成本) × 数量（对齐 App 盈亏着色：盈绿/亏红/平无色）
function profitOf(l: SaleLine): number {
  return (Number(l.sale_price) - Number(l.cost_price)) * Number(l.quantity || 0);
}
function profitClass(l: SaleLine): string {
  if (!isAdmin.value || Number(l.cost_price) <= 0 || Number(l.quantity) === 0) return '';
  const p = profitOf(l);
  return p > 0 ? 'profit-win' : p < 0 ? 'profit-loss' : '';
}
function profitText(l: SaleLine): string {
  const p = profitOf(l);
  if (!p) return '';
  return `${p > 0 ? '盈 +' : '亏 '}¥${fmtNum(Math.abs(p))}`;
}

// ── 出货流水：展开为明细行并按日期分组（对齐 App：日期头 + 明细行卡片，非整单嵌套）──
type SaleLine = {
  key: string; date: string; week: string; client_name: string; item_name: string;
  note: string; sale_price: number; quantity: string | number; unit: string; amount: number;
  cost_price: number; category: string;
  sort: number; // 行序（识别批次/插入序，对齐 App _buildSaleFlow）；旧数据无 sort=0 回退 id 数字段
  count_qty?: number | null; count_unit?: string; // 折合计数（对齐 App 行编辑）
  itemId: string; orderId: string; order: Record<string, any>;
};
type SaleGroup = { date: string; week: string; count: number; amount: number; lines: SaleLine[] };

/// 单据/明细行 id → 数值比较键：明细行 id 形如 si{微秒}{随机}、单据 id 形如 s{毫秒}{随机}
/// （s 前缀无 i；旧版只识别 si/pi 前缀 → 单据 id 回退字符串比较位数不同失真=批次乱序）；
/// 统一提取数字段补前导零，字典序=数值序；与 App _rowIdNumeric 同口径
function idNum(id: string): string {
  const m = /^(?:s|p|si|pi|sl|pl)?(\d+)/.exec(String(id || '').trim());
  return m ? m[1].padStart(24, '0') : String(id || '');
}
const saleGroups = computed<SaleGroup[]>(() => {
  const q = searchQ.value.trim().toLowerCase();
  const allLines: SaleLine[] = [];
  const pushLine = (line: SaleLine) => {
    // 搜索过滤：按商品名/店铺名/备注（本地行级，对齐 App）
    if (q) {
      const hit = (line.item_name || '').toLowerCase().includes(q) ||
          (line.client_name || '').toLowerCase().includes(q) ||
          (line.note || '').toLowerCase().includes(q);
      if (!hit) return;
    }
    allLines.push(line);
  };
  for (const s of sales.value) {
    const orderDate = String(s.happened_at || '').slice(0, 10);
    const items = ((s.items as Array<Record<string, any>>) || []);
    if (items.length === 0) {
      pushLine({
        key: `o-${s.id}`, date: orderDate, week: '', client_name: String(s.client_name || ''),
        item_name: '备注行', note: String(s.note || ''), sale_price: 0, quantity: '', unit: '',
        amount: Number(s.total || 0), cost_price: 0, category: '', sort: 0, itemId: '', orderId: String(s.id), order: s,
      });
      continue;
    }
    for (const it of items) {
      const d = String(it.happened_at || orderDate).slice(0, 10);
      pushLine({
        key: `${s.id}-${it.id}`, date: d || orderDate, week: '', client_name: String(s.client_name || ''),
        item_name: String(it.item_name || ''), note: String(it.note || ''),
        sale_price: Number(it.sale_price || 0), quantity: it.quantity ?? '', unit: String(it.unit || ''),
        amount: Number(it.amount || 0), cost_price: Number(it.cost_price || 0), category: String(it.item_category || it.category_name || it.category || ''),
        sort: Number(it.sort ?? 0), itemId: String(it.id || ''), orderId: String(s.id), order: s,
      });
    }
  }
  // 批次/批内排序（对齐 App _buildSaleFlow）：日期降序 → 订单 id 数字段（批次序，第一批在上）→
  // 行 sort（批内扫描/录入序）→ 行 id。**不按 sort 全局交错**（每单 sort 都 0 起，
  // 全局排会 A1,B1,C1… 交错=fix-sort 后全乱根因）。
  allLines.sort((a, b) => {
    const x = String(b.date).localeCompare(String(a.date));
    if (x !== 0) return x;
    const z = idNum(String((a.order as any)?.id || '')).localeCompare(idNum(String((b.order as any)?.id || '')));
    if (z !== 0) return z;
    const s2 = a.sort - b.sort;
    if (s2 !== 0) return s2;
    return idNum(a.itemId).localeCompare(idNum(b.itemId));
  });
  const map = new Map<string, SaleGroup>();
  const WEEKS = ['日', '一', '二', '三', '四', '五', '六'];
  for (const line of allLines) {
    const g = map.get(line.date) || { date: line.date, week: '', count: 0, amount: 0, lines: [] };
    const d = new Date(`${line.date}T00:00:00`);
    g.week = `${line.date.slice(0, 4)}年${line.date.slice(5, 7)}月${line.date.slice(8, 10)}日 周${WEEKS[d.getDay()]}`;
    g.count += 1;
    // 日分组合计=每笔先舍入再累加（与单笔显示/余额笔舍入一致，digits=0/1 时原始累加会与单笔对不上）
    g.amount += roundAmount(Number(line.amount || 0));
    g.lines.push(line);
    map.set(line.date, g);
  }
  return [...map.values()].sort((a, b) => (a.date > b.date ? -1 : a.date < b.date ? 1 : 0));
});

function monthRange(): { from: string; to: string } {
  const y = selYear.value;
  const m = selMonth.value;
  const from = `${y}-${pad(m)}-01`;
  // 当月最后一天（下月 0 日）
  const next = new Date(y, m, 0); // m 是 1-12，new Date(y,m,0) = 当月最后一天
  const to = `${next.getFullYear()}-${pad(next.getMonth() + 1)}-${pad(next.getDate())}`;
  return { from, to };
}
// 收款列表按搜索关键词过滤（店铺名/备注/收款方式——对齐 App _filteredPayments）
const filteredPayments = computed(() => {
  const q = searchQ.value.trim().toLowerCase();
  if (!q) return payments.value;
  return payments.value.filter((p) => {
    const hit = String(p.client_name || '').toLowerCase().includes(q) ||
        String(p.note || '').toLowerCase().includes(q) ||
        String(p.method || '').toLowerCase().includes(q);
    return hit;
  });
});

function onClientFilter(e: { detail: { value: number } }) {
  const c = clients.value[e.detail.value];
  if (!c) return;
  filterClientId.value = c.id;
  filterClientName.value = c.name;
  uni.setStorageSync('taozhu_cur_client', c.id); // 我的页统计卡「本店交易/店铺结余」共用当前店铺
  load();
}

async function loadClients() {
  try {
    const d = await request<{ clients: Array<{ id: string; name: string }> }>('/clients', 'GET');
    clients.value = d.clients || [];
    clientNames.value = clients.value.map((x) => x.name);
    // 恢复上次选择的店铺（我的页统计卡共用该口径）；无存档取第一家（与 App 端一致）
    const saved = uni.getStorageSync('taozhu_cur_client') as string;
    const c0 = clients.value.find((x) => x.id === saved) || clients.value[0];
    if (c0) {
      filterClientId.value = c0.id;
      filterClientName.value = c0.name;
    }
  } catch (e) {
    clientNames.value = [];
  }
}

onShow(async () => {
  onWs('*', load);
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

// 月份-交易联动（对齐 App 滚动联动）：列表滚动时按视口内最顶部日期头切统计月份；
// 节流 120ms + 年月变化才重算（防抖）
let monthSyncTimer: ReturnType<typeof setTimeout> | null = null;
function onFlowScroll() {
  if (monthSyncTimer) return;
  monthSyncTimer = setTimeout(() => {
    monthSyncTimer = null;
    syncMonthFromViewport();
  }, 120);
}
function syncMonthFromViewport() {
  // #ifndef H5
  try {
    const q = uni.createSelectorQuery();
    q.selectAll('.day-bar').boundingClientRect((res: any) => {
      const rects: Array<any> = Array.isArray(res) ? res : [res];
      if (!rects || rects.length === 0) return;
      let best: { top: number; date: string } | null = null;
      for (const r of rects) {
        const date = String(r?.dataset?.date || '');
        if (!date || date.length < 7) continue;
        if (r.top > -60 && r.top < 150 && (!best || r.top < best.top)) best = { top: r.top, date };
      }
      if (!best) return;
      const y = Number(best.date.slice(0, 4));
      const m = Number(best.date.slice(5, 7));
      if (!y || !m) return;
      if (y !== selYear.value || m !== selMonth.value) {
        selYear.value = y;
        selMonth.value = m;
        loadMonthly();
      }
    }).exec();
  } catch (_) {}
  // #endif
}

async function load() {
  try {
    // 列表始终显示全部数据（对齐 App：月份切换只影响顶部统计卡，列表不按月过滤）
    const cq = filterClientId.value ? `&client_id=${filterClientId.value}` : '';
    const results = await Promise.all([
      // 出货/收款按店铺过滤；进货已在独立 tab（purchase-history），交易页不再拉进货
      request<{ sales: any[]; sale_items?: any[] }>(`/sales?limit=500${cq}`, 'GET'),
      request<{ payments: any[] }>(`/payments?limit=500${cq}`, 'GET'),
    ]);
    // 去单据化主结构：优先行级 sale_items（每条商品一行，自带店铺/日期/备注），否则整单嵌套兼容
    const saleItems = results[0].sale_items;
    sales.value = (saleItems && saleItems.length > 0)
        ? assembleSalesFromRows(saleItems)
        : (results[0].sales || []);
    payments.value = results[1].payments;
    await loadMonthly();
    loadAttachCounts();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

/// 所选月份统计卡（售出/收入/未回款/结余=毛利），月份切换只重算此处，列表保持全量
async function loadMonthly() {
  try {
    const { from, to } = monthRange();
    const cq = filterClientId.value ? `&client_id=${filterClientId.value}` : '';
    const sum = await request<Record<string, any>>(`/stats/summary?start=${from}&end=${to}${cq}`, 'GET').catch(() => null);
    if (sum) {
      mSold.value = Number(sum.sales_total || 0);
      mDebt.value = Number(sum.debt || 0);
      mBalance.value = Number(sum.gross_profit || 0);
    }
  } catch (e) {
    // 统计失败不阻断列表
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
    // 整单日期 = 行最大日期（与 Web/App 及服务器聚合口径一致，避免同单多行日期不同时两端对不上）
    const prev = meta.get(oid);
    const h = String(r.happened_at || '');
    meta.set(oid, {
      id: oid,
      client_id: r.client_id || (prev?.client_id || ''),
      client_name: r.client_name || (prev?.client_name || ''),
      happened_at: prev && String(prev.happened_at || '') >= h ? prev.happened_at : h,
      note: r.note || (prev?.note || ''),
    });
  }
  return [...byOrder.entries()].map(([oid, items]) => {
    const m = meta.get(oid)!;
    const total = items.reduce((s, it) => s + roundAmount(Number(it.amount) || 0), 0);
    return { ...m, total, items };
  });
}

function switchTab(t: 'sales' | 'payments') {
  tab.value = t;
}

// 月份只由顶部月度卡选择器控制（pickMonth），滚动不再联动改月份：
// 原实现每次滚动都强制切回"最新记账月"并 load() 重拉全列表 → 整页跳动+双向横跳（用户否决）。
// 列表始终全量显示（注释见 load），滚动保持位置不动。

const confirm = (title: string, content: string) =>
  new Promise<boolean>((resolve) => {
    uni.showModal({ title, content, success: (r) => resolve(!!r.confirm) });
  });

function editSale(s: Record<string, any>) {
  uni.navigateTo({ url: `/pages/sale/sale?id=${s.id}` });
}

// 日期栏点击 → 批量直编该日全部行（对齐 App dateRows：sale.vue dateRows=1&date=xxx 平铺按原单分组保存）
function openSaleBatch(date: string) {
  const cq = filterClientId.value ? `&client_id=${filterClientId.value}` : '';
  uni.navigateTo({ url: `/pages/sale/sale?dateRows=1&date=${date}${cq}` });
}

// 明细行点击 → 只编辑该商品（对齐 App 单行编辑语义：数据按明细行独立存储）
function editSaleLine(l: SaleLine) {
  const it = ((l.order?.items || []) as Array<Record<string, any>>).find((x) => String(x.id) === String(l.itemId));
  itemForm.value = {
    show: true,
    isPurchase: false,
    saleId: l.orderId,
    itemId: l.itemId,
    goodsId: String(it?.item_id || it?.goods_id || ''), // 商品库真实商品 id（改分类用）：明细行 id≠商品 id
    itemName: l.item_name,
    quantity: String(l.quantity ?? ''),
    unit: String(l.unit || ''),
    salePrice: String(l.sale_price ?? ''),
    countQty: l.count_qty ? String(l.count_qty) : '',
    countUnit: String(l.count_unit || ''),
    date: l.date.slice(0, 10),
    note: String(l.note ?? ''),
    category: String(l.category || ''),
    categoryId: String(it?.category_id || ''),
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
    goodsId: String(it.item_id || it.goods_id || ''), // 商品库真实商品 id（改分类用）
    itemName: String(it.item_name || ''),
    quantity: String(it.quantity ?? ''),
    unit: String(it.unit || ''),
    salePrice: String(it.sale_price ?? ''),
    countQty: it.count_qty ? String(it.count_qty) : '',
    countUnit: String(it.count_unit || ''),
    date: String(it.happened_at || s.happened_at || '').slice(0, 10),
    note: String(it.note ?? ''),
    category: String(it.category || it.item_category || ''),
    categoryId: String(it.category_id || ''),
  };
}

// 点进货明细行 → 只编辑该商品（进价/数量/单位/折合计数/日期/备注）
function editPurchaseItem(p: Record<string, any>, it: Record<string, any>) {
  itemForm.value = {
    show: true,
    isPurchase: true,
    saleId: String(p.id),
    itemId: String(it.id || ''),
    goodsId: String(it.item_id || it.goods_id || ''), // 商品库真实商品 id（改分类用）
    itemName: String(it.item_name || ''),
    quantity: String(it.quantity ?? ''),
    unit: String(it.unit || ''),
    salePrice: String(it.purchase_price ?? it.price ?? ''),
    countQty: it.count_qty ? String(it.count_qty) : '',
    countUnit: String(it.count_unit || ''),
    date: String(it.happened_at || p.happened_at || '').slice(0, 10),
    note: String(it.note ?? ''),
    category: String(it.category || it.item_category || ''),
    categoryId: String(it.category_id || ''),
  };
}

// 修改商品分类（商品级，全局生效）：加载两级目录 → 选择 → PATCH /items/:id（对齐 App changeCategory）
const catDlg = ref(false);
const catList = ref<Array<{ id: string; name: string; parent_id: string | null }>>([]);
const catSaving = ref(false);
// 一级分类（parent_id 空）与二级（挂在父下）——对齐 App changeCategory 两级目录
const catParents = computed(() => catList.value.filter((c) => !c.parent_id));
const catChildrenOf = (pid: string) => catList.value.filter((c) => c.parent_id === pid);
async function changeItemCategory() {
  const goodsId = itemForm.value.goodsId;
  if (!goodsId) {
    uni.showToast({ title: '该商品已从商品库删除（历史明细仍显示原名称），无法修改分类', icon: 'none' });
    return;
  }
  try {
    const d = await request<{ categories?: Array<{ id: string; name: string; parent_id: string | null }> }>('/categories?type=item', 'GET');
    catList.value = d?.categories || [];
    catDlg.value = true;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '分类加载失败', icon: 'none' });
  }
}
async function pickCategory(id: string) {
  catDlg.value = false;
  const cat = catList.value.find((c) => c.id === id);
  const catName = id ? (cat?.name || '') : '';
  catSaving.value = true;
  try {
    await request(`/items/${itemForm.value.goodsId}`, 'PATCH', {
      category: catName,
      category_id: id || null,
    });
    itemForm.value.category = catName;
    itemForm.value.categoryId = id;
    uni.showToast({ title: catName ? `已改为「${catName}」` : '已改为未分类', icon: 'success' });
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '分类修改失败', icon: 'none' });
  } finally {
    catSaving.value = false;
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
    // 折合计数：空/<=0 时不传（后端按原单位/价格行规格推算，与记单页一致）
    const countQty = Number(itemForm.value.countQty) > 0 ? Number(itemForm.value.countQty) : null;
    if (itemForm.value.isPurchase) {
      await request(`/purchases/items/${itemForm.value.itemId}`, 'PATCH', {
        quantity: qty,
        unit: itemForm.value.unit,
        purchase_price: Number(itemForm.value.salePrice) || 0,
        count_qty: countQty,
        happened_at: itemForm.value.date,
        note: itemForm.value.note,
      });
    } else {
      await request(`/sales/items/${itemForm.value.itemId}`, 'PATCH', {
        quantity: qty,
        unit: itemForm.value.unit,
        sale_price: Number(itemForm.value.salePrice) || 0,
        count_qty: countQty,
        happened_at: itemForm.value.date,
        note: itemForm.value.note,
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

// 弹窗内删除该行（对齐 App 单行编辑「删除」按钮：DELETE 行级接口，自动清空无行单据）
async function deleteItem() {
  if (!itemForm.value.itemId) {
    uni.showToast({ title: '该行无独立明细，无法单独删除', icon: 'none' });
    return;
  }
  if (!(await confirm('删除商品', `确定删除「${itemForm.value.itemName}」这一行吗？仅删除该商品，库存自动回滚。`))) return;
  saving.value = true;
  try {
    const id = itemForm.value.itemId;
    if (itemForm.value.isPurchase) {
      await request(`/purchases/items/${id}`, 'DELETE');
    } else {
      await request(`/sales/items/${id}`, 'DELETE');
    }
    uni.showToast({ title: '已删除该商品', icon: 'success' });
    itemForm.value.show = false;
    load();
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
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

  onHide(() => { offWs('*', load); });
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { height: 100vh; overflow: hidden; display: flex; flex-direction: column; background: var(--page-bg); }
.flow { flex: 1; min-height: 0; } /* 列表区占剩余高度内部滚动：统计栏/筛选/seg 固定顶部不随滑动消失 */
.filter-bar { display: flex; align-items: center; gap: 12rpx; background: transparent; border-radius: 12rpx; padding: 8rpx 4rpx 12rpx; margin-bottom: 4rpx; }
.client-picker { flex-shrink: 0; max-width: 200rpx; }
.client-btn { font-size: 26rpx; color: var(--primary); border: 1rpx solid var(--primary); border-radius: 8rpx; padding: 8rpx 16rpx; max-width: 200rpx; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.search { flex: 1; min-width: 0; background: var(--card-bg); border: var(--card-border); border-radius: 12rpx; padding: 8rpx 20rpx; font-size: 26rpx; height: 60rpx; }
.month-nav { display: flex; align-items: center; }
.month-label { font-size: 28rpx; font-weight: bold; }
.month-caret { font-size: 22rpx; color: var(--text-sub); margin-left: 6rpx; }
/* 月度结余卡（对齐 App：左年月两层 + 竖线 + 右四列左对齐；透明无卡底） */
.month-card { display: flex; align-items: center; background: transparent; border: none; box-shadow: none; border-radius: 0; padding: 4rpx 0 12rpx; margin-bottom: 4rpx; }
.month-left { display: flex; flex-direction: column; align-items: center; justify-content: center; padding-right: 20rpx; }
.month-y { font-size: 24rpx; font-weight: 600; color: var(--text-sub); line-height: 1.3; }
.month-row { display: flex; align-items: center; gap: 4rpx; }
.month-m { font-size: 40rpx; font-weight: 800; color: var(--primary); line-height: 1.2; }
.month-caret { font-size: 22rpx; color: var(--text-sub); }
.month-tip { font-size: 20rpx; color: var(--text-sub); }
.mdivider { width: 1rpx; height: 80rpx; background: var(--divider); }
.mcols { flex: 1; display: flex; margin-left: 20rpx; } /* 四列容器：横排 */
.mcol { flex: 1; display: flex; flex-direction: column; align-items: flex-start; gap: 6rpx; padding-right: 8rpx; }
.ml { font-size: 22rpx; color: var(--text-sub); }
.mv { font-size: 30rpx; font-weight: bold; color: var(--text-main); max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.client-btn { font-size: 26rpx; color: var(--primary); border: 1rpx solid var(--primary); border-radius: 8rpx; padding: 8rpx 16rpx; max-width: 200rpx; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.export-btn { font-size: 26rpx; color: var(--primary); border: 1rpx solid var(--primary); border-radius: 8rpx; padding: 6rpx 16rpx; flex-shrink: 0; }
.seg { display: flex; background: var(--card-bg); border: var(--card-border); border-radius: 12rpx; margin-bottom: 20rpx; overflow: hidden;}
.seg-item { flex: 1; text-align: center; padding: 20rpx; font-size: 28rpx; color: var(--text-sub); }
.seg-item.active { color: var(--primary); font-weight: bold; background: var(--primary-soft); }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8rpx; }
.name { font-size: 30rpx; font-weight: bold; }
.amt { font-size: 30rpx; font-weight: bold; color: #f56c6c; }
.sub { font-size: 26rpx; color: var(--text-sub); margin-bottom: 12rpx; }
/* 出货流水：日期头 + 行级卡片（对齐 App _saleLineTile：圆角10 + 1px 描边无阴影 + 盈亏着色） */
.day-bar { display: flex; justify-content: space-between; align-items: center; padding: 16rpx 8rpx 10rpx; }
.day-ic { color: var(--primary); font-size: 28rpx; margin-right: 8rpx; }
.day-name { font-size: 27rpx; font-weight: bold; color: var(--text-main); flex: 1; }
.day-total { font-size: 23rpx; color: var(--text-sub); }
.day-arrow { color: var(--text-sub); font-size: 30rpx; margin-left: 8rpx; }
.card-sale { background: var(--card-bg); border: var(--card-border); border-radius: 10rpx; padding: 16rpx 18rpx; margin-bottom: 12rpx; box-shadow: none; }
.card-sale.profit-win { border-color: rgba(34, 197, 94, 0.4); }
.card-sale.profit-loss { border-color: rgba(239, 68, 68, 0.4); }
.line-top { display: flex; align-items: center; gap: 12rpx; }
.store-ic { width: 56rpx; height: 56rpx; border-radius: 50%; background: var(--primary-soft); display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.st-tx { font-size: 26rpx; line-height: 1; }
.line-main { flex: 1; min-width: 0; }
.line-name { font-size: 28rpx; font-weight: 600; color: var(--text-main); display: block; max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.line-note { font-size: 22rpx; color: var(--text-sub); }
.line-subrow { display: flex; align-items: center; gap: 8rpx; margin-top: 4rpx; }
.l2-cat { font-size: 20rpx; color: var(--text-sub); background: var(--input-bg); border-radius: 6rpx; padding: 2rpx 10rpx; }
.attach-entry { display: flex; align-items: center; gap: 2rpx; padding: 2rpx; }
.attach-ic { width: 30rpx; height: 30rpx; }
.attach-ic-off { filter: grayscale(1); opacity: 0.45; }
.attach-cnt { font-size: 20rpx; color: var(--primary); font-weight: 600; }
.line-bottom { display: flex; align-items: baseline; gap: 12rpx; margin-top: 8rpx; }
.l2-tx { font-size: 23rpx; color: var(--text-sub); }
.l2-profit { font-size: 23rpx; font-weight: bold; margin-left: auto; }
.card-sale.profit-win .l2-profit { color: #22c55e; }
.card-sale.profit-loss .l2-profit { color: #ef4444; }
.line { display: flex; justify-content: space-between; align-items: center; padding: 10rpx 0; border-top: 1rpx solid var(--divider); }
.line-left { flex: 1; min-width: 0; }
.line-name { font-size: 27rpx; color: var(--text-main); display: block; }
.line-meta { font-size: 22rpx; color: var(--text-sub); margin-top: 2rpx; display: block; }
.line-amt { font-size: 27rpx; font-weight: bold; color: #f56c6c; margin-left: 16rpx; }
.ops { display: flex; justify-content: flex-end; gap: 32rpx; margin-top: 8rpx; }
.del { color: #f56c6c; font-size: 26rpx; }
.tip-longpress { color: var(--text-sub); font-size: 22rpx; }
.empty { color: var(--text-sub); text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: var(--sheet-bg); border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; max-height: 85vh; display: flex; flex-direction: column; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; flex-shrink: 0; }
.sheet-body { flex: 1; min-height: 0; max-height: 60vh; display: flex; }
.sheet-body-scroll { flex: 1; height: 100%; }
.ipt { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.field { margin-bottom: 16rpx; }
.field-inner { display: flex; justify-content: space-between; padding: 18rpx 20rpx; background: var(--input-bg); border-radius: 10rpx; }
.label { color: var(--text-sub); font-size: 28rpx; }
.value { color: var(--text-main); font-size: 28rpx; }
.placeholder { color: var(--text-sub); }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; }
.form-row { display: flex; gap: 16rpx; }
.form-row.v { display: flex; flex-direction: column; gap: 8rpx; margin-bottom: 16rpx; }
.f-col { flex: 1; min-width: 0; }
.f-label { display: block; font-size: 22rpx; color: var(--text-sub); margin-bottom: 8rpx; }
.f-col .ipt { width: 100%; box-sizing: border-box; margin-bottom: 16rpx; }
.form-row.v .ipt { width: 100%; box-sizing: border-box; background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; font-size: 28rpx; }
.f-info { display: flex; flex-direction: column; gap: 4rpx; }
.f-pick { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; display: flex; justify-content: space-between; align-items: center; }
.f-act { color: var(--primary); font-size: 26rpx; flex-shrink: 0; margin-top: 8rpx; text-align: right; }
.attach-row { display: flex; justify-content: space-between; align-items: center; padding: 18rpx 20rpx; background: var(--input-bg); border-radius: 10rpx; margin-bottom: 16rpx; }
.attach-go { color: var(--primary); }
.flex1 { flex: 1; }
.btn-del { background: var(--card-bg); color: #f56c6c; border: 1rpx solid #f56c6c; border-radius: 12rpx; font-size: 30rpx; }
.dlg-ops { display: flex; gap: 20rpx; margin-top: 8rpx; flex-shrink: 0; padding-top: 16rpx; }
.dlg-ops .btn-save, .dlg-ops .btn-del { flex: 1; }
/* 修改商品分类弹层（两级目录，对齐 App changeCategory SimpleDialog） */
.cat-sheet { padding: 32rpx 28rpx; max-height: 65vh; display: flex; flex-direction: column; }
.cat-sheet .s-title { font-size: 30rpx; font-weight: bold; text-align: center; margin-bottom: 20rpx; flex-shrink: 0; }
.cat-scroll { flex: 1; min-height: 0; }
.cat-opt { padding: 18rpx 24rpx; font-size: 28rpx; color: var(--text-main); border-bottom: 1rpx solid var(--divider); }
.cat-opt:last-child { border-bottom: none; }
.cat-opt-p { font-weight: bold; }
.cat-opt-c { padding-left: 56rpx; color: var(--text-sub); }
/* 附件弹层 */
.attach-scroll { max-height: 600rpx; margin-bottom: 16rpx; }
.attach-item { display: flex; align-items: center; gap: 16rpx; padding: 12rpx 0; border-bottom: 1rpx solid var(--divider); }
.attach-img { width: 200rpx; height: 200rpx; border-radius: 12rpx; flex-shrink: 0; }
.attach-del { color: #f56c6c; font-size: 26rpx; margin-left: auto; }
.attach-actions { display: flex; gap: 16rpx; }
.attach-actions .btn-sub { flex: 1; }
.attach-actions .btn-save { flex: 1; }
/* 全屏凭证查看器（对齐 App attachment_viewer：大图 + 上边操作按钮） */
.viewer { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: #000; display: flex; flex-direction: column; z-index: 300; }
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