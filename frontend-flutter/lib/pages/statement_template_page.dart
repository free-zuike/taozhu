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
  int _gridTick = 0; // 结构变化计数：PlutoGrid columns/rows 只在创建时生效，加列/行后 key 变化强制重建
  String _view = 'preview'; // preview 默认（开箱即用先看效果） | edit（高级：网格编辑）

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

  /// 从 PlutoGrid 回读编辑内容写回模板（预览/保存前必须调用，否则变量与增删行丢失）
  void _flushGrid() {
    final cur = _cur;
    final st = _gridState;
    if (st == null) return;
    final rows = st.refRows;
    final cols = cur.grid.isEmpty ? 3 : cur.grid[0].length;
    final oldGrid = cur.grid;
    cur.grid = [
      for (var r = 0; r < rows.length; r++)
        [
          for (var cc = 0; cc < cols; cc++)
            GridCell(
              '${rows[r].cells['c$cc']?.value ?? ''}',
              r < oldGrid.length && cc < oldGrid[r].length ? oldGrid[r][cc].align : 'left',
            ),
        ],
    ];
  }

  Future<void> _save() async {
    final cur = _cur;
    _flushGrid();
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
                        _view = 'edit';
                      }),
                    ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Wrap(spacing: 8, children: [
                  OutlinedButton.icon(icon: const Icon(Icons.add, size: 16), label: const Text('新建模板'), onPressed: _addTemplate),
                  OutlinedButton.icon(icon: const Icon(Icons.delete_outline, size: 16), label: const Text('删除'), onPressed: _deleteTemplate),
                  Text('下方「编辑/预览」切换实时预览效果', style: TextStyle(fontSize: 11, color: c.textSub)),
                ]),
              ),
              const Divider(height: 1),
              Expanded(child: _gridEditor(c)),
            ]),
    );
  }

  Widget _gridEditor(TaozhuColors c) {
    final cur = _cur;
    // 网格为唯一编辑形态：旧组件/正文模板进入编辑转为网格；空模板用默认多栏账单网格（避免空白边框）
    if (cur.comps.isNotEmpty || cur.content.trim().isNotEmpty) {
      cur.comps = [];
      cur.content = '';
    }
    if (cur.grid.isEmpty) {
      cur.grid = [
        [GridCell('{店铺}{年}年{月}月份账单', 'center')],
        [GridCell('{月账单}', '')],
        [GridCell('出货合计：{出货合计}　收款合计：{收款合计}　期末欠款：{期末欠款}', 'left')],
      ];
    }
    final cols = cur.grid[0].length;
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
    // 结构变化后强制重建（PlutoGrid columns/rows 只在创建时生效，setState 不会刷新）
    void rebuild() => setState(() => _gridTick++);
    void addCol() {
      _flushGrid();
      for (final r in cur.grid) {
        r.add(GridCell());
      }
      cur.colAligns.add('left');
      rebuild();
    }
    void delCol() {
      if (cols <= 1) return;
      _flushGrid();
      for (final r in cur.grid) {
        r.removeLast();
      }
      if (cur.colAligns.length > cols - 1) cur.colAligns.removeLast();
      rebuild();
    }
    void addRow() {
      _flushGrid();
      cur.grid.add([for (var cc = 0; cc < cols; cc++) GridCell()]);
      rebuild();
    }
    void delRow() {
      if (cur.grid.length <= 1) return;
      _flushGrid();
      cur.grid.removeLast();
      rebuild();
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Wrap(spacing: 6, runSpacing: 4, children: [
          // 页内切换：编辑（Excel 式网格） / 预览（真实数据渲染）
          SegmentedButton<String>(
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
            ),
            segments: const [
              ButtonSegment(value: 'edit', label: Text('编辑')),
              ButtonSegment(value: 'preview', label: Text('预览')),
            ],
            selected: {_view},
            onSelectionChanged: (s) {
              if (s.first == 'edit') {
                setState(() => _view = 'edit');
              } else {
                _flushGrid();
                setState(() => _view = 'preview');
              }
            },
          ),
          const VerticalDivider(width: 12),
          OutlinedButton.icon(
              icon: const Icon(Icons.playlist_add, size: 14), label: const Text('加列'),
              onPressed: addCol),
          OutlinedButton.icon(
              icon: const Icon(Icons.playlist_remove, size: 14), label: const Text('删列'),
              onPressed: cols > 1 ? delCol : null),
          OutlinedButton.icon(
              icon: const Icon(Icons.add, size: 14), label: const Text('加行'),
              onPressed: addRow),
          OutlinedButton.icon(
              icon: const Icon(Icons.remove, size: 14), label: const Text('删行'),
              onPressed: cur.grid.length > 1 ? delRow : null),
          // 每列对齐循环按钮（左→中→右），渲染时 colAligns 优先于单元格 align
          for (var cc = 0; cc < cols; cc++)
            ActionChip(
              label: Text('${cc + 1}列 ${_alignTxt(cc < cur.colAligns.length ? cur.colAligns[cc] : '')}',
                  style: const TextStyle(fontSize: 11)),
              onPressed: () => setState(() {
                while (cur.colAligns.length <= cc) {
                  cur.colAligns.add('');
                }
                cur.colAligns[cc] = cur.colAligns[cc] == 'center'
                    ? 'right'
                    : (cur.colAligns[cc] == 'right' ? 'left' : 'center');
              }),
            ),
          Text('双击单元格编辑；可放变量 {店铺}{年}{月}{日}{1日}…{31日}{明细}{月账单}；{月账单}=整月分栏账单一格生成',
              style: TextStyle(fontSize: 11, color: c.textSub)),
        ]),
      ),
      Expanded(
        child: _view == 'preview'
            ? _previewPane(c)
            : PlutoGrid(
                key: ValueKey('grid-$_selName-$_gridTick'),
                columns: columns,
                rows: gridRows,
                onLoaded: (e) => _gridState = e.stateManager,
              ),
      ),
    ]);
  }

  /// 页内预览（所见即所得）：拉当月出货数据渲染当前模板（与导出/打印同源）
  Widget _previewPane(TaozhuColors c) {
    return FutureBuilder<TemplateData?>(
      future: _previewData(),
      builder: (ctx, snap) {
        final td = snap.data;
        if (snap.connectionState != ConnectionState.done || td == null) {
          return const Center(child: Text('加载预览数据…', style: TextStyle(fontSize: 12)));
        }
        try {
          final rows = renderTemplateRows(_cur, td);
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              child: Table(
                border: TableBorder.all(color: const Color(0xFF9E9E9E), width: 0.5),
                defaultColumnWidth: const IntrinsicColumnWidth(),
                children: [
                  for (final row in rows)
                    TableRow(children: [
                      for (final cell in row)
                        Container(
                          color: cell.bg == 'grey' ? const Color(0xFFF2F2F2) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                          child: Text(cell.text,
                              textAlign: cell.align == 'center'
                                  ? TextAlign.center
                                  : (cell.align == 'right' ? TextAlign.right : TextAlign.left),
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: cell.bold ? FontWeight.w700 : FontWeight.normal,
                                  color: c.textMain)),
                        ),
                    ]),
                ],
              ),
            ),
          );
        } catch (_) {
          return const Center(child: Text('预览渲染失败', style: TextStyle(fontSize: 12)));
        }
      },
    );
  }
}

/// 轻量提示（页面内）
void _pageToast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
}

/// 对齐按钮显示文本
String _alignTxt(String a) => a == 'center' ? '居中' : (a == 'right' ? '右' : '左');