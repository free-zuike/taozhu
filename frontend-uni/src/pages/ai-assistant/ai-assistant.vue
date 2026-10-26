<template>
  <view class="page" :style="tv">
    <image v-if="patternSrc" class="bg-pattern" :src="patternSrc" mode="aspectFill" />
    <scroll-view scroll-y class="chat" :scroll-into-view="bottomAnchor" scroll-with-animation>
      <view v-for="(m, i) in messages" :key="i" :id="'m' + i"
        :class="['bubble-row', m.role === 'user' ? 'mine' : 'peer']">
        <view :class="['bubble', m.role === 'user' ? 'b-mine' : 'b-peer']">
          <rich-text v-if="m.role !== 'user'" :nodes="mdHtml(shownContent(m, i))"></rich-text>
          <text v-else>{{ m.content }}</text>
          <view v-if="m.role !== 'user' && m.order" class="order-card">
            <view class="oc-head">📋 {{ m.order.type === 'sale' ? '出货' : '进货' }}{{ m.order.client ? ' · ' + m.order.client : '' }} · 合计 ¥{{ m.order.total }}</view>
            <view v-for="(l, li) in (m.order.lines || []).slice(0, 3)" :key="li" class="oc-line">{{ l.name }} {{ l.quantity }}{{ l.unit }} × ¥{{ l.price }}</view>
            <view v-if="(m.order.lines || []).length > 3" class="oc-line">…</view>
            <view class="oc-done">合计 ¥{{ m.order.total }}（已在账本中）</view>
          </view>
          <view v-if="m.role !== 'user' && m.toolsJson" class="tl">
            <view v-for="(t, ti) in toolsOf(m)" :key="ti" class="tl-row">
              <text class="tl-ic">🛠</text>
              <text class="tl-name">{{ t.label || t.name }}</text>
              <text class="tl-res">{{ cut(t.result, 26) }}</text>
            </view>
          </view>
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
      <text class="op mic" @click="voiceAsk">🎤</text>
      <text class="op cam" @click="photoAsk">📷</text>
      <input class="ipt" v-model="input" placeholder="问问经营数据…（语音/拍小票也可以）" confirm-type="send" @confirm="send()" />
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
import { onLoad, onUnload } from '@dcloudio/uni-app';
import { useThemeVars } from '../../theme';
import { request, uploadAi } from '../../api';

const { tv, patternSrc } = useThemeVars();

const HIST_KEY = 'ai_assistant_history';
interface OrderLine { name?: string; unit?: string; quantity?: number; price?: number }
interface Msg {
  role: 'user' | 'assistant';
  content: string;
  sources?: string;
  toolsJson?: string;
  order?: { type?: string; client?: string; total?: number; lines?: OrderLine[] }
}
const messages = ref<Msg[]>([]);
const input = ref('');
const thinking = ref(false);
const bottomAnchor = ref('');
const quickQs = ['今天卖了多少？', '本月毛利多少？', '哪个店欠款最多？', '哪些货快卖完了？', '有什么快过期？', '怎么记一笔账？'];
const showMemories = ref(false);
const memories = ref<Array<{ id: string; content: string; created_at: string }>>([]);
// 打字机：最新一条助手回复逐字显示
const typingIdx = ref(-1);
const typingAt = ref(0);
let typingTimer: ReturnType<typeof setInterval> | null = null;

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

onUnload(() => {
  if (typingTimer) clearInterval(typingTimer);
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
    const d = await request<Record<string, unknown>>('/ai/chat', 'POST', {
      messages: messages.value.map((m) => ({ role: m.role, content: m.content })),
    });
    // 写操作（落单/记忆）待授权：弹层确认 → approve 后连同结果落库
    if (d?.need_approval) {
      thinking.value = false;
      const decision = await showApproval(d);
      if (!decision) return;
      try {
        const r = await request<Record<string, unknown>>('/ai/chat/approve', 'POST', {
          approval_id: d.approval_id,
          decision,
          messages: messages.value.map((m) => ({ role: m.role, content: m.content })),
        });
        thinking.value = false;
        applyReply(r);
        uni.showToast({ title: decision === 'always_allow' ? '已设为总是允许' : '已设为总是拒绝', icon: 'none' });
      } catch (e) {
        thinking.value = false;
        uni.showToast({ title: (e as Error).message || '操作失败', icon: 'none' });
      }
      return;
    }
    thinking.value = false;
    applyReply(d);
  } catch (e) {
    thinking.value = false;
    uni.showToast({ title: (e as Error).message || 'AI 助手请求失败', icon: 'none' });
  }
}

