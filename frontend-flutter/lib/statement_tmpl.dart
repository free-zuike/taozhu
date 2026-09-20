/// 对账单模板公共库：数据模型（XlsCfg/GridCell/TmplComp）+ 纯渲染（组件/网格/正文 → 行集合）+ 模板存储。
/// 与具体页面解耦（不依赖 State），交易页/对账单页/独立模板设置页共用；渲染纯函数便于测试。
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 网格单元格：文本（可含 {变量} 占位）+ 对齐（left/center/right）+ 样式（bold 加粗 / bg 底纹色名）
class GridCell {
  GridCell([this.text = '', this.align = 'left', this.bold = false, this.bg = '']);
  String text;
  String align;
  bool bold;
  String bg; // 底纹色名：'grey'=浅灰（表头用）；空=无底纹
  Map<String, dynamic> toJson() => {'t': text, 'a': align, 'b': bold, 'g': bg};
  GridCell.fromJson(Map<String, dynamic> j)
      : text = '${j['t'] ?? ''}',
        align = '${j['a'] ?? 'left'}',
        bold = j['b'] == true,
        bg = '${j['g'] ?? ''}';
}

/// 模板组件（组件式设计器）：按顺序渲染成表格块
/// type：title=标题 | fields=信息字段（店铺/账期/日期）| stats=统计（出货/收款/欠款）
///       days=按日金额表（1-31 日逐行，自动当月天数）| detail=出货明细表 | text=自定义文本（可含变量）
class TmplComp {
  TmplComp({this.type = 'text', this.text = '', this.align = 'left'});
  String type;
  String text;
  String align; // left | center | right
  Map<String, dynamic> toJson() => {'t': type, 'x': text, 'a': align};
  TmplComp.fromJson(Map<String, dynamic> j)
      : type = '${j['t'] ?? 'text'}',
        text = '${j['x'] ?? ''}',
        align = '${j['a'] ?? 'left'}';
}

/// 对账单排版模板（前端自定义，本机持久化）
class XlsCfg {
  XlsCfg();

  String name = '标准';
  String title = '陶朱对账单';
  /// 模板正文（支持变量占位：{店铺}{账期}{日期}{出货合计}{收款合计}{期末欠款}{出货笔数}{明细}{旬段表}{1日}…{31日}）
  String content = '';
  /// Excel 式网格模板（行×列单元格 + 对齐）
  List<List<GridCell>> grid = [];
  /// 每列对齐（网格模式渲染优先于单元格自身 align；空=用单元格 align）
  List<String> colAligns = [];
  /// 组件式模板（有序组件列表；渲染优先级：comps > grid > content > 默认 fields+days）
  List<TmplComp> comps = [];
  // 旧版结构化字段（兼容旧模板数据；新渲染不再使用）
  bool headClient = true;
  bool headPeriod = true;
  bool headSaleTotal = true;
  bool headPayTotal = true;
  bool headDebt = true;
  String mode = 'detail';
  bool colDate = true;
  bool colItem = true;
  bool colQty = true;
  bool colPrice = true;
  bool colAmount = true;

  Map<String, dynamic> toJson() => {
        'name': name,
        'title': title,
        'content': content,
        'grid': [
          for (final row in grid) [for (final c in row) c.toJson()],
        ],
        'colAligns': colAligns,
        'comps': [for (final c in comps) c.toJson()],
        'headClient': headClient,
        'headPeriod': headPeriod,
        'headSaleTotal': headSaleTotal,
        'headPayTotal': headPayTotal,
        'headDebt': headDebt,
        'mode': mode,
        'colDate': colDate,
        'colItem': colItem,
        'colQty': colQty,
        'colPrice': colPrice,
        'colAmount': colAmount,
      };

