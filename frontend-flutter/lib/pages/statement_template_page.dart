/// 对账单模板设置页（本地优先，离线可用）：只保留「网格模板」一种可编辑形态——
/// 用现成 Excel 式网格组件 pluto_grid 编辑（单元格可放 {变量} 含 {1日}…{31日}），保存到本地（SharedPreferences）。
/// 组件/正文旧模板仍可被导出渲染（renderTemplateRows 兼容），但编辑入口收敛为网格。
/// 预览取本地镜像（原生）；Web 无本地库回退请求服务器。
import 'package:flutter/material.dart';
import 'package:pluto_grid/pluto_grid.dart';
import '../api.dart';
import '../local_db.dart';
import '../statement_tmpl.dart';
import '../theme.dart';

class StatementTemplatePage extends StatefulWidget {
  const StatementTemplatePage({super.key});
  @override
  State<StatementTemplatePage> createState() => _StatementTemplatePageState();
}

class _StatementTemplatePageState extends State<StatementTemplatePage> {
  List<XlsCfg> _templates = [];
  String _selName = '';
  bool _loading = true;
  PlutoGridStateManager? _gridState; // 网格编辑状态（保存时回读）

  XlsCfg get _cur => _templates.firstWhere((t) => t.name == _selName, orElse: () => _templates.first);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final t = await loadTemplates();
    if (mounted) {
      setState(() {
        _templates = t;
        _selName = t.first.name;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final cur = _cur;
    if (_gridState != null) {
      // 从 PlutoGrid 读回（含追加行/编辑的单元格）写回模板
      final rows = _gridState!.refRows;
      final cols = cur.grid.isEmpty ? 3 : cur.grid[0].length;
      cur.grid = [
        for (final r in rows)
          [for (var cc = 0; cc < cols; cc++) GridCell('${r.cells['c$cc']?.value ?? ''}')],
      ];
    }
    if (cur.grid.isEmpty) {
      _pageToast(context, '网格为空，先填单元格或加行');
      return;
    }
    await saveTemplates(_templates, _selName);
    if (mounted) _pageToast(context, '模板「${cur.name}」已保存');
  }

  Future<void> _addTemplate() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: const Text('新建模板'),
          content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: '模板名')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('创建')),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;
    setState(() {
      _templates.add(XlsCfg()..name = name);
      _selName = name;
    });
    await _save();
  }

  Future<void> _deleteTemplate() async {
    final cur = _cur;
    if (cur.name == '标准' || cur.name == '按日汇总') {
      _pageToast(context, '内置模板不可删除');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模板'),
        content: Text('删除模板「${cur.name}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _templates.removeWhere((t) => t.name == _selName);
      _selName = _templates.first.name;
    });
    await _save();
  }

  /// 预览数据：本地优先（原生读本地镜像，离线可用）；Web（无本地库）回退请求服务器当月出货
  Future<TemplateData?> _previewData() async {
    final now = DateTime.now();
    final from = '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
    final to = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    // 原生：本地镜像（整单 sales 含明细、payments）组装，零网络
    try {
      final all = await LocalDb.getAll('sales');
      if (all.isNotEmpty) {
        final inMonth = all.where((s) {
          final d = '${s['happened_at'] ?? ''}';
          return d.length >= 10 && d.substring(0, 7) == (from.length >= 7 ? from.substring(0, 7) : '');
        }).toList();
        final pays = await LocalDb.getAll('payments');
        double saleTotal = 0, paidTotal = 0;
        for (final s in all) {
          for (final it in ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
            saleTotal += (it['amount'] as num?)?.toDouble() ?? 0;
          }
        }
        for (final p in pays) {
          paidTotal += (p['amount'] as num?)?.toDouble() ?? 0;
          paidTotal += (p['waived'] as num?)?.toDouble() ?? 0;
        }
        return TemplateData(
          sales: inMonth,
          from: from,
          to: to,
          clientName: '全部店铺',
          debtEnd: saleTotal - paidTotal,
        );
      }
    } catch (_) {}
    // Web / 本地无镜像：请求服务器
    try {
      final d = await Api.instance.get('/sales?date_from=$from&date_to=$to&limit=1000');
      final sales = ((d['sales'] as List?) ?? []).cast<Map<String, dynamic>>();
      return TemplateData(sales: sales, from: from, to: to, clientName: '全部店铺');
    } catch (_) {
      return null;
    }
  }

  Future<void> _preview() async {
    final td = await _previewData();
    if (!mounted) return;
    if (td == null) {
      _pageToast(context, '无数据可预览（本地无记录且网络失败）');
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('预览：${_cur.name}'),
        content: SingleChildScrollView(
          child: Table(
            border: TableBorder.all(color: Colors.black26, width: 0.5),
            defaultColumnWidth: const IntrinsicColumnWidth(),
            children: [
              for (final row in renderTemplateRows(_cur, td))
                TableRow(children: [
                  for (final c in row)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Text(c.text,
                          textAlign: c.align == 'center'
                              ? TextAlign.center
                              : (c.align == 'right' ? TextAlign.right : TextAlign.left),
                          style: const TextStyle(fontSize: 11)),
                    ),
                ]),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('对账单模板'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Wrap(spacing: 6, runSpacing: 4, children: [
                  for (final t in _templates)
                    ChoiceChip(
                      label: Text(t.name, style: const TextStyle(fontSize: 12)),
                      selected: t.name == _selName,
                      onSelected: (_) => setState(() {
                        _selName = t.name;
                        _gridState = null;
                      }),
                    ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Wrap(spacing: 8, children: [
                  OutlinedButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('新建模板'), onPressed: _addTemplate),
                  OutlinedButton.icon(icon: const Icon(Icons.delete_outline, size: 16), label: const Text('删除'), onPressed: _deleteTemplate),
                  OutlinedButton.icon(icon: const Icon(Icons.visibility_outlined, size: 16), label: const Text('预览'), onPressed: _preview),
                ]),
              ),
              const Divider(height: 1),
              Expanded(child: _gridEditor(c)),
            ]),
    );
  }

  Widget _gridEditor(TaozhuColors c) {
    final cur = _cur;
    // 网格为唯一编辑形态：旧组件/正文模板在此转为网格（清空，改以 grid 渲染）
    if (cur.comps.isNotEmpty || cur.content.trim().isNotEmpty) {
      cur.comps = [];
      cur.content = '';
    }
    final cols = cur.grid.isEmpty ? 3 : cur.grid[0].length;
    if (cur.grid.isEmpty) {
      cur.grid = [
        for (var r = 0; r < 3; r++) [for (var cc = 0; cc < cols; cc++) GridCell()],
      ];
    }
    final columns = <PlutoColumn>[
      for (var cc = 0; cc < cols; cc++)
        PlutoColumn(title: '${cc + 1} 列', field: 'c$cc', type: PlutoColumnType.text(), width: 110),
    ];
    final gridRows = [
      for (var r = 0; r < cur.grid.length; r++)
        PlutoRow(cells: {
          for (var cc = 0; cc < cols; cc++) 'c$cc': PlutoCell(value: cur.grid[r][cc].text),
        }),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Wrap(spacing: 6, runSpacing: 4, children: [
          OutlinedButton.icon(
              icon: const Icon(Icons.playlist_add, size: 14), label: const Text('加列'),
              onPressed: () => setState(() {
                for (final r in cur.grid) {
                  r.add(GridCell());
                }
                _gridState = null;
              })),
          OutlinedButton.icon(
              icon: const Icon(Icons.playlist_remove, size: 14), label: const Text('删列'),
              onPressed: cols > 1
                  ? () => setState(() {
                      for (final r in cur.grid) {
                        r.removeLast();
                      }
                      _gridState = null;
                    })
                  : null),
          Text('双击单元格编辑（可放 {店铺}{1日}…{31日}{明细} 变量）；表格底部「+」追加行',
              style: TextStyle(fontSize: 11, color: c.textSub)),
        ]),
      ),
      Expanded(
        child: PlutoGrid(
          columns: columns,
          rows: gridRows,
          onLoaded: (e) => _gridState = e.stateManager,
        ),
      ),
    ]);
  }
}

/// 轻量提示（页面内）
void _pageToast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
}