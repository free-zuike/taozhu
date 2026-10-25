<template>
  <view class="page" :style="tv">
    <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <scroll-view scroll-y class="chat" :scroll-into-view="bottomAnchor" scroll-with-animation>
      <view v-for="(m, i) in messages" :key="i" :id="'m' + i"
        :class="['bubble-row', m.role === 'user' ? 'mine' : 'peer']">
        <view :class="['bubble', m.role === 'user' ? 'b-mine' : 'b-peer']">
          <text>{{ m.content }}</text>
          <view v-if="m.role !== 'user' && m.sources" class="src">📖 依据：{{ m.sources }}</view>
        </view>
      </view>
      <view v-if="thinking" class="bubble-row peer">
        <view class="bubble b-peer typing">AI 思考中…</view>
      </view>
      <view id="bottom" style="height: 8rpx" />
    </scroll-view>

    <scroll-view scroll-x class="quick-bar">
      <view v-for="q in quickQs" :key="q" class="chip" @click="send(q)">{{ q }}</view>
    </scroll-view>

    <view class="input-bar">
      <input class="ipt" v-model="input" placeholder="问问经营数据…（需在线）" confirm-type="send" @confirm="send()" />
      <button class="btn-send" :disabled="thinking || !input.trim()" @click="send()">{{ thinking ? '…' : '发送' }}</button>
    </view>
  </view>
</template>

<script setup lang="ts">
import { ref } from 'vue';
import { onLoad } from '@dcloudio/uni-app';
import { useThemeVars } from '../../theme';
import { request } from '../../api';

const { tv, patternSrc } = useThemeVars();

const HIST_KEY = 'ai_assistant_history';
interface Msg { role: 'user' | 'assistant'; content: string; sources?: string }
const messages = ref<Msg[]>([]);
const input = ref('');
const thinking = ref(false);
const bottomAnchor = ref('');
const quickQs = ['今天卖了多少？', '本月毛利多少？', '哪个店欠款最多？', '哪些货快卖完了？', '有什么快过期？', '怎么记一笔账？'];

const WELCOME = '你好，我是 AI 助手。可以问我经营数据，比如：今天卖了多少？哪个店欠款多？哪些货该补了？也可以问功能怎么用。';

function loadHistory() {
  try {
    const raw = uni.getStorageSync(HIST_KEY);
    if (raw) {
      const list = JSON.parse(raw) as Msg[];
      messages.value = list.filter((m) => m.role === 'user' || m.role === 'assistant');
    }
  } catch (_) {}
  if (!messages.value.length) messages.value = [{ role: 'assistant', content: WELCOME }];
}
function saveHistory() {
  try {
    const list = messages.value.length > 60 ? messages.value.slice(-60) : messages.value;
    uni.setStorageSync(HIST_KEY, JSON.stringify(list));
  } catch (_) {}
}
function scrollBottom() {
  setTimeout(() => { bottomAnchor.value = 'bottom'; }, 60);
}
function clearChat() {
  messages.value = [{ role: 'assistant', content: WELCOME }];
  saveHistory();
}

onLoad(() => {
  loadHistory();
  scrollBottom();
  uni.setNavigationBarTitle({ title: 'AI 助手' });
});

async function send(preset?: string) {
  const text = (preset ?? input.value).trim();
  if (!text || thinking.value) return;
  if (!preset) input.value = '';
  messages.value.push({ role: 'user', content: text });
  thinking.value = true;
  saveHistory();
  scrollBottom();
  try {
    // 多轮历史一并带上（服务端无状态，客户端负责上下文）
    const d = await request<{ reply: string; sources?: string[] }>('/ai/chat', 'POST', {
      messages: messages.value.map((m) => ({ role: m.role, content: m.content })),
    });
    thinking.value = false;
    const sources = (d?.sources || []).join('、');
    messages.value.push({
      role: 'assistant',
      content: (d?.reply || '').trim() || '（模型没有返回内容，请稍后再试）',
      ...(sources ? { sources } : {}),
    });
    saveHistory();
    scrollBottom();
  } catch (e) {
    thinking.value = false;
    uni.showToast({ title: (e as Error).message || 'AI 助手请求失败', icon: 'none' });
  }
}
</script>

<style>
.bg-pattern { position: absolute; left: 0; top: 0; width: 100%; height: 100%; z-index: -1; opacity: 0.9; pointer-events: none; }
.page { min-height: 100vh; background: var(--page-bg); display: flex; flex-direction: column; }
.chat { flex: 1; padding: 24rpx; box-sizing: border-box; }
.bubble-row { display: flex; margin-bottom: 20rpx; }
.bubble-row.mine { justify-content: flex-end; }
.bubble { max-width: 78%; padding: 20rpx 26rpx; font-size: 28rpx; line-height: 1.5; border-radius: 24rpx; word-break: break-all; }
.b-mine { background: var(--primary); color: #fff; border-bottom-right-radius: 6rpx; }
.b-peer { background: var(--card-bg); color: var(--text-main); border: 1rpx solid var(--divider); border-bottom-left-radius: 6rpx; }
.typing { color: var(--text-sub); }
.src { margin-top: 10rpx; font-size: 22rpx; color: var(--text-sub); }
.quick-bar { white-space: nowrap; padding: 8rpx 16rpx; box-sizing: border-box; }
.chip { display: inline-block; padding: 12rpx 24rpx; margin-right: 16rpx; background: var(--card-bg); border-radius: 28rpx; font-size: 26rpx; color: var(--text-sub); border: 1rpx solid var(--divider); }
.input-bar { display: flex; align-items: center; gap: 16rpx; padding: 20rpx 24rpx calc(20rpx + env(safe-area-inset-bottom)); box-sizing: border-box; }
.ipt { flex: 1; background: var(--input-bg); border-radius: 34rpx; padding: 14rpx 26rpx; font-size: 28rpx; }
.btn-send { background: var(--primary); color: #fff; border-radius: 34rpx; font-size: 28rpx; padding: 0 40rpx; margin: 0; }
.btn-send[disabled] { opacity: 0.5; }
</style>