  XlsCfg.fromJson(Map<String, dynamic> j) {
    name = '${j['name'] ?? '标准'}';
    title = '${j['title'] ?? '陶朱对账单'}';
    content = '${j['content'] ?? ''}';
    final rawGrid = j['grid'];
    if (rawGrid is List) {
      grid = [
        for (final row in rawGrid)
          [
            for (final c in (row as List? ?? []))
              if (c is Map) GridCell.fromJson(Map<String, dynamic>.from(c)),
          ],
      ];
    }
    final rawComps = j['comps'];
    if (rawComps is List) {
      comps = [
        for (final c in rawComps)
          if (c is Map) TmplComp.fromJson(Map<String, dynamic>.from(c)),
      ];
    }
    colAligns = [for (final a in (j['colAligns'] as List? ?? [])) '${a ?? 'left'}'];
    headClient = j['headClient'] != false;
    headPeriod = j['headPeriod'] != false;
    headSaleTotal = j['headSaleTotal'] != false;
    headPayTotal = j['headPayTotal'] != false;
    headDebt = j['headDebt'] != false;
    mode = '${j['mode'] ?? 'detail'}';
    colDate = j['colDate'] != false;
    colItem = j['colItem'] != false;
    colQty = j['colQty'] != false;
    colPrice = j['colPrice'] != false;
    colAmount = j['colAmount'] != false;
  }

  XlsCfg copy() => XlsCfg.fromJson(toJson());
}

/// 渲染输入（对账单数据快照）：由调用方（页面 State 或 Web 直连）提供
class TemplateData {
  TemplateData({
    required this.sales,
    this.payments = const [],
    required this.from,
    required this.to,
    required this.clientName,
    this.debtEnd = 0,
  });
  final List<Map<String, dynamic>> sales;
  final List<Map<String, dynamic>> payments;
  final String from;
  final String to;
  final String clientName;
  final double debtEnd;
}

// ── 渲染（纯函数，无 Flutter 依赖，可测试）─────────────────────────────

String _date(Object? v) {
  final s = '$v';
  return s.length >= 10 ? s.substring(0, 10) : s;
}

double _num(Object? v) {
  final n = v is num ? v.toDouble() : double.tryParse('$v');
  return n ?? 0;
}

/// 出货明细行（每件商品一行）与销售额合计（{明细} 与 明细表组件用）
List<List<String>> _detailLines(TemplateData d) {
  final out = <List<String>>[];
  for (final s in d.sales) {
    final orderDate = _date(s['happened_at']);
    final items = ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    if (items.isEmpty) {
      final note = '${s['note'] ?? ''}'.trim();
      out.add([
        orderDate,
        note.isEmpty ? '（无明细）' : note,
        '',
        '¥${(_num(s['total']) * 100).round() / 100}',
      ]);
      continue;
    }
    for (final it in items) {
      final id = '${it['happened_at'] ?? ''}';
      final dstr = id.length >= 10 ? id.substring(0, 10) : orderDate;
      out.add([
        dstr,
        '${it['item_name'] ?? ''}',
        '${it['quantity'] ?? ''}${it['unit'] ?? ''}',
        '¥${((_num(it['amount']) * 100).round()) / 100}',
      ]);
    }
  }
  return out;
}

/// 出货按日聚合（from 所在月 1..月末，无数据日=0）——({days: List<double>, total: double})
({List<double> days, double total}) _dailyOf(TemplateData d) {
  final y = int.tryParse(d.from.length >= 7 ? d.from.substring(0, 4) : '') ?? DateTime.now().year;
  final m = int.tryParse(d.from.length >= 7 ? d.from.substring(5, 7) : '') ?? DateTime.now().month;
  final daysInMonth = DateTime(y, m + 1, 0).day;
  final arr = List<double>.filled(daysInMonth, 0);
  double total = 0;
  for (final s in d.sales) {
    final orderDate = _date(s['happened_at']);
    for (final it in ((s['items'] as List?) ?? []).cast<Map<String, dynamic>>()) {
      final id = '${it['happened_at'] ?? ''}';
      final dd = id.length >= 10 ? id.substring(0, 10) : orderDate;
      if (dd.length < 10) continue;
      final dy = int.tryParse(dd.substring(0, 4)) ?? 0;
      final dm = int.tryParse(dd.substring(5, 7)) ?? 0;
      if (dy != y || dm != m) continue;
      final day = int.tryParse(dd.substring(8, 10)) ?? 1;
      if (day < 1 || day > daysInMonth) continue;
      final v = _num(it['amount']);
      arr[day - 1] += v;
      total += v;
    }
  }
  return (days: arr, total: total);
}

