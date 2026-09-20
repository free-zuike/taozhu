/// 对账单模板设置页（本地优先，离线可用）：只保留「网格模板」一种可编辑形态——
/// 用 Flutter 官方表格组件 two_dimensional_scrollables（TableView，BSD-3 免费）编辑：
/// 原生支持合并单元格（TableViewCell.rowMergeSpan/columnMergeSpan，编辑时真实可见合并），
/// 单元格可放 {变量} 含 {1日}…{31日}，保存到本地（SharedPreferences）。
/// 组件/正文旧模板仍可被导出渲染（renderTemplateRows 兼容），但编辑入口收敛为网格。
/// 预览取本地镜像（原生）；Web 无本地库回退请求服务器。
import 'package:flutter/material.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';
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
  String _view = 'edit'; // edit 默认（TableView Excel 式网格，点击编辑/合并可见） | preview（真实数据渲染）
  // 合并选择模式：点「合并」进入，依次点两个对角单元格完成矩形合并
  bool _mergeMode = false;
  ({int r, int c})? _mergeStart;
  // 当前选中格（加粗/对齐/字号作用于它）
  ({int r, int c})? _selCell;

  XlsCfg get _cur => _templates.firstWhere((t) => t.name == _selName, orElse: () => _templates.first);

  /// 对齐解析：列级 colAligns 优先，否则单元格自身 align——与渲染库 renderTemplateRows 一致
  /// （编辑/预览/导出/打印同一套对齐，杜绝"编辑居中但预览不居中"）
  String _cellAlign(XlsCfg cfg, int col, String fallback) {
    if (col < cfg.colAligns.length && cfg.colAligns[col].isNotEmpty) return cfg.colAligns[col];
    return fallback;
  }

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
                        _mergeMode = false;
                        _mergeStart = null;
                        _selCell = null;
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
    final rows = cur.grid.length;
    final cols = cur.grid[0].length;
    final rowCount = rows < 4 ? 4 : rows; // 最少展示 4 行，便于加内容
    final colCount = cols < 3 ? 3 : cols; // 最少 3 列
    // 扩展网格到最小行列（不落库，仅编辑视图展示）
    for (var r = 0; r < rowCount; r++) {
      if (r >= cur.grid.length) cur.grid.add([for (var cc = 0; cc < colCount; cc++) GridCell()]);
      while (cur.grid[r].length < colCount) cur.grid[r].add(GridCell());
    }
    void rebuild() => setState(() {});
    // 在指定位置插入/删除行、列（操作面板用；调用前要 flush 不做——TableView 直接改 cur.grid）
    void insertRowAt(int r) {
      final w = cur.grid[0].length;
      cur.grid.insert(r, [for (var cc = 0; cc < w; cc++) GridCell()]);
      rebuild();
    }
    void removeRowAt(int r) {
      if (cur.grid.length <= 1) return;
      cur.grid.removeAt(r);
      rebuild();
    }
    void insertColAt(int cc) {
      for (var r = 0; r < cur.grid.length; r++) {
        cur.grid[r].insert(cc, GridCell());
      }
      cur.colAligns.insert(cc, 'left');
      rebuild();
    }
    void removeColAt(int cc) {
      if (cur.grid[0].length <= 1) return;
      for (var r = 0; r < cur.grid.length; r++) {
        cur.grid[r].removeAt(cc);
      }
      if (cc < cur.colAligns.length) cur.colAligns.removeAt(cc);
      rebuild();
    }
    // 查找覆盖 (r,c) 的合并起点（含自身）
    ({int sr, int sc, int rs, int cs})? owner(int r, int c) {
      for (var sr = 0; sr <= r && sr < cur.grid.length; sr++) {
        for (var sc = 0; sc <= c && sc < cur.grid[sr].length; sc++) {
          final cell = cur.grid[sr][sc];
          if ((cell.rowSpan > 1 || cell.colSpan > 1) &&
              r < sr + cell.rowSpan && c < sc + cell.colSpan) {
            return (sr: sr, sc: sc, rs: cell.rowSpan, cs: cell.colSpan);
          }
        }
      }
      return null;
    }
    // 单元格操作面板（Excel 式，一个入口收纳编辑/对齐/加粗/插入行列/合并/删除）：
    // 点单元格弹出，不再顶部加一排按钮
    Future<void> _showCellMenu(int r, int col) async {
      setState(() => _selCell = (r: r, c: col));
      final cell = cur.grid[r][col];
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('单元格 (${r + 1},${col + 1})',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                // 行：插入/删除
                Row(children: [
                  Expanded(
                      child: OutlinedButton.icon(
                          icon: const Icon(Icons.arrow_upward, size: 16),
                          label: const Text('上方插行'),
                          onPressed: () {
                            Navigator.pop(ctx);
                            insertRowAt(r);
                          })),
                  const SizedBox(width: 8),
                  Expanded(
                      child: OutlinedButton.icon(
                          icon: const Icon(Icons.arrow_downward, size: 16),
                          label: const Text('下方插行'),
                          onPressed: () {
                            Navigator.pop(ctx);
                            insertRowAt(r + 1);
                          })),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      child: OutlinedButton.icon(
                          icon: const Icon(Icons.arrow_back, size: 16),
                          label: const Text('左侧插列'),
                          onPressed: () {
                            Navigator.pop(ctx);
                            insertColAt(col);
                          })),
                  const SizedBox(width: 8),
                  Expanded(
                      child: OutlinedButton.icon(
                          icon: const Icon(Icons.arrow_forward, size: 16),
                          label: const Text('右侧插列'),
                          onPressed: () {
                            Navigator.pop(ctx);
                            insertColAt(col + 1);
                          })),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      child: OutlinedButton.icon(
                          icon: const Icon(Icons.remove, size: 16),
                          label: const Text('删除本行'),
                          onPressed: () {
                            Navigator.pop(ctx);
                            removeRowAt(r);
                          })),
                  const SizedBox(width: 8),
                  Expanded(
                      child: OutlinedButton.icon(
                          icon: const Icon(Icons.close, size: 16),
                          label: const Text('删除本列'),
                          onPressed: () {
                            Navigator.pop(ctx);
                            removeColAt(col);
                          })),
                ]),
                const Divider(height: 20),
                // 行：编辑文本 / 加粗
                Row(children: [
                  Expanded(
                      child: OutlinedButton.icon(
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          label: const Text('编辑文本'),
                          onPressed: () {
                            final ctrl = TextEditingController(text: cell.text);
                            showDialog<void>(
                              context: ctx,
                              builder: (dctx) => AlertDialog(
                                title: const Text('编辑单元格'),
                                content: TextField(controller: ctrl, autofocus: true, maxLines: 3),
                                actions: [
                                  TextButton(
                                      onPressed: () => Navigator.pop(dctx),
                                      child: const Text('取消')),
                                  FilledButton(
                                      onPressed: () {
                                        cell.text = ctrl.text;
                                        setState(() {});
                                        Navigator.pop(dctx);
                                      },
                                      child: const Text('确定')),
                                ],
                              ),
                            );
                          })),
                  const SizedBox(width: 8),
                  Expanded(
                      child: OutlinedButton.icon(
                          icon: Icon(
                              cell.bold ? Icons.format_bold : Icons.format_bold_outlined,
                              size: 16),
                          label: const Text('加粗'),
                          onPressed: () {
                            cell.bold = !cell.bold;
                            setState(() {});
                            Navigator.pop(ctx);
                          })),
                ]),
                const SizedBox(height: 8),
                // 行：对齐（列级）—— 与渲染一致（colAligns 优先）
                Row(children: [
                  for (final (val, label, icon) in [
                    ('left', '左对齐', Icons.format_align_left),
                    ('center', '居中', Icons.format_align_center),
                    ('right', '右对齐', Icons.format_align_right),
                  ])
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: OutlinedButton.icon(
                          icon: Icon(icon, size: 16),
                          label: Text(label, style: const TextStyle(fontSize: 12)),
                          onPressed: () {
                            while (cur.colAligns.length <= col) cur.colAligns.add('');
                            cur.colAligns[col] = val;
                            setState(() {});
                            Navigator.pop(ctx);
                          },
                        ),
                      ),
                    ),
                ]),
                const Divider(height: 20),
                // 行：合并 / 取消合并
                OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.primary,
                      side: BorderSide(color: c.primary.withOpacity(0.5)),
                    ),
                    icon: const Icon(Icons.merge_type, size: 16),
                    label: const Text('合并选中区域（点起点后点终点）'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _mergeMode = true;
                        _mergeStart = null;
                      });
                      _pageToast(context, '请点第一格=起点，再点第二格=终点');
                    }),
                OutlinedButton.icon(
                    icon: const Icon(Icons.merge_type, size: 16),
                    label: const Text('取消全部合并'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      int cleared = 0;
                      for (final row in cur.grid) {
                        for (final cell in row) {
                          if (cell.rowSpan > 1 || cell.colSpan > 1) {
                            cell.rowSpan = 1;
                            cell.colSpan = 1;
                            cleared++;
                          }
                        }
                      }
                      setState(() {});
                      _pageToast(context, cleared == 0 ? '当前没有合并单元格' : '已取消全部合并');
                    }),
              ],
            ),
          ),
        ),
      );
    }

    // 单元格内容 widget：点击=合并模式两步 / 否则弹出操作面板（Excel 式：编辑/对齐/加粗/插入行列/合并一体）
    Widget cellWidget(int r, int col) {
      final cell = (r < cur.grid.length && col < cur.grid[r].length) ? cur.grid[r][col] : GridCell();
      final a = _cellAlign(cur, col, cell.align);
      final isSel = _selCell != null && _selCell!.r == r && _selCell!.c == col;
      return InkWell(
        onTap: () {
          if (_mergeMode) {
            // 合并两步：第一格=起点，第二格=终点（矩形真合并）
            if (_mergeStart == null) {
              setState(() {
                _mergeStart = (r: r, c: col);
                _selCell = (r: r, c: col);
              });
              _pageToast(context, '已选起点，再点终点完成合并');
            } else {
              final s = _mergeStart!;
              final rMin = s.r < r ? s.r : r;
              final rMax = s.r > r ? s.r : r;
              final cMin = s.c < col ? s.c : col;
              final cMax = s.c > col ? s.c : col;
              if (rMin == rMax && cMin == cMax) {
                setState(() {
                  _mergeStart = null;
                  _mergeMode = false;
                });
                _pageToast(context, '已取消合并选择');
                return;
              }
              for (var rr = rMin; rr <= rMax; rr++) {
                for (var cc = cMin; cc <= cMax; cc++) {
                  if (rr == rMin && cc == cMin) continue;
                  cur.grid[rr][cc].text = '';
                }
              }
              cur.grid[rMin][cMin].colSpan = cMax - cMin + 1;
              cur.grid[rMin][cMin].rowSpan = rMax - rMin + 1;
              setState(() {
                _mergeStart = null;
                _mergeMode = false;
                _selCell = null;
              });
              _pageToast(context, '已合并 ${cMax - cMin + 1} 列 × ${rMax - rMin + 1} 行');
            }
            return;
          }
          _showCellMenu(r, col);
        },
        child: Container(
          alignment: a == 'center'
              ? Alignment.center
              : (a == 'right' ? Alignment.centerRight : Alignment.centerLeft),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          color: cell.bg == 'grey'
              ? c.primary.withOpacity(0.08)
              : (isSel ? c.primary.withOpacity(0.12) : null),
          child: Text(cell.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: cell.bold ? FontWeight.w700 : FontWeight.normal,
                  color: cell.bg == 'grey' ? c.primary : c.textMain)),
        ),
      );
    }
    // 列/行 span（TableSpan）
    TableSpan colSpan(int i) => TableSpan(
          extent: const FixedTableSpanExtent(120),
          foregroundDecoration: TableSpanDecoration(
            border: TableSpanBorder(
              trailing: BorderSide(color: c.divider.withOpacity(0.6), width: 0.5),
            ),
          ),
        );
    TableSpan rowSpan(int i) => TableSpan(
          extent: const FixedTableSpanExtent(42),
          foregroundDecoration: TableSpanDecoration(
            border: TableSpanBorder(
              trailing: BorderSide(color: c.divider.withOpacity(0.6), width: 0.5),
            ),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          // 页内切换：编辑（TableView Excel 式网格） / 预览（真实数据渲染）
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
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
          Text('点单元格 = 编辑/对齐/加粗/插入行列/合并（Excel 操作方式）',
              style: TextStyle(fontSize: 11, color: c.textSub)),
        ]),
      ),
      Expanded(
        child: _view == 'preview'
            ? _previewPane(c)
            : TableView.builder(
                columnCount: cur.grid[0].length,
                rowCount: cur.grid.length,
                columnBuilder: colSpan,
                rowBuilder: rowSpan,
                cellBuilder: (context, vicinity) {
                  final r = vicinity.row;
                  final cc = vicinity.column;
                  if (r >= cur.grid.length || cc >= cur.grid[r].length) {
                    return TableViewCell(child: cellWidget(r, cc));
                  }
                  final o = owner(r, cc);
                  if (o != null) {
                    // 合并区：起点返回内容，被覆盖格返回占位（带相同 merge 信息保证真合并渲染）
                    return TableViewCell(
                      rowMergeStart: o.sr,
                      rowMergeSpan: o.rs,
                      columnMergeStart: o.sc,
                      columnMergeSpan: o.cs,
                      child: (o.sr == r && o.sc == cc) ? cellWidget(r, cc) : const SizedBox.shrink(),
                    );
                  }
                  return TableViewCell(child: cellWidget(r, cc));
                },
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
                border: TableBorder.all(color: const Color(0xFFD9D9D9), width: 0.5),
                defaultColumnWidth: const IntrinsicColumnWidth(),
                children: [
                  for (final row in rows)
                    TableRow(children: [
                      for (final cell in row)
                        Container(
                          color: cell.bg == 'grey' ? c.primary.withOpacity(0.08) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                          child: Text(cell.text,
                              textAlign: cell.align == 'center'
                                  ? TextAlign.center
                                  : (cell.align == 'right' ? TextAlign.right : TextAlign.left),
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: cell.bold ? FontWeight.w700 : FontWeight.normal,
                                  color: cell.bg == 'grey' ? c.primary : c.textMain)),
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