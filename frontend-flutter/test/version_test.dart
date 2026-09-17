import 'package:flutter_test/flutter_test.dart';
import 'package:taozhu_app/version.dart';

void main() {
  group('versionBelow（三位版本号比较，强制更新/检查更新用）', () {
    test('正常版本比较', () {
      expect(versionBelow('0.17.114', '0.17.115'), isTrue);
      expect(versionBelow('0.17.115', '0.17.114'), isFalse);
      expect(versionBelow('0.17.114', '0.17.114'), isFalse);
      expect(versionBelow('0.17.9', '0.17.10'), isTrue);
      expect(versionBelow('0.17.124', '1.0.0'), isTrue);
      expect(versionBelow('2.0.0', '1.99.999'), isFalse);
    });

    test('非法版本按相等处理（不误伤）', () {
      expect(versionBelow('0.17.114', 'abc'), isFalse);
      expect(versionBelow('abc', '0.17.114'), isFalse);
      expect(versionBelow('', '0.17.114'), isFalse);
      expect(versionBelow('0.17', '0.17.114'), isTrue); // 位数不足按 0 补
    });

    test('位数不齐按 0 补齐比较', () {
      expect(versionBelow('0.17', '0.17.1'), isTrue);
      expect(versionBelow('0.17.1', '0.17'), isFalse);
    });
  });
}