String _fmtMoney(double v) => '¥${((v * 100).round()) / 100}';

/// 单文本变量替换（{店铺}{账期}{日期}{出货合计}{收款合计}{期末欠款}{出货笔数} + {N日}）
String _replaceVars(String text, TemplateData d) {
  final now = DateTime.now();
  final today = '${now.year}年${now.month}月${now.day}日';
  double saleTotal = 0;
  for (final s in d.sales) {
    saleTotal += _num(s['total']);
  }
  var line = text
      .replaceAll('{店铺}', d.clientName)
      .replaceAll('{账期}', '${d.from} 至 ${d.to}')
      .replaceAll('{年}', '${now.year}')
      .replaceAll('{月}', '${now.month}')
      .replaceAll('{日}', '${now.day}')
      .replaceAll('{日期}', today)
      .replaceAll('{出货合计}', _fmtMoney(saleTotal))
      .replaceAll('{收款合计}', _fmtMoney(d.payments.fold<double>(0, (a, p) => a + _num(p['amount']) + _num(p['waived']))))
      .replaceAll('{期末欠款}', _fmtMoney(d.debtEnd))
      .replaceAll('{出货笔数}', '${d.sales.length}');
  final daily = _dailyOf(d).days;
  for (var dd = 1; dd <= daily.length; dd++) {
    line = line.replaceAll('{$dd日}', _fmtMoney(daily[dd - 1]));
  }
  return line;
}

/// 模板统一渲染入口：comps → grid → content → 默认（fields+days）
/// 返回表格行集合（每行 = 单元格列表）；预览/导出/打印共用。
List<List<GridCell>> renderTemplateRows(XlsCfg cfg, TemplateData d) {
  if (cfg.comps.isNotEmpty) return _renderComps(cfg, d);
  if (cfg.grid.isNotEmpty) return _renderGrid(cfg, d);
  if (cfg.content.trim().isNotEmpty) {
    final day = _dailyOf(d);
    return [
      for (final raw in cfg.content.split('\n'))
        [GridCell(_replaceContentLine(raw, d, day), 'left')],
    ];
  }
  // 默认模板：标题 + 信息字段 + 按日金额表（对应"标准"模板）
  final fallback = XlsCfg()
    ..comps = [
      TmplComp(type: 'title', text: cfg.title.isEmpty ? '对账单' : cfg.title, align: 'center'),
      TmplComp(type: 'fields'),
      TmplComp(type: 'days'),
    ];
  return _renderComps(fallback, d);
}

/// 正文行渲染（含 {明细}/{旬段表} 特殊块）
String _replaceContentLine(String raw, TemplateData d, ({List<double> days, double total}) day) {
  var line = _replaceVars(raw, d);
  if (line.contains('{明细}')) {
    final items = _detailLines(d);
    line = line.replaceAll('{明细}',
        items.isEmpty ? '（本期无出货明细）' : items.map((r) => r.join(' ')).join('\n'));
  }
  if (line.contains('{旬段表}')) {
    double total = 0;
    final parts = <String>[];
    for (var i = 0; i < day.days.length; i++) {
      total += day.days[i];
      if (day.days[i] != 0 || parts.isEmpty) {
        parts.add('${i + 1}日 ${_fmtMoney(day.days[i])}');
      }
    }
    parts.add('总计 ${_fmtMoney(total)}');
    line = line.replaceAll('{旬段表}', parts.join('、'));
  }
  return line;
}

