<template>
  <view class="page" :style="tv">
  <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <view class="group-title">AI 服务商（Key 由服务器持有）</view>
    <view class="card" v-for="p in providers" :key="p.id">
      <view class="p-head">
        <view class="p-info">
          <text class="p-name">{{ p.name }}</text>
          <text :class="['p-state', p.hasKey ? 'ok' : 'no']">{{ p.hasKey ? '已配置' : '未配置 Key' }}</text>
          <text class="p-id">{{ p.isBuiltIn ? '内置' : '自定义' }}</text>
        </view>
        <view class="p-ops">
          <text v-if="!p.isBuiltIn" class="p-del" @click="removeProvider(p)">删除</text>
        </view>
      </view>
      <view class="f-row">
        <text class="f-lb">API 地址</text>
        <input class="f-ipt" :value="(editBase[p.id] ?? p.baseUrl) || ''" placeholder="https://api.xxx.com/v1" @input="onBase(p.id, $event)" />
      </view>
      <view class="f-row">
        <text class="f-lb">API Key</text>
        <input class="f-ipt" :value="editKey[p.id] ?? ''" placeholder="留空=保留原值" @input="onKey(p.id, $event)" />
        <text v-if="p.hasKey" class="p-clear" @click="clearKey(p)">清空</text>
      </view>
    </view>
    <view class="add-btn" @click="showAdd = true">+ 添加自定义服务商</view>

    <view class="group-title">能力绑定</view>
    <view class="card">
      <view class="b-row" v-for="row in bindRows" :key="row.key">
        <view class="b-left">
          <text class="r-tx">{{ row.label }}</text>
          <picker :range="providers" range-key="name" :value="bindIdx[row.key]" @change="onBind(row.key, $event)">
            <view class="r-pick">{{ row.name }} ▾</view>
          </picker>
        </view>
        <text class="t-btn" @click="testOne(row.cap)">{{ row.testTxt || '测试' }}</text>
      </view>
    </view>

    <button class="btn" :disabled="saving" @click="save">{{ saving ? '保存中…' : '保存' }}</button>
    <button class="btn ghost" :disabled="testing" @click="testAll">{{ testing ? '测试中…' : '一键测试三项能力' }}</button>

    <!-- 添加自定义服务商弹层 -->
    <view v-if="showAdd" class="mask" @click="showAdd = false">
      <view class="sheet" @click.stop>
        <view class="sheet-title">添加自定义服务商</view>
        <input class="ipt" v-model="addForm.name" placeholder="名称（如 阿里云百炼）" />
        <input class="ipt" v-model="addForm.baseUrl" placeholder="API 地址 https://…/v1" />
        <input class="ipt" v-model="addForm.apiKey" placeholder="API Key" />
        <button class="btn-save" @click="addProvider">添加</button>
      </view>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref, computed } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';
import { useThemeVars } from '../../theme';

const { tv, patternSrc } = useThemeVars();
interface Provider { id: string; name: string; isBuiltIn?: boolean; hasKey?: boolean; baseUrl?: string }
const providers = ref<Provider[]>([]);
const editKey = ref<Record<string, string | undefined>>({});
const editBase = ref<Record<string, string | undefined>>({});
const bind = ref<Record<string, string>>({ textProviderId: '', visionProviderId: '', speechProviderId: '' });
const saving = ref(false);
const testing = ref(false);
const showAdd = ref(false);
const addForm = ref({ name: '', baseUrl: '', apiKey: '' });
const testTxt = ref<Record<string, string>>({});

