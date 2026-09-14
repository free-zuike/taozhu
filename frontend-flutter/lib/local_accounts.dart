import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../api.dart';
import '../local_db.dart';
import '../log.dart';
import '../sync_service.dart';

/// 收款方式账户（收款账户，服务器同步实体）：现金/微信/支付宝/银行卡/转账 等。
/// - App：本地库镜像优先（离线秒开可下拉选择），账户管理走服务端 PUT（全量覆盖），成功后写本地镜像 + 触发同步
/// - Web：直连服务器
/// 数据以服务端为准（与其他同步实体一致），同步面板显示 本地 vs 服务器 账户数量。
class LocalAccounts {
  LocalAccounts._();
  static const _defaults = ['现金', '微信', '支付宝', '银行卡', '转账'];

  /// 账户名列表：
  /// - App：读本地库镜像（未同步过则为空 → 网络拉取写镜像；失败回退默认预设）
  /// - Web：直连服务器
  static Future<List<String>> load() async {
    if (!kIsWeb) {
      try {
        final local = await LocalDb.getAll('payment_accounts');
        if (local.isNotEmpty) {
          local.sort((a, b) => ((a['sort'] as num?)?.toInt() ?? 0).compareTo((b['sort'] as num?)?.toInt() ?? 0));
          return [for (final a in local) '${a['name'] ?? ''}'.trim()].where((s) => s.isNotEmpty).toList();
        }
      } catch (e) {
        appLog('accounts', '读取本地账户镜像失败: ${e.toString().split('\n').first}', level: 'error');
      }
    }
    try {
      final d = await Api.instance.get('/payment-accounts');
      final list = ((d['accounts'] as List?) ?? [])
          .cast<Map<String, dynamic>>()
          .map((a) => '${a['name'] ?? ''}'.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (list.isEmpty) return [..._defaults];
      // App 同步写本地镜像（Web 无本地库，LocalDb 空操作）
      await _mirror(d);
      return list;
    } catch (e) {
      appLog('accounts', '拉取收款账户失败: ${e.toString().split('\n').first}', level: 'error');
      return [..._defaults];
    }
  }

  /// 保存整个列表（增/删/改后统一调用）：全量覆盖服务端，成功后写本地镜像 + 触发增量同步
  static Future<void> save(List<String> accounts) async {
    final names = accounts.where((s) => s.trim().isNotEmpty).map((s) => s.trim()).toList();
    try {
      final d = await Api.instance.put('/payment-accounts', {
        'accounts': [for (final n in names) {'name': n}],
      });
      await _mirror(d);
      // App：服务端已记录变更流，触发增量拉取合并本机镜像（Web 无本地库，跳过）
      if (!kIsWeb) SyncService.schedulePullNow();
    } catch (e) {
      appLog('accounts', '保存收款账户失败: ${e.toString().split('\n').first}', level: 'error');
      rethrow;
    }
  }

  /// 服务端响应写入本地镜像（Web 端 LocalDb 空操作）
  static Future<void> _mirror(Map<String, dynamic> d) async {
    try {
      final rows = ((d['accounts'] as List?) ?? [])
          .cast<Map<String, dynamic>>()
          .map((a) => {
                'id': '${a['id'] ?? ''}',
                'name': '${a['name'] ?? ''}',
                'sort': (a['sort'] as num?)?.toInt() ?? 0,
              })
          .toList();
      await LocalDb.putAll('payment_accounts', rows);
    } catch (e) {
      appLog('accounts', '写入账户本地镜像失败: ${e.toString().split('\n').first}', level: 'error');
    }
  }
}

/// 收款方式账户选择（收款登记/编辑用）：加载账户列表弹层选择，带「管理账户」入口。
/// [current] 当前已选值；返回选中账户名（null=取消）。
Future<String?> pickAccount(BuildContext context, {String current = ''}) async {
  final accounts = await LocalAccounts.load();
  if (!context.mounted) return null;
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('选择收款方式'),
      children: [
        for (final a in accounts)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, a),
            child: Row(
              children: [
                Icon(Icons.account_balance_wallet_outlined, size: 18,
                    color: a == current ? const Color(0xFF409EFF) : const Color(0xFF909399)),
                const SizedBox(width: 10),
                Text(a, style: const TextStyle(fontSize: 15)),
              ],
            ),
          ),
        const Divider(height: 1),
        SimpleDialogOption(
          onPressed: () {
            Navigator.pop(ctx);
            _manageAccounts(ctx);
          },
          child: const Row(
            children: [
              Icon(Icons.settings_outlined, size: 18, color: Color(0xFF409EFF)),
              SizedBox(width: 10),
              Text('管理账户（增删改）', style: TextStyle(fontSize: 15, color: Color(0xFF409EFF))),
            ],
          ),
        ),
      ],
    ),
  );
  return picked;
}

/// 账户管理弹层：列出账户，可重命名/删除/新增（保存=全量覆盖服务端）
Future<bool?> _manageAccounts(BuildContext context) async {
  var accounts = await LocalAccounts.load();
  if (!context.mounted) return null;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlg) => AlertDialog(
        title: const Text('管理收款账户'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final (i, a) in accounts.indexed) ...[
                      if (i > 0) const Divider(height: 1),
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(a, style: const TextStyle(fontSize: 15)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () => _renameAccount(ctx, setDlg, accounts, i),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFF56C6C)),
                              onPressed: () => setDlg(() => accounts.removeAt(i)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (accounts.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('暂无账户，点下方「添加账户」', style: TextStyle(color: Color(0xFF909399))),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _addAccount(ctx, setDlg, accounts),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加账户'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              LocalAccounts.save(accounts).then((_) {
                if (ctx.mounted) Navigator.pop(ctx, true);
              }).catchError((_) {
                if (ctx.mounted) Navigator.pop(ctx, false);
              });
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _renameAccount(BuildContext ctx, StateSetter setDlg, List<String> accounts, int i) async {
  final ctrl = TextEditingController(text: accounts[i]);
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: const Text('重命名账户'),
      content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: '账户名称')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('保存')),
      ],
    ),
  );
  if (ok != true) return;
  final name = ctrl.text.trim();
  if (name.isEmpty) return;
  setDlg(() => accounts[i] = name);
}

Future<void> _addAccount(BuildContext ctx, StateSetter setDlg, List<String> accounts) async {
  final ctrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: const Text('添加账户'),
      content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: '账户名称')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('添加')),
      ],
    ),
  );
  if (ok != true) return;
  final name = ctrl.text.trim();
  if (name.isEmpty) return;
  setDlg(() {
    accounts.add(name);
    LocalAccounts.save(accounts);
  });
}