/// 多栏月账单（寻牛记式）：一个自然月按每栏 N 天分栏（默认 10 天/栏，31 天→4 栏），
/// 每栏两列「日期 营业额」逐日平铺、栏底小计、底部总计。日期格式 2026.8.1，金额纯数字两位。
List<List<GridCell>> _multiColBill(TemplateData d, {int perCol = 10}) {
  final daily = _dailyOf(d).days;
  final n = daily.length;
  final cols = (n + perCol - 1) ~/ perCol;
  final y = int.tryParse(d.from.length >= 4 ? d.from.substring(0, 4) : '') ?? DateTime.now().year;
  final m = int.tryParse(d.from.length >= 7 ? d.from.substring(5, 7) : '') ?? DateTime.now().month;
  final rows = <List<GridCell>>[
    // 标题（店铺 + N月账单，居中加粗）
    [GridCell('${d.clientName}${m}月账单', 'center', true)],
    // 表头：每栏「日期 营业额」加粗底纹
    [
      for (var cc = 0; cc < cols; cc++) ...[
        GridCell('日期', 'center', true, 'grey'),
        GridCell('营业额', 'center', true, 'grey'),
      ],
    ],
  ];
  for (var r = 0; r < perCol; r++) {
    final line = <GridCell>[];
    for (var cc = 0; cc < cols; cc++) {
      final day = cc * perCol + r + 1;
      if (day <= n) {
        line.add(GridCell('$y.$m.$day', 'center'));
        line.add(GridCell(daily[day - 1].toStringAsFixed(2), 'right'));
      } else {
        line.add(GridCell('', 'center'));
        line.add(GridCell('', 'right'));
      }
    }
    rows.add(line);
  }
  // 栏底小计（用户示例：每栏营业额列下放金额，日期列留空；加粗）
  final subtotal = <GridCell>[];
  double grand = 0;
  for (var cc = 0; cc < cols; cc++) {
    double s = 0;
    for (var dd = cc * perCol; dd < (cc + 1) * perCol && dd < n; dd++) {
      s += daily[dd];
    }
    grand += s;
    subtotal.add(GridCell('', 'right', true));
    subtotal.add(GridCell(s.toStringAsFixed(2), 'right', true));
  }
  rows.add(subtotal);
  // 底部总计（跨栏，示例「总计 41349.81」尾部对齐；加粗）
  rows.add([
    GridCell('总计', 'right', true),
    for (var cc = 0; cc < cols * 2 - 2; cc++) GridCell('', ''),
    GridCell(grand.toStringAsFixed(2), 'right', true),
  ]);
  return rows;
}

List<List<GridCell>> _renderGrid(XlsCfg cfg, TemplateData d) {
  final out = <List<GridCell>>[];
  for (final row in cfg.grid) {
    // {月账单} 单元格 → 整行展开为多栏月账单
    if (row.any((c) => c.text.contains('{月账单}'))) {
      out.addAll(_multiColBill(d));
      continue;
    }
    out.add([
      for (var cc = 0; cc < row.length; cc++)
        GridCell(
          _replaceVars(row[cc].text, d),
          cc < cfg.colAligns.length && cfg.colAligns[cc].isNotEmpty ? cfg.colAligns[cc] : row[cc].align,
          row[cc].bold,
          row[cc].bg,
        ),
    ]);
  }
  return out;
}

