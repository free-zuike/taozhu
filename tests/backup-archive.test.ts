/** 云备份 ZIP 归档包测试：buildBackupArchive（db.json + attachments/ 附件原始文件）与
 *  restoreBackupArchive（解包 → db.json 合并导入 + 附件写回存储端）；formatBackupName 兼容 .zip。 */
import { beforeEach, describe, expect, it } from 'vitest';
import { ensureSchema, resetSchemaState } from '../src/schema';
import { createFakeD1, fakeAssets, type FakeD1 } from './helpers/fake-d1';
import { buildBackupArchive, restoreBackupArchive, formatBackupName, BACKUP_PREFIX } from '../src/services/backup-core';

/** 内存 R2Bucket mock（对齐 attachments.test.ts） */
class FakeBucket {
  private store = new Map<string, { bytes: Uint8Array }>();
  async put(key: string, value: BodyInit) {
    const bytes = new Uint8Array(await new Response(value).arrayBuffer());
    this.store.set(key, { bytes });
    return {} as R2Object;
  }
  async get(key: string) {
    const o = this.store.get(key);
    if (!o) return null;
    return new R2TestObject(o.bytes) as unknown as R2ObjectBody;
  }
  async list(opts?: { prefix?: string }) {
    const prefix = opts?.prefix ?? '';
    return {
      objects: [...this.store.keys()].filter((k) => k.startsWith(prefix)).map((k) => ({
        key: k, size: this.store.get(k)!.bytes.byteLength, uploaded: new Date(),
      })),
      truncated: false,
    } as R2Objects;
  }
  async delete(key: string) {
    this.store.delete(key);
  }
}
class R2TestObject {
  constructor(private bytes: Uint8Array) {}
  get size() { return this.bytes.byteLength; }
  get uploaded() { return new Date(); }
  get httpEtag() { return 'test-etag'; }
  get body() {
    const bytes = this.bytes;
    return new ReadableStream<Uint8Array>({
      start(controller) { controller.enqueue(bytes); controller.close(); },
    });
  }
  writeHttpMetadata(headers: Headers) { headers.set('content-type', 'image/jpeg'); }
}

const store = new FakeBucket();
let db: FakeD1;

beforeEach(async () => {
  resetSchemaState();
  db = await createFakeD1();
  await ensureSchema(db as never);
});

describe('云备份 ZIP 归档包（附件以原始文件入包）', () => {
  it('buildBackupArchive 生成 backup-*.zip：含 db.json + attachments/ 附件原始字节', async () => {
    // 造数据 + 附件（引用行 + 存储端文件）
    await db.prepare('INSERT INTO clients (id, name) VALUES (?, ?)').bind('c-1', 'A店').run();
    const photo = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
    await store.put('taozhu/images/attachments/md5abc.jpg', photo);
    await db.prepare(
      "INSERT INTO attachment_refs (id, entity, entity_id, file_key, md5) VALUES ('sale:s-1:taozhu/images/attachments/md5abc.jpg', 'sale', 's-1', 'taozhu/images/attachments/md5abc.jpg', 'md5abc')",
    ).run();

    const r = await buildBackupArchive(db, store);
    expect(r.status).toBe('succeeded');
    expect(r.key).toMatch(/^taozhu\/backups\/backup-.*\.zip$/);
    expect(r.size).toBeGreaterThan(0);
    expect(r.tables.total).toBeGreaterThan(0);
    expect(r.attachments).toEqual({ total: 1, ok: 1, failed: 0 });

    // 解包校验：db.json 有数据、attachments/ 附件字节一致
    const obj = await store.get(r.key);
    expect(obj).not.toBeNull();
    const zipBytes = new Uint8Array(await new Response(obj!.body).arrayBuffer());
    const { ZipReader, BlobReader, TextWriter, Uint8ArrayWriter } = await import('@zip.js/zip.js');
    const reader = new ZipReader(new BlobReader(new Blob([zipBytes])));
    const entries = await reader.getEntries();
    const names = entries.map((e) => e.filename);
    expect(names).toContain('db.json');
    expect(names).toContain('meta.json');
    expect(names).toContain('attachments/taozhu/images/attachments/md5abc.jpg');
    let dbJson: string | null = null;
    let attBytes: Uint8Array | null = null;
    for (const e of entries) {
      if (e.filename === 'db.json') {
        dbJson = await (e as { getData(w: unknown): Promise<unknown> }).getData(new TextWriter()) as string;
      } else if (e.filename.startsWith('attachments/')) {
        attBytes = await (e as { getData(w: unknown): Promise<unknown> }).getData(new Uint8ArrayWriter()) as Uint8Array;
      }
    }
    expect(dbJson).toContain('A店');
    expect(attBytes).toEqual(photo);
    await reader.close();
  });

  it('restoreBackupArchive 解包：db.json 合并导入 + 附件写回存储端', async () => {
    await db.prepare('INSERT INTO clients (id, name) VALUES (?, ?)').bind('c-1', 'A店').run();
    const photo = new Uint8Array([9, 8, 7, 6]);
    await store.put('taozhu/images/attachments/md5xyz.jpg', photo);
    await db.prepare(
      "INSERT INTO attachment_refs (id, entity, entity_id, file_key, md5) VALUES ('sale:s-1:taozhu/images/attachments/md5xyz.jpg', 'sale', 's-1', 'taozhu/images/attachments/md5xyz.jpg', 'md5xyz')",
    ).run();
    const r = await buildBackupArchive(db, store);
    expect(r.status).toBe('succeeded');
    const zipBytes = new Uint8Array(await new Response((await store.get(r.key)!).body).arrayBuffer());

    // 模拟跨环境：清空存储端附件 → 从归档恢复（全新库）
    store.delete('taozhu/images/attachments/md5xyz.jpg');
    resetSchemaState(); // ensureSchema 有模块级已建短路，新库需先重置
    const db2 = await createFakeD1();
    await ensureSchema(db2 as never);
    const out = await restoreBackupArchive(db2, store, zipBytes);
    expect(out.ok).toBe(true);
    expect(out.ok).toBe(true);
    expect(out.total_inserted).toBeGreaterThan(0);
    expect(out.attachments).toBe(1);
    // 附件写回，字节一致
    const restored = await store.get('taozhu/images/attachments/md5xyz.jpg');
    expect(restored).not.toBeNull();
    const bytes = new Uint8Array(await new Response(restored!.body).arrayBuffer());
    expect(bytes).toEqual(photo);
    // 数据导入
    const clients = await db2.prepare("SELECT name FROM clients WHERE id = 'c-1'").all<{ name: string }>();
    expect(clients.results[0]?.name).toBe('A店');
  });

  it('formatBackupName 兼容 .zip / .json 后缀与旧格式', () => {
    expect(formatBackupName('backup-20261022-150505123.zip')).toBe('2026-10-22 15:05:05');
    expect(formatBackupName('backup-20261022-150505123.json')).toBe('2026-10-22 15:05:05');
    expect(formatBackupName('backup-2026-09-18.json')).toBe('2026-09-18');
    expect(formatBackupName('backup-2026-09-18')).toBe('2026-09-18');
    expect(formatBackupName('unknown-name')).toBe('unknown-name');
  });
});
