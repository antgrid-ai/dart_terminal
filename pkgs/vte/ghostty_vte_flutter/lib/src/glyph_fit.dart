import 'package:flutter/painting.dart';

/// Whether a glyph [glyphWidth] wide fits the [cellsWidth] of its cells.
///
/// [slack] is how far the font's natural advance may exceed the cells: cells
/// are snapped to whole pixels (and scaled by `cellWidthScale`) while glyphs
/// keep the font's advance, so an ordinary glyph can measure a little wider
/// than its cells without being oversized. Text painted as a single run
/// overflows by the same amount, so such a glyph must not be shrunk.
bool glyphFitsCells(double glyphWidth, double cellsWidth, {double slack = 0}) =>
    glyphWidth <= cellsWidth + slack;

/// Paints [painter]'s single grapheme into [cellRect], the cells the engine
/// gave it.
///
/// The engine owns column widths, so a glyph may not paint wider than its
/// cells. One that fits (see [glyphFitsCells] for [slack]) sits left-aligned
/// on the row baseline, exactly where a single-run paint would put it. One
/// that does not — a color emoji or an oversized symbol-font fallback standing
/// in for a glyph the terminal font lacks — is scaled down to the cells' width
/// and centered in them, as Ghostty constrains glyphs. Left to overflow, it
/// would cover its neighbours and be cut in half wherever a clip met it, such
/// as the content edge in column 0.
void paintGlyphInCells(
  Canvas canvas,
  TextPainter painter,
  Rect cellRect, {
  double slack = 0,
}) {
  if (glyphFitsCells(painter.width, cellRect.width, slack: slack)) {
    painter.paint(canvas, cellRect.topLeft);
    return;
  }
  canvas.save();
  canvas.translate(cellRect.center.dx, cellRect.center.dy);
  final scale = cellRect.width / painter.width;
  canvas.scale(scale, scale);
  painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
  canvas.restore();
}
