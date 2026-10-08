<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <button class="btn" :disabled="busy" @click="backupNow">{{ busy ? '备份中…' : '立即备份到云端' }}</button>
    <button class="btn-out" @click="exportBackup">导出备份（复制 JSON 存档）</button>
    <button class="btn-out" @click="importBackup">导入备份（合并，不覆盖）</button>
    <view class="tip">备份为全库 JSON 存档（云端历史可直接恢复，不覆盖现有数据；导出=把数据复制到剪贴板自行保存）</view>

    <view class="group-title">自动备份</view>
    <view class="auto-card">
      <view class="auto-row">
        <text class="auto-label">每天时间</text>
        <picker class="auto-pick" mode="time" :value="autoTime" @change="onAutoTime">
          <view class="auto-value">{{ autoTime }}</view>
        </picker>
      </view>
      <view class="auto-row">
        <text class="auto-label">保留份数</text>
        <input class="auto-input" type="number" v-model="autoKeep" placeholder="7" />
      </view>
      <button class="btn-save" @click="saveAuto">保存自动备份设置</button>
    </view>

    <view class="group-title">备份历史<span class="badge">{{ backups.length }}</span></view>
    <view v-if="backups.length === 0" class="empty">暂无备份，点上方按钮创建</view>
    <view v-else class="list">
      <view v-for="b in backups" :key="b.key" class="card">
        <view class="info">
          <text class="b-name">{{ b.name_display || b.name }}</text>
          <text class="b-size">{{ b.size ? (b.size / 1024).toFixed(1) + ' KB' : '' }}</text>
        </view>
        <text class="op" @click="restore(b)">恢复</text>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { useThemeVars } from '../../theme';
const { tv, patternSrc } = useThemeVars();
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

type BackupItem = { name: string; name_display?: string; key: string; size?: number };
const backups = ref<BackupItem[]>([]);
const busy = ref(false);

// 自动备份配置（存服务器 settings：backup_time/backup_keep，Cloudflare cron 每天到点执行）
const autoTime = ref('02:00');
const autoKeep = ref('7');

onShow(async () => {
  if (!getToken()) return;
  load();
  loadAuto();
});

async function loadAuto() {
  try {
    const d = await request<{ time?: string; keep?: number }>('/backup/auto', 'GET');
    if (d?.time) autoTime.value = d.time;
    if (typeof d?.keep === 'number') autoKeep.value = String(d.keep);
  } catch (_) {}
}
function onAutoTime(e: { detail: { value: string } }) {
  autoTime.value = e.detail.value;
}
async function saveAuto() {
  const keep = Math.max(1, Math.min(90, Number(autoKeep.value) || 7));
  try {
    await request('/backup/auto', 'PUT', { time: autoTime.value, keep });
    uni.showToast({ title: '自动备份设置已保存', icon: 'success' });
  } catch (e) {
    uni.showToast({ title: '保存失败', icon: 'none' });
  }
}

/// 导出备份：GET /backup 全库 JSON → 复制剪贴板（对齐小程序复制文本形态；超大提示走云端备份）
async function exportBackup() {
  uni.showLoading({ title: '导出中…' });
  try {
    const d = await request<Record<string, unknown>>('/backup', 'GET');
    uni.hideLoading();
    const json = JSON.stringify(d, null, 2);
    if (json.length > 900000) {
      uni.showToast({ title: '备份数据过大，请用「立即备份到云端」', icon: 'none' });
      return;
    }
    uni.setClipboardData({ data: json });
    uni.showToast({ title: '备份 JSON 已复制，请粘贴到备忘录/电脑保存', icon: 'success' });
  } catch (e) {
    uni.hideLoading();
    uni.showToast({ title: '导出失败', icon: 'none' });
  }
}

