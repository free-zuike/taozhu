import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:taozhu_app/utils/pending_download.dart';

void main() {
  group('PendingDownload（中断下载进度记录）', () {
    test('toJson / fromJson 往返保留版本、文件、下载源与系统下载 id', () {
      const p = PendingDownload(
        ver: '0.17.505',
        fileName: 'taozhu-update-0.17.505.apk',
        url: 'https://github.com/free-zuike/taozhu/releases/download/taozhu-v0.17.505/taozhu-app-0.17.505.apk',
        androidId: 42,
      );
      final r = PendingDownload.fromJson(jsonEncode(p.toJson()));
      expect(r, isNotNull);
      expect(r!.ver, '0.17.505');
      expect(r.fileName, 'taozhu-update-0.17.505.apk');
      expect(r.url, p.url);
      expect(r.androidId, 42);
    });

    test('桌面端记录没有 androidId；脏数据一律不恢复', () {
      const p = PendingDownload(
        ver: '0.17.505',
        fileName: 'taozhu-windows-0.17.505.zip',
        url: 'https://github.com/free-zuike/taozhu',
      );
      final r = PendingDownload.fromJson(jsonEncode(p.toJson()));
      expect(r!.androidId, isNull);
      expect(PendingDownload.fromJson(null), isNull);
      expect(PendingDownload.fromJson(''), isNull);
      expect(PendingDownload.fromJson('not-json'), isNull);
      expect(PendingDownload.fromJson('{"ver":"0.17.505"}'), isNull);
      expect(PendingDownload.fromJson('{"fileName":"x"}'), isNull);
    });
  });
}
