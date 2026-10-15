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
    this.debtUnit = '',
    this.roundMode = false,
    this.displayUnit = 'fen',
  });
  final List<Map<String, dynamic>> sales;
  final List<Map<String, dynamic>> payments;
  final String from;
  final String to;
  final String clientName;
  final double debtEnd;
  /// 期末欠款显示精度（店铺 round_unit：yuan/jiao/fen；空=fen 逐笔舍入到分）。
  /// 欠款按店铺抹零口径，显示按抹零精度（用户"欠款应显示整元而非到分"）。
  final String debtUnit;
  /// true=逐步舍入（每笔先按分舍入再累加，与账本/欠款口径一致）；false=原始金额直接累加。
  /// 合计/每日销售额/明细金额都跟随此口径（用户"合计口径切换逐步舍入或者原始金额，下边显示也要跟随"）
  final bool roundMode;
  /// 页面金额显示精度（店铺 round_unit：yuan/jiao/fen；空=fen 两位小数）。
  /// 对账单所有金额显示跟随（合计/每日/明细/小计/总计），仅显示精度不影响数值
  /// （用户"金额显示的位数需要和店铺管理中设置的对应"）。
  final String displayUnit;
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
        _fmtMoneyU(_num(s['total']), d.displayUnit),
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
        _fmtMoneyU(_num(it['amount']), d.displayUnit),
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

String _fmtMoney(double v) => '${((v * 100).round() / 100).toStringAsFixed(2)}';

/// 金额显示精度跟随店铺 round_unit（元=整元 0 位/角=1 位/分=2 位；空=分）。
/// 仅显示精度，不改变数值（合计仍按真实金额累加后四舍五入显示）。
/// 金额纯数字不带 ¥（用户"不需要显示金额符号￥，会显示不全"——模板内金额统一无符号）
String _fmtMoneyU(double v, String unit) {
  if (unit == 'yuan') return '${v.round()}';
  if (unit == 'jiao') return v.toStringAsFixed(1);
  return _fmtMoney(v);
}

/// 多栏月账单用纯数字金额（无 ¥，对齐用户示例「总计 41349.81」），精度同上
String _numU(double v, String unit) {
  if (unit == 'yuan') return '${v.round()}';
  if (unit == 'jiao') return v.toStringAsFixed(1);
  return ((v * 100).round() / 100).toStringAsFixed(2);
}

/// 单文本变量替换（{店铺}{账期}{日期}{出货合计}{收款合计}{期末欠款}{出货笔数}{月合计} + {N日}/{N日销售额}）
/// 函数式变量（自动计算）：出货合计/收款合计/期末欠款/月合计/出货笔数；每日销售额 {1日}…{31日} 与可读别名 {1日销售额}…
String _replaceVars(String text, TemplateData d) {
  final now = DateTime.now();
  // 日期点分格式（用户定稿"年月日改成 ."，示例 2026.10.16）
  final today = '${now.year}.${now.month}.${now.day}';
  // 账单月份 = 数据区间 from 的月份（用户"店铺 x月份账单"标题跟随所选账期的年月，非当前自然月）
  final fromY = int.tryParse(d.from.length >= 4 ? d.from.substring(0, 4) : '') ?? now.year;
  final fromM = int.tryParse(d.from.length >= 7 ? d.from.substring(5, 7) : '') ?? now.month;
  double saleTotal = 0;
  for (final s in d.sales) {
    saleTotal += _roundVal(d, _num(s['total']));
  }
  final daily = _dailyOf(d);
  final payTotal = d.payments.fold<double>(0, (a, p) => a + _roundVal(d, _num(p['amount']) + _num(p['waived'])));
  // 旬段小计（用户"1-10 的总金额、11-20 的总金额"）：{1-10日合计}{11-20日合计}{21日以后合计}
  final segSum = (int from, int to) {
    var s = 0.0;
    for (var i = from; i <= to && i <= daily.days.length; i++) s += daily.days[i - 1];
    return _fmtMoneyU(s, d.displayUnit);
  };
  var line = text
      .replaceAll('{店铺}', d.clientName)
      .replaceAll('{账期}', '${d.from} 至 ${d.to}')
      .replaceAll('{年}', '${fromY}')
      .replaceAll('{月}', '${fromM}')
      .replaceAll('{日}', '${now.day}')
      .replaceAll('{日期}', today)
      .replaceAll('{出货合计}', _fmtMoneyU(saleTotal, d.displayUnit))
      .replaceAll('{收款合计}', _fmtMoneyU(payTotal, d.displayUnit))
      .replaceAll('{期末欠款}', d.debtUnit == 'yuan' ? '${d.debtEnd.round()}' : (d.debtUnit == 'jiao' ? d.debtEnd.toStringAsFixed(1) : _fmtMoney(d.debtEnd)))
      .replaceAll('{出货笔数}', '${d.sales.length}')
      .replaceAll('{月合计}', _fmtMoneyU(daily.total, d.displayUnit))
      .replaceAll('{1-10日合计}', segSum(1, 10))
      .replaceAll('{11-20日合计}', segSum(11, 20))
      .replaceAll('{21-30日合计}', segSum(21, 30))
      .replaceAll('{21日以后合计}', segSum(21, 31));
  for (var dd = 1; dd <= 31; dd++) {
    // 超出当月天数（如 9 月 30 天时 31 日）→ 替换为空串，杜绝字面 {31日销售额} 残留
    // （用户"9月直接显示文字"——31日替换不到；按实际月份不显示）
    final val = dd <= daily.days.length ? _fmtMoneyU(daily.days[dd - 1], d.displayUnit) : '';
    line = line
        .replaceAll('{$dd日}', val)
        .replaceAll('{$dd日销售额}', val)
        // 日期格 {月}月N日（{月} 已替换为数字）→ 点分带年 2026.10.16（用户"年月日改成 ."）
        .replaceAll('${fromM}月$dd日', '${fromY}.${fromM}.$dd');
  }
  return line;
}

