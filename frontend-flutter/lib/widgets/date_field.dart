import 'package:flutter/material.dart';
import '../theme.dart';

/// 日期选择输入框：点击弹自绘主题化月历（替代系统日历对话框，样式跟随陶朱主题、选择更直观）
class DateField extends StatelessWidget {
  final TextEditingController controller;
  final String? label;
  final String? hint;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final IconData? icon;
  final Color? focusColor;

  const DateField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.firstDate,
    this.lastDate,
    this.icon,
    this.focusColor,
  });

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final current = DateTime.tryParse(controller.text.trim());
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _ThemeDateSheet(
        initial: current ?? now,
        firstDate: firstDate ?? DateTime(now.year - 10),
        lastDate: lastDate ?? DateTime(now.year + 5, 12, 31),
      ),
    );
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

/// 自绘月历弹层：周一起始网格 + 年月切换 + 今天/取消/确定，跟随陶朱主题（暗色适配）
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

  static const _weekTitles = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  void initState() {
    super.initState();
    _year = widget.initial.year;
    _month = widget.initial.month;
    _selDay = widget.initial.day;
  }

  bool _outside(DateTime d) =>
      d.isBefore(widget.firstDate) || d.isAfter(widget.lastDate);

  void _shiftMonth(int delta) {
    final dt = DateTime(_year, _month + delta, 1);
    if (dt.isBefore(DateTime(widget.firstDate.year, widget.firstDate.month, 1)) ||
        dt.isAfter(DateTime(widget.lastDate.year, widget.lastDate.month, 1))) {
      return;
    }
    setState(() {
      _year = dt.year;
      _month = dt.month;
      final maxDay = DateTime(_year, _month + 1, 0).day;
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
    final daysInMonth = DateTime(_year, _month + 1, 0).day;
    // 周一起始：1 号是周几 → 前置空位数（DateTime.weekday: 1=周一 … 7=周日）
    final leading = DateTime(_year, _month, 1).weekday - 1;
    final today = DateTime.now();
    final isToday = (int d) =>
        _year == today.year && _month == today.month && d == today.day;
    final todayNum = today.day;

    Widget dayCell(int d, {required bool enabled}) {
      final selected = d == _selDay;
      final isT = isToday(d);
      return Expanded(
        child: AspectRatio(
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
                    '$d',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: selected || isT ? FontWeight.w700 : FontWeight.normal,
                      color: selected
                          ? Colors.white
                          : (enabled ? c.textMain : c.textSub.withOpacity(0.4)),
                    ),
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
            // 年月切换
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _shiftMonth(-1),
                ),
                Expanded(
                  child: Text(
                    '$_year 年 $_month 月',
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
            // 周标题
            Row(
              children: [
                for (final t in _weekTitles)
                  Expanded(
                    child: Center(
                      child: Text(t,
                          style: TextStyle(fontSize: 12, color: c.textSub)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // 日期网格（前置空位补齐）
            Row(children: [
              for (var i = 0; i < leading; i++) Expanded(child: const SizedBox()),
              for (var d = 1; d <= 7 - leading; d++)
                dayCell(d, enabled: !_outside(DateTime(_year, _month, d))),
            ]),
            for (var rowStart = 8 - leading; rowStart <= daysInMonth; rowStart += 7)
              Row(children: [
                for (var d = rowStart; d < rowStart + 7; d++)
                  d <= daysInMonth
                      ? dayCell(d, enabled: !_outside(DateTime(_year, _month, d)))
                      : const Expanded(child: SizedBox()),
              ]),
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