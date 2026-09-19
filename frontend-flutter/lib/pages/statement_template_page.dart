/// 对账单模板设置页（独立管理）：模板列表（新建/删除/切换）+ 组件式设计器（组件/网格/正文）
/// + 实时预览（拉当月出货数据渲染，所见即所得）。与对账单导出共用公共模板库（statement_tmpl.dart）。
import 'package:flutter/material.dart';
import 'package:pluto_grid/pluto_grid.dart';
import '../api.dart';
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
  String _tab = 'comps'; // comps | grid | content
  bool _loading = true;
  final _contentCtrl = TextEditingController();
  PlutoGridStateManager? _gridState; // 网格模板编辑状态（保存时回读）

  XlsCfg get _cur => _templates.firstWhere((t) => t.name == _selName, orElse: () => _templates.first);

  static const _typeNames = <String, String>{
    'title': '标题', 'fields': '信息字段', 'stats': '统计',
    'days': '按日金额表（1-31）', 'detail': '出货明细', 'text': '自定义文本',
  };

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _contentCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final t = await loadTemplates();
    if (mounted) {
      setState(() {
        _templates = t;
        _selName = t.first.name;
        _contentCtrl.text = _cur.content;
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    final cur = _cur;
    if (_tab == 'content') cur.content = _contentCtrl.text;
    if (_tab == 'grid' && _gridState != null) {
      // 从 PlutoGrid 读回（含追加行/编辑的单元格）
      final rows = _gridState!.refRows;
      final cols = cur.grid.isEmpty ? 3 : cur.grid[0].length;
      cur.grid = [
        for (final r in rows)
          [for (var cc = 0; cc < cols; cc++) GridCell('${r.cells['c$cc']?.value ?? ''}')],
      ];
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
      _contentCtrl.text = '';
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
      _contentCtrl.text = _cur.content;
    });
    await _save();
  }

  /// 预览：拉当月出货数据（Web/原生都走请求；主动刷新可接受）渲染模板
  Future<void> _preview() async {
    final now = DateTime.now();
    final from = '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
    final to = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    try {
      final d = await Api.instance.get('/sales?date_from=$from&date_to=$to&limit=1000');
      final sales = ((d['sales'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (!mounted) return;
      final td = TemplateData(
        sales: sales,
        from: from,
        to: to,
        clientName: '全部店铺',
      );
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
    } catch (e) {
      _pageToast(context, '预览拉取数据失败：${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  void _moveComp(int i, int delta) {
    final ni = i + delta;
    if (ni < 0 || ni >= _cur.comps.length) return;
    final t = _cur.comps.removeAt(i);
    _cur.comps.insert(ni, t);
  }

  Future<void> _configComp(int i) async {
    final c = _cur.comps[i];
    final textCtrl = TextEditingController(text: c.text);
    var align = c.align;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setC) => AlertDialog(
          title: Text('配置：${_typeNames[c.type] ?? c.type}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (c.type == 'text' || c.type == 'title')
              TextField(
                controller: textCtrl,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '内容（可含变量 {店铺}{明细}{1日}…）'),
              ),
            Wrap(spacing: 4, children: [
              for (final a in const ['left', 'center', 'right'])
                ChoiceChip(
                  label: Text(a == 'left' ? '左' : a == 'center' ? '中' : '右'),
                  selected: align == a,
                  onSelected: (_) => setC(() => align = a),
                ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                c.text = textCtrl.text;
                c.align = align;
                Navigator.pop(ctx, true);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) setState(() {});
  }

  Future<void> _addComp() async {
    final type = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('添加组件'),
        children: [
          for (final e in _typeNames.entries)
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, e.key), child: Text(e.value, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
    if (type == null) return;
    setState(() => _cur.comps.add(TmplComp(type: type)));
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('对账单模板'),
        actions: [
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
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
                        _contentCtrl.text = _cur.content;
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'comps', label: Text('组件模板')),
                      ButtonSegment(value: 'grid', label: Text('网格模板')),
                      ButtonSegment(value: 'content', label: Text('自定义正文')),
                    ],
                    selected: {_tab},
                    onSelectionChanged: (s) => setState(() => _tab = s.first),
                  ),
                ),
              ),
              Expanded(
                child: _tab == 'content'
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: TextField(
                          controller: _contentCtrl,
                          maxLines: null,
                          expands: true,
                          textAlignVertical: TextAlignVertical.top,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            hintText: '留空 = 用组件模板；或写正文（可含变量：{店铺}{账期}{日期}{出货合计}{期末欠款}{明细}{1日}…{31日}）',
                          ),
                        ),
                      )
                    : _tab == 'grid'
                        ? _gridEditor(c) // PlutoGrid 自带滚动，需 Expanded 高度
                        : SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: _compsEditor(c),
                          ),
              ),
            ]),
    );
  }

  Widget _compsEditor(TaozhuColors c) {
    final cur = _cur;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      OutlinedButton.icon(
          icon: const Icon(Icons.add, size: 16), label: const Text('添加组件'), onPressed: _addComp),
      const SizedBox(height: 8),
      for (var i = 0; i < cur.comps.length; i++)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
              color: c.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.divider)),
          child: Row(children: [
            Expanded(
              child: InkWell(
                onTap: () => _configComp(i),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${i + 1}. ${_typeNames[cur.comps[i].type] ?? cur.comps[i].type}',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textMain)),
                  if (cur.comps[i].text.isNotEmpty)
                    Text('${cur.comps[i].text}', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: c.textSub)),
                ]),
              ),
            ),
            IconButton(iconSize: 18, icon: const Icon(Icons.arrow_upward), onPressed: () => setState(() => _moveComp(i, -1))),
            IconButton(iconSize: 18, icon: const Icon(Icons.arrow_downward), onPressed: () => setState(() => _moveComp(i, 1))),
            IconButton(iconSize: 18, icon: const Icon(Icons.close), onPressed: () => setState(() => cur.comps.removeAt(i))),
          ]),
        ),
    ]);
  }

  Widget _gridEditor(TaozhuColors c) {
    final cur = _cur;
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
          Text('双击单元格编辑；表格底部「+」追加行；保存时写回模板',
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

/// 轻量 toast（页面内提示，避免依赖全局 toast 上下文差异）
void _pageToast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
}