/// 模板统一渲染入口：comps → grid → content → 默认（fields+days）
/// 返回表格行集合（每行 = 单元格列表）；预览/导出/打印共用。
/// 统一后处理：标题去重（多余标题行自动去掉）+ 合计函数化（合计/总计行自动填月合计）。
/// [evalSum] 是否把 =sum(...) 公式求值为文本（预览/打印=true 显示值；导出 Excel=false 保留公式原文，
/// 由导出层写成公式单元格——用户"导出的 excel 合计应是公式不是死数字"）
List<List<GridCell>> renderTemplateRows(XlsCfg cfg, TemplateData d, {bool evalSum = true}) {
  List<List<GridCell>> rows;
  if (cfg.comps.isNotEmpty) {
    rows = _renderComps(cfg, d);
  } else if (cfg.grid.isNotEmpty) {
    rows = _renderGrid(cfg, d, evalSum: evalSum);
  } else if (cfg.content.trim().isNotEmpty) {
    final day = _dailyOf(d);
    rows = [
      for (final raw in cfg.content.split('\n'))
        [GridCell(_replaceContentLine(raw, d, day), 'left')],
    ];
  } else {
    // 默认模板：标题 + 信息字段 + 按日金额表（对应"标准"模板）
    final fallback = XlsCfg()
      ..comps = [
        TmplComp(type: 'title', text: cfg.title.isEmpty ? '对账单' : cfg.title, align: 'center'),
        TmplComp(type: 'fields'),
        TmplComp(type: 'days'),
      ];
    rows = _renderComps(fallback, d);
  }
  return _finalizeRows(rows, d);
}

/// 标题行判定：整行合并、居中加粗、文本含店铺/对账单/月份账单（渲染后用于去重多余标题）
bool _isTitleRow(List<GridCell> r) {
  if (r.length != 1) return false;
  final t = r.first.text.trim();
  return r.first.bold && r.first.align == 'center' &&
      (t.contains('对账单') || t.contains('月份账单') || t.contains('{店铺}'));
}

