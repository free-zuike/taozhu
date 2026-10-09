import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import '../api.dart';
import '../local_db.dart';
import '../local_freq.dart';
import '../log.dart';
import '../sync_service.dart';
import '../theme.dart';
import '../utils/money.dart';
import '../widgets/date_field.dart';
import '../widgets/center_sheet.dart';
import '../widgets/number_pad_field.dart';
import 'attachment_viewer.dart';
import 'router.dart';

class PurchasePage extends StatefulWidget {
  const PurchasePage({super.key, this.editId, this.initDate, this.dateRows, this.shareBytes, this.shareMime});
  /// 非空 = 编辑已有进货单（从账本进入），提交走 PATCH
  final String? editId;
  /// 新建模式预填日期（如从进货记录日期栏补录当天进货）；编辑模式忽略
  final String? initDate;
  /// 从进货记录日期栏进入：该日全部商品明细行（直接平铺编辑，保存逐行走行级 diff）
  final List<Map<String, dynamic>>? dateRows;
  /// 微信/系统分享图片 → App：图片字节+真实 MIME（进入即自动识别填行，可修改后保存）
  final Uint8List? shareBytes;
  final String? shareMime;
  @override
  State<PurchasePage> createState() => _PurchasePageState();
}

class _PRow {
  String? itemId;
  String? priceId;
  double quantity = 0;
  double purchasePrice = 0;
  String happenedAt = ''; // 该行商品的独立日期（空=用单据日期）
  /// 明细行 id（编辑模式加载原单时保存；行级附件锚点，空=新建未提交行）
  String rowId = '';
  /// 日期栏批量直编：该行所属原进货单号（该日可能多单，各行保留各自单号，不能统一挂新单）
  String origPurchaseId = '';
  /// 行原备注（直编/编辑保存时保留，避免 payload 缺 note 清空服务端行备注）
  String note = '';
  /// 本单折合计数数量（如进 1 大单位折合 N 个计数单位→库存按计数单位累计；空=不折按原单位。仅当商品配计数单位时生效）
  double? countQty;
  /// 保存时构建的商品行 payload（去单据化：逐行入队 purchase_item 用）
  Map<String, dynamic>? itemsPayload;
  // 输入框控制器：行重建时保留已输入内容（无 controller 时下拉切换/刷新会丢输入）
  final nameCtrl = TextEditingController();
  final unitCtrl = TextEditingController();
  final qtyCtrl = TextEditingController();
  final priceCtrl = TextEditingController();
  final countCtrl = TextEditingController(); // 折合计数（可选）
}

class _PurchasePageState extends State<PurchasePage> {
  List<Map<String, dynamic>> _items = [];
  bool _isStaff = false; // 店员不可见进价（进货价手填）
  /// 初始空行必须预生成 rowId（否则首行保存后无行 id，历史页长按删除会误判为整单）
  late final List<_PRow> _rows = [_newPRow()];
  Map<String, double> _lastQty = {}; // price_id → 上次数量（选单位自动带出）
  late final _dateCtrl = TextEditingController(text: _initDate());
  final _noteCtrl = TextEditingController();
  bool _busy = false;

  bool get _editing => widget.editId != null;

  /// 编辑模式原单行 id 集合（保存时对被删行发 purchase_item delete，防"删的行服务端复活"）
  Set<String> _origItemIds = {};
  /// 原单号映射（行 id → 原 purchase_id；批量直编该日多单时删行按各自原单补位）
  Map<String, String> _rowPurchaseId = {};
  /// Web 新建保存后服务端返回的真实单据 id（识别原图附件须挂它，否则 Web 端查不到）
  String _webPurchaseId = '';

  /// 该日全部真实单据 id（dateRows 批量直编：识别记账/编辑页凭证挂单据级真实单 id，
  /// 查看器批量模式须一并查——此前只查 _purchaseId 临时单 id 导致"批量编辑暂无附件"）
  List<String> get _orderIds => [
        for (final r in _rows)
          if (r.origPurchaseId.isNotEmpty) r.origPurchaseId,
      ].toSet().toList();

  /// 新建模式表单默认日期：优先 initDate（如进货记录日期栏补录当天），否则今天；编辑模式忽略
  String _initDate() {
    if (!_editing) {
      final d = widget.initDate ?? '';
      if (d.length >= 10) return d.substring(0, 10);
    }
    return _today();
  }

  /// 单据 id：编辑模式用原单 id；新建模式提前生成（附件/提交都挂在这个 id 上）
  late final String _purchaseId =
      _editing ? widget.editId! : 'p${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';

  /// 今日日期（YYYY-MM-DD），表单默认值；可改=补录历史日期
  static String _today() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  /// 批量直编模式（进货历史某日进入：该日全部行平铺，按原单分组 PATCH）
  bool get isDateRows => widget.dateRows != null && widget.dateRows!.isNotEmpty;

  @override
  void dispose() {
    _dateCtrl.dispose();
    _noteCtrl.dispose();
    for (final r in _rows) {
      r.nameCtrl.dispose();
      r.unitCtrl.dispose();
      r.qtyCtrl.dispose();
      r.priceCtrl.dispose();
      r.countCtrl.dispose();
    }
    // 未提交退出（取消）：清理识别即挂载的原图（引用+本地副本，零网络）
    if (!_submitted && _pendingGroups.isNotEmpty) {
      unawaited(_cleanupRecognizedOnCancel());
    }
    super.dispose();
  }

  /// 取消退出时清理识别挂载：删单据级引用行 + 本地副本文件（识别挂载未入上传队列，零网络）
  Future<void> _cleanupRecognizedOnCancel() async {
    final groups = List<Map<String, dynamic>>.from(_pendingGroups);
    if (groups.isEmpty) return;
    try {
      for (final g in groups) {
        final file = '${g['file'] ?? ''}';
        if (file.isEmpty) continue;
        await LocalDb.deleteOne('attachment_refs', 'purchase/$_purchaseId/$file');
      }
      final root = await getApplicationDocumentsDirectory();
      final files = groups.map((g) => '${g['file']}').toSet();
      final refs = await LocalDb.getAll('attachment_refs');
      for (final f in files) {
        if (f.isEmpty) continue;
        final ff = File('${root.path}/attachments/$f');
        if (ff.existsSync() && !refs.any((r) => '${r['file'] ?? ''}' == f)) await ff.delete();
      }
      _pendingGroups.clear();
    } catch (_) {}
    appLog('sync', '识别取消清理：移除识别挂载 ${groups.length} 组（零网络）', level: 'info');
  }

  @override
  void initState() {
    super.initState();
    Api.instance.getRole().then((r) {
      if (mounted) setState(() => _isStaff = r == 'staff');
    });
    _load();
    _maybeShare();
  }

