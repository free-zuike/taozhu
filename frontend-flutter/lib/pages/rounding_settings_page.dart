import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import 'router.dart';

/// 金额舍入设置（仅老板）：进位临界（四舍五入/5舍6入/自定义 0~1）+ 精度（元/角/分）。
/// 保存 PUT /settings/rounding（服务器权威），广播后各端刷新本地口径；本地缓存同步更新。
/// 店铺结账抹零（round_stage/round_unit）也在此设置：欠款按各店口径计算（0.17.323 起）。
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
  List<Map<String, dynamic>> _clients = [];

  // 预设档位（进位临界）：四舍五入 0.5 / 5舍6入 0.6 / 自定义（数值输入）
  static const presets = <(String, double)>[
    ('四舍五入（尾数≥5 进，<5 舍）', 0.5),
    ('5舍6入（尾数 5 舍、≥6 进）', 0.6),
    ('四舍六入（尾数≥7 进，更收紧）', 0.7),
  ];

  static const _stageNames = {
    'none': '不抹零',
    'txn': '每单抹零',
    'day': '按天抹零',
    'total': '结账抹零',
  };
  static const _unitNames = {'yuan': '元', 'jiao': '角', 'fen': '分'};

  @override
  void initState() {
    super.initState();
    // 本地优先：只读本地缓存口径（离线秒开、不拉网络不跳动）。
    // 联网后的最新值由实时 WS 'rounding' 事件（Money.refresh）维护，本页不再打开即拉服务器。
    _carry = Money.carry;
    _digits = Money.digits;
    _loading = false;
    _loadClients();
  }

  Future<void> _loadClients() async {
    try {
      final local = await LocalDb.getAllByName('clients');
      if (mounted) setState(() => _clients = local);
    } catch (_) {}
  }

  String _stageText(Map<String, dynamic> c) {
    final cfg = normalizeRoundConfig(c['round_stage'], c['round_unit']);
    return '${_stageNames[cfg.stage] ?? '不抹零'}${_unitNames[cfg.unit] ?? ''}';
  }

  Future<void> _editClientRounding(Map<String, dynamic> c) async {
    final cfg = normalizeRoundConfig(c['round_stage'], c['round_unit']);
    var stage = cfg.stage;
    var unit = cfg.unit;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text('${c['name']} 抹零设置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: stage,
                decoration: const InputDecoration(labelText: '抹零方式'),
                items: _stageNames.entries
                    .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setDlg(() => stage = v ?? stage),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: unit,
                decoration: const InputDecoration(labelText: '抹零精度'),
                items: _unitNames.entries
                    .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setDlg(() => unit = v ?? unit),
              ),
              const SizedBox(height: 6),
              const Text('欠款按此口径计算（记录金额不变，仅欠款面抹零）', style: TextStyle(fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final updated = Map<String, dynamic>.from(c)..['round_stage'] = stage..['round_unit'] = unit;
    if (kIsWeb) {
      // Web 无本地库/同步队列：直连服务端（App 走本地优先队列）
      try {
        await Api.instance.patch('/clients/${c['id']}', {'round_stage': stage, 'round_unit': unit});
      } catch (e) {
        toast(context, e.toString().replaceFirst('Exception: ', ''));
        return;
      }
    } else {
      // 本地优先：写本地镜像 + 入同步队列推送（App 不直连改服务器数据库）
      await LocalDb.upsertOne('clients', updated);
      await SyncService.enqueueChange(entityType: 'client', entitySyncId: '${c['id']}', payload: updated);
    }
    if (mounted) setState(() => _clients = _clients.map((x) => '${x['id']}' == '${c['id']}' ? updated : x).toList());
    toast(context, '已保存（欠款按新口径重算）');
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // 本地优先：先写本地口径（立即生效、重进仍生效、离线可用）；标记脏由同步队列推送
      // （App 不直连改服务器数据库——服务端收到后广播 WS payload 各端直接应用）
      await Money.apply(_carry, _digits);
      await Money.markRoundingDirty();
      SyncService.sync(); // 触发同步推送（失败静默保留脏标记下次再推，不阻塞、不兜底）
      toast(context, '已保存（新记账按新规则计算）');
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
                if (_clients.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  const Text('店铺结账抹零（欠款按各店设置计算）', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text('记录金额不变，仅欠款面按店铺抹零方式/精度计算；点店铺修改', style: TextStyle(fontSize: 12, color: Theme.of(context).extension<TaozhuColors>()!.textSub)),
                  const SizedBox(height: 6),
                  Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: Column(
                      children: [
                        for (final c in _clients)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.store_outlined, size: 20, color: Color(0xFF409EFF)),
                            title: Text('${c['name']}', style: const TextStyle(fontSize: 14)),
                            subtitle: Text('抹零：${_stageText(c)}', style: const TextStyle(fontSize: 12)),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                            onTap: () => _editClientRounding(c),
                          ),
                      ],
                    ),
                  ),
                ],
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