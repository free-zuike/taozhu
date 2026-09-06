/** AI 拍照识别（智谱免费视觉模型 glm-4v-flash）：图片 → 商品明细草稿 */

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

/** AI 配置（后台可设置，OpenAI 兼容） */
export interface AiConfig {
  apiKey: string;
  baseUrl: string;
  model: string;
}

export const DEFAULT_AI_CONFIG = {
  baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
  model: 'glm-4v-flash',
};

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