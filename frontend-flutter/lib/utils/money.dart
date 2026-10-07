import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';
import '../api.dart';

/// 金额格式化：千分位 + 当前舍入设置位数（digits=2 分/1 角/0 元，默认 2）。
/// 先按配置（carry 进位临界）换算再格式化——与统计/欠款同口径，避免"计算 1 位、显示 2 位"不一致。
String fmtMoney(num v) {
  final s = roundMoney(v.toDouble(), Money.carry, Money.digits).toStringAsFixed(Money.digits);
  final neg = s.startsWith('-');
  final body = neg ? s.substring(1) : s;
  final parts = body.split('.');
  final intPart = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${neg ? '-' : ''}$intPart${parts.length > 1 ? '.${parts[1]}' : ''}';
}

/// 金额舍入口径（与服务器 /settings/rounding 一致）：carry 进位临界（0.5=四舍五入、
/// 0.6=5舍6入，可自定义 0~1）+ digits 精度（0=元/1=角/2=分，默认 2）。
/// 本地缓存（SharedPreferences），登录/收到 rounding 事件时刷新——店员无写权限，只读服务器值；
/// 首次使用（缓存未加载）用服务器默认四舍五入 2 位，行为与旧版一致。
/// 单价/进价等"输入值"显示**不**走 fmtMoney（不跟随舍入位数，不进位——2.58 不能显示成 2.6），
/// 用 fmtPrice 固定最多 2 位去尾零。
String fmtPrice(num v) {
  var t = v.toStringAsFixed(2);
  if (t.contains('.')) {
    t = t.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return t;
}

class Money {
  static double _carry = 0.5;
  static int _digits = 2;
  static bool _loaded = false;

  static double get carry => _carry;
  static int get digits => _digits;

  /// 从服务器拉取舍入配置并写入本地缓存；失败保留缓存值（离线用旧口径，联网同步后刷新）。
  static Future<void> refresh() async {
    try {
      final d = await Api.instance
          .get('/settings/rounding')
          .timeout(const Duration(seconds: 8));
      final carry = (d['carry'] as num?)?.toDouble() ?? _carry;
      final digits = (d['digits'] as num?)?.toInt() ?? _digits;
      if (carry > 0 && carry <= 1 && [0, 1, 2].contains(digits)) {
        _carry = carry;
        _digits = digits;
        try {
          final p = await SharedPreferences.getInstance();
          await p.setDouble('money_carry', carry);
          await p.setInt('money_digits', digits);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 本地优先：从 SharedPreferences 同步读缓存设置口径（启动/登录时调用，**不拉网络不跳动**）。
  /// 网络值仅由实时 WS 'rounding' 事件（其他端改设置）或 refresh() 显式核对后覆盖。
  static void loadFromPrefs(SharedPreferences p) {
    final c = p.getDouble('money_carry');
    final d = p.getInt('money_digits');
    if (c != null && c > 0 && c <= 1) _carry = c;
    if (d != null && [0, 1, 2].contains(d)) _digits = d;
    _loaded = true;
  }

  /// 初始化：读本地缓存 + 后台核对服务器（登录后调用一次；仅同步后覆盖，不阻塞展示）
  static Future<void> ensure() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final c = p.getDouble('money_carry');
      final d = p.getInt('money_digits');
      if (c != null && c > 0 && c <= 1) _carry = c;
      if (d != null && [0, 1, 2].contains(d)) _digits = d;
    } catch (_) {}
    refresh();
  }

  /// 按当前口径舍入金额（同步实现，供记单/收款/本地统计调用）
  static double round(double value) => roundMoney(value, _carry, _digits);

  /// 保存后同步写入本地口径（不依赖网络回读——网络抖动失败也会静默，导致退出重进读旧缓存）。
  /// 随后可再调 refresh() 与服务器核对；本地先更新保证"保存即生效、重进仍生效"。
  static Future<void> apply(double carry, int digits) async {
    if (!(carry > 0 && carry <= 1) || ![0, 1, 2].contains(digits)) return;
    _carry = carry;
    _digits = digits;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble('money_carry', carry);
      await p.setInt('money_digits', digits);
    } catch (_) {}
  }
}

/// 按配置舍入金额（进位临界 + 精度）。临界位判定用放大取整，避免浮点误差；负数对称处理。
double roundMoney(double value, double carry, int digits) {
  final f = math.pow(10, digits).toDouble();
  final sign = value < 0 ? -1 : 1;
  final abs = value.abs();
  final scaled = abs * f;
  final next = (scaled * 10 + 1e-9).floor() % 10;
  final threshold = (carry * 10).round();
  final base = (scaled + 1e-9).floor();
  final out = next >= threshold ? base + 1 : base;
  return (sign * out) / f;
}

/// 店铺结账抹零配置（对齐后端 RoundStage/RoundUnit）：
/// stage：none=不抹零（逐笔舍入）；txn=每张出货单合计向下抹零；day=每日出货合计向下抹零；total=全部一次向下抹零。
/// unit：向下取整档位（yuan=元/jiao=角/fen=分）。非法值回退默认，配置来自旧端/手工改库时兜底。
({String stage, String unit}) normalizeRoundConfig(Object? stage, Object? unit) {
  final s = '${stage ?? ''}';
  final u = '${unit ?? ''}';
  return (
    stage: (s == 'txn' || s == 'day' || s == 'total') ? s : 'none',
    unit: (u == 'jiao' || u == 'fen') ? u : 'yuan',
  );
}

/// 向下取整到指定档位（负数对称，与 roundMoney 同向）
double floorToUnit(double value, String unit) {
  final f = unit == 'yuan' ? 1.0 : unit == 'jiao' ? 10.0 : 100.0;
  final sign = value < 0 ? -1 : 1;
  return sign * (value.abs() * f + 1e-9).floorToDouble() / f;
}

/// 出货侧按店铺抹零配置的欠款口径（对齐后端 salesSideRounded）：
/// rows 为 sale_items 行（本地镜像，含 sale_id/happened_at/amount）。
/// 组内一律「每笔先 Money.round 再累加」，组合计再向下取整到 unit。
double salesSideRoundedLocal(List<Map<String, dynamic>> rows, String stage, String unit) {
  if (stage == 'none') {
    return rows.fold(0.0, (s, x) => s + Money.round((x['amount'] as num?)?.toDouble() ?? 0));
  }
  if (stage == 'total') {
    final total = rows.fold(0.0, (s, x) => s + Money.round((x['amount'] as num?)?.toDouble() ?? 0));
    return floorToUnit(total, unit);
  }
  final keyOf = stage == 'txn'
      ? (Map<String, dynamic> x) => 's:${x['sale_id'] ?? ''}'
      : (Map<String, dynamic> x) => 'd:${('${x['happened_at'] ?? ''}').length >= 10 ? '${x['happened_at']}'.substring(0, 10) : ''}';
  final groups = <String, double>{};
  for (final x in rows) {
    final k = keyOf(x);
    groups[k] = (groups[k] ?? 0) + Money.round((x['amount'] as num?)?.toDouble() ?? 0);
  }
  return groups.values.fold(0.0, (s, v) => s + floorToUnit(v, unit));
}

/// 本地全量出货行按各店抹零配置分别算出货侧欠款合计（对齐后端 salesAggByConfig）。
/// cfgById 由本地 clients 镜像构建（同步 payload 已含 round_stage/round_unit）；查不到配置的店按 none。
Map<String, double> salesSideRoundedByClient(
  List<Map<String, dynamic>> saleRows,
  Map<String, ({String stage, String unit})> cfgById,
) {
  final byClient = <String, List<Map<String, dynamic>>>{};
  for (final x in saleRows) {
    byClient.putIfAbsent('${x['client_id'] ?? ''}', () => []).add(x);
  }
  final out = <String, double>{};
  for (final e in byClient.entries) {
    final cfg = cfgById[e.key] ?? (stage: 'none', unit: 'yuan');
    out[e.key] = salesSideRoundedLocal(e.value, cfg.stage, cfg.unit);
  }
  return out;
}