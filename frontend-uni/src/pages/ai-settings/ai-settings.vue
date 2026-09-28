<template>
  <view class="page">
    <view class="group-title">AI 识别设置</view>
    <view class="card">
      <view class="row" v-for="p in providers" :key="p.id">
        <view class="p-info">
          <text class="p-name">{{ p.name }}</text>
          <text :class="['p-state', p.has_key ? 'ok' : 'no']">{{ p.has_key ? '已配置 Key' : '未配置 Key' }}</text>
        </view>
        <text class="p-id">{{ p.is_built_in ? '内置' : '自定义' }}</text>
      </view>
    </view>

    <view class="group-title">能力绑定</view>
    <view class="card">
      <view class="row"><text class="r-tx">文本记账</text><text class="r-val">{{ bindName(bind.textProviderId) }}</text></view>
      <view class="row"><text class="r-tx">图片识别</text><text class="r-val">{{ bindName(bind.visionProviderId) }}</text></view>
      <view class="row"><text class="r-tx">语音记账</text><text class="r-val">{{ bindName(bind.speechProviderId) }}</text></view>
    </view>

    <view class="tip">在 App「我的 → AI 识别设置」可完整配置服务商 Key 与模型；小程序仅查看绑定状态（服务商 Key 由服务器持有）。</view>

    <view class="group-title">测试</view>
    <button class="btn" :disabled="testing" @click="testAll">{{ testing ? '测试中…' : '一键测试三项能力' }}</button>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onShow } from '@dcloudio/uni-app';
import { request, getToken } from '../../api';

const providers = ref<Array<{ id: string; name: string; is_built_in?: boolean; has_key?: boolean }>>([]);
const bind = ref<{ textProviderId?: string; visionProviderId?: string; speechProviderId?: string }>({});
const testing = ref(false);

const bindName = (id?: string) => providers.value.find((p) => p.id === id)?.name || '智谱GLM(默认)';

onShow(async () => {
  if (!getToken()) return;
  try {
    const d = await request<{ providers: Array<{ id: string; name: string; is_built_in?: boolean; has_key?: boolean }>; binding: { textProviderId?: string; visionProviderId?: string; speechProviderId?: string } }>('/settings/ai', 'GET');
    if (d?.providers) providers.value = d.providers;
    if (d?.binding) bind.value = d.binding;
  } catch (e) {
    uni.showToast({ title: 'AI 配置读取失败', icon: 'none' });
  }
});

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
.page { padding: 24rpx; background: #f5f7fa; min-height: 100vh; }
.group-title { font-size: 25rpx; color: #909399; margin: 8rpx 8rpx 16rpx; }
.card { background: #fff; border-radius: 20rpx; padding: 8rpx 24rpx; margin-bottom: 24rpx; }
.row { display: flex; align-items: center; justify-content: space-between; padding: 22rpx 0; border-bottom: 1rpx solid #f5f5f5; }
.row:last-child { border-bottom: none; }
.p-info { display: flex; align-items: center; gap: 14rpx; }
.p-name { font-size: 28rpx; color: #303133; }
.p-state { font-size: 20rpx; padding: 4rpx 14rpx; border-radius: 999rpx; }
.p-state.ok { background: #e8f7ee; color: #67c23a; }
.p-state.no { background: #fdf3e7; color: #e6a23c; }
.p-id { font-size: 22rpx; color: #c0c4cc; }
.r-tx { font-size: 28rpx; color: #303133; }
.r-val { font-size: 26rpx; color: #409eff; }
.tip { font-size: 22rpx; color: #909399; line-height: 1.6; margin: 0 8rpx 24rpx; }
.btn { background: #409eff; color: #fff; border-radius: 14rpx; font-size: 30rpx; }
</style>