/** AI 拍照识别 + 文本/语音记账（分能力模型）：图片/文字/语音 → 商品明细草稿 */
import { randomId } from '../lib/password';

export interface DraftItem {
  name: string;
  unit: string;
  quantity: number;
  price: number;
}

/** 提示词：要求输出严格 JSON 明细（名称/单位/数量/单价） */
export function buildAiPrompt(purpose: 'purchase' | 'sale'): string {
  const priceLabel = purpose === 'purchase' ? '进货单价' : '出货单价';
  return `请识别这张图中的商品清单（如小票、价签、进货单或白条）。输出严格 JSON，不要 Markdown 代码块，不要额外文字，结构如下：
{"items":[{"name":"商品名称","unit":"单位（斤/公斤/件/包/箱/袋，若图上有单位就照抄）","quantity":数字,"price":数字（${priceLabel}，元）}]}
要求：1) 每项一行，数量只填数字（不包含单位）；2) 看不清的字段填 0；3) 若图片不是清单，输出 {"items":[]}。`;
}

/** 文本记账提示词：一句话/一段描述 → 商品明细 JSON（参考实现对账思维对齐） */
export function buildTextPrompt(purpose: 'purchase' | 'sale'): string {
  const verb = purpose === 'purchase' ? '进货' : '出货';
  return `你是${verb}记账助手。请从下面这段描述中提取商品清单。输出严格 JSON，不要 Markdown 代码块，不要额外文字，结构如下：
{"items":[{"name":"商品名称","unit":"单位（斤/公斤/件/包/箱/袋，缺省留空）","quantity":数字,"price":数字（${verb}单价，元）}]}
要求：1) 每项一行，数量只填数字（不包含单位）；2) 没提到的字段填 0 或空字符串；3) 数量/价格是"50斤3元一斤"这种说法时，quantity=50、price=3；4) 多笔用逗号或换行分开；5) 若描述不是商品清单，输出 {"items":[]}。`;
}

/**
 * 容错解析 LLM 输出 → DraftItem[]。
 * 处理：Markdown 代码块、顶层数组/对象包装、中英文字段名、数量带单位文本。
 */
export function normalizeDrafts(raw: string): DraftItem[] {
  if (!raw) return [];
  let text = raw.trim();
  // 去掉 markdown 代码块围栏
  text = text.replace(/```(?:json)?/gi, '').trim();
  // 提取最外层 {...} 或 [...]（JSON.parse 容错前先尝试干净解析）
  let parsed: unknown = null;
  for (const guess of [text, extractBalanced(text)]) {
    if (!guess) continue;
    try {
      parsed = JSON.parse(guess);
      break;
    } catch {
      /* try next */
    }
  }
  const list = unwrapItems(parsed);
  return list
    .map(normalizeOne)
    .filter((d): d is DraftItem => d.name.trim().length > 0);
}

function extractBalanced(s: string): string | null {
  const start = Math.max(s.indexOf('{'), s.indexOf('['));
  if (start < 0) return null;
  const open = s[start];
  const close = open === '{' ? '}' : ']';
  let depth = 0;
  let inStr = false;
  for (let i = start; i < s.length; i++) {
    const ch = s[i];
    if (ch === '"') inStr = !inStr;
    if (inStr) continue;
    if (ch === open) depth++;
    else if (ch === close) {
      depth--;
      if (depth === 0) return s.slice(start, i + 1);
    }
  }
  return null;
}

function unwrapItems(input: unknown): Array<Record<string, unknown>> {
  if (Array.isArray(input)) return input as Array<Record<string, unknown>>;
  if (input && typeof input === 'object') {
    const obj = input as Record<string, unknown>;
    for (const key of ['items', 'data', 'results', 'rows', '商品', '商品清单', 'list']) {
      if (key in obj) {
        const v = obj[key];
        if (Array.isArray(v)) return v as Array<Record<string, unknown>>;
      }
    }
    // 单对象也可能是单条（直接含 name）→ 包装成数组
    if ('name' in obj || '名称' in obj) return [obj];
  }
  return [];
}

function pick(obj: Record<string, unknown>, keys: string[]): string {
  for (const k of keys) {
    const v = obj[k];
    if (v !== undefined && v !== null) return String(v);
  }
  return '';
}

function toNumber(v: unknown): number {
  if (typeof v === 'number') return Number.isFinite(v) ? v : 0;
  if (typeof v === 'string') {
    const m = v.match(/-?\d+(\.\d+)?/);
    return m ? Number(m[0]) : 0;
  }
  return 0;
}

function normalizeOne(obj: Record<string, unknown>): DraftItem {
  return {
    name: pick(obj, ['name', '名称', '商品名', '商品', 'item']),
    unit: pick(obj, ['unit', '单位', 'uom']),
    quantity: toNumber(pick(obj, ['quantity', '数量', 'qty', 'count', 'amount'])),
    price: toNumber(pick(obj, ['price', '单价', 'unit_price', '价格', 'amount_price', '进货价', '出货价'])),
  };
}

/** Uint8Array → base64（分块避免大文件 btoa 栈溢出） */
export function bytesToBase64(bytes: Uint8Array): string {
  let bin = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    bin += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(bin);
}

/** AI 配置（后台可设置，OpenAI 兼容；分能力模型，默认智谱免费模型） */
export interface AiConfig {
  apiKey: string;
  baseUrl: string;
  model: string;        // 视觉模型（拍照）
  textModel: string;    // 文本模型（一句话记账）
  audioModel: string;   // 语音转文字模型（语音记账）
}

export const DEFAULT_AI_CONFIG = {
  baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
  model: 'glm-4v-flash',
};
export const DEFAULT_TEXT_MODEL = 'glm-4-flash';
export const DEFAULT_AUDIO_MODEL = 'glm-4-voice';

/** 调用 OpenAI 兼容视觉模型做识别；未配置 key 抛错带提示 */
export async function parsePhoto(
  config: AiConfig,
  mime: string,
  imageBytes: Uint8Array,
  purpose: 'purchase' | 'sale',
): Promise<DraftItem[]> {
  if (!config.apiKey.trim()) {
    throw new Error('AI 拍照识别未启用：请老板在「系统设置」填写 API Key');
  }
  const base64 = bytesToBase64(imageBytes);
  const baseUrl = config.baseUrl.replace(/\/+$/, '');
  const endpoint = baseUrl.endsWith('/chat/completions') ? baseUrl : `${baseUrl}/chat/completions`;
  const resp = await fetch(endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${config.apiKey.trim()}` },
    body: JSON.stringify({
      model: config.model,
      temperature: 0.1,
      messages: [
        {
          role: 'user',
          content: [
            { type: 'image_url', image_url: { url: `data:${mime || 'image/jpeg'};base64,${base64}` } },
            { type: 'text', text: buildAiPrompt(purpose) },
          ],
        },
      ],
    }),
  });
  if (!resp.ok) {
    const bodyText = await resp.text().catch(() => '');
    throw new Error(`AI 识别接口错误 HTTP ${resp.status}: ${bodyText.slice(0, 200)}`);
  }
  const data = (await resp.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  const content = data.choices?.[0]?.message?.content ?? '';
  return normalizeDrafts(content);
}

