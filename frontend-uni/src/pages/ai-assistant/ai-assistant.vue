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

    <view class="tool-row">
      <text class="op" @click="openMemories">我的记忆</text>
      <text class="op" @click="clearChat">清空对话</text>
    </view>

    <view class="input-bar">
      <input class="ipt" v-model="input" placeholder="问问经营数据…（需在线）" confirm-type="send" @confirm="send()" />
      <button class="btn-send" :disabled="thinking || !input.trim()" @click="send()">{{ thinking ? '…' : '发送' }}</button>
    </view>

    <!-- 记忆管理弹层（查看/删除/清空） -->
    <view v-if="showMemories" class="mask" @click="showMemories = false">
      <view class="sheet trace-sheet" @click.stop>
        <view class="sheet-title">我的记忆（共 {{ memories.length }} 条）</view>
        <view class="form-item count-hint">跟助手说「记住：…」就能记下重要事项；说「忘记…」可遗忘</view>
        <scroll-view scroll-y class="trace-list">
          <view v-if="memories.length === 0" class="empty">还没有记忆</view>
          <view v-for="(m, i) in memories" :key="m.id" class="t-row">
            <view class="t-body">
              <text class="t-name">{{ m.content }}</text>
              <text class="t-date">{{ m.created_at.slice(0, 10) }}</text>
            </view>
            <text class="op del-op" @click="forgetMemory(m.id)">忘记</text>
          </view>
        </scroll-view>
        <view class="btn-row">
          <button v-if="memories.length" class="btn-ghost" @click="clearMemories">清空记忆</button>
          <button class="btn-save" @click="showMemories = false">关闭</button>
        </view>
      </view>
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
const showMemories = ref(false);
const memories = ref<Array<{ id: string; content: string; created_at: string }>>([]);

const WELCOME = '你好，我是 AI 助手。可以问我经营数据，比如：今天卖了多少？哪个店欠款多？哪些货该补了？也可以说「记住：…」让我帮你记下重要事项，或问功能怎么用。';

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
async function loadServerHistory() {
  try {
    const d = await request<{ messages: Msg[] }>('/ai/chat/history', 'GET');
    const msgs = (d?.messages || []).filter((m) => m.role === 'user' || m.role === 'assistant');
    if (msgs.length) {
      messages.value = msgs;
      saveHistory();
      scrollBottom();
    }
  } catch (_) {}
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

onLoad(() => {
  loadHistory();
  scrollBottom();
  uni.setNavigationBarTitle({ title: 'AI 助手' });
  loadServerHistory();
});

async function clearChat() {
  try {
    await request('/ai/chat/history', 'DELETE');
  } catch (_) {}
  messages.value = [{ role: 'assistant', content: WELCOME }];
  saveHistory();
}

async function openMemories() {
  try {
    const d = await request<{ memories: Array<{ id: string; content: string; created_at: string }> }>('/ai/memories', 'GET');
    memories.value = d?.memories || [];
    showMemories.value = true;
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '加载记忆失败', icon: 'none' });
  }
}
async function forgetMemory(id: string) {
  try {
    await request(`/ai/memories/${id}`, 'DELETE');
    uni.showToast({ title: '已忘记', icon: 'success' });
    memories.value = memories.value.filter((m) => m.id !== id);
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '操作失败', icon: 'none' });
  }
}
async function clearMemories() {
  try {
    await request('/ai/memories', 'DELETE');
    uni.showToast({ title: '已清空记忆', icon: 'success' });
    memories.value = [];
  } catch (e) {
    uni.showToast({ title: (e as Error).message || '操作失败', icon: 'none' });
  }
}

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
.tool-row { display: flex; justify-content: flex-end; gap: 32rpx; padding: 4rpx 24rpx 8rpx; box-sizing: border-box; }
.tool-row .op { font-size: 26rpx; color: var(--text-sub); }
.count-hint { font-size: 24rpx; color: var(--text-sub); }
.del-op { color: #f56c6c; }
.btn-row { display: flex; gap: 20rpx; margin-top: 20rpx; }
.btn-ghost { flex: 1; background: var(--input-bg); color: var(--text-main); border-radius: 12rpx; font-size: 28rpx; }
.btn-row .btn-save { flex: 1; }
.quick-bar { white-space: nowrap; padding: 8rpx 16rpx; box-sizing: border-box; }
.chip { display: inline-block; padding: 12rpx 24rpx; margin-right: 16rpx; background: var(--card-bg); border-radius: 28rpx; font-size: 26rpx; color: var(--text-sub); border: 1rpx solid var(--divider); }
.input-bar { display: flex; align-items: center; gap: 16rpx; padding: 20rpx 24rpx calc(20rpx + env(safe-area-inset-bottom)); box-sizing: border-box; }
.ipt { flex: 1; background: var(--input-bg); border-radius: 34rpx; padding: 14rpx 26rpx; font-size: 28rpx; }
.btn-send { background: var(--primary); color: #fff; border-radius: 34rpx; font-size: 28rpx; padding: 0 40rpx; margin: 0; }
.btn-send[disabled] { opacity: 0.5; }
</style>