/// 渲染后统一处理：
/// ①标题去重（用户"还是2行标题/寻牛对账单去不掉"）：开头连续标题行只留一个（保留后出现的"店铺 N月份账单"）
/// ②合计兜底（用户"合计用函数而非 {月合计} 变量"）：模板已用 =sum(...) 时自动算好（见 _evalFormulas）；
///    仅当合计/总计标签行除标签外全空（旧模板/自定义未写公式）才补月合计。
List<List<GridCell>> _finalizeRows(List<List<GridCell>> rows, TemplateData d) {
  while (rows.length >= 2 && _isTitleRow(rows[0]) && _isTitleRow(rows[1])) {
    rows.removeAt(0);
  }
  final total = _fmtMoneyU(_dailyOf(d).total, d.displayUnit);
  for (final row in rows) {
    if (row.isEmpty) continue;
    final label = row.first.text.trim();
    if (label == '合计' || label == '总计') {
      // 行内除标签外已有内容（=sum 已算/自定义文本）→ 不覆盖；全空才补月合计
      final hasOther = row.skip(1).any((c) => c.text.trim().isNotEmpty);
      if (!hasOther) {
        for (final c in row) {
          if (c.text.trim().isEmpty) {
            c.text = total;
            break;
          }
        }
      }
    }
  }
  return rows;
}

// ── =sum(...) 单元格函数 ────────────────────────────────
// 用户"不要 {1-10日合计}/{月合计} 变量，要 =sum(b2,b11) 这种函数"：
// 模板合计格写 Excel 风格公式（大小写不敏感，支持逗号多参与 colon 区间），
// 渲染时按**模板坐标**（第 1 行=1，A 列=1）对变量替换后的文本求值填入。

/// 解析坐标引用（A1 → (0,0) 0基行/列）；非法返回 null
(int, int)? _coordOf(String ref) {
  final m = RegExp(r'^([a-z]+)(\d+)$', caseSensitive: false).firstMatch(ref);
  if (m == null) return null;
  var col = 0;
  for (final ch in m.group(1)!.toLowerCase().codeUnits) {
    col = col * 26 + (ch - 0x61 + 1);
  }
  return (int.parse(m.group(2)!) - 1, col - 1);
}

/// 文本 → 数值（千分位逗号/¥/元 前缀、空=0）；非数字返回 null
double? _numOf(String t) {
  final s = t.replaceAll(',', '').replaceAll('¥', '').replaceAll('元', '').trim();
  if (s.isEmpty) return 0;
  final n = double.tryParse(s);
  if (n == null) return null;
  return n;
}

/// 单格求值：普通文本 → 数值；=sum 公式 → 递归求值（visiting 防自引用环）
double? _cellValue(List<List<GridCell>> rows, int r, int c, Set<String> visiting, String unit) {
  if (r < 0 || r >= rows.length) return null;
  final row = rows[r];
  if (c < 0 || c >= row.length) return null;
  final key = '$r,$c';
  if (visiting.contains(key)) return null;
  final t = row[c].text.trim();
  if (t.isEmpty) return 0;
  if (t.startsWith('=')) {
    visiting.add(key);
    final ev = _evalFormula(t, rows, visiting, unit);
    visiting.remove(key);
    return _numOf(ev);
  }
  return _numOf(t);
}

/// 解析并求值 =sum(...)（逗号多参 + 冒号区间；其它函数/非法格式原样保留，不误导）
String _evalFormula(String text, List<List<GridCell>> rows, Set<String> visiting, String unit) {
  final m = RegExp(r'^=\s*([a-z]+)\s*\(([^)]*)\)\s*$', caseSensitive: false).firstMatch(text);
  if (m == null) return text;
  if (m.group(1)!.toLowerCase() != 'sum') return text;
  double total = 0;
  for (final part in m.group(2)!.split(',')) {
    final p = part.trim();
    if (p.isEmpty) continue;
    if (p.contains(':')) {
      final seg = p.split(':');
      if (seg.length != 2) return text;
      final a = _coordOf(seg[0]);
      final b = _coordOf(seg[1]);
      if (a == null || b == null) return text;
      for (var r = a.$1; r <= b.$1; r++) {
        for (var cc = a.$2; cc <= b.$2; cc++) {
          final v = _cellValue(rows, r, cc, visiting, unit);
          if (v == null) return text;
          total += v;
        }
      }
    } else {
      final c = _coordOf(p);
      if (c == null) return text;
      final v = _cellValue(rows, c.$1, c.$2, visiting, unit);
      if (v == null) return text;
      total += v;
    }
  }
  return _fmtMoneyU(total, unit);
}

/// 全网格 =sum 公式求值（模板坐标，行不裁剪；在列剪枝/空行过滤之前执行）
void _evalFormulas(List<List<GridCell>> rows, String unit) {
  for (var r = 0; r < rows.length; r++) {
    for (var cc = 0; cc < rows[r].length; cc++) {
      final t = rows[r][cc].text.trim();
      if (!t.startsWith('=')) continue;
      final ev = _evalFormula(t, rows, <String>{}, unit);
      if (ev != t) rows[r][cc].text = ev;
    }
  }
}

