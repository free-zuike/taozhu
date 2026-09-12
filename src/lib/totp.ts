/** TOTP 两步验证（RFC 6238）：HMAC-SHA1 + 6 位动态码，30 秒窗口，允许 ±1 个窗口防时钟漂移。零依赖（Web Crypto）。 */

const enc = new TextEncoder();
const B32_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/** 生成随机 Base32 密钥（默认 20 字符 = 100 位熵，Google Authenticator 兼容） */
export function randomSecret(length = 20): string {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  return [...bytes].map((b) => B32_ALPHABET[b & 31]).join('');
}

export function base32Decode(s: string): Uint8Array {
  const clean = s.toUpperCase().replace(/[^A-Z2-7]/g, '');
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of clean) {
    value = (value << 5) | B32_ALPHABET.indexOf(ch);
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return new Uint8Array(out);
}

async function hmacSha1(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const k = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, data));
}

/** 生成某时刻的 6 位验证码 */
export async function totpCode(secretB32: string, at = Date.now()): Promise<string> {
  const counter = Math.floor(at / 1000 / 30);
  const buf = new Uint8Array(8);
  let c = counter;
  for (let i = 7; i >= 0; i--) {
    buf[i] = c & 0xff;
    c = Math.floor(c / 256);
  }
  const hmac = await hmacSha1(base32Decode(secretB32), buf);
  const offset = hmac[hmac.length - 1] & 0x0f;
  const bin = ((hmac[offset] & 0x7f) << 24) | (hmac[offset + 1] << 16) | (hmac[offset + 2] << 8) | hmac[offset + 3];
  return String(bin % 1_000_000).padStart(6, '0');
}

/** 校验验证码（±1 窗口） */
export async function verifyTotp(secretB32: string, code: string): Promise<boolean> {
  if (!secretB32 || !/^\d{6}$/.test(code)) return false;
  const now = Date.now();
  for (const offset of [0, -1, 1]) {
    if ((await totpCode(secretB32, now + offset * 30_000)) === code) return true;
  }
  return false;
}
