/** 密码哈希：PBKDF2-SHA256（Web Crypto，零依赖）。存格式：saltHex:hashHex */

const enc = new TextEncoder();

function toHex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function fromHex(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return bytes;
}

async function derive(password: string, salt: Uint8Array, iterations: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt, iterations },
    key,
    256,
  );
  return new Uint8Array(bits);
}

/** 生成哈希（salt 随机 16 字节，10 万次迭代） */
export async function hashPassword(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await derive(password, salt, 100_000);
  return `${toHex(salt)}:${toHex(hash)}`;
}

/** 校验密码 */
export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const [saltHex, hashHex] = stored.split(':');
  if (!saltHex || !hashHex) return false;
  const hash = await derive(password, fromHex(saltHex), 100_000);
  const expected = toHex(hash);
  if (expected.length !== hashHex.length) return false;
  // 常量时间比较
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ hashHex.charCodeAt(i);
  return diff === 0;
}

export function randomId(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** 订单/批次 id：{s|p}{毫秒}{随机}——与客户端录入（App `s${毫秒}${随机}`/小程序 `si${毫秒}${随机}`）同格式，
 *  内嵌创建时间毫秒，客户端按数字段即可还原批次创建序（服务端 randomId 纯 hex 无时间戳=批次乱序根因）。 */
export function orderIdWith(prefix: 's' | 'p'): string {
  return `${prefix}${Date.now()}${Math.floor(Math.random() * 0x7fffffff)}`;
}