/** 文本记账：一句话/一段文字 → 商品明细（用文本模型） */
export async function parseText(
  config: AiConfig,
  text: string,
  purpose: 'purchase' | 'sale',
): Promise<DraftItem[]> {
  if (!config.apiKey.trim()) {
    throw new Error('AI 记账未启用：请老板在「系统设置」填写 API Key');
  }
  const trimmed = text.trim();
  if (!trimmed) return [];
  const baseUrl = config.baseUrl.replace(/\/+$/, '');
  const endpoint = baseUrl.endsWith('/chat/completions') ? baseUrl : `${baseUrl}/chat/completions`;
  const resp = await fetch(endpoint, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${config.apiKey.trim()}` },
    body: JSON.stringify({
      model: config.textModel || DEFAULT_TEXT_MODEL,
      temperature: 0.1,
      messages: [
        { role: 'user', content: `${buildTextPrompt(purpose)}\n\n${trimmed}` },
      ],
    }),
  });
  if (!resp.ok) {
    const bodyText = await resp.text().catch(() => '');
    throw new Error(`AI 记账接口错误 HTTP ${resp.status}: ${bodyText.slice(0, 200)}`);
  }
  const data = (await resp.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  const content = data.choices?.[0]?.message?.content ?? '';
  return normalizeDrafts(content);
}

/** 语音转文字（OpenAI 兼容 /audio/transcriptions；multipart file+model） */
export async function speechToText(
  config: AiConfig,
  mime: string,
  audioBytes: Uint8Array,
  filename: string,
): Promise<string> {
  if (!config.apiKey.trim()) {
    throw new Error('AI 语音记账未启用：请老板在「系统设置」填写 API Key');
  }
  const baseUrl = config.baseUrl.replace(/\/+$/, '');
  const endpoint = baseUrl.endsWith('/audio/transcriptions') ? baseUrl : `${baseUrl}/audio/transcriptions`;
  const form = new FormData();
  form.append('file', new Blob([audioBytes], { type: mime || 'audio/webm' }), filename || 'audio.webm');
  form.append('model', config.audioModel || DEFAULT_AUDIO_MODEL);
  const resp = await fetch(endpoint, {
    method: 'POST',
    headers: { Authorization: `Bearer ${config.apiKey.trim()}` },
    body: form,
  });
  if (!resp.ok) {
    const bodyText = await resp.text().catch(() => '');
    throw new Error(`语音转文字接口错误 HTTP ${resp.status}: ${bodyText.slice(0, 200)}`);
  }
  const data = (await resp.json()) as { text?: string };
  return (data.text ?? '').trim();
}

/** 语音记账（语音转文字 → 文本解析），供 /ai/parse-voice 使用 */
export async function parseVoice(
  config: AiConfig,
  mime: string,
  audioBytes: Uint8Array,
  filename: string,
  purpose: 'purchase' | 'sale',
): Promise<{ text: string; items: DraftItem[] }> {
  const text = await speechToText(config, mime, audioBytes, filename);
  if (!text) return { text: '', items: [] };
  const items = await parseText(config, text, purpose);
  return { text, items };
}

/** 生成随机幂等键（复用既有 randomId 语义，避免重复 import 冲突） */
export function aiNonce(): string {
  return randomId();
}