  /// 微信/系统分享图片进入：等商品目录就绪后自动识别填行（草稿，用户可修改后保存）
  Future<void> _maybeShare() async {
    final sb = widget.shareBytes;
    if (sb == null || widget.editId != null) return;
    try {
      // 等 _load 完成（需要 _items 就绪才能匹配填行）；_load 未跑完最多等 3s
      var waited = 0;
      while (_items.isEmpty && waited < 3000) {
        await Future.delayed(const Duration(milliseconds: 100));
        waited += 100;
      }
      if (!mounted) return;
      await _parseBytes(sb, widget.shareMime ?? 'image/jpeg');
      appLog('op', '分享图片识别：进货 ${sb.length} 字节，已填行待确认保存');
    } catch (e) {
      appLog('error', '分享图片识别失败：${e.toString().replaceFirst('Exception: ', '')}');
      if (mounted) toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 识别图片字节 → 填行草稿 + 原图立即挂为本单凭证（拍照/相册/分享共用）。
  /// App 本地优先：识别即挂载（副本+引用表+入队上传），打开凭证查看器立即可见——
  /// 不再用"预览卡片等提交后再挂"的形态；Web 无本地库暂存原图，保存成功后用服务端返回的单据 id 直传。
  Future<void> _parseBytes(Uint8List bytes, String mime) async {
    final ext = mime.contains('png') ? 'png' : (mime.contains('webp') ? 'webp' : 'jpg');
    toast(context, '识别中…');
    final d = await Api.instance.uploadPhoto('/ai/parse-photo?purpose=purchase', bytes, 'photo.$ext', mime);
    final rowIds = _fillFromDrafts((d['items'] as List?) ?? [], '${d['date'] ?? ''}');
    if (kIsWeb) {
      setState(() => _pendingPhoto = bytes); // Web 无本地库：保存成功后直传（多批组含 bytes）
      _pendingGroups.add({'file': '${md5.convert(bytes).toString()}.jpg', 'rowIds': rowIds, 'bytes': bytes});
    } else {
      await _attachRecognized(bytes); // App 本地：立即挂单据级，取消时 dispose 清理
    }
    toast(context, '识别完成（原图已作为本单凭证，提交后同步上传）');
  }

  /// 识别原图立即挂为本单凭证（App 本地优先）：写公共目录副本 + **挂单据级一份**
  /// （entity=purchase/{_purchaseId}，对齐 Web 直传与"单据级一份全商品行共享可见"——
  /// 顶部整单凭证与行级入口（orderIds 聚合单据级）都能看到，计数一份不虚高）；
  /// 不立即上传——提交成功后才入队上传（_uploadPending），取消退出=纯本地清理零网络。
  Future<void> _attachRecognized(Uint8List bytes) async {
    try {
      final fileName = '${md5.convert(bytes).toString()}.jpg';
      final root = await getApplicationDocumentsDirectory();
      final adir = Directory('${root.path}/attachments');
      if (!adir.existsSync()) adir.createSync(recursive: true);
      final af = File('${adir.path}/$fileName');
      if (!af.existsSync()) await af.writeAsBytes(bytes);
      _pendingPhoto = bytes; // 兼容标记（log/UI 判断有识别图）
      _pendingGroups.add({'file': fileName, 'rowIds': <String>[]});
      // 单据级挂载一份（_purchaseId=客户端生成正式 id，提交前后不变）
      await SyncService.clearTombstone(entity: 'purchase', id: _purchaseId, file: fileName);
      await LocalDb.upsertOne('attachment_refs', {
        'id': 'purchase/$_purchaseId/$fileName',
        'entity': 'purchase',
        'entity_id': _purchaseId,
        'file': fileName,
        'key': 'taozhu/images/attachments/$fileName',
      });
      SyncService.version.notifyListeners();
    } catch (_) {}
  }

  /// 识别批次附件：每次拍照/分享识别=一组 {file, rowIds}（提交后逐行入队上传；取消退出遍历清理）
  final List<Map<String, dynamic>> _pendingGroups = [];

  bool _submitted = false; // 已提交成功（取消退出时据此清理识别挂载）

  Future<void> _load() async {
    // Web（无本地库）：直连网络刷新；原生：只读本地库镜像（同步由「我的」页/进应用驱动，页面不访问网络）
    if (kIsWeb) {
      try {
        final i = await Api.instance.get('/items/summary');
        await Api.instance.setCache('/items/summary', i);
        if (!mounted) return;
        final freq = await Freq.load();
        final lastQty = await Freq.loadLastQty();
        final list = ((i['items'] as List?) ?? []).cast<Map<String, dynamic>>()
          ..sort((a, b) => _freqOf(b, freq) - _freqOf(a, freq));
        if (!mounted) return;
        setState(() {
          _items = list;
          _lastQty = lastQty;
        });
        // 编辑模式：商品目录就绪后预填原单据明细
        if (_editing) await _loadEdit();
        else if (widget.dateRows != null) await _loadDateRows();
      } catch (e) {
        toast(context, e.toString().replaceFirst('Exception: ', ''));
      }
      return;
    }
    // 原生：本地库镜像秒开（离线可回显商品），同步完成后会再触发刷新
    final freq = await Freq.load();
    final lastQty = await Freq.loadLastQty();
    final list = await LocalDb.getAllByName('items')
      ..sort((a, b) => _freqOf(b, freq) - _freqOf(a, freq));
    if (!mounted) return;
    setState(() {
      _items = list;
      _lastQty = lastQty;
    });
    // 编辑模式：商品目录就绪后预填原单据明细（本地库优先，离线也能回显）
    if (_editing) await _loadEdit();
        else if (widget.dateRows != null) await _loadDateRows();
  }

  /// 折合计数（未手填时按价格行规格 per 自动算：数量×per；无 per=按原数量）
  double _autoPCount(_PRow row) {
    final opt = _items.where((x) => x['id'] == row.itemId).firstOrNull;
    final price = ((opt?['prices'] as List?) ?? [])
        .cast<Map<String, dynamic>>()
        .where((p) => p['id'] == row.priceId)
        .firstOrNull;
    final per = (price?['per'] as num?)?.toDouble() ?? 0;
    return per > 0 ? (row.quantity * per * 100).round() / 100 : row.quantity;
  }

  /// 商品在本地频率表中的最大使用次数（按价格组合取峰值，0=无记录）
  int _freqOf(Map<String, dynamic> item, Map<String, int> freq) {
    var max = 0;
    for (final p in ((item['prices'] as List?) ?? [])) {
      final f = freq['${(p as Map)['id']}'] ?? 0;
      if (f > max) max = f;
    }
    return max;
  }

  /// 编辑模式预填：优先本地库回显（离线也能填原单），无本地副本再走网络
  Future<void> _loadEdit() async {
    Map<String, dynamic>? d;
    try {
      final list = await LocalDb.getAll('purchases');
      d = list.where((s) => '${s['id']}' == widget.editId).firstOrNull;
    } catch (_) {}
    if (d == null && kIsWeb) {
      try {
        d = await Api.instance.get('/purchases/${widget.editId}');
      } catch (_) {
        // 无网络且本地无缓存：错误已记日志，表单留空由用户重新填写
        return;
      }
    }
    if (d == null) {
      // 页面零网络铁律：原生不直连服务端；本地无副本提示先同步，不再网络兜底
      toast(context, '本地无该单据，请先在「同步状态」同步后编辑');
      return;
    }
    if (!mounted || d == null) return;
    final data = d;
    setState(() {
      final hd = '${data['happened_at'] ?? ''}';
      _dateCtrl.text = hd.length >= 10 ? hd.substring(0, 10) : _today();
      _noteCtrl.text = '${data['note'] ?? ''}';
      final items = ((data['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      _rows.clear();
      _origItemIds = items.map((it) => '${it['id'] ?? ''}').where((x) => x.isNotEmpty).toSet();
      var skipped = 0;
      for (final it in items) {
        final itemId = '${it['item_id']}';
        final unit = '${it['unit'] ?? ''}';
        final qty = it['quantity'] is num
            ? (it['quantity'] as num).toDouble()
            : double.tryParse('${it['quantity']}') ?? 0;
        final pp = it['purchase_price'] is num
            ? (it['purchase_price'] as num).toDouble()
            : double.tryParse('${it['purchase_price']}') ?? 0;
        final match = _items.where((x) => '${x['id']}' == itemId).firstOrNull;
        final prices = ((match?['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
        final price = prices.where((p) => '${p['unit']}' == unit).firstOrNull;
        if (match == null || price == null) {
          skipped++;
          continue;
        }
        // 行日期：仅在与单据日期不同（真正独立日期）时才保留；==单据日期视为跟随单据，
        // 置空以便改顶部日期时整单生效（否则行旧日期覆盖新单据日期导致改日期无效）
        final lineDate = '${it['happened_at'] ?? ''}';
        final keepLineDate =
            lineDate.length >= 10 && lineDate.substring(0, 10) != hd.substring(0, 10);
        _rows.add(_PRow()
          ..itemId = itemId
          ..priceId = price['id'] as String?
          ..quantity = qty
          ..purchasePrice = pp
          ..happenedAt = keepLineDate ? lineDate : ''
          ..rowId = '${it['id'] ?? ''}'
          ..origPurchaseId = _purchaseId
          ..note = '${it['note'] ?? ''}'
          ..nameCtrl.text = '${it['item_name'] ?? match['name']}'
          ..unitCtrl.text = unit
          ..qtyCtrl.text = qty.toString()
          ..priceCtrl.text = pp.toStringAsFixed(2)
          ..countQty = (double.tryParse('${it['count_qty'] ?? ''}') ?? 0) > 0 ? double.tryParse('${it['count_qty'] ?? ''}') : null);
        if ((it['count_qty'] as num?)?.toDouble() != null && ((it['count_qty'] as num?)?.toDouble() ?? 0) > 0) {
          _rows.last.countCtrl.text = '${it['count_qty']}';
        }
        _rowPurchaseId['${it['id'] ?? ''}'] = _purchaseId;
      }
      if (_rows.isEmpty) _rows.add(_newPRow());
      if (skipped > 0) {
        toast(context, '原单 $skipped 条商品已删除或价格停用，保存后将移除');
      }
    });
  }

  /// 日期栏批量直编：直接平铺该日全部进货商品行（行内直接改，保存走行级 diff）。
  /// lines 字段约定（进货记录展开行）：item_id=商品 id、row_id/id=明细行 id、
  /// quantity/unit/purchase_price/happened_at
  Future<void> _loadDateRows() async {
    final lines = (widget.dateRows ?? []).cast<Map<String, dynamic>>();
    if (lines.isEmpty) return;
    setState(() {
      final hd = widget.initDate ?? _today();
      _dateCtrl.text = hd.length >= 10 ? hd.substring(0, 10) : _today();
      _noteCtrl.text = '';
      _rows.clear();
      _origItemIds = lines
          .map((l) => '${l['row_id'] ?? l['id'] ?? ''}')
          .where((x) => x.isNotEmpty)
          .toSet();
      var skipped = 0;
      for (final it in lines) {
        final rowId = '${it['row_id'] ?? it['id'] ?? ''}';
        final itemId = '${it['item_id'] ?? ''}';
        final unit = '${it['unit'] ?? ''}';
        // 该行原进货单号（该日可能多单，各行保留各自单号——批量直编不能统一挂新单）
        final origPurchaseId = '${(it['order'] as Map?)?['id'] ?? ''}';
        if (rowId.isNotEmpty && origPurchaseId.isNotEmpty) _rowPurchaseId[rowId] = origPurchaseId;
        // 数量兼容 num 与字符串（purchase_history 传的是 '5'，Web/后端为 num）
        final rawQty = it['quantity'];
        final qty = rawQty is num
            ? rawQty.toDouble()
            : (double.tryParse('$rawQty') ??
                (it['qty_num'] is num
                    ? (it['qty_num'] as num).toDouble()
                    : double.tryParse('${it['qty_num']}') ?? 0));
        final pp = (it['purchase_price'] is num)
            ? (it['purchase_price'] as num).toDouble()
            : (double.tryParse('${it['purchase_price']}') ?? 0);
        final match = _items.where((x) => '${x['id']}' == itemId).firstOrNull;
        final prices = ((match?['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
        final price = prices.where((p) => '${p['unit']}' == unit).firstOrNull;
        // 仅商品已删/停用才跳过；单位与商品库价格组合不匹配（如识别单位差异）不跳过——
        // 保留行（priceId 空、价格沿用原单识别值），老板保存时按实际单位校验
        if (itemId.isEmpty || match == null) {
          skipped++;
          continue;
        }
        final lineDate = '${it['happened_at'] ?? ''}';
        final keepLineDate = lineDate.isNotEmpty && lineDate.substring(0, 10) != hd.substring(0, 10);
        _rows.add(_PRow()
          ..itemId = itemId
          ..priceId = price?['id'] as String?
          ..quantity = qty
          ..purchasePrice = pp
          ..happenedAt = keepLineDate ? lineDate : ''
          ..rowId = rowId
          ..origPurchaseId = origPurchaseId
          ..note = '${it['note'] ?? ''}'
          ..nameCtrl.text = '${it['item_name'] ?? match['name']}'
          ..unitCtrl.text = unit
          ..qtyCtrl.text = qty.toString()
          ..priceCtrl.text = pp.toStringAsFixed(2)
          ..countQty = (double.tryParse('${it['count_qty'] ?? ''}') ?? 0) > 0 ? double.tryParse('${it['count_qty'] ?? ''}') : null);
        if ((it['count_qty'] as num?)?.toDouble() != null && ((it['count_qty'] as num?)?.toDouble() ?? 0) > 0) {
          _rows.last.countCtrl.text = '${it['count_qty']}';
        }
      }
      if (_rows.isEmpty) _rows.add(_newPRow());
      if (skipped > 0) toast(context, '该日 $skipped 条商品已删除或价格停用，保存后将移除');
    });
  }

  /// 选中商品：填入名称/分类，带出默认单位与进价
  void _selectItem(_PRow row, Map<String, dynamic> item) {
    row.itemId = '${item['id']}';
    row.nameCtrl.text = '${item['name'] ?? ''}';
    final prices = ((item['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
    final price = prices.where((p) => (p['active'] as num?) != 0).firstOrNull ?? prices.firstOrNull;
    if (price != null) {
      row.priceId = price['id'] as String?;
      row.unitCtrl.text = '${price['unit'] ?? ''}';
      row.purchasePrice = (price['purchase_price'] as num?)?.toDouble() ?? 0;
      row.priceCtrl.text = row.purchasePrice > 0 ? row.purchasePrice.toStringAsFixed(2) : '';
    }
  }

  /// 名称输入变化：精确匹配到已有商品 → 关联（**不覆盖识别/手填的价格与单位**——
  /// AI 识别填行改错名时只关联商品，识别价保留）；否则视为新商品名（可点「新增」入库）
  void _onNameChanged(_PRow row, String v) {
    final name = v.trim();
    final match = _items.where((x) => '${x['name']}' == name).firstOrNull;
    if (match != null) {
      if (row.itemId != '${match['id']}') {
        // 行上还没有有效价格（全新行）→ 带出商品库默认价；已有识别/手填价 → 只关联商品与价格 id
        final hasPrice = (row.purchasePrice > 0) || row.priceCtrl.text.trim().isNotEmpty;
        if (!hasPrice) {
          _selectItem(row, match);
        } else {
          row.itemId = '${match['id']}';
          row.nameCtrl.text = '${match['name'] ?? ''}';
          final prices = ((match['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
          final pr = row.unitCtrl.text.trim().isNotEmpty
              ? prices.where((p) => '${p['unit']}' == row.unitCtrl.text).firstOrNull
              : prices.where((p) => (p['active'] as num?) != 0).firstOrNull ?? prices.firstOrNull;
          if (pr != null) row.priceId = pr['id'] as String?;
        }
        setState(() {});
      }
      return;
    }
    if (row.itemId != null) {
      row.itemId = null;
      row.priceId = null;
    }
    setState(() {});
  }

  /// 单位输入变化：匹配到该商品的价格组合 → 带出默认进价；否则保持手动进价
  void _onUnitChanged(_PRow row, String v) {
    final unit = v.trim();
    final item = _items.where((x) => x['id'] == row.itemId).firstOrNull;
    final prices = ((item?['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
    final price = prices.where((p) => '${p['unit']}' == unit).firstOrNull;
    row.unitCtrl.text = unit; // 保持用户输入（含非预设单位）
    if (price != null) {
      row.priceId = price['id'] as String?;
      row.purchasePrice = (price['purchase_price'] as num?)?.toDouble() ?? 0;
      row.priceCtrl.text = row.purchasePrice > 0 ? row.purchasePrice.toStringAsFixed(2) : '';
    } else {
      row.priceId = null; // 自定义单位：进价手动填
    }
    setState(() {});
  }

  /// 商品选择弹层：搜索 + 列表选择（也可直接输入新名称走「新增商品」）
  Future<void> _pickItem(_PRow row) async {
    final searchCtrl = TextEditingController();
    final picked = await showCenterSheet<String>(
      context: context,
      maxHeightFactor: 0.8,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final q = searchCtrl.text.trim().toLowerCase();
          final list = q.isEmpty
              ? _items
              : _items.where((x) => '${x['name']}'.toLowerCase().contains(q)).toList();
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: TextField(
                  controller: searchCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 20),
                    hintText: '搜索商品名称',
                    isDense: true,
                  ),
                  onChanged: (_) => setSheet(() {}),
                ),
              ),
              Flexible(
                child: list.isEmpty
                    ? Center(child: Text('没有匹配商品，可直接在上方输入新名称', style: TextStyle(color: Theme.of(ctx).extension<TaozhuColors>()!.textSub)))
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final it in list)
                            ListTile(
                              dense: true,
                              leading: const Icon(Icons.label_outline, size: 18, color: Color(0xFF409EFF)),
                              title: Text('${it['name']}'),
                              subtitle: '${it['category'] ?? ''}'.isNotEmpty
                                  ? Text('${it['category']}', style: const TextStyle(fontSize: 11))
                                  : null,
                              onTap: () => Navigator.pop(ctx, '${it['id']}'),
                            ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
    if (picked == null) return;
    final item = _items.where((x) => '${x['id']}' == picked).firstOrNull;
    if (item != null) _selectItem(row, item);
    setState(() {});
  }

  /// 创建商品：Web 直连 POST /items；原生本地生成 id 落库+入队（离线可用，队列推送跨端生效）
  /// 新建商品入库：category=分类名称（冗余快照，商品行/列表直接显示）、categoryId=分类 id
  /// （后端按 id 关联分类；两者都写，避免商品页/交易行把 id 当名称显示）
  Future<String?> _createItem(String name,
      {String unit = '', double price = 0, String category = '', String categoryId = ''}) async {
    final u = unit.isEmpty ? '件' : unit;
    try {
      String id, pid;
      if (kIsWeb) {
        final d = await Api.instance.post('/items', {
          'name': name,
          'category': category,
          if (categoryId.isNotEmpty) 'category_id': categoryId,
          'prices': [
            {'unit': u, 'purchase_price': price > 0 ? price : 0, 'sale_price': 0},
          ],
        });
        id = '${d['id'] ?? ''}';
        if (id.isEmpty) return null;
        // 后端 POST /items 返回 prices 为价格 ID 字符串数组（如 ["pr…"]），取第一个作为新价格组合 id
        pid = '${(d['prices'] as List?)?.firstOrNull ?? ''}';
        _items.add({
          'id': id,
          'name': name,
          'category': category,
          'prices': [
            {'id': pid, 'unit': u, 'purchase_price': price > 0 ? price : 0, 'sale_price': 0, 'active': 1},
          ],
        });
        return id;
      }
      // 原生本地优先：本地生成 id → 内存目录 + 落库 + 入队（等不到 pull 时记单/改分类也能立即用）
      id = 'it${DateTime.now().millisecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';
      pid = 'pr${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';
      _items.add({
        'id': id,
        'name': name,
        'category': category,
        'prices': [
          {'id': pid, 'unit': u, 'purchase_price': price > 0 ? price : 0, 'sale_price': 0, 'active': 1},
        ],
      });
      await LocalDb.upsertOne('items', {
        'id': id,
        'name': name,
        'category': category,
        'category_id': categoryId.isEmpty ? null : categoryId,
        'deleted_at': null,
        'prices': [
          {'id': pid, 'item_id': id, 'unit': u, 'purchase_price': price > 0 ? price : 0, 'sale_price': 0, 'active': 1},
        ],
      });
      await SyncService.enqueueChange(entityType: 'item', entitySyncId: id, payload: {
        'id': id,
        'name': name,
        'category': category,
        'category_id': categoryId.isEmpty ? null : categoryId,
        'deleted_at': null,
        'prices': [
          {'id': pid, 'item_id': id, 'unit': u, 'purchase_price': price > 0 ? price : 0, 'sale_price': 0, 'active': 1},
        ],
      });
      return id;
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
      return null;
    }
  }

  /// 新增商品入库：在线创建（仅老板；店员提示找老板添加）→ 加入本地目录并选中
  Future<bool> _quickAddItem(_PRow row, String name) async {
    // 分类选择（对齐提交弹窗：下拉选择现有商品分类，可无分类；原生本地镜像/Web 直连）
    var cats = await LocalDb.getAll('categories');
    cats = cats.where((x) => '${x['type'] ?? ''}' == 'item').toList()
      ..sort((a, b) => ((a['sort'] as num?)?.toInt() ?? 0).compareTo((b['sort'] as num?)?.toInt() ?? 0));
    if (kIsWeb) {
      try {
        final d = await Api.instance.get('/categories?type=item');
        cats = ((d['categories'] as List?) ?? []).cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    String category = '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text('新增商品「$name」'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('分类', style: TextStyle(fontSize: 13, color: Theme.of(ctx).extension<TaozhuColors>()!.textSub)),
              const SizedBox(height: 6),
              DropdownButton<String>(
                value: category,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: '', child: Text('无分类')),
                  // 两级结构（对齐 _changeCategory）：父分类 + 缩进子分类
                  for (final p in cats.where((x) => (x['parent_id'] as String? ?? '').isEmpty))
                    ...[
                      DropdownMenuItem(value: '${p['id']}', child: Text('${p['name'] ?? ''}')),
                      for (final ch in cats.where((x) => '${x['parent_id']}' == '${p['id']}'))
                        DropdownMenuItem(
                          value: '${ch['id']}',
                          child: Padding(
                            padding: const EdgeInsets.only(left: 24),
                            child: Text('${ch['name'] ?? ''}'),
                          ),
                        ),
                    ],
                ],
                onChanged: (v) => setDlg(() => category = v ?? ''),
              ),
              const SizedBox(height: 8),
              Text('单位与进价可在下方明细行直接填写', style: TextStyle(fontSize: 12, color: Theme.of(ctx).extension<TaozhuColors>()!.textSub)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('添加商品')),
          ],
        ),
      ),
    );
    if (ok != true) return false;
    // category 变量存的是分类 id（Dropdown value）→ 解析名称为快照 + 传 id 关联
    final catName = category.isEmpty
        ? ''
        : '${cats.where((x) => '${x['id']}' == category).firstOrNull?['name'] ?? ''}';
    final id = await _createItem(name,
        unit: row.unitCtrl.text.trim(), price: row.purchasePrice,
        category: catName, categoryId: category);
    if (id == null) return false;
    final opt = _items.where((x) => '${x['id']}' == id).firstOrNull;
    if (opt != null) _selectItem(row, opt);
    setState(() {});
    toast(context, '已添加商品「$name」');
    return true;
  }

  double get _total => _rows.fold(0, (s, r) => s + r.quantity * r.purchasePrice);

  /// AI 拍照识别：拍照或从相册选图 → 后端解析 → 匹配已有商品填行
  // 识别原图：识别成功暂存本地，提交交易成功后才上传为本单附件（避免取消/放弃留孤儿附件）
  Uint8List? _pendingPhoto;

  Future<void> _aiParse() async {
    try {
      final source = await showDialog<ImageSource>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('图片识别'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined, color: Color(0xFF409EFF)),
                title: const Text('拍照'),
                onTap: () => Navigator.pop(ctx, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined, color: Color(0xFF409EFF)),
                title: const Text('从相册选择'),
                onTap: () => Navigator.pop(ctx, ImageSource.gallery),
              ),
            ],
          ),
        ),
      );
      if (source == null) return;
      final picked = await ImagePicker()
          .pickImage(source: source, maxWidth: 1600, imageQuality: 85);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      // 按真实 MIME 上传（相册 PNG 若标成 JPEG，后端/模型会解析失败 1210）
      final mime = picked.mimeType ?? 'image/jpeg';
      await _parseBytes(bytes, mime);
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 提交成功后上传识别原图为本单凭证（失败静默，可稍后在凭证处手动添加）。
  /// 挂载**单据级一份**（entity=purchase/{purchaseId}，全商品行共享可见）；
  /// 多页扫描多次识别=同单多张单据级图，行级/整单查看器均可见（0.17.353 回归单据级）。
  Future<void> _uploadPending(String purchaseId, List<_PRow> rows) async {
    final groups = List<Map<String, dynamic>>.from(_pendingGroups);
    if (groups.isEmpty) return;
    _pendingPhoto = null;
    try {
      if (kIsWeb) {
        for (final g in groups) {
          final bytes = g['bytes'] as Uint8List?;
          if (bytes == null) continue;
          await Api.instance.uploadPhoto('/attachments?entity=purchase&id=$purchaseId', bytes, '${g['file'] ?? 'photo.jpg'}');
        }
        if (mounted) toast(context, '识别图片已存为本单凭证');
        _pendingGroups.clear();
        return;
      }
      for (final g in groups) {
        final file = '${g['file'] ?? ''}';
        if (file.isEmpty) continue;
        // 单据级一份（purchase/{purchaseId}，全商品行共享可见=对齐 Web 直传/用户"全行可见"诉求；
        // 多页扫描多次识别=同单多张单据级图，行级/整单查看器均可见）
        await SyncService.enqueueAttachmentUpload(entity: 'purchase', id: purchaseId, fileName: file);
      }
      _pendingGroups.clear();
      if (mounted) toast(context, '识别图片已存为本单凭证（联网后自动上传）');
    } catch (_) {
      _pendingGroups.clear();
    }
  }

  /// AI 文字记账：输入一句话（如"白菜50斤 3元一斤，土豆30斤 2元一斤"）→ 解析填行
  Future<void> _aiText() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('文字记账'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '例：白菜50斤 3元一斤，土豆30斤 2元一斤，萝卜20斤 1.5元一斤',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('识别')),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    toast(context, '识别中…');
    try {
      final d = await Api.instance.post('/ai/parse-text?purpose=purchase', {'text': text});
      _fillFromDrafts((d['items'] as List?) ?? [], '${d['date'] ?? ''}');
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// AI 语音记账：录音 → 语音转文字 → 解析填行
  Future<void> _aiVoice() async {
    try {
      _VoiceRecorder.takeContext = context;
      final rec = _VoiceRecorder();
      final audio = await rec.take();
      _VoiceRecorder.takeContext = null;
      if (audio == null) return;
      toast(context, '识别中…');
      final d = await Api.instance.uploadAudio('/ai/parse-voice?purpose=purchase', audio.bytes, audio.name, audio.mime);
      final text = '${d['text'] ?? ''}';
      if (text.isNotEmpty) toast(context, '语音识别：$text');
      _fillFromDrafts((d['items'] as List?) ?? [], '${d['date'] ?? ''}');
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// 识别结果 → 填日期 + 匹配已有商品填行（拍照/文字/语音共用；进货无购货单位字段）。
  /// 返回本次实际填充的商品行 id 列表（识别图按批次挂行=行级附件"批对批"；文字/语音无图可忽略返回值）
  List<String> _fillFromDrafts(List<dynamic> items, [String date = '']) {
    // 日期：识别出的单据日期（YYYY-MM-DD）
    if (date.isNotEmpty && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
      _dateCtrl.text = date;
    }
    if (items.isEmpty) {
      toast(context, '未识别到商品，请手动填写');
      return <String>[];
    }
    var filled = 0;
    var unmatched = 0;
    final rowIds = <String>[];
    for (final raw in items) {
      final name = '${raw['name'] ?? ''}'.trim();
      final qty = (raw['quantity'] as num?)?.toDouble() ?? 0;
      final price = (raw['price'] as num?)?.toDouble() ?? 0;
      final unit = '${raw['unit'] ?? ''}'.trim();
      final match = _items
          .where((it) => '${it['name']}' == name ||
              '${it['name']}'.contains(name) ||
              name.contains('${it['name']}'))
          .firstOrNull;
      final prices = ((match?['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
      Map<String, dynamic>? pr;
      if (match != null) {
        if (unit.isNotEmpty) {
          pr = prices.where((p) => '${p['unit']}' == unit).firstOrNull;
        }
        pr ??= prices.firstOrNull;
      }
      setState(() {
        final row = (_rows.length == 1 && _rows.first.itemId == null && _rows.first.nameCtrl.text.trim().isEmpty)
            ? _rows.first
            : (_rows..add(_newPRow()..happenedAt = _dateCtrl.text.trim())).last;
        if (row.rowId.isNotEmpty) rowIds.add(row.rowId);
        if (match != null && pr != null) {
          row.itemId = '${match['id']}';
          row.priceId = pr!['id'] as String?;
          row.quantity = qty;
          row.purchasePrice = price > 0 ? price : (pr!['purchase_price'] as num).toDouble();
          row.nameCtrl.text = '${match['name']}'; // 识别命中商品库：名称也回填（否则输入框空白）
          row.unitCtrl.text = unit;
          row.qtyCtrl.text = qty.toString();
          row.priceCtrl.text = (price > 0 ? price : (pr!['purchase_price'] as num).toDouble()).toStringAsFixed(2);
        } else {
          // 识别出但商品库没有：名称/单位/数量/单价照填（提交时老板自动入库/店员提示添加）
          unmatched++;
          row.nameCtrl.text = name;
          row.unitCtrl.text = unit;
          row.quantity = qty;
          row.purchasePrice = price;
          row.qtyCtrl.text = qty.toString();
          row.priceCtrl.text = price.toStringAsFixed(2);
        }
        filled++;
      });
    }
    toast(context,
        filled > 0
            ? (unmatched > 0 ? '已导入 $filled 项（$unmatched 项不在商品库，已填入名称待确认）' : '已导入 $filled 项商品')
            : '识别结果未匹配到已有商品，请手动填写');
    return rowIds;
  }

  Future<void> _submit() async {
    // 名称手动输入但未入库的新商品：弹窗让用户决定是否加入商品库（不再静默自动入库）
    final newNames = _rows
        .where((r) => r.nameCtrl.text.trim().isNotEmpty && r.itemId == null)
        .map((r) => r.nameCtrl.text.trim())
        .toList();
    if (newNames.isNotEmpty) {
      if (_isStaff) {
        toast(context, '「${newNames.join('、')}」不在商品库，请让老板先添加');
        return;
      }
      // 新商品入库分类选择：读商品分类目录（原生本地镜像/Web 直连），弹窗下拉选择（可无分类）
      var cats = await LocalDb.getAll('categories');
      cats = cats.where((x) => '${x['type'] ?? ''}' == 'item').toList()
        ..sort((a, b) => ((a['sort'] as num?)?.toInt() ?? 0).compareTo((b['sort'] as num?)?.toInt() ?? 0));
      if (kIsWeb) {
        try {
          final d = await Api.instance.get('/categories?type=item');
          cats = ((d['categories'] as List?) ?? []).cast<Map<String, dynamic>>();
        } catch (_) {}
      }
      String category = '';
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDlg) => AlertDialog(
            title: const Text('新商品入库'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('「${newNames.join('、')}」不在商品库，是否加入？\n（不加入则本次无法提交）'),
                const SizedBox(height: 12),
                Text('入库分类', style: TextStyle(fontSize: 13, color: Theme.of(ctx).extension<TaozhuColors>()!.textSub)),
                const SizedBox(height: 6),
                DropdownButton<String>(
                  value: category,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: '', child: Text('无分类')),
                    // 两级结构（对齐 _changeCategory）：父分类 + 缩进子分类
                    for (final p in cats.where((x) => (x['parent_id'] as String? ?? '').isEmpty))
                      ...[
                        DropdownMenuItem(value: '${p['id']}', child: Text('${p['name'] ?? ''}')),
                        for (final ch in cats.where((x) => '${x['parent_id']}' == '${p['id']}'))
                          DropdownMenuItem(
                            value: '${ch['id']}',
                            child: Padding(
                              padding: const EdgeInsets.only(left: 24),
                              child: Text('${ch['name'] ?? ''}'),
                            ),
                          ),
                      ],
                  ],
                  onChanged: (v) => setDlg(() => category = v ?? ''),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, 'no'), child: const Text('不加入')),
              FilledButton(onPressed: () => Navigator.pop(ctx, 'yes'), child: const Text('加入商品库')),
            ],
          ),
        ),
      );
      if (picked != 'yes') return;
      // category 变量存的是分类 id（Dropdown value）→ 解析名称为快照 + 传 id 关联
      final catName = category.isEmpty
          ? ''
          : '${cats.where((x) => '${x['id']}' == category).firstOrNull?['name'] ?? ''}';
      for (final r in _rows) {
        final name = r.nameCtrl.text.trim();
        if (name.isEmpty || r.itemId != null) continue;
        final id = await _createItem(name,
            unit: r.unitCtrl.text.trim(), price: r.purchasePrice,
            category: catName, categoryId: category);
        if (id == null) return;
        final opt = _items.where((x) => '${x['id']}' == id).firstOrNull;
        if (opt != null) _selectItem(r, opt);
      }
    }
    // 校验：有名称、有数量、有单位（默认件）即可提交；进价可直接手填
    for (final r in _rows) {
      final name = r.nameCtrl.text.trim();
      if (name.isEmpty && r.itemId == null) continue; // 空行忽略
      if (r.itemId == null) {
        toast(context, '「$name」尚未添加到商品库，提交失败');
        return;
      }
      if (r.quantity <= 0) {
        toast(context, '请填写「${name.isNotEmpty ? name : '商品'}」的数量');
        return;
      }
      if (r.unitCtrl.text.trim().isEmpty) r.unitCtrl.text = '件';
    }
    final valid = _rows.where((r) => r.itemId != null && r.quantity > 0).toList();
    if (valid.isEmpty) {
      toast(context, '请填写完整的商品明细');
      return;
    }
    setState(() => _busy = true);
    // 写本地优先：构建完整 payload → 落本地库 → 入队列 → debounce push
    final purchaseId = _purchaseId;    // 单据日期 = 明细行最大日期
    final orderDate = valid
        .map((r) => r.happenedAt.trim().isEmpty ? _dateCtrl.text.trim() : r.happenedAt.trim())
        .reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
    final itemsPayload = <Map<String, dynamic>>[];
    var totalCalc = 0.0;
    for (final (i, r) in valid.indexed) {
      final opt = _items.where((x) => x['id'] == r.itemId).firstOrNull;
      final prices = ((opt?['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
      final price = prices.where((p) => p['id'] == r.priceId).firstOrNull;
      // 存储浮点原值（对齐参考项目 REAL：本地镜像/提交不取整；舍入配置只在统计/欠款/展示层换算）
      final amount = r.quantity * r.purchasePrice;
      totalCalc += amount;
      // 批量直编：行保留各自原单号（该日可能多单，统一挂新单会把原单行搬走→本地/服务器错乱）
      final rowPurchaseId = isDateRows ? (r.origPurchaseId.isNotEmpty ? r.origPurchaseId : purchaseId) : purchaseId;
      final rowPayload = {
        'id': r.rowId, // 复用预生成的行级 id（行级附件锚点/同步实体 key 一致）
        'purchase_id': rowPurchaseId,
        'item_id': r.itemId,
        'item_name': opt?['name'] ?? r.nameCtrl.text.trim(),
        'unit': r.unitCtrl.text.trim(),
        'quantity': r.quantity,
        'count_qty': r.countQty != null && r.countQty! > 0 ? r.countQty : null,
        'purchase_price': r.purchasePrice,
        'amount': amount,
        'happened_at': r.happenedAt.trim().isEmpty ? orderDate : r.happenedAt.trim(),
        'note': r.note, // 保留行原备注（payload 缺 note 会被同步 upsert 写成空）
        'sort': i, // 行序=展示/插入顺序（服务端/账本按 sort 展开，插入行不再排末尾）
      };
      r.itemsPayload = rowPayload;
      itemsPayload.add(rowPayload);
    }
    final payload = {
      'id': purchaseId,
      'happened_at': orderDate,
      'note': _noteCtrl.text.trim(),
      'total': totalCalc,
      'items': itemsPayload,
    };
    if (kIsWeb) {
      // Web 无本地库/同步队列：直连服务端。
      // 批量直编：按原单分组 PATCH；编辑：PATCH /purchases/:id 全量替换；新建：POST（sync_key 幂等）
      final webItems = [
        for (final (i, r) in valid.indexed)
          {
            'id': r.rowId, // 保留原行 id（服务端重建明细时不换新 id，行级附件不孤儿化）
            'price_id': r.priceId,
            'quantity': r.quantity,
            'count_qty': r.countQty != null && r.countQty! > 0 ? r.countQty : null,
            'purchase_price': r.purchasePrice,
            'happened_at': r.happenedAt.trim().isEmpty ? orderDate : r.happenedAt.trim(),
            'note': r.note,
            'sort': i, // 行序=展示顺序（服务端按 sort 存储，插入行不排末尾）
          },
      ];
      try {
        if (isDateRows) {
          final byOrder = <String, List<_PRow>>{};
          for (final r in valid) {
            final oid = r.origPurchaseId.isNotEmpty ? r.origPurchaseId : purchaseId;
            (byOrder[oid] ??= []).add(r);
          }
          for (final e in byOrder.entries) {
            // 批量直编只改日期/数量/价格：不传整单 note（防清空），items 逐行带原 id + 原行备注
            await Api.instance.patch('/purchases/${e.key}', {
              'happened_at': orderDate,
              'items': [
                for (final (i, r) in e.value.indexed)
                  {
                    'id': r.rowId,
                    'price_id': r.priceId,
                    'quantity': r.quantity,
                    'count_qty': r.countQty != null && r.countQty! > 0 ? r.countQty : null,
                    'purchase_price': r.purchasePrice,
                    'happened_at': r.happenedAt.trim().isEmpty ? orderDate : r.happenedAt.trim(),
                    'note': r.note,
                    'sort': i,
                  },
              ],
            });
          }
        } else if (_editing) {
          await Api.instance.patch('/purchases/$purchaseId', {
            'happened_at': orderDate, 'note': _noteCtrl.text.trim(), 'items': webItems,
          });
        } else {
          // 服务端生成单据 id：返回 id 供识别原图附件挂载（此前用本地预生成 _purchaseId 挂附件
          // 与真实单据 id 不一致 = Web 端附件看不到的根因）
          final r = await Api.instance.post('/purchases', {
            'happened_at': orderDate, 'note': _noteCtrl.text.trim(),
            'sync_key': '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(0x7fffffff)}',
            'items': webItems,
          });
          if (r is Map && '${r['id'] ?? ''}'.isNotEmpty) {
            _webPurchaseId = '${r['id']}';
          }
        }
        toast(context, '已保存');
        _submitted = true;
        // 提交成功后才上传识别原图附件（Web）：新建用服务端返回的真实单据 id，
        // 编辑/批量直编用现有单 id——挂错 id 会导致 Web 端"附件看不到"
        if (kIsWeb) unawaited(_uploadPending(
            _webPurchaseId.isNotEmpty
                ? _webPurchaseId
                : (isDateRows && _orderIds.isNotEmpty ? _orderIds.first : purchaseId),
            valid));
      } catch (e) {
        toast(context, e.toString().replaceFirst('Exception: ', ''));
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      if (mounted) Navigator.pop(context, true);
      return;
    }
    // 本地优先：整单落库（列表立即展示）→ 行级 store 双写（进货历史读行级 purchase_items）；批量直编不改单号不新建整单镜像
    if (!isDateRows) await LocalDb.upsertOne('purchases', payload);
    for (final r in valid) {
      final rowPayload = Map<String, dynamic>.from(r.itemsPayload ?? {});
      if (rowPayload.isNotEmpty && r.rowId.isNotEmpty) {
        await LocalDb.upsertOne('purchase_items', rowPayload);
      }
    }
    final keptIds = <String>{};
    for (final r in valid) {
      final rowPayload = Map<String, dynamic>.from(r.itemsPayload ?? {});
      if (rowPayload.isNotEmpty && r.rowId.isNotEmpty) {
        keptIds.add(r.rowId);
        await SyncService.enqueueChange(
          entityType: 'purchase_item',
          entitySyncId: r.rowId,
          action: 'upsert',
          payload: rowPayload,
        );
      }
    }
    // 编辑/批量直编：原单行被删除的行 → 行级 delete（防"删的行服务端复活"）
    if (_editing || isDateRows) {
      final removedIds = _origItemIds.difference(keptIds);
      for (final rid in removedIds) {
        await SyncService.cleanupLocalAttachmentsOf('purchase_item', rid); // 删行附件引用+本地副本（不残留）
        await LocalDb.deleteOne('purchase_items', rid);
        await SyncService.enqueueChange(
          entityType: 'purchase_item', entitySyncId: rid, action: 'delete',
          payload: {'id': rid, 'purchase_id': _rowPurchaseId[rid] ?? purchaseId},
        );
      }
    }
    await Freq.bump(valid.map((r) => r.priceId ?? ''));
    for (final r in valid) {
      await Freq.saveLastQty(r.priceId ?? '', r.quantity);
    }
    toast(context, _editing ? '已保存，正在同步' : '已提交，合计 ¥${fmtMoney(_total)}');
    // 关键事件实时落日志（日志页可即时查看，便于复现）＋通知进货历史刷新（列表/统计即时更新）
    appLog('sync', '本地保存进货 ${valid.length} 行（${_editing ? '编辑' : '新增'}），已入队待推送${_pendingGroups.isNotEmpty ? '，识别图 ${_pendingGroups.length} 组待上传为行凭证' : ''}', level: 'info');
    SyncService.version.notifyListeners();
    // 提交成功后才上传识别原图附件（App 本地写完入队后）
    // 提交成功后才上传识别原图附件（App 本地写完入队后）；
    // 批量直编挂真实原单 id（dateRows 无 _purchaseId 真实单，此前挂临时 id=进货历史查不到）
    unawaited(_uploadPending(isDateRows && _orderIds.isNotEmpty ? _orderIds.first : purchaseId, valid));
    if (mounted) Navigator.pop(context, true);
    if (mounted) setState(() => _busy = false);
  }

  /// 新建一行：预生成行级 id（保存时 itemsPayload 复用同一 id——
  /// 顶栏整单凭证批量挂行依赖它与保存入库的明细行一致）
  _PRow _newPRow() => _PRow()
    ..rowId = 'pi${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(0x7fffffff)}';

  /// 复制上一笔进货单：预填明细，可修改后提交。
  /// Web 直连 /purchases?limit=1；原生零网络——读本地镜像按 happened_at 取最近一笔
  Future<void> _copyLast() async {
    try {
      Map<String, dynamic>? last;
      if (kIsWeb) {
        final d = await Api.instance.get('/purchases?limit=1');
        last = ((d['purchases'] as List?) ?? []).cast<Map<String, dynamic>>().firstOrNull;
      } else {
        final list = await LocalDb.getAll('purchases');
        list.sort((a, b) => '${b['happened_at'] ?? ''}'.compareTo('${a['happened_at'] ?? ''}'));
        last = list.firstOrNull;
      }
      if (last == null) {
        toast(context, '暂无历史进货单');
        return;
      }
      final items = ((last['items'] as List?) ?? []).cast<Map<String, dynamic>>();
      setState(() {
        _rows.clear();
        for (final it in items) {
          final itemId = '${it['item_id']}';
          final unit = '${it['unit'] ?? ''}';
          final match = _items.where((x) => '${x['id']}' == itemId).firstOrNull;
          final prices = ((match?['prices'] as List?) ?? []).cast<Map<String, dynamic>>();
          final price = prices.where((p) => '${p['unit']}' == unit).firstOrNull;
          if (match == null || price == null) continue;
          final qty = (it['quantity'] as num?)?.toDouble() ?? 0;
          final pp = (it['purchase_price'] as num?)?.toDouble() ?? 0;
          final row = _newPRow()
            ..itemId = itemId
            ..priceId = price['id'] as String?
            ..quantity = qty
            ..purchasePrice = pp
            ..happenedAt = '${it['happened_at'] ?? ''}'
            ..nameCtrl.text = '${it['item_name'] ?? match['name']}'
            ..unitCtrl.text = unit
            ..qtyCtrl.text = qty.toString()
            ..priceCtrl.text = pp.toStringAsFixed(2);
          _rows.add(row);
        }
        if (_rows.isEmpty) _rows.add(_newPRow());
      });
      toast(context, '已复制上一笔进货单，可修改后提交');
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    // 底部提交栏背景跟随主题（暗色非固定 0xFF1C1C1E 死黑=用户"最下边那一条"）
    final navColor = Theme.of(context).brightness == Brightness.dark
        ? Color.lerp(c.primary, Colors.black, 0.45)
        : c.card;
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: appBarBackground(context), // 顶部露出主题背景（无标题文字）
        actions: [
          IconButton(
            tooltip: '复制上一单',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: _busy ? null : _copyLast,
          ),
          PopupMenuButton<String>(
            tooltip: 'AI 记账（拍照/文字/语音）',
            icon: const Icon(Icons.auto_awesome_outlined),
            onSelected: (v) {
              if (v == 'photo') _aiParse();
              if (v == 'text') _aiText();
              if (v == 'voice') _aiVoice();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'photo', child: ListTile(leading: Icon(Icons.camera_alt_outlined), title: Text('拍照识别'), contentPadding: EdgeInsets.zero)),
              PopupMenuItem(value: 'text', child: ListTile(leading: Icon(Icons.keyboard_outlined), title: Text('文字记账'), contentPadding: EdgeInsets.zero)),
              PopupMenuItem(value: 'voice', child: ListTile(leading: Icon(Icons.mic_outlined), title: Text('语音记账'), contentPadding: EdgeInsets.zero)),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _infoCard(),
          const SizedBox(height: 10),
          for (int i = 0; i < _rows.length; i++) ...[
            _insertBar(i),
            _buildRow(i),
          ],
          const SizedBox(height: 10),
          // 添加商品（提交栏固定在底部悬浮）
          OutlinedButton.icon(
            onPressed: () => setState(
                () => _rows.add(_newPRow()..happenedAt = _dateCtrl.text.trim())),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加商品'),
            style: OutlinedButton.styleFrom(
              foregroundColor: c.success,
              side: BorderSide(color: c.success.withOpacity(0.5)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
        ],
      ),
      // 底部悬浮栏：合计 + 提交 固定可见，长单无需滚到底
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: BoxDecoration(
            color: navColor,
            border: Border(top: BorderSide(color: c.divider)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('合计', style: TextStyle(fontSize: 12, color: c.textSub)),
                    Text('¥${fmtMoney(_total)}',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: c.danger)),
                  ],
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(140, 48),
                  backgroundColor: c.success,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? '提交中…' : (_editing ? '保存修改' : '提交进货单')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 填充式输入框装饰（圆角 12、无边框、聚焦成功色描边）
  InputDecoration _fieldDec({IconData? icon, String? label, String? hint}) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: icon == null ? null : Icon(icon, size: 20, color: c.textSub),
      filled: true,
      fillColor: c.field,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c.success, width: 1.4),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }

  /// 卡片（主题卡片底、radius 16）
  Widget _card(Widget child) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Container(
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }

  /// 修改某一行商品的独立日期（不影响其他行）。统一紧凑滚轮（对齐小程序 picker mode=date，不占屏幕）
  Future<void> _pickRowDate(_PRow row) async {
    final cur = DateTime.tryParse(row.happenedAt.trim().isEmpty ? _dateCtrl.text.trim() : row.happenedAt.trim());
    final now = DateTime.now();
    final picked = await pickThemeDateCompact(
      context,
      initial: cur ?? now,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (picked == null) return;
    setState(() => row.happenedAt =
        '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}');
  }

  /// 进货日期信息卡
  Widget _infoCard() {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return _card(Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DateField(
            controller: _dateCtrl,
            icon: Icons.calendar_today_outlined,
            label: _editing ? '日期（新加商品默认）' : '进货日期',
            hint: '点击选择日期（可补录历史）',
            focusColor: c.success,
            onChanged: (_) => setState(() {
              // 批量直编：改批量日期=全部行改期（行级独立日期清空统一跟随新日期，
              // 对齐小程序"批量日期（全部行改期）"；普通/编辑模式只影响新行与无独立日期的行）
              if (widget.dateRows != null && widget.dateRows!.isNotEmpty) {
                for (final r in _rows) r.happenedAt = '';
              }
            }),
          ),
          if (_editing)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('每行商品可有自己的日期：点行内日期可单独修改，改某一行的日期不影响其他行。',
                  style: TextStyle(fontSize: 11, color: c.textSub, height: 1.4)),
            ),
          const SizedBox(height: 10),
          TextField(
            controller: _noteCtrl,
            style: TextStyle(color: c.textMain),
            decoration: _fieldDec(icon: Icons.notes_outlined, label: '备注（可留空）'),
          ),
          // 整单通用附件（当天单据共用的凭证：送货单/发货单等）；行级附件在各商品行单独加。
          // 识别/分享原图已"识别即挂载"为本单凭证（App 本地/Web 保存后直传），不再显示预览卡片
          const SizedBox(height: 4),
          Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: c.success.withOpacity(0.06),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            child: ListTile(
              dense: true,
              visualDensity: const VisualDensity(horizontal: 0, vertical: -2),
              leading: const Icon(Icons.image_outlined, size: 20, color: Color(0xFF409EFF)),
              title: const Text('整单凭证（自动关联全部商品）', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: const Text('上传一张凭证自动存到该单每个商品行', style: TextStyle(fontSize: 11)),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => showAttachmentViewer(
                  context, 'purchase',
                  // 批量直编：上传/查看挂真实原单 id（此前挂临时 _purchaseId=进货历史按真实单 id 查不到=附件不显示）
                  _orderIds.isNotEmpty ? _orderIds.first : _purchaseId,
                  '进货单附件',
                  lineIds: [
                    for (final r in _rows)
                      if (r.rowId.isNotEmpty) r.rowId,
                  ],
                  orderIds: [
                    ..._orderIds,
                    if (_purchaseId.isNotEmpty && !_orderIds.contains(_purchaseId)) _purchaseId,
                  ]),
            ),
          ),
        ],
      ),
    ));
  }

  /// 点击插入条：弹「补录/新商品」二选一——补录=并入上方行原单（共享整单凭证），
  /// 新商品=独立新单（附件单独挂）；对齐用户"补录和新商品插入方式显著分开"
  Future<void> _promptInsert(int i) async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.merge_type),
              title: const Text('补录（并入上方原单）'),
              subtitle: const Text('补漏的商品，整单凭证共享可见'),
              onTap: () => Navigator.pop(ctx, 'merge'),
            ),
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: const Text('新商品（独立新单）'),
              subtitle: const Text('补的不是原单商品，单独成一单、附件单独挂'),
              onTap: () => Navigator.pop(ctx, 'new'),
            ),
          ],
        ),
      ),
    );
    if (mode == null || !mounted) return;
    setState(() {
      final row = _newPRow()..happenedAt = _dateCtrl.text.trim();
      // 补录：归入上方行原单（插入位置=提交位置，整单凭证挂原单时插入行同单可见）；
      // 新商品：保持独立新单（保存时行级落库/独立成单）
      if (mode == 'merge' && i > 0 && _rows[i - 1].origPurchaseId.isNotEmpty) {
        row.origPurchaseId = _rows[i - 1].origPurchaseId;
        _rowPurchaseId[row.rowId] = row.origPurchaseId;
      }
      _rows.insert(i, row);
    });
  }

  /// 行上方插入条：点击在该行上方插入一行（补识别漏行/调整顺序与凭证一致）。
  /// 独立细条不占行头宽度（行头放 ➕ 会挤压商品名输入框，用户反馈只显示一个字）
  Widget _insertBar(int i) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return InkWell(
      onTap: () => _promptInsert(i),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Divider(color: c.primary.withOpacity(0.25), height: 1)),
            const SizedBox(width: 8),
            Icon(Icons.add_circle_outline, size: 15, color: c.primary.withOpacity(0.7)),
            const SizedBox(width: 4),
            Text('在此上方插入', style: TextStyle(fontSize: 12, color: c.primary.withOpacity(0.7))),
            const SizedBox(width: 8),
            Expanded(child: Divider(color: c.primary.withOpacity(0.25), height: 1)),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(int i) {
    final row = _rows[i];
    final c = Theme.of(context).extension<TaozhuColors>()!;
    final txtStyle = TextStyle(color: c.textMain);
    final item = row.itemId == null
        ? null
        : _items.where((x) => '${x['id']}' == row.itemId).firstOrNull;
    final name = row.nameCtrl.text.trim();
    final unmatched = name.isNotEmpty && item == null;
    return _card(Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: c.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text('${i + 1}',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: c.primary)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: row.nameCtrl,
                  style: txtStyle,
                  decoration: _fieldDec(label: '商品名称（可输入或选择）'),
                  onChanged: (v) => _onNameChanged(row, v),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '选择商品',
                icon: const Icon(Icons.search, size: 22, color: Color(0xFF409EFF)),
                onPressed: () => _pickItem(row),
              ),
              // 行级附件：该条商品独立凭证（仅编辑已有明细行；新建未提交行无行 id）
              if (row.rowId.isNotEmpty) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '该行凭证附件',
                  icon: const Icon(Icons.image_outlined, size: 20, color: Color(0xFF409EFF)),
                  onPressed: () => showAttachmentViewer(context, 'purchase_item', row.rowId,
                      '进货明细行凭证', lineIds: [row.rowId], orderIds: [row.origPurchaseId.isNotEmpty ? row.origPurchaseId : _purchaseId]),
                ),
              ],
              const SizedBox(width: 4),
              IconButton(
                tooltip: '删除此商品',
                icon: Icon(Icons.delete_outline, color: c.danger),
                onPressed: _rows.length > 1 ? () => setState(() => _rows.removeAt(i)) : null,
              ),
            ],
          ),
          if (item != null && '${item['category'] ?? ''}'.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 44),
              child: Text('分类：${item['category']}', style: TextStyle(fontSize: 11, color: c.textSub)),
            ),
          if (unmatched)
            Padding(
              padding: const EdgeInsets.only(left: 44, top: 2),
              child: Row(children: [
                Text('未在商品库：', style: TextStyle(fontSize: 12, color: c.warning)),
                InkWell(
                  onTap: () => _quickAddItem(row, name),
                  child: Text('新增商品「$name」',
                      style: TextStyle(fontSize: 12, color: c.primary, fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          const SizedBox(height: 6),
          TextField(
            controller: row.unitCtrl,
            style: txtStyle,
            decoration: _fieldDec(label: '单位（可手动填写）'),
            onChanged: (v) => _onUnitChanged(row, v),
          ),
          const SizedBox(height: 4),
          // 行独立日期：点此修改，只影响本行
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _pickRowDate(row),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Icon(Icons.event_outlined, size: 16, color: c.textSub),
                const SizedBox(width: 6),
                Text('该行日期：${row.happenedAt.trim().isEmpty ? _dateCtrl.text.trim() : row.happenedAt.trim()}',
                    style: TextStyle(fontSize: 13, color: c.primary, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('点此修改（不影响其他行）', style: TextStyle(fontSize: 11, color: c.textSub)),
              ]),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: NumberPadField(
                  controller: row.qtyCtrl,
                  style: txtStyle,
                  decoration: _fieldDec(label: '数量'),
                  onChanged: (v) => setState(() => row.quantity = double.tryParse(v) ?? 0),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: NumberPadField(
                  controller: row.priceCtrl,
                  style: txtStyle,
                  decoration: _fieldDec(label: _isStaff ? '进价（手工填写）' : '进价（可直接改）'),
                  onChanged: (v) => setState(() => row.purchasePrice = double.tryParse(v) ?? 0),
                ),
              ),
            ],
          ),
          // 折合计数输入（进销单位换算通用字段）：商品配了计数单位（袋/个…）且与当前单位不同时显示。
          // 填"本单折合几个计数单位"（进 1 大单位 → 填折合出的计数单位数），库存/备货按它累计——备货页显示"还剩几个"。
          if (item != null && '${item['count_unit'] ?? ''}'.isNotEmpty && '${item['count_unit'] ?? ''}' != row.unitCtrl.text.trim())
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: NumberPadField(
                controller: row.countCtrl,
                style: txtStyle,
                decoration: _fieldDec(
                    label: '折合 ${item!['count_unit']} 数（本单相当于 ${row.countCtrl.text.trim().isEmpty ? _autoPCount(row) : row.countCtrl.text.trim()} ${item!['count_unit']}；可改）'),
                onChanged: (v) {
                  row.countQty = double.tryParse(v);
                  setState(() {});
                },
              ),
            ),
        ],
      ),
    ));
  }
}

/// 录音工具：请求麦克风权限 → 弹窗按住/点开始/结束 → 返回录音字节。
/// 用于 AI 语音记账（调用后端 /ai/parse-voice：语音转文字后解析商品）。
class _VoiceRecorder {
  Future<({Uint8List bytes, String name, String mime})?> take() async {
    // 麦克风权限
    final perm = await Permission.microphone.request();
    if (!perm.isGranted) {
      if (takeContext != null) toast(takeContext!, '需要麦克风权限才能语音记账');
      return null;
    }
    final rec = AudioRecorder();
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/taozhu_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await rec.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    // 录音弹窗：开始 → 点击结束
    var finished = false;
    if (takeContext != null) {
      await showDialog<void>(
        context: takeContext!,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('语音记账'),
          content: const Text('正在录音，说完点击「结束」'),
          actions: [
            FilledButton(
              onPressed: () {
                finished = true;
                Navigator.pop(ctx);
              },
              child: const Text('结束'),
            ),
          ],
        ),
      );
    }
    await rec.stop();
    if (!finished && takeContext != null) toast(takeContext!, '已停止录音');
    final bytes = await XFile(path).readAsBytes();
    return (bytes: bytes, name: 'voice.m4a', mime: 'audio/mp4');
  }

  static BuildContext? takeContext;
}