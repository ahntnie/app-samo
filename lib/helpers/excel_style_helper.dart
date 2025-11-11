import 'dart:math' as math;

import 'package:excel/excel.dart';

class ExcelSizingTracker {
  final List<double> _maxColumnWidths;
  final Map<int, int> _rowLineCounts = {};

  ExcelSizingTracker(int columnCount)
      : _maxColumnWidths = List<double>.filled(columnCount, 0);

  void update(int rowIndex, int columnIndex, String? rawValue) {
    final value = (rawValue ?? '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = value.isEmpty ? const [''] : value.split('\n');
    final longestLine = lines.fold<int>(
      0,
      (currentMax, line) => math.max(currentMax, line.length),
    );
    if (_maxColumnWidths[columnIndex] < longestLine.toDouble()) {
      _maxColumnWidths[columnIndex] = longestLine.toDouble();
    }
    final currentLines = _rowLineCounts[rowIndex] ?? 1;
    final effectiveLines = lines.length;
    if (effectiveLines > currentLines) {
      _rowLineCounts[rowIndex] = effectiveLines;
    } else if (!_rowLineCounts.containsKey(rowIndex)) {
      _rowLineCounts[rowIndex] = currentLines;
    }
  }

  void applyToSheet(Sheet sheet) {
    final baseRowHeight = (sheet.defaultRowHeight ?? 15).toDouble();
    final baseColumnWidth = (sheet.defaultColumnWidth ?? 8.43).toDouble();

    for (int columnIndex = 0;
        columnIndex < _maxColumnWidths.length;
        columnIndex++) {
      final contentWidth = _maxColumnWidths[columnIndex];
      final computedWidth =
          contentWidth > 0 ? contentWidth + 2 : baseColumnWidth;
      sheet.setColumnWidth(
        columnIndex,
        math.max(baseColumnWidth, computedWidth),
      );
    }

    _rowLineCounts.forEach((rowIndex, lineCount) {
      final effectiveLineCount = lineCount < 1 ? 1 : lineCount;
      sheet.setRowHeight(rowIndex, baseRowHeight * effectiveLineCount);
    });
  }
}

class ExcelCellStyles {
  final CellStyle header;
  final CellStyle centered;
  final CellStyle multiline;

  ExcelCellStyles._({
    required this.header,
    required this.centered,
    required this.multiline,
  });

  factory ExcelCellStyles.build({Border? border}) {
    final cellBorder = border ?? Border(borderStyle: BorderStyle.Thin);

    CellStyle createStyle({
      required bool bold,
      required VerticalAlign verticalAlign,
    }) {
      return CellStyle(
        bold: bold,
        horizontalAlign: HorizontalAlign.Center,
        verticalAlign: verticalAlign,
        textWrapping: TextWrapping.WrapText,
        topBorder: cellBorder,
        bottomBorder: cellBorder,
        leftBorder: cellBorder,
        rightBorder: cellBorder,
      );
    }

    return ExcelCellStyles._(
      header: createStyle(bold: true, verticalAlign: VerticalAlign.Center),
      centered: createStyle(bold: false, verticalAlign: VerticalAlign.Center),
      multiline: createStyle(bold: false, verticalAlign: VerticalAlign.Top),
    );
  }
}

