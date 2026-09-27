import 'package:flutter/material.dart';
import '../theme.dart';

/// 主题设置（静态主题：配色 + 背景；动态主题后续版本支持）。
/// 选择即时生效并持久化，无需保存按钮。
class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({super.key});
  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<TaozhuColors>()!;
    return Scaffold(
      appBar: AppBar(title: const Text('主题设置')),
      body: ListenableBuilder(
        listenable: Listenable.merge([ThemeConfig.instance, themeNotifier]),
        builder: (context, _) {
          final cfg = ThemeConfig.instance;
          final preset = cfg.preset;
          final dark = themeNotifier.value == ThemeMode.dark ||
              (themeNotifier.value == ThemeMode.system &&
                  MediaQuery.of(context).platformBrightness == Brightness.dark);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: c.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '静态主题：选择配色与背景立即生效。动态主题（动画/动态壁纸）将在后续版本支持。',
                  style: TextStyle(fontSize: 13, color: c.textMain, height: 1.4),
                ),
              ),
              const SizedBox(height: 18),
              _groupTitle(c, '配色主题'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 12,
                children: [for (final p in kThemePresets) _presetTile(cfg, p, dark)],
              ),
              const SizedBox(height: 20),
              _groupTitle(c, '明暗模式'),
              const SizedBox(height: 8),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
                  ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                ],
                selected: {themeNotifier.value},
                onSelectionChanged: (s) => setThemeMode(s.first),
              ),
              const SizedBox(height: 20),
              _groupTitle(c, '背景'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('显示背景渐变', style: TextStyle(fontSize: 14)),
                subtitle: const Text('页面使用主题背景（静态背景）', style: TextStyle(fontSize: 12)),
                value: cfg.bgEnabled,
                onChanged: (v) => cfg.setBgEnabled(v),
              ),
              const SizedBox(height: 10),
              _previewCard(c, preset, cfg.bgEnabled, dark),
            ],
          );
        },
      ),
    );
  }

  Widget _groupTitle(TaozhuColors c, String t) {
    return Text(t, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.textMain));
  }

  Widget _presetTile(ThemeConfig cfg, ThemePreset p, bool dark) {
    final selected = cfg.presetId == p.id;
    final main = dark ? p.darkPrimary : p.lightPrimary;
    return InkWell(
      onTap: () => cfg.setPreset(p.id),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 92,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).extension<TaozhuColors>()!.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? main : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [main, main.withOpacity(0.5)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, color: Colors.white, size: 26)
                  : null,
            ),
            const SizedBox(height: 8),
            Text(
              p.name,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).extension<TaozhuColors>()!.textMain,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 实时预览：主题背景 + 卡片 + 按钮
  Widget _previewCard(TaozhuColors c, ThemePreset preset, bool bgOn, bool dark) {
    final main = dark ? preset.darkPrimary : preset.lightPrimary;
    return Container(
      height: 190,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: bgOn
              ? (dark ? const [Color(0xFF17181C), Color(0xFF101216)] : preset.bgGradient)
              : [Theme.of(context).scaffoldBackgroundColor, Theme.of(context).scaffoldBackgroundColor],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: main, borderRadius: BorderRadius.circular(8)),
                child: Icon(Icons.storefront_outlined, size: 16, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Text('预览', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: c.textMain)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: main.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                child: Text('本月结余', style: TextStyle(fontSize: 11, color: main)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.card.withOpacity(dark ? 0.85 : 0.92),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(width: 120, height: 12, decoration: BoxDecoration(color: c.divider, borderRadius: BorderRadius.circular(6))),
                  const SizedBox(height: 10),
                  Container(width: 180, height: 12, decoration: BoxDecoration(color: c.divider, borderRadius: BorderRadius.circular(6))),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 34,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: main, borderRadius: BorderRadius.circular(9)),
                          child: const Text('按钮', style: TextStyle(color: Colors.white, fontSize: 12)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Container(
                          height: 34,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(border: Border.all(color: main, width: 1.5), borderRadius: BorderRadius.circular(9)),
                          child: Text('次要按钮', style: TextStyle(color: main, fontSize: 12)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
