import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../theme.dart';

/// 日期选择输入框：点击弹主题化日期选择（三段式滚轮，对齐小程序原生 picker mode=date——
/// 批量直编页行日期/整单日期用，不占屏幕）
class DateField extends StatelessWidget {
  final TextEditingController controller;
  final String? label;
  final String? hint;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final IconData? icon;
  final Color? focusColor;
  /// 是否显示后缀日历小图标（窄弹窗（单商品编辑）里 16px 图标会显得像多余的小点，传 false 只留日期一行）
  final bool showSuffixIcon;
  /// 是否填充底色（弹窗/卡片内与其他无填充输入框并排时传 false 对齐视觉；
  /// 表单页传默认 true 与主题填充式输入框一致）
  final bool filled;
  /// 日期写入回调（TextField readOnly 不触发原生 onChanged，选完日期写入后手动回调；
  /// 批量直编顶栏用=改批量日期后页内行日期联动）
  final ValueChanged<String>? onChanged;

  const DateField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.firstDate,
    this.lastDate,
    this.icon,
    this.focusColor,
    this.showSuffixIcon = true,
    this.filled = true,
    this.onChanged,
  });

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final current = DateTime.tryParse(controller.text.trim());
    final DateTime? picked = await pickThemeDateCompact(context,
        initial: current ?? now,
        firstDate: firstDate ?? DateTime(now.year - 10),
        lastDate: lastDate ?? DateTime(now.year + 5, 12, 31));
    if (picked != null) {
      final v = '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
      controller.text = v;
      onChanged?.call(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    final accent = focusColor ?? c.primary;
    return TextField(
      controller: controller,
      readOnly: true,
      onTap: () => _pick(context),
      style: TextStyle(color: c.textMain),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon, size: 20, color: c.textSub),
        suffixIcon: showSuffixIcon
            ? const Icon(Icons.calendar_today_outlined, size: 16, color: Color(0xFF909399))
            : null,
        filled: filled,
        fillColor: filled ? c.field : null,
        border: filled
            ? OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)
            : null, // 弹窗内与周围无填充输入框一致（null → 主题默认 OutlineInputBorder）
        enabledBorder: filled
            ? OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)
            : null,
        focusedBorder: filled
            ? OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: accent, width: 1.4),
              )
            : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}


/// 紧凑滚轮日期选择弹层（对齐小程序原生 picker mode=date：年/月/日三段滚轮，
/// 高度紧凑不占屏幕——批量编辑页行日期/整单日期统一用）
Future<DateTime?> pickThemeDateCompact(
  BuildContext context, {
  required DateTime initial,
  DateTime? firstDate,
  DateTime? lastDate,
}) {
  final now = DateTime.now();
  return showModalBottomSheet<DateTime>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _CompactDateSheet(
      initial: initial,
      firstDate: firstDate ?? DateTime(now.year - 10),
      lastDate: lastDate ?? DateTime(now.year + 5, 12, 31),
    ),
  );
}

/// 三段滚轮（年 / 月 / 日）：CupertinoPicker 各一列，确定/取消——不占地方
class _CompactDateSheet extends StatefulWidget {
  const _CompactDateSheet({
    required this.initial,
    required this.firstDate,
    required this.lastDate,
  });

  final DateTime initial;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_CompactDateSheet> createState() => _CompactDateSheetState();
}

class _CompactDateSheetState extends State<_CompactDateSheet> {
  late int _year;
  late int _month;
  late int _day;
  late final FixedExtentScrollController _yearCtrl;
  late final FixedExtentScrollController _monthCtrl;
  late final FixedExtentScrollController _dayCtrl;

  List<int> get _years {
    final lo = widget.firstDate.year;
    final hi = widget.lastDate.year;
    return [for (var y = lo; y <= hi; y++) y];
  }

  int get _daysInMonth => DateTime(_year, _month + 1, 0).day;

  @override
  void initState() {
    super.initState();
    _year = widget.initial.year;
    _month = widget.initial.month;
    final maxDay = _daysInMonth;
    _day = widget.initial.day > maxDay ? maxDay : widget.initial.day;
    final yIdx = ((_year - _years.first).clamp(0, _years.length - 1)).toInt();
    _yearCtrl = FixedExtentScrollController(initialItem: yIdx);
    _monthCtrl = FixedExtentScrollController(initialItem: _month - 1);
    _dayCtrl = FixedExtentScrollController(initialItem: _day - 1);
  }

  @override
  void dispose() {
    _yearCtrl.dispose();
    _monthCtrl.dispose();
    _dayCtrl.dispose();
    super.dispose();
  }

  void _onYear(int i) {
    setState(() {
      _year = _years[i];
      _clampDay();
    });
  }

  void _onMonth(int i) {
    setState(() {
      _month = i + 1;
      _clampDay();
    });
  }

  void _clampDay() {
    if (_day > _daysInMonth) {
      _day = _daysInMonth;
      _dayCtrl.jumpToItem(_day - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 确定/取消
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, DateTime(_year, _month, _day)),
                  child: const Text('确定'),
                ),
              ],
            ),
            SizedBox(
              height: 180,
              child: Row(
                children: [
                  // 年
                  Expanded(
                    child: CupertinoPicker(
                      scrollController: _yearCtrl,
                      itemExtent: 36,
                      onSelectedItemChanged: _onYear,
                      children: [
                        for (final y in _years)
                          Center(child: Text('$y 年', style: TextStyle(fontSize: 16, color: c.textMain))),
                      ],
                    ),
                  ),
                  // 月
                  Expanded(
                    child: CupertinoPicker(
                      scrollController: _monthCtrl,
                      itemExtent: 36,
                      onSelectedItemChanged: _onMonth,
                      children: [
                        for (var m = 1; m <= 12; m++)
                          Center(child: Text('$m 月', style: TextStyle(fontSize: 16, color: c.textMain))),
                      ],
                    ),
                  ),
                  // 日
                  Expanded(
                    child: CupertinoPicker(
                      scrollController: _dayCtrl,
                      itemExtent: 36,
                      onSelectedItemChanged: (i) => setState(() => _day = i + 1),
                      children: [
                        for (var d = 1; d <= _daysInMonth; d++)
                          Center(child: Text('$d 日', style: TextStyle(fontSize: 16, color: c.textMain))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}