/// 合计/总计标签行（尾列剪枝时保留其非空金额格并左移）
bool _isTotalRow(List<GridCell> row) =>
    row.isNotEmpty && (row.first.text.trim() == '合计' || row.first.text.trim() == '总计');

/// 尾列剪枝（用户"没有 31 号最后那 2 列不需要显示"）：
/// 从最右列起，若「日期行」（模板含 {N日销售额}/{月}月N日 变量的行）该列渲染后全空
/// → 整列从所有行删除（表头/小计跟随删；标题跨列合并格 span 缩短；总计行金额格保留左移）。
/// 两遍实现：先确定要删的列集合（连续尾列），再统一重建每行——避免逐列重建导致
/// 总计行"金额格保留补位"后行宽比其它行多 1 格（9 月无 31 日时打印表格多出一列，
/// 预览/编辑按行渲染看不出，打印 HTML 按最宽行排版就长出去一列）。
void _pruneTailEmptyCols(List<List<GridCell>> rows, {required Set<int> dayRowIdx}) {
  if (dayRowIdx.isEmpty) return;
  final cols = rows.fold<int>(0, (m, r) {
    var w = 0;
    for (final c in r) {
      w += c.colSpan < 1 ? 1 : c.colSpan;
    }
    return w > m ? w : m;
  });
  // 第一遍：从右往左找连续"日期行全空"的列
  final colsToDelete = <int>{};
  for (var cc = cols - 1; cc >= 0; cc--) {
    var allEmpty = true;
    for (final ri in dayRowIdx) {
      if (ri >= rows.length) continue;
      final row = rows[ri];
      var acc = 0;
      GridCell? hit;
      for (final c in row) {
        final sp = c.colSpan < 1 ? 1 : c.colSpan;
        if (cc >= acc && cc < acc + sp) {
          hit = c;
          break;
        }
        acc += sp;
      }
      if (hit != null && hit.text.trim().isNotEmpty) {
        allEmpty = false;
        break;
      }
    }
    if (!allEmpty) break;
    colsToDelete.add(cc);
  }
  if (colsToDelete.isEmpty) return;
  final targetWidth = cols - colsToDelete.length;
  // 第二遍：统一重建每行（命中删除列的格删除/缩短；总计行非空金额格保留补位）
  for (var ri = 0; ri < rows.length; ri++) {
    final row = rows[ri];
    final newRow = <GridCell>[];
    final deferred = <GridCell>[];
    var acc = 0;
    for (final c in row) {
      final sp = c.colSpan < 1 ? 1 : c.colSpan;
      var overlap = 0;
      for (var i = acc; i < acc + sp; i++) {
        if (colsToDelete.contains(i)) overlap++;
      }
      if (overlap > 0) {
        if (sp > 1) {
          // 标题等跨列合并格：右端被删 → 缩短 span；整格都在删除列内 → 整格删
          if (sp - overlap > 0) {
            c.colSpan = sp - overlap;
            newRow.add(c);
          }
        } else if (_isTotalRow(row) && c.text.trim().isNotEmpty) {
          deferred.add(c); // 总计行金额格保留，左移到行尾
        }
        // span==1 空文本/表头/小计格 → 随列删除
      } else {
        newRow.add(c);
      }
      acc += sp;
    }
    newRow.addAll(deferred);
    // 金额格"保留补位"会使总计行比其它行多 1 格 → 从行尾修剪空文本格对齐
    while (newRow.length > targetWidth) {
      var removed = false;
      for (var i = newRow.length - 1; i >= 0; i--) {
        if (newRow[i].text.trim().isEmpty && newRow[i].colSpan == 1) {
          newRow.removeAt(i);
          removed = true;
          break;
        }
      }
      if (!removed) break; // 全非空（理论不会）：放弃修剪避免删错
    }
    rows[ri] = newRow;
  }
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
        line.add(GridCell(_numU(daily[day - 1], d.displayUnit), 'right'));
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
    subtotal.add(GridCell(_numU(s, d.displayUnit), 'right', true));
  }
  rows.add(subtotal);
  // 底部总计（跨栏，示例「总计 41349.81」尾部对齐；加粗；「总计」标签居中美观）
  rows.add([
    GridCell('总计', 'center', true),
    for (var cc = 0; cc < cols * 2 - 2; cc++) GridCell('', ''),
    GridCell(_numU(grand, d.displayUnit), 'right', true),
  ]);
  return rows;
}

