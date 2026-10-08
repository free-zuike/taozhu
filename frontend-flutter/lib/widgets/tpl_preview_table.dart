/// 对账单模板成品预览表格：与模板编辑同款 TableView（two_dimensional_scrollables）。
/// 支持 rowSpan/colSpan 合并单元格渲染——编辑时可见的合并，预览里同样可见。
import 'package:flutter/material.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';
import '../statement_tmpl.dart';

/// 渲染模板行集合为只读表格（默认列宽 120/行高 44，横向滚动查看）。
/// [primary] 用于底纹（bg='grey' 的表头浅色底）。
Widget tplPreviewTable(List<List<GridCell>> rows, {double fontSize = 12, Color? primary}) {
  const borderC = Color(0xFFD9D9D9);
  final cols = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);

  // 查找覆盖 (r,c) 的合并起点（含自身），与模板编辑页 owner 同逻辑
  ({int sr, int sc, int rs, int cs})? owner(int r, int c) {
    for (var sr = 0; sr <= r && sr < rows.length; sr++) {
      final row = rows[sr];
      for (var sc = 0; sc <= c && sc < row.length; sc++) {
        final cell = row[sc];
        if ((cell.rowSpan > 1 || cell.colSpan > 1) && r < sr + cell.rowSpan && c < sc + cell.colSpan) {
          return (sr: sr, sc: sc, rs: cell.rowSpan, cs: cell.colSpan);
        }
      }
    }
    return null;
  }

  TableSpan colSpan(int i) => TableSpan(
        extent: const FixedTableSpanExtent(120),
        foregroundDecoration: TableSpanDecoration(
          border: TableSpanBorder(trailing: BorderSide(color: borderC, width: 0.5)),
        ),
      );
  TableSpan rowSpan(int i) => TableSpan(
        extent: const FixedTableSpanExtent(44),
        foregroundDecoration: TableSpanDecoration(
          border: TableSpanBorder(trailing: BorderSide(color: borderC, width: 0.5)),
        ),
      );

  return TableView.builder(
    columnCount: cols,
    rowCount: rows.length,
    columnBuilder: colSpan,
    rowBuilder: rowSpan,
    cellBuilder: (context, vicinity) {
      final r = vicinity.row;
      final c = vicinity.column;
      if (r >= rows.length || c >= rows[r].length) {
        return TableViewCell(
          foregroundDecoration: TableSpanDecoration(
            border: TableSpanBorder(
              leading: BorderSide(color: borderC, width: 0.5),
              top: BorderSide(color: borderC, width: 0.5),
            ),
          ),
          child: const SizedBox.shrink(),
        );
      }
      final o = owner(r, c);
      // 被合并覆盖的格：带相同 merge 信息占位（保证真合并渲染）
      if (o != null && (o.sr != r || o.sc != c)) {
        return TableViewCell(
          rowMergeStart: o.sr,
          rowMergeSpan: o.rs,
          columnMergeStart: o.sc,
          columnMergeSpan: o.cs,
          child: const SizedBox.shrink(),
        );
      }
      final cell = rows[r][c];
      return TableViewCell(
        rowMergeStart: o?.sr ?? r,
        rowMergeSpan: o?.rs ?? 1,
        columnMergeStart: o?.sc ?? c,
        columnMergeSpan: o?.cs ?? 1,
        foregroundDecoration: TableSpanDecoration(
          border: TableSpanBorder(
            leading: BorderSide(color: borderC, width: 0.5),
            top: BorderSide(color: borderC, width: 0.5),
          ),
        ),
        child: Container(
          color: cell.bg == 'grey' ? (primary ?? const Color(0xFFE8E8E8)).withOpacity(0.12) : null,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          alignment: cell.align == 'center'
              ? Alignment.center
              : (cell.align == 'right' ? Alignment.centerRight : Alignment.centerLeft),
          child: Text(cell.text,
              textAlign: cell.align == 'center'
                  ? TextAlign.center
                  : (cell.align == 'right' ? TextAlign.right : TextAlign.left),
              style: TextStyle(
                  fontSize: cell.bold ? fontSize + 2 : fontSize,
                  fontWeight: cell.bold ? FontWeight.w700 : FontWeight.normal,
                  color: cell.bg == 'grey' ? primary : null)),
        ),
      );
    },
  );
}