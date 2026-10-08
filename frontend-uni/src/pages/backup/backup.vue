<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="group-title">备份</view>
    <view class="grp">
      <view class="tile" @click="backupNow">
        <view class="t-ic ic-blue"><text class="mi ic-tx">&#xE2C3;</text></view>
        <view class="t-body"><text class="t-tx">立即备份</text><text class="t-sub">手动备份全库到云端（历史可直接恢复），保留最近 {{ autoKeep }} 份</text></view>
        <text class="t-arrow">›</text>
      </view>
      <view class="tile" @click="exportBackup">
        <view class="t-ic ic-blue"><text class="mi ic-tx">&#xE2C0;</text></view>
        <view class="t-body"><text class="t-tx">导出备份</text><text class="t-sub">导出全库 JSON 存档（建议定期导出留底）</text></view>
        <text class="t-arrow">›</text>
      </view>
      <view class="tile" @click="importBackup">
        <view class="t-ic ic-blue"><text class="mi ic-tx">&#xE88E;</text></view>
        <view class="t-body"><text class="t-tx">导入备份</text><text class="t-sub">从备份 JSON 合并恢复（不覆盖现有数据）</text></view>
        <text class="t-arrow">›</text>
      </view>
    </view>

    <view class="group-title">自动备份</view>
    <view class="grp">
      <view class="tile">
        <view class="t-ic ic-blue"><text class="mi ic-tx">&#xE8B5;</text></view>
        <view class="t-body"><text class="t-tx">自动备份时间</text><text class="t-sub">每天 {{ autoTime }}（北京时间）自动备份全库到云端</text></view>
        <picker mode="time" :value="autoTime" @change="onAutoTime">
          <text class="t-value">{{ autoTime }} ›</text>
        </picker>
      </view>
      <view class="tile" @click="pickAutoKeep">
        <view class="t-ic ic-blue"><text class="mi ic-tx">&#xE889;</text></view>
        <view class="t-body"><text class="t-tx">保留备份份数</text><text class="t-sub">云端只保留最近 {{ autoKeep }} 份，超出自动删除最旧</text></view>
        <text class="t-value">{{ autoKeep }}</text>
      </view>
    </view>

    <view class="group-title">备份历史（云端）<span class="badge">{{ backups.length }}</span></view>
    <view v-if="backups.length === 0" class="empty">暂无备份，点「立即备份」创建</view>
    <view v-else class="grp">
      <view v-for="b in backups" :key="b.key" class="tile">
        <view class="t-ic ic-green"><text class="mi ic-tx" style="color:#22c55e">&#xE86C;</text></view>
        <view class="t-body"><text class="t-tx">{{ b.name_display || b.name }}</text><text class="t-sub">{{ b.size ? (b.size / 1024).toFixed(1) + ' KB' : '' }}</text></view>
        <text class="t-op" @click="restore(b)">恢复</text>
      </view>
    </view>

    <view class="foot-note">导出会把全部店铺、商品、出货、收款等数据保存为一个 JSON 文件；导入只新增备份里有而当前没有的记录，不会覆盖或删除现有数据。</view>
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
  saveAuto(); // 选完即保存（对齐 App：点击时间即 PUT）
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
/// 保留份数：弹框输入（对齐 App dialog 输入 1-90）
function pickAutoKeep() {
  uni.showModal({
    title: '自动备份保留份数',
    editable: true,
    content: String(autoKeep.value),
    placeholderText: '1-90（默认 14）',
    success: (r) => {
      if (!r.confirm) return;
      const keep = Number((r.content || '').trim());
      if (!keep || keep < 1 || keep > 90) {
        uni.showToast({ title: '请输入 1-90 的份数', icon: 'none' });
        return;
      }
      autoKeep.value = String(keep);
      saveAuto();
    },
  });
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
.page { min-height: 100vh;  background: var(--page-bg); padding: 24rpx; box-sizing: border-box; }
.group-title { font-size: 25rpx; color: var(--text-sub); margin: 8rpx 8rpx 16rpx; display: flex; align-items: center; }
.badge { display: inline-block; background: var(--primary-soft); color: var(--primary); border-radius: 999rpx; padding: 2rpx 14rpx; font-size: 20rpx; margin-left: 12rpx; }
/* 分组卡片 + tile 行（对齐 App backup_page 卡片布局） */
.grp { background: var(--card-bg); border: var(--card-border); border-radius: 20rpx; margin-bottom: 24rpx; overflow: hidden; }
.tile { display: flex; align-items: center; gap: 16rpx; padding: 24rpx; border-bottom: 1rpx solid var(--divider); }
.tile:last-child { border-bottom: none; }
.t-ic { width: 72rpx; height: 72rpx; border-radius: 18rpx; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.ic-blue { background: var(--primary-soft); } .ic-green { background: var(--ok-bg); }
.ic-tx { font-size: 34rpx; line-height: 1; color: var(--primary); }
.t-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 6rpx; }
.t-tx { font-size: 29rpx; color: var(--text-main); }
.t-sub { font-size: 23rpx; color: var(--text-sub); line-height: 1.5; }
.t-value { font-size: 28rpx; color: var(--primary); font-weight: 600; flex-shrink: 0; }
.t-arrow { font-size: 36rpx; color: var(--text-sub); flex-shrink: 0; }
.t-op { font-size: 26rpx; color: #22c55e; padding: 8rpx 16rpx; flex-shrink: 0; }
.empty { background: var(--card-bg); border-radius: 20rpx; text-align: center; color: var(--text-sub); padding: 60rpx 0; font-size: 26rpx; margin-bottom: 24rpx; }
.foot-note { font-size: 22rpx; color: var(--text-sub); line-height: 1.6; padding: 0 8rpx; }
</style>