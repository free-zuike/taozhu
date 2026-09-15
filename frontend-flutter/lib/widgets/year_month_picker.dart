import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../theme.dart';

/// 年月选择器（底部弹层 + 年/月双滚轮）：顶部月份切换弹层用——只需选年月，无需选日。
/// 参考实现用 CupertinoPicker 滚轮，避免 showDatePicker 强制先选日。
class YearMonthPicker extends StatefulWidget {
  final int year;
  final int month;
  const YearMonthPicker({super.key, required this.year, required this.month});

  @override
  State<YearMonthPicker> createState() => _YearMonthPickerState();
}

/// 弹层入口：返回选中的年月 DateTime（day=1）；取消返回 null
Future<DateTime?> showYearMonthPicker(
  BuildContext context, {
  required int year,
  required int month,
}) {
  return showModalBottomSheet<DateTime>(
    context: context,
    builder: (_) => YearMonthPicker(year: year, month: month),
  );
}

class _YearMonthPickerState extends State<YearMonthPicker> {
  late int _year;
  late int _month;
  late FixedExtentScrollController _yearCtrl;
  late FixedExtentScrollController _monthCtrl;

  /// 可选年份范围：最早 2015，最晚当前年（日期不能选未来）
  int get _minYear => 2015;
  int get _maxYear => DateTime.now().year;
  /// 当前年月（选到当前年时月份不能超过当前月）
  int get _nowMonth => DateTime.now().month;
  List<int> get _years => [for (var y = _minYear; y <= _maxYear; y++) y];

  /// 某年的可选月份：过去年份 1-12，当前年限到当前月
  List<int> _monthsOf(int year) =>
      [for (var m = 1; m <= (year == _maxYear ? _nowMonth : 12); m++) m];

  @override
  void initState() {
    super.initState();
    _year = widget.year;
    _month = widget.month;
    _yearCtrl = FixedExtentScrollController(initialItem: _years.indexOf(_year));
    _monthCtrl = FixedExtentScrollController(initialItem: _month - 1);
  }

  @override
  void dispose() {
    _yearCtrl.dispose();
    _monthCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头部：取消 / 标题 / 确定
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('取消', style: TextStyle(fontSize: 15, color: c.textSub)),
                ),
                const Spacer(),
                Text('选择月份', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.textMain)),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context, DateTime(_year, _month, 1)),
                  child: Text('确定', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.primary)),
                ),
              ],
            ),
          ),
          Container(height: 0.5, color: c.divider),
          // 年 / 月 双滚轮
          SizedBox(
            height: 180,
            child: Row(
              children: [
                Expanded(
                  child: CupertinoPicker(
                    scrollController: _yearCtrl,
                    itemExtent: 44,
                    onSelectedItemChanged: (i) {
                      final y = _years[i];
                      final months = _monthsOf(y);
                      // 切到当前年后，月滚轮不能超过当前月
                      final clamped = _month > months.last ? months.last : _month;
                      setState(() {
                        _year = y;
                        _month = clamped;
                      });
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _monthCtrl.jumpToItem(months.indexOf(clamped));
                      });
                    },
                    children: [
                      for (final y in _years)
                        Center(
                          child: Text('$y 年',
                              style: TextStyle(fontSize: 17, color: _year == y ? c.primary : c.textMain)),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: CupertinoPicker(
                    scrollController: _monthCtrl,
                    itemExtent: 44,
                    onSelectedItemChanged: (i) => setState(() => _month = _monthsOf(_year)[i]),
                    children: [
                      for (final m in _monthsOf(_year))
                        Center(
                          child: Text('$m 月',
                              style: TextStyle(fontSize: 17, color: _month == m ? c.primary : c.textMain)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => false;
}
