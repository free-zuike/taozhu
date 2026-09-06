/** 认证核心单元测试：JWT + 密码哈希 */
import { describe, expect, it } from 'vitest';
import { signToken, verifyToken } from '../src/lib/jwt';
import { hashPassword, verifyPassword } from '../src/lib/password';

const SECRET = 'test-secret-123';

describe('jwt', () => {
  it('sign → verify 往返成功', async () => {
    const token = await signToken(SECRET, { sub: 'u1', username: 'boss', role: 'admin' });
    const payload = await verifyToken(SECRET, token);
    expect(payload).not.toBeNull();
    expect(payload!.sub).toBe('u1');
    expect(payload!.username).toBe('boss');
    expect(payload!.role).toBe('admin');
  });

  it('过期 token 拒绝', async () => {
    const token = await signToken(SECRET, { sub: 'u1', username: 'b', role: 'staff' }, -10);
    expect(await verifyToken(SECRET, token)).toBeNull();
  });

  it('篡改签名拒绝', async () => {
    const token = await signToken(SECRET, { sub: 'u1', username: 'b', role: 'staff' });
    const tampered = token.slice(0, -2) + (token.endsWith('ab') ? 'cd' : 'ab');
    expect(await verifyToken(SECRET, tampered)).toBeNull();
  });
});

describe('password', () => {
  it('hash → verify 正确密码通过，错误拒绝', async () => {
    const hash = await hashPassword('mima123456');
    expect(hash).toContain(':');
    expect(await verifyPassword('mima123456', hash)).toBe(true);
    expect(await verifyPassword('wrong-pass', hash)).toBe(false);
  });

  it('不同 salt 生成不同 hash', async () => {
    const a = await hashPassword('same');
    const b = await hashPassword('same');
    expect(a).not.toBe(b);
  });
});