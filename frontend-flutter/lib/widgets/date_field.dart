import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../theme.dart';

/// 日期选择输入框：点击弹主题化日期选择（默认三段式大月历；compact=true 用紧凑滚轮，
/// 对齐小程序原生 picker mode=date——批量直编页行日期/整单日期用，不占屏幕）
class DateField extends StatelessWidget {
  final TextEditingController controller;
  final String? label;
  final String? hint;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final IconData? icon;
  final Color? focusColor;
  final bool compact;

  const DateField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.firstDate,
    this.lastDate,
    this.icon,
    this.focusColor,
    this.compact = false,
  });

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final current = DateTime.tryParse(controller.text.trim());
    final DateTime? picked = compact
        ? await pickThemeDateCompact(context,
            initial: current ?? now,
            firstDate: firstDate ?? DateTime(now.year - 10),
            lastDate: lastDate ?? DateTime(now.year + 5, 12, 31))
        : await pickThemeDate(context,
            initial: current ?? now,
            firstDate: firstDate ?? DateTime(now.year - 10),
            lastDate: lastDate ?? DateTime(now.year + 5, 12, 31));
    if (picked != null) {
      controller.text = '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
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
        suffixIcon: const Icon(Icons.calendar_today_outlined, size: 16, color: Color(0xFF909399)),
        filled: true,
        fillColor: c.field,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: accent, width: 1.4),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    );
  }
}

/// 弹出三段式 (年/月/日) 日期选择弹层，返回选中日期（表单页/行独立日期共用）
Future<DateTime?> pickThemeDate(
  BuildContext context, {
  required DateTime initial,
  DateTime? firstDate,
  DateTime? lastDate,
}) {
  final now = DateTime.now();
  return showModalBottomSheet<DateTime>(
    context: context,
    isScrollControlled: false,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _ThemeDateSheet(
      initial: initial,
      firstDate: firstDate ?? DateTime(now.year - 10),
      lastDate: lastDate ?? DateTime(now.year + 5, 12, 31),
    ),
  );
}

/// 自绘日期选择弹层：年/月/日三段式（对齐交易页顶部年月形态 + 补「日」）——
/// 年份左右切换可任意跨年（不再只能逐月滚到目标年）、日网格固定 31 格（跨月高度不变，
/// 当日实际天数不足时置灰禁用），解决月历"不能选年份+每月高度跳动"。
class _ThemeDateSheet extends StatefulWidget {
  const _ThemeDateSheet({required this.initial, required this.firstDate, required this.lastDate});

  final DateTime initial;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_ThemeDateSheet> createState() => _ThemeDateSheetState();
}

class _ThemeDateSheetState extends State<_ThemeDateSheet> {
  late int _year;
  late int _month;
  late int _selDay;

  static const _months = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12'];

  @override
  void initState() {
    super.initState();
    _year = widget.initial.year;
    _month = widget.initial.month;
    _selDay = widget.initial.day;
  }

  bool _outside(DateTime d) =>
      d.isBefore(widget.firstDate) || d.isAfter(widget.lastDate);

  int get _daysInMonth => DateTime(_year, _month + 1, 0).day;

  void _shiftYear(int delta) {
    final y = _year + delta;
    final lo = widget.firstDate.year;
    final hi = widget.lastDate.year;
    if (y < lo || y > hi) return;
    setState(() {
      _year = y;
      final maxDay = _daysInMonth;
      if (_selDay > maxDay) _selDay = maxDay;
    });
  }

  void _shiftMonth(int delta) {
    final dt = DateTime(_year, _month + delta, 1);
    if (dt.isBefore(DateTime(widget.firstDate.year, widget.firstDate.month, 1)) ||
        dt.isAfter(DateTime(widget.lastDate.year, widget.lastDate.month, 1))) {
      return;
    }
    setState(() {
      _year = dt.year;
      _month = dt.month;
      final maxDay = _daysInMonth;
      if (_selDay > maxDay) _selDay = maxDay;
    });
  }

  void _today() {
    final now = DateTime.now();
    if (_outside(now)) return;
    setState(() {
      _year = now.year;
      _month = now.month;
      _selDay = now.day;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    final today = DateTime.now();
    final daysInMonth = _daysInMonth;

    Widget dayCell(int d) {
      final blank = d > daysInMonth; // 本月不足 31 天的空白格：禁点、空文本（勿用 99 占位——DateTime 会 normalize 到跨月日期）
      final enabled = !blank && !_outside(DateTime(_year, _month, d));
      final selected = !blank && d == _selDay;
      final isT = !blank && _year == today.year && _month == today.month && d == today.day;
      // 固定宽高单元格（Wrap 内）——不能返回 Expanded（仅 Flex 可用，否则白屏异常）
      return AspectRatio(
        aspectRatio: 1,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Material(
            color: selected ? c.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: enabled ? () => setState(() => _selDay = d) : null,
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isT && !selected ? c.primary : Colors.transparent,
                    width: 1.2,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  blank ? '' : '$d',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: selected || isT ? FontWeight.w700 : FontWeight.normal,
                    color: selected
                        ? Colors.white
                        : (enabled ? c.textMain : c.textSub.withOpacity(0.35)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 年份行：左右切换（可任意跨年，解决月历不能选年份）
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _shiftYear(-1),
                ),
                Expanded(
                  child: Text(
                    '$_year 年',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => _shiftYear(1),
                ),
              ],
            ),
            // 月份行：左右切换
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _shiftMonth(-1),
                ),
                Expanded(
                  child: Text(
                    '$_month 月',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => _shiftMonth(1),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 日期网格：固定 31 格（每月高度一致，不足天数置灰禁用——不再随月跳动）
            Wrap(
              children: [
                for (var d = 1; d <= 31; d++)
                  SizedBox(
                    width: (MediaQuery.of(context).size.width - 32 - 16) / 7,
                    child: dayCell(d),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton.icon(
                  onPressed: _today,
                  icon: const Icon(Icons.today_outlined, size: 16),
                  label: const Text('今天'),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, DateTime(_year, _month, _selDay)),
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 紧凑滚轮日期选择弹层（对齐小程序原生 picker mode=date：年/月/日三段滚轮，
/// 高度紧凑不占屏幕——批量编辑页行日期用；普通表单页仍用 pickThemeDate 大月历）
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