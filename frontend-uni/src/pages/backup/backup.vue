<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <!-- 备份状态卡：运行状态（进行中/成功/失败+日志）优先，点卡片查看日志（对齐 App 备份页） -->
    <view class="status-card" :class="statusCls" @click="statusTap">
      <view class="st-ic"><text class="mi st-tx" :style="{ color: statusColor }">{{ statusIcon }}</text></view>
      <view class="st-body">
        <text class="st-title">{{ statusTitle }}</text>
        <text class="st-sub" :style="{ color: statusColor }">{{ statusSub }}</text>
      </view>
      <text v-if="showRunArrow" class="st-arrow">›</text>
    </view>

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
import { ref, computed } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

type BackupItem = { name: string; name_display?: string; key: string; size?: number; created_at?: string };
const backups = ref<BackupItem[]>([]);
const busy = ref(false);
// 最近一次备份运行状态（/backup/runs/latest：running/succeeded/failed + 日志，对齐 App backup_page）
const lastRun = ref<{ status: string; message?: string; log_text?: string; started_at?: string } | null>(null);
// 最近一次备份距今天数（null=从未备份/读取失败）+ 显示文本（对齐 App 备份页状态卡）
const lastBackupDays = ref<number | null>(null);
const lastBackupLabel = ref('');
const statusCls = computed(() => {
  const st = lastRun.value?.status;
  if (st === 'failed') return 'stale';
  if (st === 'running' || busy.value) return 'running';
  return lastBackupDays.value === null ? '' : lastBackupDays.value > 7 ? 'stale' : 'ok';
});
/// 状态卡是否可点开查看日志（失败/进行中才有日志可看）
const showRunArrow = computed(() => ['running', 'failed'].includes(lastRun.value?.status || '') || busy.value);
const statusColor = computed(() => {
  const st = lastRun.value?.status;
  if (st === 'failed') return '#f56c6c';
  if (st === 'running' || busy.value) return 'var(--primary)';
  const d = lastBackupDays.value;
  if (d === null) return 'var(--text-sub)';
  if (d > 7) return '#f56c6c';
  return '#22c55e';
});
const statusIcon = computed(() => {
  const st = lastRun.value?.status;
  if (st === 'failed') return '&#xE8B2;'; // 警告
  if (st === 'running' || busy.value) return '&#xE868;'; // 上传
  const d = lastBackupDays.value;
  if (d === null) return '&#xE8B7;'; // 云朵×（未备份）
  if (d > 7) return '&#xE8B2;';
  return '&#xE86C;'; // 云端完成
});
const statusTitle = computed(() => {
  const st = lastRun.value?.status;
  if (st === 'running' || busy.value) return '备份中…';
  if (st === 'failed') return '上次备份失败';
  const d = lastBackupDays.value;
  if (d === null) return '从未备份';
  if (d > 7) return `已 ${d} 天未备份`;
  return `上次备份：${lastBackupLabel.value}`;
});
const statusSub = computed(() => {
  const r = lastRun.value;
  if (r?.status === 'failed') return `${r.message || '点击查看失败原因'}（点击查看详情）`;
  if (r?.status === 'running' || busy.value) return r?.message || '正在打包数据与附件，请稍候';
  const d = lastBackupDays.value;
  if (d === null) return '点「立即备份」把全库数据存到云端，历史可直接恢复';
  if (d > 7) return '建议立即备份，或开启每日自动备份';
  return d <= 1 ? '数据已云端留底' : `距今 ${d} 天 · 数据已云端留底`;
});
/// 点状态卡：查看备份运行日志/失败详情
function statusTap() {
  const r = lastRun.value;
  if (!r || !r.log_text || !r.message) return;
  uni.showModal({
    title: r.status === 'running' ? '备份进行中' : r.status === 'failed' ? '备份失败' : '最近备份',
    content: String(r.log_text || r.message || ''),
    showCancel: false,
  });
}

// 自动备份配置（存服务器 settings：backup_time/backup_keep，Cloudflare cron 每天到点执行）
const autoTime = ref('02:00');
const autoKeep = ref('7');

