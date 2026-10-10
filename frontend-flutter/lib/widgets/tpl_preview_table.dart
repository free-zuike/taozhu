/// 对账单模板成品预览表格：与模板编辑同款 TableView（two_dimensional_scrollables）。
/// 支持 rowSpan/colSpan 合并单元格渲染——编辑时可见的合并，预览里同样可见。
/// 边框为**单元格级**（GridCell.borderTop/Right/Bottom/Left 每侧独立开关，Excel 式逐格设置线）。
import 'package:flutter/material.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';
import '../statement_tmpl.dart';

/// 按单元格四边开关绘制边框（单侧 BorderSide 组合；与结构边框一致用浅灰细线）
Border _cellBorder(GridCell cell, {Color borderC = const Color(0xFFD9D9D9), double width = 0.5}) {
  return Border(
    top: cell.borderTop ? BorderSide(color: borderC, width: width) : BorderSide.none,
    right: cell.borderRight ? BorderSide(color: borderC, width: width) : BorderSide.none,
    bottom: cell.borderBottom ? BorderSide(color: borderC, width: width) : BorderSide.none,
    left: cell.borderLeft ? BorderSide(color: borderC, width: width) : BorderSide.none,
  );
}

/// 渲染模板行集合为只读表格（默认列宽 120/行高 44，横向滚动查看）。
/// [primary] 用于底纹（bg='grey' 的表头浅色底）。
Widget tplPreviewTable(List<List<GridCell>> rows, {double fontSize = 12, Color? primary}) {
  const borderC = Color(0xFFD9D9D9);
  // 列数 = colSpan 展开宽度（合并起点占多列，物理格子数会漏列）
  int rowWidth(List<GridCell> row) {
    var w = 0;
    for (final c in row) {
      w += c.colSpan < 1 ? 1 : c.colSpan;
    }
    return w;
  }
  final cols = rows.fold<int>(0, (m, r) => rowWidth(r) > m ? rowWidth(r) : m);

  // 展开列坐标 → 该行实际格子索引
  ({int idx, GridCell cell}) cellAt(int r, int c) {
    final row = rows[r];
    var acc = 0;
    for (var i = 0; i < row.length; i++) {
      final span = row[i].colSpan < 1 ? 1 : row[i].colSpan;
      if (c < acc + span) return (idx: i, cell: row[i]);
      acc += span;
    }
    return (idx: row.length - 1, cell: row.isEmpty ? GridCell() : row.last);
  }

  // 查找覆盖 (r,c) 的合并起点（含自身），与模板编辑页 owner 同逻辑。
  // 按 colSpan 展开列坐标遍历（合并起点 colSpan>1 占多列，其后格子索引后移——物理索引遍历会漏合并）
  ({int sr, int sc, int rs, int cs})? owner(int r, int c) {
    for (var sr = 0; sr <= r && sr < rows.length; sr++) {
      final row = rows[sr];
      var acc = 0;
      for (var i = 0; i < row.length; i++) {
        final cell = row[i];
        final span = cell.colSpan < 1 ? 1 : cell.colSpan;
        if (c < acc + span &&
            (cell.rowSpan > 1 || cell.colSpan > 1) &&
            r < sr + cell.rowSpan) {
          return (sr: sr, sc: acc, rs: cell.rowSpan, cs: cell.colSpan);
        }
        acc += span;
      }
    }
    return null;
  }

  TableSpan colSpan(int i) => const TableSpan(
        extent: FixedTableSpanExtent(120),
        // 边框改在单元格内绘制（单元格级四边开关）；列 span 不再画统一 trailing 线
        foregroundDecoration: TableSpanDecoration(border: TableSpanBorder()),
      );
  TableSpan rowSpan(int i) => const TableSpan(
        extent: FixedTableSpanExtent(44),
        foregroundDecoration: TableSpanDecoration(border: TableSpanBorder()),
      );

  return TableView.builder(
    columnCount: cols,
    rowCount: rows.length,
    columnBuilder: colSpan,
    rowBuilder: rowSpan,
    cellBuilder: (context, vicinity) {
      final r = vicinity.row;
      final c = vicinity.column;
      if (r >= rows.length) {
        return TableViewCell(child: const SizedBox.shrink());
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
      final at = cellAt(r, c);
      final cell = at.cell;
      return TableViewCell(
        rowMergeStart: o?.sr ?? r,
        rowMergeSpan: o?.rs ?? 1,
        columnMergeStart: o?.sc ?? c,
        columnMergeSpan: o?.cs ?? 1,
        child: Container(
          decoration: BoxDecoration(border: _cellBorder(cell, borderC: borderC)),
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