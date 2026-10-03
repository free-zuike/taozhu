<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="filter-bar">
      <picker class="act-picker" mode="selector" :range="actNames" @change="onActFilter">
        <view class="act-btn">{{ actFilter ? actFilter : '全部操作' }} ▾</view>
      </picker>
    </view>

    <view v-for="l in logs" :key="l.id" class="card" @longpress="remove(l)">
      <view class="head">
        <view class="left">
          <text class="who">{{ l.username }} · {{ headLabel(l) }}</text>
          <text class="when">{{ l.created_at || '' }}</text>
        </view>
        <text class="tag">{{ l.action_label || l.action }}</text>
      </view>
      <view class="body">
        <text class="ent">{{ l.entity_label || l.entity_type || '' }}</text>
        <text class="detail">{{ l.detail || '' }}</text>
      </view>
    </view>
    <view v-if="logs.length === 0" class="empty">暂无审计记录</view>
    <view v-if="logs.length > 0" class="tip-longpress">长按某条可删除该记录</view>
  </view>
</template>

<script setup lang="ts">
import { onShow, onHide } from '@dcloudio/uni-app';
import { onWs, offWs } from '../../ws';
import { useThemeVars } from '../../theme';
const { tv, patternSrc } = useThemeVars();
import { ref } from 'vue';
import { request, getRole, getToken } from '../../api';

interface Log {
  id: number;
  username: string;
  action: string;
  action_label?: string;
  entity_type?: string;
  entity_label?: string;
  entity_id?: string;
  detail?: string;
  created_at?: string;
}

const logs = ref<Log[]>([]);
const actFilter = ref('');
const isAdmin = ref(true);
// 操作类型过滤（对齐 App 审计页）：常用操作
const ACTS = ['', 'create', 'update', 'delete', 'login', 'logout', 'backup', 'restore', 'sync', 'theme'];
const actNames = ['全部操作', '新增', '修改', '删除', '登录', '退出', '备份', '恢复', '同步', '主题'];

onShow(async () => {
  onWs('audit', load);
  onWs('*', load);
  if (!getToken()) {
    uni.reLaunch({ url: '/pages/login/login' });
    return;
  }
  isAdmin.value = getRole() !== 'staff';
  await load();
});

onHide(() => {
  offWs('audit', load);
  offWs('*', load);
});

async function load() {
  try {
    const q = actFilter.value ? `&action=${actFilter.value}` : '';
    const d = await request<{ logs: Log[] }>(`/audit?limit=100${q}`, 'GET');
    logs.value = d.logs || [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载失败', icon: 'none' });
  }
}

function onActFilter(e: { detail: { value: number } }) {
  actFilter.value = ACTS[e.detail.value] || '';
  load();
}

// 标题副语：优先显示留痕详情（含业务名称，如"删除了店铺品味轩"）；旧记录无 detail 回退动作+实体
function headLabel(l: Log): string {
  if (l.detail) return l.detail;
  const act = l.action_label || l.action || '';
  const ent = l.entity_label || l.entity_type || '';
  const known = ['新增', '修改', '删除', '导出', '导入', '重算'];
  const verb = known.includes(act) ? `${act}了` : act;
  return ent ? `${verb}${ent}` : act;
}

function remove(l: Log) {
  if (!isAdmin.value) {
    uni.showToast({ title: '仅老板可删除', icon: 'none' });
    return;
  }
  uni.showModal({
    title: '删除审计记录',
    content: '确定删除这条操作留痕吗？',
    success: async (r) => {
      if (!r.confirm) return;
      try {
        const d = await request<{ deleted: number }>(`/audit/${l.id}`, 'DELETE');
        if (!d || Number(d.deleted) <= 0) {
          uni.showToast({ title: '删除失败：记录不存在或已被删除', icon: 'none' });
          return;
        }
        // 本地立即移除该条（即时消失，不依赖重拉成败；load 兜底对齐）
        logs.value = logs.value.filter((x) => Number(x.id) !== Number(l.id));
        uni.showToast({ title: '已删除', icon: 'success' });
        await load();
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '删除失败', icon: 'none' });
        // 请求异常但服务端可能已执行删除（响应丢失）→ 强制重拉对齐，避免"删了还在直到退出重进"
        await load();
      }
    },
  });
}
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh; padding: 20rpx; box-sizing: border-box; background: var(--page-bg); }
.filter-bar { background: var(--card-bg); border-radius: 12rpx; padding: 16rpx 20rpx; margin-bottom: 16rpx; }
.act-btn { font-size: 26rpx; color: var(--primary); border: 1rpx solid var(--primary); border-radius: 8rpx; padding: 6rpx 16rpx; display: inline-block; }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 20rpx 24rpx; margin-bottom: 14rpx; }
.head { display: flex; align-items: flex-start; }
.left { flex: 1; min-width: 0; }
.who { font-size: 28rpx; font-weight: bold; display: block; color: var(--text-main); }
.when { font-size: 22rpx; color: var(--text-sub); margin-top: 4rpx; display: block; }
.tag { font-size: 20rpx; color: var(--primary); background: var(--primary-soft); border-radius: 6rpx; padding: 2rpx 10rpx; flex-shrink: 0; }
.body { margin-top: 14rpx; }
.ent { font-size: 24rpx; color: var(--text-sub); display: block; }
.detail { font-size: 26rpx; color: var(--text-main); margin-top: 6rpx; display: block; word-break: break-all; }
.empty { color: var(--text-sub); text-align: center; padding: 60rpx 0; font-size: 26rpx; }
.tip-longpress { color: var(--text-sub); font-size: 22rpx; text-align: center; padding: 10rpx 0 30rpx; }
</style>