List<List<GridCell>> _renderComps(XlsCfg cfg, TemplateData d) {
  final now = DateTime.now();
  final today = '${now.year}年${now.month}月${now.day}日';
  final rows = <List<GridCell>>[];
  double saleTotal = 0;
  for (final s in d.sales) {
    saleTotal += _num(s['total']);
  }
  final payTotal = d.payments.fold<double>(0, (a, p) => a + _num(p['amount']) + _num(p['waived']));
  final daily = _dailyOf(d);
  for (final c in cfg.comps) {
    switch (c.type) {
      case 'title':
        rows.add([GridCell(_replaceVars(c.text.isEmpty ? '对账单' : c.text, d), c.align)]);
        break;
      case 'fields':
        rows.add([GridCell('店铺：${d.clientName}', 'left')]);
        rows.add([GridCell('账期：${d.from} 至 ${d.to}', 'left')]);
        rows.add([GridCell('日期：$today', 'left')]);
        break;
      case 'stats':
        rows.add([
          GridCell('出货合计\n${_fmtMoney(saleTotal)}', 'center'),
          GridCell('收款合计\n${_fmtMoney(payTotal)}', 'center'),
          GridCell('期末欠款\n${_fmtMoney(d.debtEnd)}', 'center'),
        ]);
        break;
      case 'days':
        rows.add([GridCell('日期', 'center'), GridCell('销售额', 'center')]);
        double total = 0;
        for (var i = 0; i < daily.days.length; i++) {
          final v = daily.days[i];
          total += v;
          rows.add([GridCell('${i + 1}日', 'left'), GridCell(_fmtMoney(v), 'right')]);
        }
        rows.add([GridCell('总计', 'right'), GridCell(_fmtMoney(total), 'right')]);
        break;
      case 'multi': // 多栏月账单（寻牛记式）
        rows.addAll(_multiColBill(d));
        break;
      case 'detail':
        rows.add([
          GridCell('日期', 'center'),
          GridCell('商品', 'center'),
          GridCell('数量', 'center'),
          GridCell('金额', 'center'),
        ]);
        for (final r in _detailLines(d)) {
          rows.add([
            GridCell(r[0], 'left'),
            GridCell(r[1], 'left'),
            GridCell(r[2], 'center'),
            GridCell(r[3], 'right'),
          ]);
        }
        break;
      default: // text
        for (final ln in _replaceVars(c.text, d).split('\n')) {
          rows.add([GridCell(ln, c.align)]);
        }
    }
  }
  return rows;
}

// ── 模板存储（SharedPreferences，跨页面共用）─────────────────────────

Future<List<XlsCfg>> loadTemplates({String? preferred}) async {
  final p = await SharedPreferences.getInstance();
  final raw = p.getString('taozhu_stmt_templates');
  if (raw != null && raw.isNotEmpty) {
    final list = (jsonDecode(raw) as List? ?? [])
        .whereType<Map>()
        .map((e) => XlsCfg.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    // 清洗空模板（旧版残留：grid/comps/content 全空 → 渲染出只有边框的空表格=预览灰色）。
    // 保留有效模板；全空时返回内置默认（标题+多栏月账单），保证列表第一条必有内容。
    final valid = list.where(_hasContent).toList();
    if (valid.isNotEmpty) return valid;
  }
  // 兼容旧单模板存储
  final old = p.getString('taozhu_stmt_xls_cfg');
  if (old != null && old.isNotEmpty) {
    try {
      final cfg = XlsCfg.fromJson(jsonDecode(old) as Map<String, dynamic>);
      if (_hasContent(cfg)) return [cfg..name = '标准', _periodTemplate()];
    } catch (_) {}
  }
  return [_defaultTemplate(), _periodTemplate()];
}

/// 模板是否含可渲染内容（grid 有非空文本 或 comps 非空 或 content 非空）
bool _hasContent(XlsCfg t) {
  if (t.comps.isNotEmpty || t.content.trim().isNotEmpty) return true;
  for (final row in t.grid) {
    for (final c in row) {
      if (c.text.trim().isNotEmpty) return true;
    }
  }
  return false;
}

/// 内置默认模板（网格式，开箱即用）：标题 + 多栏月账单（对齐用户常见账单版式）
/// 标题（店铺+年月账单，居中加粗）+ {月账单} 一键生成日期×营业额 4 栏 + 小计 + 总计
XlsCfg _defaultTemplate() => XlsCfg()
  ..name = '标准'
  ..grid = [
    [GridCell('{店铺}{年}年{月}月份账单', 'center', true)],
    [GridCell('{月账单}', '')],
  ];

/// 内置按日汇总模板（网格式）：标题 + 多栏月账单
XlsCfg _periodTemplate() => XlsCfg()
  ..name = '按日汇总'
  ..grid = [
    [GridCell('对账单', 'center', true)],
    [GridCell('{店铺}　{账期}', 'center')],
    [GridCell('{月账单}', '')],
  ];

Future<void> saveTemplates(List<XlsCfg> templates, String currentName) async {
  final p = await SharedPreferences.getInstance();
  await p.setString('taozhu_stmt_templates',
      jsonEncode([for (final t in templates) t.toJson()]));
  await p.setString('taozhu_stmt_xls_name', currentName);
}