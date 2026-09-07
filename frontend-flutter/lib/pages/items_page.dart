import 'package:flutter/material.dart';
import '../api.dart';

class ItemsPage extends StatefulWidget {
  const ItemsPage({super.key});
  @override
  State<ItemsPage> createState() => _ItemsPageState();
}

class _ItemsPageState extends State<ItemsPage> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await Api.instance.get('/items');
      setState(() {
        _items = ((d['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('商品管理')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final it in _items)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Text('${it['name']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                              const SizedBox(width: 8),
                              Text('${it['category'] ?? ''}', style: const TextStyle(color: Colors.grey)),
                            ]),
                            const SizedBox(height: 8),
                            for (final p in (it['prices'] as List? ?? []))
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Text('${p['unit']}：进 ¥${p['purchase_price']} → 出 ¥${p['sale_price']}'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (_items.isEmpty) const Center(child: Text('暂无商品', style: TextStyle(color: Colors.grey))),
                ],
              ),
            ),
    );
  }
}