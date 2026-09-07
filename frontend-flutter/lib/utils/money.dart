/// 金额格式化：千分位 + 两位小数（如 12345.6 → 12,345.60）
String fmtMoney(num v) {
  final s = v.toStringAsFixed(2);
  final neg = s.startsWith('-');
  final body = neg ? s.substring(1) : s;
  final parts = body.split('.');
  final intPart = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${neg ? '-' : ''}$intPart.${parts[1]}';
}
