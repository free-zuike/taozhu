import 'package:flutter/material.dart';

/// 全局统一弹窗入口：所有业务弹层一律**从屏幕中间弹出**（不混用底部抽屉），
/// 圆角卡片式、宽度随内容（超宽设备限制最大宽度）、高度不超过屏幕 88%。
/// 替代历史上分散的 showModalBottomSheet，保证全局版式一致。
/// 点击遮罩关闭（barrierDismissible），与底部抽屉行为一致。
Future<T?> showCenterSheet<T>({
  required BuildContext context,
  required Widget Function(BuildContext) builder,
  double maxHeightFactor = 0.88,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.of(ctx).size.height * maxHeightFactor,
        ),
        child: builder(ctx),
      ),
    ),
  );
}