function applyReply(d: Record<string, unknown> | undefined) {
  const tools = ((d?.tools as Array<{ name?: string; label?: string; result?: string }>) || []);
  const sources = ((d?.sources as string[]) || []).join('、');
  const order = d?.order as Record<string, unknown> | undefined;
  const reply = (d?.reply as string || '').trim() || '（模型没有返回内容，请稍后再试）';
  messages.value.push({
    role: 'assistant',
    content: reply,
    ...(sources ? { sources } : {}),
    ...(tools.length ? { toolsJson: JSON.stringify(tools) } : {}),
    ...(order ? { order } : {}),
  });
  if (reply.length > 24 && (d?.reply as string || '').trim()) startTyping(messages.value.length - 1, reply);
  saveHistory();
  scrollBottom();
}

/** 打字机：逐字显示最新一条助手回复 */
function startTyping(idx: number, full: string) {
  if (typingTimer) clearInterval(typingTimer);
  typingIdx.value = idx;
  typingAt.value = 0;
  typingTimer = setInterval(() => {
    typingAt.value += 2;
    if (typingAt.value >= full.length) {
      if (typingTimer) clearInterval(typingTimer);
      typingTimer = null;
      typingIdx.value = -1;
    }
  }, 24);
}

function shownContent(m: Msg, i: number): string {
  if (i === typingIdx.value && typingAt.value < m.content.length) {
    return m.content.slice(0, typingAt.value);
  }
  return m.content;
}

function cut(s: string | undefined, n: number) {
  s = s || '';
  return s.length > n ? s.slice(0, n) + '…' : s;
}

interface ToolRow { label?: string; name?: string; result?: string }
function toolsOf(m: Msg): ToolRow[] {
  try {
    return (JSON.parse(m.toolsJson || '[]') as ToolRow[]) || [];
  } catch (_) {
    return [];
  }
}

/** 轻量 Markdown → HTML（rich-text 渲染）：标题/列表/加粗/代码/表格行 */
function mdHtml(s: string): string {
  const esc = (x: string) => x.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const inline = (x: string) => esc(x)
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*([^*]+)\*/g, '<em>$1</em>');
  const lines = s.split('\n');
  const html: string[] = [];
  for (const raw of lines) {
    const t = raw.trim();
    if (!t) { html.push('<br/>'); continue; }
    const head = /^(#{1,3})\s+(.*)$/.exec(t);
    if (head) {
      const size = head[1].length === 1 ? '18px' : head[1].length === 2 ? '16px' : '15px';
      html.push(`<div style="font-size:${size};font-weight:600;margin:4rpx 0">${inline(head[2])}</div>`);
      continue;
    }
    const bullet = /^[-*•]\s+(.*)$/.exec(t);
    if (bullet) {
      html.push(`<div style="padding-left:16rpx">• ${inline(bullet[1])}</div>`);
      continue;
    }
    const num = /^(\d+)[.、]\s+(.*)$/.exec(t);
    if (num) {
      html.push(`<div style="padding-left:16rpx">${num[1]}. ${inline(num[2])}</div>`);
      continue;
    }
    if (t.startsWith('|') && t.endsWith('|') && t.split('|').length > 2) {
      const cells = t.split('|').filter((c) => c.trim()).map((c) => c.trim()).join('　　');
      html.push(`<div style="font-size:13px">${inline(cells)}</div>`);
      continue;
    }
    html.push(`<div>${inline(t)}</div>`);
  }
  return html.join('');
}

