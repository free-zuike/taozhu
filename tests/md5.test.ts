/** MD5（公共图片去重基础）标准向量测试 */
import { describe, expect, it } from 'vitest';
import { md5 } from '../src/lib/md5';
import { imageKey } from '../src/lib/image-key';

const enc = (s: string) => new TextEncoder().encode(s);

describe('md5（RFC 1321 标准向量）', () => {
  it('空串', () => {
    expect(md5(enc(''))).toBe('d41d8cd98f00b204e9800998ecf8427e');
  });

  it('abc', () => {
    expect(md5(enc('abc'))).toBe('900150983cd24fb0d6963f7d28e17f72');
  });

  it('message digest', () => {
    expect(md5(enc('message digest'))).toBe('f96b697d7cb7938d525a2f31aaf161d0');
  });

  it('abcdefghijklmnopqrstuvwxyz', () => {
    expect(md5(enc('abcdefghijklmnopqrstuvwxyz'))).toBe('c3fcd3d76192e4007dfb496cca67e13b');
  });
});

describe('imageKey 公共命名空间', () => {
  it('key = taozhu/images/{type}/{segments}/{md5}.jpg；同内容同 key（去重）', () => {
    const bytes = new Uint8Array([0xff, 0xd8, 0xff, 0x00]);
    const k1 = imageKey('attachments', ['sale', 's1'], bytes);
    const k2 = imageKey('attachments', ['sale', 's1'], bytes);
    const k3 = imageKey('avatar', ['u1'], bytes);
    expect(k1).toBe(k2);
    expect(k1.startsWith('taozhu/images/attachments/sale/s1/')).toBe(true);
    expect(k1.endsWith('.jpg')).toBe(true);
    expect(k3.startsWith('taozhu/images/avatar/u1/')).toBe(true);
    expect(k3).not.toBe(k1);
  });

  it('内容不同 → 不同 key', () => {
    const a = imageKey('attachments', ['sale', 's1'], new Uint8Array([1, 2, 3]));
    const b = imageKey('attachments', ['sale', 's1'], new Uint8Array([1, 2, 4]));
    expect(a).not.toBe(b);
  });
});