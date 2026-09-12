import 'package:flutter/material.dart';
import '../theme.dart';
import 'account_settings_page.dart';
import 'users_page.dart';

/// 成员：账号设置（我的资料 / 密码 / 两步验证 / 服务器地址）+ 账号管理（成员列表，仅老板可操作）。
/// 「我的」页同步卡片下方入口；把原「账号设置」「账号管理」合并为一个入口。
class MembersPage extends StatefulWidget {
  const MembersPage({super.key});
  @override
  State<MembersPage> createState() => _MembersPageState();
}

class _MembersPageState extends State<MembersPage> {
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('成员'),
          bottom: TabBar(
            labelColor: c.primary,
            indicatorColor: c.primary,
            tabs: const [
              Tab(text: '账号设置'),
              Tab(text: '账号管理'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            AccountSettingsPage(embed: true),
            UsersPage(embed: true),
          ],
        ),
      ),
    );
  }
}