List<List<GridCell>> _renderGrid(XlsCfg cfg, TemplateData d, {bool evalSum = true}) {
  final out = <List<GridCell>>[];
  final daily = _dailyOf(d);
  // 日期行索引（模板期含 {N日销售额}/{月}月N日 变量的行；尾列剪枝按此判定"该列是否空"）
  final dayRowIdx = <int>{};
  final dayVarRe = RegExp(r'\{\d{1,2}日销售额\}|\{月\}月\d{1,2}日');
  final hasMonthBill = cfg.grid.any((r) => r.any((c) => c.text.contains('{月账单}')));
  final maxDay = daily.days.length;
  String trimDay(String text) {
    // 销售额格：{N日销售额} → 超天数清空
    var t = text.replaceAllMapped(RegExp(r'\{(\d{1,2})日销售额\}'), (m) {
      final n = int.tryParse(m.group(1)!) ?? 0;
      return n > maxDay ? '' : m.group(0)!;
    });
    // 日期格：{月}月N日 → 超天数清空（保留表头等非日期格）
    t = t.replaceAllMapped(RegExp(r'\{月\}月(\d{1,2})日'), (m) {
      final n = int.tryParse(m.group(1)!) ?? 0;
      return n > maxDay ? '' : m.group(0)!;
    });
    return t;
  }
  for (var ri = 0; ri < cfg.grid.length; ri++) {
    final row = cfg.grid[ri];
    // {月账单} 单元格 → 整行展开为多栏月账单（动态栏数，无需尾列剪枝）
    if (row.any((c) => c.text.contains('{月账单}'))) {
      final onlyRow = cfg.grid.length <= 1;
      out.addAll(_multiColBill(d, withTitle: onlyRow));
      continue;
    }
    if (row.any((c) => dayVarRe.hasMatch(c.text))) dayRowIdx.add(ri);
    final rendered = [
      for (var cc = 0; cc < row.length; cc++)
        GridCell(
          _replaceVars(trimDay(row[cc].text), d),
          cc < cfg.colAligns.length && cfg.colAligns[cc].isNotEmpty ? cfg.colAligns[cc] : row[cc].align,
          row[cc].bold,
          row[cc].bg,
          row[cc].rowSpan, // 保留合并（colSpan=8 标题行此前漏传 → 渲染输出每列都画标题）
          row[cc].colSpan,
          row[cc].borderTop, row[cc].borderRight, row[cc].borderBottom, row[cc].borderLeft,
        ),
    ];
    out.add(rendered);
  }
  // =sum(...) 公式求值（模板坐标，行未裁剪时索引一致）→ 尾列剪枝（无 31 日删末 2 列）
  // 导出 Excel 时 evalSum=false：保留公式原文（合计格 =sum(...) 由导出层写成 Excel 公式）
  if (evalSum) _evalFormulas(out, d.displayUnit);
  if (!hasMonthBill) _pruneTailEmptyCols(out, dayRowIdx: dayRowIdx);
  // 整行渲染后全空（标准模板 9月31号那一行）→ 跳过不显示
  return [for (final r in out) if (r.any((c) => c.text.trim().isNotEmpty)) r];
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
          GridCell('出货合计\n${_fmtMoneyU(saleTotal, d.displayUnit)}', 'center'),
          GridCell('收款合计\n${_fmtMoneyU(payTotal, d.displayUnit)}', 'center'),
          GridCell('期末欠款\n${_fmtMoneyU(d.debtEnd, d.displayUnit)}', 'center'),
        ]);
        break;
      case 'days':
        rows.add([GridCell('日期', 'center'), GridCell('销售额', 'center')]);
        double total = 0;
        for (var i = 0; i < daily.days.length; i++) {
          final v = daily.days[i];
          total += v;
          rows.add([GridCell('${i + 1}日', 'left'), GridCell(_fmtMoneyU(v, d.displayUnit), 'right')]);
        }
        rows.add([GridCell('总计', 'right'), GridCell(_fmtMoneyU(total, d.displayUnit), 'right')]);
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
    // 展开网格（标题行 + 每日/多栏 + 合计），不再用 {月账单} 宏。
    // **内置名强制使用最新出厂定义**：用户本地存的旧「标准」/「多栏」（旧结构=40天/旧标题/旧布局）必须
    // 替换为最新展开网格——否则用户升级后看到的是旧模板（用户"32-40天还存在/标题重复"根因）。
    // 用户要自定义请另存新名；内置名 = 出厂定义，用户对内置名的修改不保留。
    var migrated = false;
    final kept = <XlsCfg>[];
    for (final t in list) {
      if (t.name == '按日汇总' && t.comps.isEmpty && t.content.trim().isEmpty) {
        migrated = true; // 内置按日汇总已与标准合并，跳过（用户自定义过的按日汇总保留）
        continue;
      }
      if (t.name == '标准') {
        kept.add(_defaultTemplate());
        migrated = true;
        continue;
      }
      if (t.name == '多栏') {
        kept.add(_multiColTemplate());
        migrated = true;
        continue;
      }
      kept.add(t);
    }
    // 内置模板始终合并进列表（用户旧缓存缺「标准」/「多栏」时补回——否则新模板不显示）
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
    // 标题行：colSpan=2 合并整行居中，无底色（用户"不要背景颜色"）
    [GridCell('{店铺} {月}月份账单', 'center', true, '', 1, 2)],
    // 表头无底色（用户"日期营业额那行文字有底部颜色要去掉"）
    [GridCell('日期', 'center', true), GridCell('营业额', 'center', true)],
    for (var d = 1; d <= 31; d++)
      [GridCell('{月}月$d日', 'center'), GridCell('{$d日销售额}', 'right')],
    // 合计 = 函数 =sum(B3:B33)（用户"要 =sum(b2,b11) 这种函数，不要 {月合计} 变量"）
    [GridCell('合计', 'center', true), GridCell('=sum(b3:b33)', 'right', true)],
  ];

