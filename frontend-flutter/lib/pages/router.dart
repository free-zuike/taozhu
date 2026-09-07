import 'package:flutter/material.dart';
import 'home_page.dart';
import 'sale_page.dart';
import 'purchase_page.dart';
import 'items_page.dart';

/// 菜单索引 → 页面（与 AdminScaffold.menuItems 顺序一致）
Widget pageFor(int index) {
  switch (index) {
    case 0:
      return const HomePage();
    case 1:
      return const SalePage();
    case 2:
      return const PurchasePage();
    case 3:
      return const ItemsPage();
    default:
      return const HomePage();
  }
}

void goPage(BuildContext context, int index) {
  if (index == 0) {
    // 「工作台」= 回到根页面（任何二级页点它都回首页，且不叠加栈）
    Navigator.of(context).popUntil((r) => r.isFirst);
    return;
  }
  // 二级页用 push 压栈：系统返回键回到上一个页面（不能用 pushReplacement——会把当前页替换掉，返回=退出 App）
  Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => pageFor(index)));
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
}