<template>
  <view class="page">
    <view class="seg">
      <view :class="['seg-item', { active: tab === 'sales' }]" @click="switchTab('sales')">出货</view>
      <view :class="['seg-item', { active: tab === 'purchases' }]" @click="switchTab('purchases')">进货</view>
      <view :class="['seg-item', { active: tab === 'payments' }]" @click="switchTab('payments')">收款</view>
    </view>

    <view v-if="tab === 'sales'">
      <view v-for="s in sales" :key="s.id" class="card">
        <view class="head">
          <text class="name">{{ s.client_name }}</text>
          <text class="amt">¥{{ s.total }}</text>
        </view>
        <view class="sub">{{ s.happened_at }} · {{ (s.items || []).length }} 项</view>
        <view class="ops">
          <text class="op" @click="editSale(s)">编辑</text>
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
        <view class="sub">{{ (p.items || []).length }} 项</view>
        <view class="ops">
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
          <text class="op" @click="editPayment(p)">编辑</text>
          <text class="del" @click="removePayment(p)">删除</text>
        </view>
      </view>
      <view v-if="payments.length === 0" class="empty">暂无收款记录</view>
    </view>

    <!-- 收款编辑弹层 -->
    <view v-if="payForm.show" class="mask" @click="payForm.show = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">编辑收款</view>
        <input class="ipt" v-model="payForm.amount" type="digit" placeholder="金额（元）" />
        <input class="ipt" v-model="payForm.date" placeholder="日期 YYYY-MM-DD" />
        <input class="ipt" v-model="payForm.method" placeholder="收款方式（现金/微信…）" />
        <input class="ipt" v-model="payForm.note" placeholder="备注" />
        <button class="btn-save" :disabled="saving" @click="savePayment">{{ saving ? '保存中…' : '保存' }}</button>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

const tab = ref<'sales' | 'purchases' | 'payments'>('sales');
const sales = ref<Array<Record<string, any>>>([]);
const purchases = ref<Array<Record<string, any>>>([]);
const payments = ref<Array<Record<string, any>>>([]);
const saving = ref(false);
const payForm = ref<{
  show: boolean; id: string; amount: string; date: string; method: string; note: string;
}>({ show: false, id: '', amount: '', date: '', method: '', note: '' });

onShow(async () => {
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  await load();
});

async function load() {
  try {
    const results = await Promise.all([
      request<{ sales: any[] }>('/sales?limit=200', 'GET'),
      request<{ purchases: any[] }>('/purchases?limit=200', 'GET'),
      request<{ payments: any[] }>('/payments?limit=200', 'GET'),
    ]);
    sales.value = results[0].sales;
    purchases.value = results[1].purchases;
    payments.value = results[2].payments;
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
  payForm.value = {
    show: true, id: p.id,
    amount: String(p.amount),
    date: String(p.happened_at || '').slice(0, 10),
    method: p.method || '',
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
.seg { display: flex; background: #fff; border-radius: 12rpx; margin-bottom: 20rpx; overflow: hidden; }
.seg-item { flex: 1; text-align: center; padding: 20rpx; font-size: 28rpx; color: #909399; }
.seg-item.active { color: #409eff; font-weight: bold; background: #ecf5ff; }
.card { background: #fff; border-radius: 12rpx; padding: 24rpx; margin-bottom: 16rpx; }
.head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8rpx; }
.name { font-size: 30rpx; font-weight: bold; }
.amt { font-size: 30rpx; font-weight: bold; color: #f56c6c; }
.sub { font-size: 26rpx; color: #909399; margin-bottom: 12rpx; }
.ops { display: flex; justify-content: flex-end; gap: 32rpx; }
.op { color: #409eff; font-size: 26rpx; }
.del { color: #f56c6c; font-size: 26rpx; }
.empty { color: #c0c4cc; text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: #fff; border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: #f5f7fa; border-radius: 10rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: #409eff; color: #fff; border-radius: 12rpx; font-size: 30rpx; }
</style>