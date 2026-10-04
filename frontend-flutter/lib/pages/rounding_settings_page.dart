import 'package:flutter/material.dart';
import '../api.dart';
import '../utils/money.dart';
import 'router.dart';

/// 金额舍入设置（仅老板）：进位临界（四舍五入/5舍6入/自定义 0~1）+ 精度（元/角/分）。
/// 保存 PUT /settings/rounding（服务器权威），广播后各端刷新本地口径；本地缓存同步更新。
class RoundingSettingsPage extends StatefulWidget {
  const RoundingSettingsPage({super.key});
  @override
  State<RoundingSettingsPage> createState() => _RoundingSettingsPageState();
}

class _RoundingSettingsPageState extends State<RoundingSettingsPage> {
  bool _loading = true;
  double _carry = 0.5;
  int _digits = 2;
  bool _saving = false;

  // 预设档位（进位临界）：四舍五入 0.5 / 5舍6入 0.6 / 自定义（数值输入）
  static const presets = <(String, double)>[
    ('四舍五入（尾数≥5 进，<5 舍）', 0.5),
    ('5舍6入（尾数 5 舍、≥6 进）', 0.6),
    ('四舍六入（尾数≥7 进，更收紧）', 0.7),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.get('/settings/rounding').timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _carry = (d['carry'] as num?)?.toDouble() ?? 0.5;
        _digits = (d['digits'] as num?)?.toInt() ?? 2;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _carry = Money.carry;
        _digits = Money.digits;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await Api.instance.put('/settings/rounding', {
        'carry': _carry,
        'digits': _digits,
      });
      await Money.refresh(); // 本地口径立即更新（新记账即按新规则）
      toast(context, '已保存（新记账按新规则计算）');
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _digitsLabel(int d) => switch (d) { 0 => '元（整数）', 1 => '角（1 位小数）', _ => '分（2 位小数）' };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('金额舍入')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: .4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    '所有金额计算按此舍入（行金额/合计/毛利/统计/欠款）。历史数据存储不变，统计与欠款展示按新规则实时重算。',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(height: 18),
                const Text('进位临界（四舍五入的变体）', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                for (final (label, v) in presets)
                  RadioListTile<double>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(label, style: const TextStyle(fontSize: 14)),
                    value: v,
                    groupValue: _carry,
                    onChanged: (x) => setState(() => _carry = x ?? 0.5),
                  ),
                _customCarryRow(),
                const SizedBox(height: 20),
                const Text('精度（保留到多少分/角/元）', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                for (final d in const [0, 1, 2])
                  RadioListTile<int>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(_digitsLabel(d), style: const TextStyle(fontSize: 14)),
                    value: d,
                    groupValue: _digits,
                    onChanged: (x) => setState(() => _digits = x ?? 2),
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '保存中…' : '保存'),
                ),
              ],
            ),
    );
  }

  Widget _customCarryRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const Text('自定义临界值', style: TextStyle(fontSize: 14)),
          const SizedBox(width: 10),
          Expanded(
            child: Slider(
              value: _carry.clamp(0.1, 0.9),
              min: 0.1,
              max: 0.9,
              divisions: 16,
              label: _carry.toStringAsFixed(1),
              onChanged: (v) => setState(() => _carry = double.parse(v.toStringAsFixed(1))),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text('${_carry.toStringAsFixed(1)}', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}