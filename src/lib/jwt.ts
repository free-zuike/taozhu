/** HS256 JWT（Web Crypto 实现，零依赖） */

const enc = new TextEncoder();

function base64url(bytes: Uint8Array): string {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64urlDecode(s: string): Uint8Array {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/');
  const pad = b64.length % 4 === 0 ? '' : '='.repeat(4 - (b64.length % 4));
  const bin = atob(b64 + pad);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
}

export interface JwtPayload {
  sub: string;
  username: string;
  role: 'admin' | 'staff';
  /** access=访问令牌（短效）；refresh=刷新令牌（长效，仅 /auth/refresh 使用） */
  typ?: 'access' | 'refresh';
  iat: number;
  exp: number;
}

/** 签发 token（access 默认 24h；refresh 传 typ='refresh' 30 天；兼容旧调用默认 7 天单 token）。
 *  iatSec 可选：外部指定签发时刻（/auth/refresh 需将 iat 落库 refresh_iat 供防重放比对）。 */
export async function signToken(
  secret: string,
  payload: Omit<JwtPayload, 'iat' | 'exp' | 'typ'> & { typ?: 'access' | 'refresh' },
  ttlSec = payload.typ === 'refresh' ? 30 * 24 * 3600 : 24 * 3600,
  iatSec?: number,
): Promise<string> {
  const now = iatSec ?? Math.floor(Date.now() / 1000);
  const header = base64url(enc.encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' })));
  const body = base64url(enc.encode(JSON.stringify({ ...payload, iat: now, exp: now + ttlSec })));
  const key = await hmacKey(secret);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(`${header}.${body}`)));
  return `${header}.${body}.${base64url(sig)}`;
}

/** 校验并解析 token；无效/过期返回 null */
export async function verifyToken(secret: string, token: string): Promise<JwtPayload | null> {
  const r = await verifyTokenFull(secret, token);
  return r.ok ? r.payload : null;
}

/** 校验并区分失败原因：{ok:true,payload} 有效；{ok:false,expired:true} 签名有效但已过期（前端据此
 *  触发静默刷新）；{ok:false,expired:false} 签名无效/格式错误。 */
export async function verifyTokenFull(
  secret: string,
  token: string,
): Promise<{ ok: true; payload: JwtPayload } | { ok: false; expired: boolean }> {
  const parts = token.split('.');
  if (parts.length !== 3) return { ok: false, expired: false };
  const [header, body, sig] = parts;
  try {
    const key = await hmacKey(secret);
    const valid = await crypto.subtle.verify('HMAC', key, base64urlDecode(sig), enc.encode(`${header}.${body}`));
    if (!valid) return { ok: false, expired: false };
    const payload = JSON.parse(base64urlDecode(body).reduce((acc, b) => acc + String.fromCharCode(b), '')) as JwtPayload;
    if (payload.exp * 1000 < Date.now()) return { ok: false, expired: true };
    return { ok: true, payload };
  } catch {
    return { ok: false, expired: false };
  }
}