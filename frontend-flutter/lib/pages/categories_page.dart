import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../api.dart';
import '../local_db.dart';
import '../sync_service.dart';
import '../theme.dart';
import 'router.dart';

/// 分类管理：商品分类 / 店铺分类（两级）
class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key});
  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  TaozhuColors get _c => Theme.of(context).extension<TaozhuColors>()!;
  String _type = 'item';
  List<Map<String, dynamic>> _cats = [];
  bool _loading = true;
  /// 已收起的一级分类 id（二级分类默认展开，点一级标题折叠/展开）
  final Set<String> _collapsed = {};

  List<Map<String, dynamic>> get _top => _cats.where((c) => c['parent_id'] == null || '${c['parent_id']}' == '').toList();
  List<Map<String, dynamic>> _childrenOf(String id) =>
      _cats.where((c) => '${c['parent_id']}' == id).toList();

  @override
  void initState() {
    super.initState();
    SyncService.version.addListener(_onSync);
    _load();
  }

  @override
  void dispose() {
    SyncService.version.removeListener(_onSync);
    super.dispose();
  }

  void _onSync() {
    if (mounted) _load(network: true);
  }

  Future<void> _load({bool network = false}) async {
    // ① 本地库秒开（含空态；不再等网络转圈，页面加载零网络请求）
    final local = await LocalDb.getAll('categories');
    if (mounted) {
      setState(() {
        final byType = local.where((x) => '${x['type']}' == _type).toList();
        _cats = byType;
        _loading = false;
      });
    }
    // ② 网络刷新 + 写本地库（静默）：仅同步完成/下拉/Web 直连时执行
    if (!network && !kIsWeb) return;
    try {
      final d = await Api.instance.get('/categories?type=$_type');
      final rows = ((d['categories'] as List?) ?? []).cast<Map<String, dynamic>>();
      await LocalDb.upsertList('categories', rows);
      if (!mounted) return;
      setState(() {
        _cats = rows;
        _loading = false;
      });
    } catch (_) {
      // 离线：本地缓存已展示，错误已记日志，不再弹提示
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _add({String? parentId, String parentName = ''}) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(parentId == null ? '新增${_type == 'item' ? '商品' : '店铺'}分类' : '在「$parentName」下新增子分类'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: '分类名称')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty) {
      toast(context, '请填写分类名称');
      return;
    }
    try {
      if (kIsWeb) {
        // Web 无本地库/同步队列：直连服务端
        await Api.instance.post('/categories', {'type': _type, 'name': name, 'parent_id': parentId});
        toast(context, '已添加');
        _load(network: true);
        return;
      }
      // 原生本地优先：本地写 + 队列推送（分类是同步实体，离线可用）
      final id = 'cat${DateTime.now().microsecondsSinceEpoch}';
      final payload = {
        'id': id, 'type': _type, 'name': name,
        'parent_id': parentId ?? null, 'sort': 0,
      };
      await LocalDb.upsertOne('categories', payload);
      await SyncService.enqueueChange(entityType: 'category', entitySyncId: id, payload: payload);
      toast(context, '已添加，正在同步');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _rename(Map<String, dynamic> c) async {
    final ctrl = TextEditingController(text: '${c['name']}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分类'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: '分类名称')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final name = ctrl.text.trim();
    if (name.isEmpty || name == c['name']) return;
    try {
      if (kIsWeb) {
        // Web 无本地库/同步队列：直连服务端
        await Api.instance.patch('/categories/${c['id']}', {'name': name});
        toast(context, '已保存');
        _load(network: true);
        return;
      }
      // 原生本地优先：本地镜像更新 + 队列推送
      final payload = Map<String, dynamic>.from(c);
      payload['name'] = name;
      await LocalDb.upsertOne('categories', payload);
      await SyncService.enqueueChange(entityType: 'category', entitySyncId: '${c['id']}', payload: payload);
      toast(context, '已保存，正在同步');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _delete(Map<String, dynamic> c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分类'),
        content: Text('确定删除「${c['name']}」吗？\n该分类下的商品/店铺将变为未分类。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _c.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      if (kIsWeb) {
        // Web 无本地库/同步队列：直连服务端
        await Api.instance.delete('/categories/${c['id']}');
        toast(context, '已删除');
        _load(network: true);
        return;
      }
      // 原生本地优先：本地删行 + 队列推送 delete + 立即推送（删除即时生效，防复活）
      await LocalDb.deleteOne('categories', '${c['id']}');
      await SyncService.enqueueChange(
          entityType: 'category', entitySyncId: '${c['id']}',
          action: 'delete', payload: {});
      unawaited(SyncService.pushPending());
      toast(context, '已删除，正在同步');
      _load();
    } catch (e) {
      toast(context, e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = _c;
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: appBarBackground(context), // 顶部露出主题背景（无标题文字）
        actions: [
          IconButton(onPressed: () => _add(), icon: const Icon(Icons.add)),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(child: themePageBackground(context)),
          Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'item', label: Text('商品分类')),
                ButtonSegment(value: 'client', label: Text('店铺分类')),
              ],
              selected: {_type},
              onSelectionChanged: (s) {
                setState(() {
                  _type = s.first;
                  _loading = true;
                });
                _load();
              },
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: () => _load(network: true),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      children: [
                        if (_top.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(
                                child: Text('暂无分类，点右上角 ＋ 添加', style: TextStyle(color: colors.textSub))),
                          ),
                        for (final c in _top) ...[
                          _itemTile(c, indent: false),
                          if (!_collapsed.contains('${c['id']}'))
                            for (final child in _childrenOf('${c['id']}')) _itemTile(child, indent: true),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
        ],
      ),
    );
  }

  /// 分类图标（按名称映射常用 Material 图标，参考分类带图标；未匹配用默认）
  static IconData _catIcon(String name, {required bool isParent}) {
    const map = <String, IconData>{
      // 食材/肉类
      '肉': Icons.lunch_dining, '猪肉': Icons.lunch_dining, '牛肉': Icons.lunch_dining,
      '羊肉': Icons.lunch_dining, '鸡': Icons.set_meal, '鸭': Icons.set_meal,
      '鱼': Icons.set_meal, '虾': Icons.set_meal, '海鲜': Icons.set_meal, '水产': Icons.set_meal,
      '菜': Icons.eco, '蔬菜': Icons.eco, '水果': Icons.apple, '粮油': Icons.grain,
      '米': Icons.grain, '面': Icons.grain, '调料': Icons.blender, '干货': Icons.inventory_2,
      '豆': Icons.spa, '蛋': Icons.egg_alt, '奶': Icons.local_drink, '饮料': Icons.local_drink,
      '饮品': Icons.local_cafe, '冷冻': Icons.ac_unit, '冰': Icons.ac_unit,
      // 店铺
      '饭': Icons.restaurant, '餐': Icons.restaurant, '火锅': Icons.local_fire_department,
      '烧烤': Icons.outdoor_grill, '快餐': Icons.fastfood, '面馆': Icons.ramen_dining,
      '超市': Icons.local_grocery_store, '便利': Icons.storefront, '杂货': Icons.storefront,
      '批发': Icons.warehouse, '市场': Icons.storefront, '酒店': Icons.hotel,
      '食堂': Icons.restaurant, '档口': Icons.storefront,
    };
    for (final e in map.entries) {
      if (name.contains(e.key)) return e.value;
    }
    return isParent ? Icons.folder : Icons.label_outline;
  }

  /// 分类图标配色的主色（名字 hash 到一组主题色，参考彩色图标块）
  static Color _catColor(String name, {required bool isParent, Color? fallback}) {
    const palette = [
      Color(0xFFEF7830), // 橙
      Color(0xFF22A06B), // 绿
      Color(0xFF2F81C1), // 蓝
      Color(0xFFB78846), // 金
      Color(0xFFA05CE6), // 紫
      Color(0xFFD9544F), // 红
    ];
    var h = 0;
    for (final ch in name.codeUnits) h = (h * 31 + ch) & 0x7fffffff;
    return palette[h % palette.length];
  }

  /// 查看该分类下商品/店铺（弹层列表）：商品按本地 items 镜像 category_id 匹配（一级=含子分类）；
  /// 店铺按 clients 镜像 category_id 匹配。
  Future<void> _viewItems(Map<String, dynamic> c) async {
    final ids = <String>{'${c['id']}'};
    for (final ch in _childrenOf('${c['id']}')) ids.add('${ch['id']}');
    final isItem = _type == 'item';
    List<Map<String, dynamic>> src;
    if (kIsWeb) {
      // Web 无本地库：直连服务器（用户"Web 分类查看商品都显示暂无商品"）
      try {
        final d = await Api.instance.get(isItem ? '/items?limit=1000' : '/clients');
        src = ((d[isItem ? 'items' : 'clients'] as List?) ?? []).cast<Map<String, dynamic>>();
      } catch (_) {
        src = [];
      }
    } else if (isItem) {
      src = await LocalDb.getAllByName('items');
    } else {
      src = await LocalDb.getAllByName('clients');
    }
    final rows = src.where((x) => ids.contains('${x['category_id'] ?? ''}')).toList();
    if (!mounted) return;
    if (rows.isEmpty) { toast(context, '该分类下暂无${isItem ? '商品' : '店铺'}'); return; }
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text('「${c['name']}」分类${isItem ? '商品' : '店铺'}（${rows.length} 个）',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final r in rows)
                    ListTile(
                      dense: true,
                      leading: Icon(isItem ? Icons.inventory_2_outlined : Icons.store_outlined,
                          size: 20, color: const Color(0xFF409EFF)),
                      title: Text('${r['name']}', style: const TextStyle(fontSize: 14)),
                      subtitle: isItem ? _itemPriceText(r) : null,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 商品镜像的首单位价格文本（prices 数组首项：单位+售价）
  Widget _itemPriceText(Map<String, dynamic> it) {
    final prices = (it['prices'] as List?) ?? const [];
    if (prices.isEmpty) return const Text('（无价格）', style: TextStyle(fontSize: 12));
    final p = (prices.first as Map);
    return Text('${p['unit'] ?? '件'}：售价 ¥${(p['sale_price'] as num?)?.toStringAsFixed(2) ?? '0.00'}',
        style: const TextStyle(fontSize: 12));
  }

  Widget _itemTile(Map<String, dynamic> c, {required bool indent}) {
    final isParent = _childrenOf('${c['id']}').isNotEmpty;
    final collapsed = _collapsed.contains('${c['id']}');
    final color = _catColor('${c['name']}', isParent: !indent);
    final children = indent ? const <Map<String, dynamic>>[] : _childrenOf('${c['id']}');
    return Card(
      elevation: 0,
      margin: EdgeInsets.only(bottom: indent ? 0 : 10),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(indent ? 0 : 12),
            bottom: Radius.circular(12),
          ),
          side: BorderSide(color: _c.divider)),
      child: ListTile(
        contentPadding: EdgeInsets.only(left: indent ? 36 : 16, right: 8),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
          child: Icon(_catIcon('${c['name']}', isParent: !indent),
              color: color, size: 22),
        ),
        title: Text('${c['name']}', style: TextStyle(fontWeight: indent ? FontWeight.w400 : FontWeight.w600)),
        subtitle: (!indent && children.isNotEmpty)
            ? Text('${children.length} 个子分类', style: TextStyle(fontSize: 12, color: _c.textSub))
            : null,
        // 一级分类可点击折叠/展开子分类（有子分类时显示箭头）
        onTap: isParent && !indent
            ? () => setState(() {
                  if (!_collapsed.add('${c['id']}')) _collapsed.remove('${c['id']}');
                })
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _iconBtn(
              icon: const Icon(Icons.view_list_outlined, size: 20),
              tooltip: '查看该分类下${_type == 'item' ? '商品' : '店铺'}',
              onPressed: () => _viewItems(c),
            ),
            if (isParent && !indent)
              Icon(collapsed ? Icons.expand_more : Icons.expand_less, size: 20, color: _c.textSub),
            _iconBtn(
              icon: const Icon(Icons.add, size: 20),
              tooltip: '添加子分类',
              // 一级分类可添加任意多个子分类；仅禁止二级分类继续加（防三级）
              onPressed: indent ? null : () => _add(parentId: '${c['id']}', parentName: '${c['name']}'),
            ),
            _iconBtn(
              icon: const Icon(Icons.edit_outlined, size: 20),
              tooltip: '改名',
              onPressed: () => _rename(c),
            ),
            _iconBtn(
              icon: Icon(Icons.delete_outline, size: 20, color: _c.danger),
              tooltip: '删除',
              onPressed: () => _delete(c),
            ),
          ],
        ),
      ),
    );
  }

  /// 行尾紧凑图标按钮：收紧命中区避免把分类名挤成竖排（此前横排 5 个默认 IconButton 宽度溢出）
  Widget _iconBtn({required Icon icon, required String tooltip, VoidCallback? onPressed}) {
    return IconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 40),
      visualDensity: VisualDensity.compact,
    );
  }
}