/// 导入备份：选本地 JSON 文件 → POST /backup/import（合并导入，跳过已存在行）
async function importBackup() {
  (uni as any).chooseMessageFile({
    count: 1,
    type: 'file',
    extension: ['json'],
    success: async (res: { tempFiles?: Array<{ path: string }> }) => {
      const file = res.tempFiles?.[0];
      if (!file) return;
      try {
        const fs = (uni as any).getFileSystemManager();
        const text = fs.readFileSync(file.path, 'utf8');
        const parsed = JSON.parse(text);
        const data = parsed?.data ?? parsed; // 兼容 {exported_at,data:{表:rows}} 与裸 {表:rows}
        if (!data || typeof data !== 'object') throw new Error('bad format');
        uni.showLoading({ title: '导入中…' });
        const r = await request<{ report?: Record<string, { inserted?: number; skipped?: number }>; total_inserted?: number }>('/backup/import', 'POST', { data });
        uni.hideLoading();
        const detail = Object.entries(r?.report || {})
          .map(([k, v]) => `${k} +${v?.inserted ?? 0}`)
          .join('、');
        uni.showModal({
          title: '导入完成',
          content: `新增 ${r?.total_inserted ?? 0} 条（已存在的跳过）：${detail || '无'}`,
          showCancel: false,
        });
        load();
      } catch (e) {
        uni.hideLoading();
        uni.showToast({ title: '导入失败（需为备份 JSON 文件）', icon: 'none' });
      }
    },
  });
}

async function load() {
  try {
    const d = await request<{ files: BackupItem[] }>('/backup/files', 'GET');
    backups.value = d?.files || [];
  } catch (e) {
    uni.showToast({ title: '备份历史读取失败', icon: 'none' });
  }
}

async function backupNow() {
  busy.value = true;
  try {
    await request('/backup/now', 'POST', {});
    uni.showToast({ title: '备份成功', icon: 'success' });
    load();
  } catch (e) {
    uni.showToast({ title: '备份失败', icon: 'none' });
  } finally {
    busy.value = false;
  }
}

function restore(b: BackupItem) {
  uni.showModal({
    title: '恢复备份',
    content: `从「${b.name_display || b.name}」合并恢复（不覆盖现有数据）？`,
    success: async (r) => {
      if (!r.confirm) return;
      uni.showLoading({ title: '恢复中…' });
      try {
        await request<any>(`/backup/files/${b.name}/restore`, 'POST', {});
        uni.hideLoading();
        uni.showToast({ title: '恢复完成', icon: 'success' });
      } catch (e) {
        uni.hideLoading();
        uni.showToast({ title: '恢复失败', icon: 'none' });
      }
    },
  });
}
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh;  background: var(--page-bg); }
.btn { background: var(--primary); color: #fff; border-radius: 14rpx; font-size: 30rpx; margin-bottom: 16rpx; }
.btn-out { background: var(--card-bg); border: 1rpx solid var(--primary); color: var(--primary); border-radius: 14rpx; font-size: 28rpx; margin-bottom: 16rpx; }
.tip { font-size: 22rpx; color: var(--text-sub); margin: 0 8rpx 28rpx; line-height: 1.6; }
.auto-card { background: var(--card-bg); border-radius: 20rpx; border: var(--card-border); padding: 24rpx; margin-bottom: 24rpx; }
.auto-row { display: flex; align-items: center; justify-content: space-between; margin-bottom: 16rpx; }
.auto-label { font-size: 26rpx; color: var(--text-sub); }
.auto-pick { background: var(--input-bg); border-radius: 12rpx; padding: 12rpx 24rpx; }
.auto-value { font-size: 28rpx; color: var(--text-main); }
.auto-input { width: 160rpx; background: var(--input-bg); border-radius: 12rpx; padding: 12rpx 24rpx; font-size: 28rpx; text-align: center; }
.btn-save { background: var(--primary-soft); color: var(--primary); border-radius: 12rpx; font-size: 26rpx; margin-top: 8rpx; }
.group-title { font-size: 25rpx; color: var(--text-sub); margin: 8rpx 8rpx 16rpx; display: flex; align-items: center; }
.badge { display: inline-block; background: var(--primary-soft); color: var(--primary); border-radius: 999rpx; padding: 2rpx 14rpx; font-size: 20rpx; margin-left: 12rpx; }
.empty { background: var(--card-bg); border-radius: 20rpx; text-align: center; color: var(--text-sub); padding: 60rpx 0; font-size: 26rpx; }
.list { display: flex; flex-direction: column; gap: 16rpx; }
.card { background: var(--card-bg); border-radius: 24rpx; border: var(--card-border); padding: 24rpx; display: flex; align-items: center; justify-content: space-between; }
.info { display: flex; flex-direction: column; gap: 6rpx; }
.b-name { font-size: 28rpx; font-weight: 600; color: var(--text-main); }
.b-size { font-size: 22rpx; color: var(--text-sub); }
.op { font-size: 26rpx; color: var(--primary); padding: 8rpx 20rpx; }
</style>