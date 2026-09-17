/// 强制更新弹窗（不可通过点背景/返回关闭）：当前版本已低于服务端最低支持版本时由
/// Api.onForceUpdate 回调或启动时检查 latest-version 触发。唯一出口=「复制下载链接」去浏览器更新。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../utils/update_sources.dart';

const _releaseUrl = 'https://github.com/free-zuike/taozhu/releases/latest';

/// 弹强制更新窗；[latest] 可为空（未知最新版时仅提示必须更新）
Future<void> showForceUpdateDialog(BuildContext context, String latest) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final c = Theme.of(ctx).extension<TaozhuColors>()!;
      return PopScope(
        canPop: false, // 返回键不可关：必须更新才能继续使用
        child: AlertDialog(
          title: const Text('版本已停用'),
          content: Text(
            latest.isEmpty
                ? '当前版本过低，已无法继续使用，请更新到最新版本后重试。'
                : '当前版本过低，必须更新到 v$latest 才能继续使用。',
          ),
          actions: [
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: c.primary),
              onPressed: () async {
                await Clipboard.setData(const ClipboardData(text: _releaseUrl));
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制下载链接，请在浏览器打开安装最新版（v 见提示）')),
                  );
                }
              },
              icon: const Icon(Icons.link, size: 18),
              label: const Text('复制下载链接'),
            ),
          ],
        ),
      );
    },
  );
}