onShow(async () => {
  if (!getToken()) return;
  load();
  loadAuto();
  loadRun();
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

/// 导出备份：GET /backup?attachments=none 全库表数据（轻量；剪贴板文本不带附件本体，
/// 同环境导入附件引用即可正常读取；跨环境带图请用「立即备份到云端」或 App 本地导出）
async function exportBackup() {
  uni.showLoading({ title: '导出中…' });
  try {
    const d = await request<Record<string, unknown>>('/backup?attachments=none', 'GET');
    uni.hideLoading();
    const json = JSON.stringify(d, null, 2);
    if (json.length > 900000) {
      uni.showToast({ title: '备份数据过大，请用「立即备份到云端」', icon: 'none' });
      return;
    }
    uni.setClipboardData({ data: json });
    uni.showToast({ title: '备份 JSON 已复制（不含附件本体，附件请用云端备份）', icon: 'success' });
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
    applyLastBackup(backups.value);
  } catch (e) {
    uni.showToast({ title: '备份历史读取失败', icon: 'none' });
  }
}

/// 从历史最新一条算"距今天数 + 显示文本"（created_at 为 UTC ISO，转本地时区按自然日差；对齐 App _applyLastBackup）
function applyLastBackup(list: BackupItem[]) {
  if (!list.length) {
    lastBackupDays.value = null;
    lastBackupLabel.value = '';
    return;
  }
  const t = new Date(list[0].created_at || '');
  if (isNaN(t.getTime())) {
    lastBackupDays.value = null;
    lastBackupLabel.value = '';
    return;
  }
  // UTC → 本地时刻（getTimezoneOffset 返回"本地-UTC"分钟差，东八区为 -480）
  const loc = new Date(t.getTime() - t.getTimezoneOffset() * 60000);
  const now = new Date();
  const d0 = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const d1 = new Date(loc.getFullYear(), loc.getMonth(), loc.getDate());
  const days = Math.max(0, Math.round((d0.getTime() - d1.getTime()) / 86400000));
  lastBackupDays.value = days;
  const hm = `${String(loc.getHours()).padStart(2, '0')}:${String(loc.getMinutes()).padStart(2, '0')}`;
  if (days <= 0) lastBackupLabel.value = `今天 ${hm}`;
  else if (days === 1) lastBackupLabel.value = `昨天 ${hm}`;
  else lastBackupLabel.value = `${String(loc.getMonth() + 1).padStart(2, '0')}-${String(loc.getDate()).padStart(2, '0')} ${hm}`;
}

async function backupNow() {
  if (busy.value) {
    uni.showToast({ title: '备份进行中，请稍候', icon: 'none' });
    return;
  }
  busy.value = true;
  try {
    const r = await request<{ key?: string; status?: string; message?: string }>('/backup/now', 'POST', {});
    const status = r?.status || 'succeeded';
    const msg = r?.message || '';
    if (status === 'failed') {
      uni.showToast({ title: `备份失败：${msg || '未知错误'}`, icon: 'none', duration: 3000 });
    } else {
      uni.showToast({ title: `备份成功：${msg || '已备份到云端'}`, icon: 'success' });
    }
    load();
    loadRun();
  } catch (e) {
    uni.showToast({ title: '备份失败（503 超时等），请重试或检查云端存储', icon: 'none', duration: 3000 });
  } finally {
    busy.value = false;
    loadRun();
  }
}

/// 最近一次备份运行状态（状态卡：进行中/成功/失败 + 日志）
async function loadRun() {
  try {
    const d = await request<{ run: { status: string; message?: string; log_text?: string; started_at?: string } | null }>('/backup/runs/latest', 'GET');
    lastRun.value = d?.run || null;
  } catch (_) {}
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
/* 备份状态卡（对齐 App 备份页状态卡：主色描边圆角，图标+标题+副文案） */
.status-card { display: flex; align-items: center; gap: 18rpx; border-radius: 20rpx; padding: 24rpx; margin-bottom: 20rpx; background: var(--card-bg); border: 1rpx solid var(--divider); }
.status-card.ok { border-color: rgba(34, 197, 94, 0.4); background: rgba(34, 197, 94, 0.08); }
.status-card.stale { border-color: rgba(245, 108, 108, 0.4); background: rgba(245, 108, 108, 0.08); }
.status-card.running { border-color: rgba(64, 158, 255, 0.45); background: rgba(64, 158, 255, 0.08); }
.st-arrow { font-size: 34rpx; color: var(--text-sub); flex-shrink: 0; }
.st-ic { width: 60rpx; height: 60rpx; border-radius: 16rpx; background: var(--card-bg); display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
.st-tx { font-size: 36rpx; line-height: 1; }
.st-body { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 6rpx; }
.st-title { font-size: 28rpx; font-weight: 600; color: var(--text-main); }
.st-sub { font-size: 22rpx; line-height: 1.5; }
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