<template>
  <view class="page" :style="tv">
    <view class="group-title">AI 服务商（Key 由服务器持有）</view>
    <view class="card" v-for="p in providers" :key="p.id">
      <view class="p-head">
        <view class="p-info">
          <text class="p-name">{{ p.name }}</text>
          <text :class="['p-state', p.hasKey ? 'ok' : 'no']">{{ p.hasKey ? '已配置' : '未配置 Key' }}</text>
          <text class="p-id">{{ p.isBuiltIn ? '内置' : '自定义' }}</text>
        </view>
      </view>
      <view class="f-row">
        <text class="f-lb">API Key</text>
        <input class="f-ipt" :value="editKey[p.id] || ''" placeholder="留空=保留原值/未配置" @input="onKey(p.id, $event)" />
      </view>
    </view>

    <view class="group-title">能力绑定</view>
    <view class="card">
      <view class="b-row" v-for="row in bindRows" :key="row.key">
        <text class="r-tx">{{ row.label }}</text>
        <picker :range="providers" range-key="name" :value="bindIdx[row.key]" @change="onBind(row.key, $event)">
          <view class="r-pick">{{ row.name }} ▾</view>
        </picker>
      </view>
    </view>

    <button class="btn" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
    <button class="btn ghost" :disabled="testing" @click="testAll">{{ testing ? '测试中…' : '一键测试三项能力' }}</button>
  </view>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';
import { useThemeVars } from '../../theme';

const tv = useThemeVars();
const providers = ref<Array<{ id: string; name: string; isBuiltIn?: boolean; hasKey?: boolean }>>([]);
const editKey = ref<Record<string, string>>({});
const bind = ref<Record<string, string>>({ textProviderId: '', visionProviderId: '', speechProviderId: '' });
const saving = ref(false);
const testing = ref(false);

const caps = [
  { key: 'textProviderId', label: '文本记账' },
  { key: 'visionProviderId', label: '图片识别' },
  { key: 'speechProviderId', label: '语音记账' },
];
const bindRows = computed(() =>
  caps.map((c) => ({ ...c, name: providers.value.find((p) => p.id === bind.value[c.key])?.name || '智谱GLM(默认)' }))
);
const bindIdx = computed(() => {
  const m: Record<string, number> = {};
  for (const c of caps) {
    m[c.key] = Math.max(0, providers.value.findIndex((p) => p.id === bind.value[c.key]));
  }
  return m;
});

function onKey(id: string, e: any) {
  editKey.value[id] = e.detail.value;
}
function onBind(key: string, e: any) {
  const p = providers.value[Number(e.detail.value)];
  if (p) bind.value[key] = p.id;
}

onShow(async () => {
  if (!getToken()) return;
  try {
    const d = await request<{ providers: Array<{ id: string; name: string; is_built_in?: boolean; has_key?: boolean }>; binding: { textProviderId?: string; visionProviderId?: string; speechProviderId?: string } }>('/settings/ai', 'GET');
    if (d?.providers) {
      providers.value = d.providers.map((p) => ({ id: p.id, name: p.name, isBuiltIn: Boolean(p.is_built_in), hasKey: Boolean(p.has_key) }));
    }
    if (d?.binding) bind.value = { ...bind.value, ...d.binding };
  } catch (e) {
    uni.showToast({ title: 'AI 配置读取失败', icon: 'none' });
  }
});

async function save() {
  saving.value = true;
  try {
    // providers：有输入 Key 的服务商更新 Key（留空=不传，保留原值；输入了=覆盖）
    const provs = Object.keys(editKey.value)
      .filter((id) => (editKey.value[id] || '').trim() !== '')
      .map((id) => ({ id, api_key: editKey.value[id].trim() }));
    const body: Record<string, unknown> = { binding: { ...bind.value } };
    if (provs.length) body.providers = provs;
    await request('/settings/ai', 'PUT', body);
    uni.showToast({ title: '已保存', icon: 'none' });
    editKey.value = {};
    // 刷新展示
    const d = await request<{ providers: Array<{ id: string; name: string; is_built_in?: boolean; has_key?: boolean }> }>('/settings/ai', 'GET');
    if (d?.providers) providers.value = d.providers.map((p) => ({ id: p.id, name: p.name, isBuiltIn: Boolean(p.is_built_in), hasKey: Boolean(p.has_key) }));
  } catch (e) {
    uni.showToast({ title: '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

async function testAll() {
  testing.value = true;
  const results: string[] = [];
  for (const cap of ['text', 'vision', 'speech']) {
    try {
      const d = await request<{ ok?: boolean }>(`/ai/test?capability=${cap}`, 'POST', {});
      results.push(`${cap === 'text' ? '文本' : cap === 'vision' ? '图片' : '语音'}:${d?.ok ? '✓' : '✗'}`);
    } catch (e) {
      results.push(`${cap === 'text' ? '文本' : cap === 'vision' ? '图片' : '语音'}:✗`);
    }
  }
  testing.value = false;
  uni.showModal({ title: 'AI 测试结果', content: results.join('\n'), showCancel: false });
}
</script>

<style>
.page { padding: 24rpx; background: linear-gradient(180deg, var(--primary-fade) 0%, #f5f7fa 34%); min-height: 100vh; }
.group-title { font-size: 25rpx; color: var(--text-sub); margin: 8rpx 8rpx 16rpx; }
.card { background: var(--card-bg); border-radius: 20rpx; padding: 8rpx 24rpx; margin-bottom: 24rpx; }
.p-head { padding: 20rpx 0 8rpx; }
.p-info { display: flex; align-items: center; gap: 14rpx; }
.p-name { font-size: 28rpx; color: var(--text-main); }
.p-state { font-size: 20rpx; padding: 4rpx 14rpx; border-radius: 999rpx; }
.p-state.ok { background: #e8f7ee; color: #67c23a; }
.p-state.no { background: #fdf3e7; color: #e6a23c; }
.p-id { font-size: 22rpx; color: #c0c4cc; }
.f-row { display: flex; align-items: center; gap: 16rpx; padding: 14rpx 0 20rpx; }
.f-lb { font-size: 24rpx; color: var(--text-sub); width: 120rpx; flex-shrink: 0; }
.f-ipt { flex: 1; background: var(--input-bg); border-radius: 12rpx; padding: 12rpx 20rpx; font-size: 26rpx; }
.b-row { display: flex; align-items: center; justify-content: space-between; padding: 22rpx 0; border-bottom: 1rpx solid var(--divider); }
.b-row:last-child { border-bottom: none; }
.r-tx { font-size: 28rpx; color: var(--text-main); }
.r-pick { font-size: 26rpx; color: var(--primary); font-weight: 600; }
.btn { background: var(--primary); color: #fff; border-radius: 14rpx; font-size: 30rpx; margin-top: 16rpx; }
.btn.ghost { background: var(--card-bg); color: var(--primary); border: 2rpx solid var(--primary); margin-top: 16rpx; }
</style>