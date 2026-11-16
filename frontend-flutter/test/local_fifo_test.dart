import 'package:flutter_test/flutter_test.dart';
import 'package:taozhu_app/utils/local_fifo.dart';

Map<String, dynamic> buy(String id, double price, double qty, String t) => {
      'id': id, 'item_id': 'i1', 'unit': '斤', 'purchase_price': price,
      'quantity': qty, 'happened_at': t,
    };

Map<String, dynamic> sale(String id, double qty, String t) => {
      'id': id, 'item_id': 'i1', 'unit': '斤', 'quantity': qty, 'happened_at': t,
    };

void main() {
  group('localFifoConsume（离线报损/盘亏成本估值）', () {
    test('先消耗最早批次；已有出货按时间序扣减，再跨批加权', () {
      final r = localFifoConsume(
        itemId: 'i1', unit: '斤', qty: 5,
        buyRows: [buy('b1', 2, 3, '2026-01-01'), buy('b2', 4, 10, '2026-01-02')],
        saleRows: [sale('s1', 2, '2026-01-03')], // 先扣 b1 两斤 → 剩 b1=1@2、b2=10@4
        lossRows: [],
      );
      expect(r.covered, 5);
      expect(r.cost, 18); // 1×2 + 4×4
    });

    test('报损也参与批次消耗（同口径）', () {
      final r = localFifoConsume(
        itemId: 'i1', unit: '斤', qty: 2,
        buyRows: [buy('b1', 2, 5, '2026-01-01')],
        saleRows: [],
        lossRows: [
          {'id': 'l1', 'item_id': 'i1', 'unit': '斤', 'qty': 4, 'happened_at': '2026-01-02'},
        ],
      );
      expect(r.covered, 1); // 5−4=1 斤可覆盖
      expect(r.cost, 2);
    });

    test('批次不足：covered 小于 qty，成本只算覆盖部分', () {
      final r = localFifoConsume(
        itemId: 'i1', unit: '斤', qty: 10,
        buyRows: [buy('b1', 2, 3, '2026-01-01')],
        saleRows: [],
        lossRows: [],
      );
      expect(r.covered, 3);
      expect(r.cost, 6);
    });

    test('过滤其他商品/单位', () {
      final r = localFifoConsume(
        itemId: 'i1', unit: '斤', qty: 1,
        buyRows: [
          buy('b1', 2, 10, '2026-01-01'),
          {'id': 'x', 'item_id': 'i2', 'unit': '斤', 'purchase_price': 99, 'quantity': 10, 'happened_at': '2026-01-01'},
          {'id': 'y', 'item_id': 'i1', 'unit': '件', 'purchase_price': 99, 'quantity': 10, 'happened_at': '2026-01-01'},
        ],
        saleRows: [],
        lossRows: [],
      );
      expect(r.cost, 2);
    });

    test('档案进价回退', () {
      final items = [
        {
          'id': 'i1',
          'prices': [
            {'unit': '斤', 'purchase_price': 3.5},
            {'unit': '件', 'purchase_price': 20},
          ],
        },
      ];
      expect(localArchivePrice(items, 'i1', '斤'), 3.5);
      expect(localArchivePrice(items, 'i1', '箱'), 0);
      expect(localArchivePrice(items, 'nope', '斤'), 0);
    });
  });
}