/** 语音提问：录音 → /ai/stt 转文字 → 填入输入框发送 */
function voiceAsk() {
  if (thinking.value) return;
  uni.authorize({
    scope: 'scope.record',
    success: () => {
      const rec = uni.getRecorderManager();
      let stopped = false;
      rec.onStart(() => {
        uni.showModal({
          title: '语音提问',
          content: '正在录音，说完点「结束」',
          showCancel: false,
          confirmText: '结束',
          success: () => {
            stopped = true;
            rec.stop();
          },
        });
      });
      rec.onStop(async (res) => {
        const fp = (res as { tempFilePath?: string }).tempFilePath;
        if (!fp) {
          uni.showToast({ title: '录音失败', icon: 'none' });
          return;
        }
        uni.showToast({ title: '识别中…', icon: 'none' });
        try {
          const d = await uploadAi<{ text?: string }>('/ai/stt', 'audio', fp);
          const text = (d?.text || '').trim();
          if (!text) {
            uni.showToast({ title: '没有听清，请再说一遍', icon: 'none' });
            return;
          }
          input.value = text;
          send();
        } catch (e) {
          uni.showToast({ title: (e as Error).message || '转写失败', icon: 'none' });
        }
      });
      rec.start({ format: 'mp3', duration: 60000 });
    },
    fail: () => uni.showToast({ title: '需要麦克风权限才能语音提问', icon: 'none' }),
  });
}

/** 拍小票识别记账：拍照/相册 → /ai/parse-photo → 生成记账消息发送（走落单授权门） */
function photoAsk() {
  if (thinking.value) return;
  uni.chooseImage({
    sourceType: ['camera', 'album'],
    success: async (r) => {
      const up = (r as { tempFiles?: Array<{ path: string }> }).tempFiles?.[0];
      if (!up) return;
      uni.showToast({ title: '识别中…', icon: 'none' });
      try {
        const d = await uploadAi<{ items?: Array<Record<string, any>>; client?: string; date?: string }>('/ai/parse-photo?purpose=purchase', 'photo', up.path);
        const items = d?.items || [];
        if (!items.length) {
          uni.showToast({ title: '没识别到商品，请拍清楚些（可拍进货小票）', icon: 'none' });
          return;
        }
        const summary = items.map((i) => `${i.name || ''} ${i.quantity ?? ''}${i.unit || ''}@¥${i.price ?? ''}`).join('、');
        const msg = `识别到进货小票：${summary}。${d?.client ? `购货单位 ${d.client}。` : ''}${d?.date ? `日期 ${d.date}。` : ''}请帮我记一笔进货`;
        send(msg);
      } catch (e) {
        uni.showToast({ title: (e as Error).message || '识别失败', icon: 'none' });
      }
    },
  });
}

/** 写工具授权弹层：允许/拒绝/总是允许/总是拒绝（对齐参考 App 授权门） */
function showApproval(d: Record<string, unknown>): Promise<string | null> {
  const tool = (d.tool as Record<string, unknown>) || {};
  return new Promise((resolve) => {
    uni.showModal({
      title: `允许「${tool.label || 'AI 操作'}」？`,
      content: `${d.preview || ''}${tool.description ? '\n' + tool.description : ''}`,
      confirmText: '允许',
      cancelText: '拒绝',
      success: (r) => {
        if (r.confirm) return resolve('allow');
        uni.showActionSheet({
          itemList: ['总是拒绝', '总是允许', '取消'],
          success: (a) => {
            if (a.tapIndex === 0) return resolve('always_deny');
            if (a.tapIndex === 1) return resolve('always_allow');
            resolve(null);
          },
          fail: () => resolve(null),
        });
      },
      fail: () => resolve(null),
    });
  });
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
.tl { margin-top: 12rpx; padding: 10rpx 14rpx; background: var(--input-bg); border-radius: 14rpx; border: 1rpx solid var(--divider); }
.tl-row { display: flex; align-items: center; gap: 8rpx; padding: 4rpx 0; }
.tl-ic { font-size: 22rpx; }
.tl-name { font-size: 22rpx; font-weight: 600; color: var(--text-main); flex-shrink: 0; }
.tl-res { flex: 1; font-size: 22rpx; color: var(--text-sub); overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
.mic, .cam { font-size: 32rpx; }
.order-card { margin-top: 12rpx; padding: 14rpx 16rpx; background: var(--input-bg); border-radius: 14rpx; border: 1rpx solid var(--divider); }
.oc-head { font-size: 24rpx; font-weight: 600; color: var(--text-main); }
.oc-line { margin-top: 6rpx; font-size: 22rpx; color: var(--text-sub); }
.oc-done { margin-top: 8rpx; font-size: 22rpx; color: var(--primary); }
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