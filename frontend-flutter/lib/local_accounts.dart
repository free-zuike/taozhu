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

  /// 账户详单（含开户行/卡号后四位）：
  /// - App：读本地库镜像（未同步过则为空 → 网络拉取写镜像；失败回退默认预设）
  /// - Web：直连服务器
  static Future<List<Map<String, dynamic>>> loadDetail() async {
    if (!kIsWeb) {
      try {
        final local = await LocalDb.getAll('payment_accounts');
        if (local.isNotEmpty) {
          local.sort((a, b) => ((a['sort'] as num?)?.toInt() ?? 0).compareTo((b['sort'] as num?)?.toInt() ?? 0));
          return local;
        }
      } catch (e) {
        appLog('accounts', '读取本地账户镜像失败: ${e.toString().split('\n').first}', level: 'error');
      }
    }
    try {
      final d = await Api.instance.get('/payment-accounts');
      final list = ((d['accounts'] as List?) ?? []).cast<Map<String, dynamic>>();
      if (list.isEmpty) {
        return [for (final n in _defaults) {'name': n}];
      }
      // App 同步写本地镜像（Web 无本地库，LocalDb 空操作）
      await _mirror(d);
      return list;
    } catch (e) {
      appLog('accounts', '拉取收款账户失败: ${e.toString().split('\n').first}', level: 'error');
      return [for (final n in _defaults) {'name': n}];
    }
  }

  /// 账户名列表（兼容旧调用：仅名字）
  static Future<List<String>> load() async {
    final rows = await loadDetail();
    return [for (final a in rows) '${a['name'] ?? ''}'.trim()].where((s) => s.isNotEmpty).toList();
  }

  /// 保存整个列表（增/删/改后统一调用）：全量覆盖服务端，成功后写本地镜像 + 触发增量同步
  /// [accounts] 形如 [{name, bank_name, card_last_four}]（开户行/卡号可空）
  static Future<void> save(List<Map<String, dynamic>> accounts) async {
    final items = accounts
        .where((a) => '${a['name'] ?? ''}'.trim().isNotEmpty)
        .map((a) => {
              'name': '${a['name'] ?? ''}'.trim(),
              'bank_name': '${a['bank_name'] ?? ''}'.trim(),
              'card_last_four': '${a['card_last_four'] ?? ''}'.trim(),
            })
        .toList();
    try {
      final d = await Api.instance.put('/payment-accounts', {'accounts': items});
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
                'bank_name': '${a['bank_name'] ?? ''}',
                'card_last_four': '${a['card_last_four'] ?? ''}',
                'sort': (a['sort'] as num?)?.toInt() ?? 0,
              })
          .toList();
      await LocalDb.putAll('payment_accounts', rows);
    } catch (e) {
      appLog('accounts', '写入账户本地镜像失败: ${e.toString().split('\n').first}', level: 'error');
    }
  }
}

/// 收款方式账户选择（收款登记/编辑用）：加载账户列表弹层选择。
/// [current] 当前已选值；返回选中账户名（null=取消）。管理入口在「我的 → 收款账户」。
/// 银行卡等带卡号账户显示「名称 · •••• 1234」区分同类型多张卡。
Future<String?> pickAccount(BuildContext context, {String current = ''}) async {
  final accounts = await LocalAccounts.loadDetail();
  if (!context.mounted) return null;
  final picked = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('选择收款方式'),
      children: [
        for (final a in accounts)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '${a['name'] ?? ''}'),
            child: Row(
              children: [
                Icon(Icons.account_balance_wallet_outlined, size: 18,
                    color: '${a['name'] ?? ''}' == current ? const Color(0xFF409EFF) : const Color(0xFF909399)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_labelOf(a), style: const TextStyle(fontSize: 15)),
                ),
              ],
            ),
          ),
      ],
    ),
  );
  return picked;
}

/// 账户显示名：带卡号/开户行的账户显示「名称 · 开户行(尾号1234)」；无附加信息仅名称
String _labelOf(Map<String, dynamic> a) {
  final name = '${a['name'] ?? ''}';
  final bank = '${a['bank_name'] ?? ''}'.trim();
  final card = '${a['card_last_four'] ?? ''}'.trim();
  if (bank.isEmpty && card.isEmpty) return name;
  final parts = [if (bank.isNotEmpty) bank, if (card.isNotEmpty) '尾号$card'];
  return '$name · ${parts.join(' ')}';
}