/// 「多栏」= 多栏月账单（寻牛记式：每栏 10 天，31 天 → 4 栏，最后一栏 1 天），展开为可编辑网格。
XlsCfg _multiColTemplate() => XlsCfg()
  ..name = '多栏'
  // 展开网格（编辑/设计器直接可见可改，不再是 {月账单} 占位文本——用户"多栏编辑显示的是{月账单}"）；
  // 渲染时按当月天数尾列剪枝（无 31 号删末 2 列——用户定稿），合计用 =sum() 函数（用户"不要变量"）
  ..grid = [
    // 标题行：colSpan=8 合并整行居中，无底色（用户"不要背景颜色"）
    [GridCell('{店铺} {月}月份账单', 'center', true, '', 1, 8)],
    [
      for (var cc = 0; cc < 4; cc++) ...[
        GridCell('日期', 'center', true),
        GridCell('营业额', 'center', true),
      ],
    ],
    for (var r = 0; r < 10; r++)
      [
        for (var cc = 0; cc < 4; cc++)
          if (cc * 10 + r + 1 <= 31) ...[
            GridCell('{月}月${cc * 10 + r + 1}日', 'center'),
            GridCell('{${cc * 10 + r + 1}日销售额}', 'right'),
          ] else ...[
            // 第 4 栏只有 31 日一天（31 天月）：其余行补齐空格（保留表格线成矩形，
            // 勿缺列——参差行会让预览/打印/Excel 出现重复格或整块空白（用户"31 日下表格线空白"））
            GridCell('', 'center'),
            GridCell('', 'right'),
          ],
      ],
    // 小计 = 每栏函数（第 4 栏 = 31 日单格；无 31 日时该列被尾列剪枝整列删除）
    [
      GridCell('小计', 'center', true),
      GridCell('=sum(b3:b12)', 'right', true),
      GridCell('', ''),
      GridCell('=sum(d3:d12)', 'right', true),
      GridCell('', ''),
      GridCell('=sum(f3:f12)', 'right', true),
      GridCell('', ''),
      GridCell('=sum(h3:h3)', 'right', true),
    ],
    // 总计 = 各栏小计之和（引用小计行；无 31 日时 4 栏小计格随列删除，剩余自动左移补位）
    [
      GridCell('总计', 'center', true),
      for (var i = 0; i < 6; i++) GridCell('', ''),
      GridCell('=sum(b13,d13,f13,h13)', 'right', true),
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