const caps = [
  { key: 'textProviderId', label: '文本记账', cap: 'text' },
  { key: 'visionProviderId', label: '图片识别', cap: 'vision' },
  { key: 'speechProviderId', label: '语音记账', cap: 'speech' },
];
const bindRows = computed(() =>
  caps.map((c) => ({
    ...c,
    name: providers.value.find((p) => p.id === bind.value[c.key])?.name || '智谱GLM(默认)',
    testTxt: testTxt.value[c.cap] || '',
  }))
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
function onBase(id: string, e: any) {
  editBase.value[id] = e.detail.value;
}
function onBind(key: string, e: any) {
  const p = providers.value[Number(e.detail.value)];
  if (p) bind.value[key] = p.id;
}
// 清空 Key：把该 id 的编辑值显式置空串（后端 ''=清空；未编辑不传=保留）
function clearKey(p: Provider) {
  editKey.value[p.id] = '';
  uni.showToast({ title: `已标记清空「${p.name}」Key，点保存生效`, icon: 'none' });
}
// 删除自定义服务商（从列表移除，保存时同步到服务器；zhipu 内置不可删）
function removeProvider(p: Provider) {
  uni.showModal({
    title: '删除服务商',
    content: `删除「${p.name}」？绑定该服务商的能力将回退到智谱默认。`,
    success: (r) => {
      if (!r.confirm) return;
      providers.value = providers.value.filter((x) => x.id !== p.id);
      for (const c of caps) {
        if (bind.value[c.key] === p.id) bind.value[c.key] = 'zhipu_glm';
      }
      delete editKey.value[p.id];
      delete editBase.value[p.id];
    },
  });
}
function addProvider() {
  const name = addForm.value.name.trim();
  if (!name) {
    uni.showToast({ title: '请填写服务商名称', icon: 'none' });
    return;
  }
  if (providers.value.some((p) => p.name === name)) {
    uni.showToast({ title: '同名服务商已存在', icon: 'none' });
    return;
  }
  const id = `custom_${Date.now().toString(36)}`;
  providers.value.push({ id, name, isBuiltIn: false, hasKey: !!(addForm.value.apiKey.trim()), baseUrl: addForm.value.baseUrl.trim() || 'https://open.bigmodel.cn/api/paas/v4' });
  if (addForm.value.apiKey.trim()) editKey.value[id] = addForm.value.apiKey.trim();
  if (addForm.value.baseUrl.trim()) editBase.value[id] = addForm.value.baseUrl.trim();
  addForm.value = { name: '', baseUrl: '', apiKey: '' };
  showAdd.value = false;
  save();
}

onShow(async () => {
  if (!getToken()) return;
  try {
    const d = await request<{ providers: Array<{ id: string; name: string; is_built_in?: boolean; has_key?: boolean; base_url?: string }>; binding: { textProviderId?: string; visionProviderId?: string; speechProviderId?: string } }>('/settings/ai', 'GET');
    if (d?.providers) {
      providers.value = d.providers.map((p) => ({ id: p.id, name: p.name, isBuiltIn: Boolean(p.is_built_in), hasKey: Boolean(p.has_key), baseUrl: p.base_url || '' }));
    }
    if (d?.binding) bind.value = { ...bind.value, ...d.binding };
  } catch (e) {
    uni.showToast({ title: 'AI 配置读取失败', icon: 'none' });
  }
});

async function save() {
  saving.value = true;
  try {
    // providers 全量：名称/地址/Key（undefined=保留、''=清空、非空=覆盖），含新增/删除
    const provs = providers.value.map((p) => {
      const body: Record<string, string> = { id: p.id, name: p.name };
      if (editBase.value[p.id] !== undefined) body.base_url = editBase.value[p.id] ?? '';
      if (editKey.value[p.id] !== undefined) body.api_key = editKey.value[p.id] ?? '';
      return body;
    });
    await request('/settings/ai', 'PUT', { providers: provs, binding: { ...bind.value } });
    uni.showToast({ title: '已保存', icon: 'none' });
    editKey.value = {};
    editBase.value = {};
    const d = await request<{ providers: Array<{ id: string; name: string; is_built_in?: boolean; has_key?: boolean; base_url?: string }> }>('/settings/ai', 'GET');
    if (d?.providers) providers.value = d.providers.map((p) => ({ id: p.id, name: p.name, isBuiltIn: Boolean(p.is_built_in), hasKey: Boolean(p.has_key), baseUrl: p.base_url || '' }));
  } catch (e) {
    uni.showToast({ title: '保存失败', icon: 'none' });
  } finally {
    saving.value = false;
  }
}

// 单项能力测试（对齐 App：测试当前绑定能力 → 结果就地显示）
async function testOne(cap: string) {
  testTxt.value[cap] = '测试中…';
  try {
    const d = await request<{ ok?: boolean }>(`/ai/test?capability=${cap}`, 'POST', {});
    testTxt.value[cap] = d?.ok ? '✓ 通过' : '✗ 失败';
  } catch (e) {
    testTxt.value[cap] = '✗ 失败';
  }
}

async function testAll() {
  testing.value = true;
  const results: string[] = [];
  for (const c of caps) {
    try {
      const d = await request<{ ok?: boolean }>(`/ai/test?capability=${c.cap}`, 'POST', {});
      results.push(`${c.label}:${d?.ok ? '✓' : '✗'}`);
    } catch (e) {
      results.push(`${c.label}:✗`);
    }
  }
  testing.value = false;
  uni.showModal({ title: 'AI 测试结果', content: results.join('\n'), showCancel: false });
}
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { padding: 24rpx;  min-height: 100vh;  background: var(--page-bg); }
.group-title { font-size: 25rpx; color: var(--text-sub); margin: 8rpx 8rpx 16rpx; }
.card { background: var(--card-bg); border-radius: 16rpx; padding: 8rpx 24rpx; margin-bottom: 24rpx; box-shadow: var(--card-shadow);}
.p-head { display: flex; align-items: center; justify-content: space-between; padding: 20rpx 0 8rpx; }
.p-info { display: flex; align-items: center; gap: 14rpx; }
.p-name { font-size: 28rpx; color: var(--text-main); }
.p-state { font-size: 20rpx; padding: 4rpx 14rpx; border-radius: 999rpx; }
.p-state.ok { background: var(--ok-bg); color: #67c23a; }
.p-state.no { background: var(--warn-bg); color: #e6a23c; }
.p-id { font-size: 22rpx; color: var(--text-sub); }
.p-ops { display: flex; gap: 16rpx; }
.p-del { font-size: 24rpx; color: #f56c6c; }
.p-clear { font-size: 22rpx; color: var(--text-sub); border: 1rpx solid var(--text-sub); border-radius: 8rpx; padding: 4rpx 12rpx; flex-shrink: 0; }
.f-row { display: flex; align-items: center; gap: 16rpx; padding: 14rpx 0 20rpx; }
.f-lb { font-size: 24rpx; color: var(--text-sub); width: 120rpx; flex-shrink: 0; }
.f-ipt { flex: 1; background: var(--input-bg); border-radius: 12rpx; padding: 12rpx 20rpx; font-size: 26rpx; }
.add-btn { text-align: center; font-size: 26rpx; color: var(--primary); border: 2rpx dashed var(--primary); border-radius: 12rpx; padding: 20rpx 0; margin-bottom: 24rpx; }
.b-row { display: flex; align-items: center; justify-content: space-between; padding: 22rpx 0; border-bottom: 1rpx solid var(--divider); }
.b-row:last-child { border-bottom: none; }
.b-left { display: flex; align-items: center; gap: 20rpx; }
.r-tx { font-size: 28rpx; color: var(--text-main); }
.r-pick { font-size: 26rpx; color: var(--primary); font-weight: 600; }
.t-btn { font-size: 22rpx; color: var(--primary); border: 1rpx solid var(--primary); border-radius: 8rpx; padding: 4rpx 14rpx; flex-shrink: 0; }
.btn { background: var(--primary); color: #fff; border-radius: 14rpx; font-size: 30rpx; margin-top: 16rpx; box-shadow: 0 6rpx 18rpx var(--primary-fade); }
.btn.ghost { background: var(--card-bg); color: var(--primary); border: 2rpx solid var(--primary); margin-top: 16rpx; box-shadow: none; }
.mask { position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: rgba(0,0,0,0.4); display: flex; align-items: flex-end; z-index: 100; }
.sheet { width: 100%; background: var(--sheet-bg); border-radius: 24rpx 24rpx 0 0; padding: 40rpx 32rpx; box-sizing: border-box; }
.sheet-title { font-size: 34rpx; font-weight: bold; margin-bottom: 24rpx; text-align: center; }
.ipt { background: var(--input-bg); border-radius: 12rpx; padding: 18rpx 20rpx; margin-bottom: 16rpx; font-size: 28rpx; }
.btn-save { background: var(--primary); color: #fff; border-radius: 12rpx; font-size: 30rpx; }
</style>