/// 对账单模板公共库：数据模型（XlsCfg/GridCell/TmplComp）+ 纯渲染（组件/网格/正文 → 行集合）+ 模板存储。
/// 与具体页面解耦（不依赖 State），交易页/对账单页/独立模板设置页共用；渲染纯函数便于测试。
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 网格单元格：文本（可含 {变量} 占位）+ 对齐（left/center/right）+ 样式（bold 加粗 / bg 底纹色名）
/// + 合并（rowSpan/colSpan：>1 表示该格为合并区起点，向右/向下覆盖；被覆盖的格子 text 置空）
/// + 边框（top/right/bottom/left：每一侧可独立开关——Excel 式逐格设置线）
class GridCell {
  GridCell([this.text = '', this.align = 'left', this.bold = false, this.bg = '', this.rowSpan = 1, this.colSpan = 1,
      this.borderTop = true, this.borderRight = true, this.borderBottom = true, this.borderLeft = true]);
  String text;
  String align;
  bool bold;
  String bg; // 底纹色名：'grey'=浅灰（表头用）；空=无底纹
  int rowSpan; // 跨行数（1=不跨）
  int colSpan; // 跨列数（1=不跨）
  bool borderTop; // 上边框（true=有线）
  bool borderRight; // 右边框
  bool borderBottom; // 下边框
  bool borderLeft; // 左边框
  Map<String, dynamic> toJson() => {
        't': text, 'a': align, 'b': bold, 'g': bg, 'rs': rowSpan, 'cs': colSpan,
        'bt': borderTop, 'br': borderRight, 'bb': borderBottom, 'bl': borderLeft,
      };
  GridCell.fromJson(Map<String, dynamic> j)
      : text = '${j['t'] ?? ''}',
        align = '${j['a'] ?? 'left'}',
        bold = j['b'] == true,
        bg = '${j['g'] ?? ''}',
        rowSpan = (j['rs'] as num?)?.toInt() ?? 1,
        colSpan = (j['cs'] as num?)?.toInt() ?? 1,
        borderTop = j['bt'] != false,
        borderRight = j['br'] != false,
        borderBottom = j['bb'] != false,
        borderLeft = j['bl'] != false;
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
    this.roundMode = false,
  });
  final List<Map<String, dynamic>> sales;
  final List<Map<String, dynamic>> payments;
  final String from;
  final String to;
  final String clientName;
  final double debtEnd;
  /// true=逐步舍入（每笔先按分舍入再累加，与账本/欠款口径一致）；false=原始金额直接累加。
  /// 合计/每日销售额/明细金额都跟随此口径（用户"合计口径切换逐步舍入或者原始金额，下边显示也要跟随"）
  final bool roundMode;
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

/// 按 TemplateData.roundMode 舍入（逐步舍入=每笔先按分舍入；原始金额直接取值）
double _roundVal(TemplateData d, double v) {
  if (d.roundMode) return ((v * 100).round()) / 100;
  return v;
}

/// 出货按日聚合（from 所在月 1..月末，无数据日=0）——({days: List<double>, total: double})
/// 金额口径跟随 d.roundMode（逐步舍入 vs 原始金额，用户联动要求）
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
      final v = _roundVal(d, _num(it['amount']));
      arr[day - 1] += v;
      total += v;
    }
  }
  return (days: arr, total: total);
}

String _fmtMoney(double v) => '¥${((v * 100).round()) / 100}';

/// 单文本变量替换（{店铺}{账期}{日期}{出货合计}{收款合计}{期末欠款}{出货笔数}{月合计} + {N日}/{N日销售额}）
/// 函数式变量（自动计算）：出货合计/收款合计/期末欠款/月合计/出货笔数；每日销售额 {1日}…{31日} 与可读别名 {1日销售额}…
String _replaceVars(String text, TemplateData d) {
  final now = DateTime.now();
  final today = '${now.year}年${now.month}月${now.day}日';
  // 账单月份 = 数据区间 from 的月份（用户"店铺 x月份账单"标题跟随所选账期的年月，非当前自然月）
  final fromY = int.tryParse(d.from.length >= 4 ? d.from.substring(0, 4) : '') ?? now.year;
  final fromM = int.tryParse(d.from.length >= 7 ? d.from.substring(5, 7) : '') ?? now.month;
  double saleTotal = 0;
  for (final s in d.sales) {
    saleTotal += _roundVal(d, _num(s['total']));
  }
  final daily = _dailyOf(d);
  final payTotal = d.payments.fold<double>(0, (a, p) => a + _roundVal(d, _num(p['amount']) + _num(p['waived'])));
  var line = text
      .replaceAll('{店铺}', d.clientName)
      .replaceAll('{账期}', '${d.from} 至 ${d.to}')
      .replaceAll('{年}', '${fromY}')
      .replaceAll('{月}', '${fromM}')
      .replaceAll('{日}', '${now.day}')
      .replaceAll('{日期}', today)
      .replaceAll('{出货合计}', _fmtMoney(saleTotal))
      .replaceAll('{收款合计}', _fmtMoney(payTotal))
      .replaceAll('{期末欠款}', _fmtMoney(d.debtEnd))
      .replaceAll('{出货笔数}', '${d.sales.length}')
      .replaceAll('{月合计}', _fmtMoney(daily.total));
  for (var dd = 1; dd <= 31; dd++) {
    // 超出当月天数（如 9 月 30 天时 31 日）→ 替换为空串，杜绝字面 {31日销售额} 残留
    // （用户"9月直接显示文字"——31日替换不到；按实际月份不显示）
    final val = dd <= daily.days.length ? _fmtMoney(daily.days[dd - 1]) : '';
    line = line
        .replaceAll('{$dd日}', val)
        .replaceAll('{$dd日销售额}', val);
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
/// [withTitle] 是否自带标题行——{月账单} 位于模板首行时自带「店铺 x月份账单」；
/// 模板已在 {月账单} 上方放了标题行（对账单头）时不重复，由模板行提供标题。
List<List<GridCell>> _multiColBill(TemplateData d, {int perCol = 10, bool withTitle = true}) {
  final daily = _dailyOf(d).days;
  final n = daily.length;
  final cols = (n + perCol - 1) ~/ perCol;
  final y = int.tryParse(d.from.length >= 4 ? d.from.substring(0, 4) : '') ?? DateTime.now().year;
  final m = int.tryParse(d.from.length >= 7 ? d.from.substring(5, 7) : '') ?? DateTime.now().month;
  final rows = <List<GridCell>>[
    if (withTitle)
      // 标题（店铺 + N月份账单，居中加粗）
      [GridCell('${d.clientName}${m}月份账单', 'center', true)],
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
  // 底部总计（跨栏，示例「总计 41349.81」尾部对齐；加粗；「总计」标签居中美观）
  rows.add([
    GridCell('总计', 'center', true),
    for (var cc = 0; cc < cols * 2 - 2; cc++) GridCell('', ''),
    GridCell(grand.toStringAsFixed(2), 'right', true),
  ]);
  return rows;
}

List<List<GridCell>> _renderGrid(XlsCfg cfg, TemplateData d) {
  final out = <List<GridCell>>[];
  final daily = _dailyOf(d);
  for (var ri = 0; ri < cfg.grid.length; ri++) {
    final row = cfg.grid[ri];
    // {月账单} 单元格 → 整行展开为多栏月账单
    if (row.any((c) => c.text.contains('{月账单}'))) {
      // {月账单} 在模板首行（全模板仅此一行内容）→ 自带标题行「店铺 x月份账单」；
      // 模板已在 {月账单} 上方放标题行（对账单头）→ 不重复，标题由模板行提供（用户"头部一行"）
      final onlyRow = cfg.grid.length <= 1;
      out.addAll(_multiColBill(d, withTitle: onlyRow));
      continue;
    }
    // 每日行按实际月份裁剪：行内 {N日销售额} 的 N 全部超出当月天数（如 9 月 30 天 → 31 日行）→ 整行不渲染
    // （用户"9月直接显示文字"/按实际月份不显示——否则 {31日销售额} 替换为空后日期格还在=多一行空表）
    final dayNs = <int>[];
    for (final c in row) {
      for (final m in RegExp(r'\{(\d{1,2})日销售额\}').allMatches(c.text)) {
        dayNs.add(int.tryParse(m.group(1)!) ?? 0);
      }
    }
    if (dayNs.isNotEmpty && dayNs.every((n) => n > daily.days.length)) continue;
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
    saleTotal += _roundVal(d, _num(s['total']));
  }
  final payTotal = d.payments.fold<double>(0, (a, p) => a + _roundVal(d, _num(p['amount']) + _num(p['waived'])));
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
    // 内置模板内容演进迁移（2026-10-08）：旧「标准」=标题行+{月账单}、旧「按日汇总」=对账单头部+{月账单}
    // 2026-10-10 用户定稿：头部只要一行「店铺X月份账单」+表格，不要重复标题行——内置模板统一为
    // 展开网格（标题行 + 每日/多栏 + 合计），不再用 {月账单} 宏。仍是内置名的旧结构才迁移，
    // 用户改过的自定义内容不碰；旧「按日汇总」与「标准」同形 → 移除（用户"去掉重复"）。
    var migrated = false;
    final kept = <XlsCfg>[];
    for (final t in list) {
      if (t.name == '按日汇总' && t.comps.isEmpty && t.content.trim().isEmpty) {
        migrated = true; // 内置按日汇总已与标准合并，跳过（用户自定义过的按日汇总保留）
        continue;
      }
      if (t.comps.isNotEmpty || t.content.trim().isNotEmpty || t.grid.isEmpty) {
        kept.add(t);
        continue;
      }
      final first = t.grid[0].isNotEmpty ? t.grid[0][0].text : '';
      if (t.name == '标准' && first.contains('月份账单')) {
        t.grid = _defaultTemplate().grid;
        migrated = true;
      } else if (t.name == '标准' && t.grid.length <= 1 && first.contains('{月账单}')) {
        t.grid = _defaultTemplate().grid;
        migrated = true;
      } else if (t.name == '标准' && first.contains('对账单') &&
          t.grid.length > 1 && t.grid[1].any((c) => c.text.contains('{月账单}'))) {
        // 旧「标准」=店铺名+对账单 头部行 + {月账单}（用户实存"寻牛 对账单 / {月账单}"双标题）
        // → 展开为内置标准网格（标题用变量，去掉写死的店名头部=只留一行头部）
        t.grid = _defaultTemplate().grid;
        migrated = true;
      }
      kept.add(t);
    }
    // 内置模板始终合并进列表（用户旧缓存缺「标准」/「多栏」时补回——否则新模板不显示）：
    // 已存在同名内置模板（含用户编辑过的）不覆盖，用户自定义模板保留
    final names = kept.map((t) => t.name).toSet();
    if (!names.contains('标准')) {
      kept.insert(0, _defaultTemplate());
      migrated = true;
    }
    if (!names.contains('多栏')) {
      kept.add(_multiColTemplate());
      migrated = true;
    }
    if (migrated) {
      await p.setString('taozhu_stmt_templates', jsonEncode([for (final t in kept) t.toJson()]));
    }
    // 清洗空模板（旧版残留：grid/comps/content 全空 → 渲染出只有边框的空表格=预览灰色）。
    // 保留有效模板；全空时返回内置默认（标题+多栏月账单），保证列表第一条必有内容。
    final valid = kept.where(_hasContent).toList();
    if (valid.isNotEmpty) return valid;
  }
  // 兼容旧单模板存储
  final old = p.getString('taozhu_stmt_xls_cfg');
  if (old != null && old.isNotEmpty) {
    try {
      final cfg = XlsCfg.fromJson(jsonDecode(old) as Map<String, dynamic>);
      if (_hasContent(cfg)) {
        final upgraded = cfg.copy()
          ..name = '标准'
          ..grid = _defaultTemplate().grid;
        return [upgraded, _multiColTemplate()];
      }
    } catch (_) {}
  }
  return [_defaultTemplate(), _multiColTemplate()];
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

/// 公开访问：内置「标准」模板的展开网格（模板编辑器新建空模板时开箱即用）
List<List<GridCell>> defaultTemplateGrid() => _defaultTemplate().grid;

/// 内置模板（网格式，所见即所得）：不再用 {月账单} 宏占位——直接存展开的完整网格
/// （标题行 + 表头 + 每日行 + 合计行），编辑时看到的就是实际表格，每格可改/可设边框，方便自定义其他模板。
/// 「标准」= 单栏逐日表：标题「{店铺} {月}月份账单」+ 日期/营业额表头 + 1..31 日逐行 + 合计行。
XlsCfg _defaultTemplate() => XlsCfg()
  ..name = '标准'
  ..grid = [
    // 标题行：colSpan=2 合并整行居中（用户"合并居中就是标题行"——否则只占首列宽度看似偏左）
    [GridCell('{店铺} {月}月份账单', 'center', true, 'grey', 1, 2)],
    [GridCell('日期', 'center', true, 'grey'), GridCell('营业额', 'center', true, 'grey')],
    // 日期格用 $d 构建时插值（{月} 是渲染时替换的模板变量；$d = 1日/2日… 固定数字，不是变量）
    for (var d = 1; d <= 31; d++)
      [GridCell('{月}月$d日', 'center'), GridCell('{$d日销售额}', 'right')],
    [GridCell('合计', 'right', true, 'grey'), GridCell('{月合计}', 'right', true, 'grey')],
  ];

/// 「多栏」= 多栏月账单（寻牛记式：每栏 10 天 × 4 栏），同样展开为可编辑网格。
XlsCfg _multiColTemplate() => XlsCfg()
  ..name = '多栏'
  ..grid = [
    // 标题行：colSpan=8 跨全部 4 栏×2 列合并居中（用户"合并居中就是标题行"）
    [GridCell('{店铺} {月}月份账单', 'center', true, 'grey', 1, 8)],
    [
      for (var cc = 0; cc < 4; cc++) ...[
        GridCell('日期', 'center', true, 'grey'),
        GridCell('营业额', 'center', true, 'grey'),
      ],
    ],
    for (var r = 0; r < 10; r++)
      [
        for (var cc = 0; cc < 4; cc++) ...[
          GridCell('{月}月${cc * 10 + r + 1}日', 'center'),
          GridCell('{${cc * 10 + r + 1}日销售额}', 'right'),
        ],
      ],
    [
      GridCell('总计', 'center', true, 'grey'),
      for (var i = 0; i < 6; i++) GridCell('', ''),
      GridCell('{月合计}', 'right', true, 'grey'),
    ],
  ];

Future<void> saveTemplates(List<XlsCfg> templates, String currentName) async {
  final p = await SharedPreferences.getInstance();
  await p.setString('taozhu_stmt_templates',
      jsonEncode([for (final t in templates) t.toJson()]));
  await p.setString('taozhu_stmt_xls_name', currentName);
}

/// 恢复出厂：清除全部用户模板缓存，回到内置「标准」「多栏」两个展开模板。
/// 用户之前改过/新建的模板全部丢弃（页面已弹确认）。
Future<List<XlsCfg>> resetTemplates() async {
  final p = await SharedPreferences.getInstance();
  await p.remove('taozhu_stmt_templates');
  await p.remove('taozhu_stmt_xls_cfg');
  await p.setString('taozhu_stmt_xls_name', '标准');
  return [_defaultTemplate(), _multiColTemplate()];
}