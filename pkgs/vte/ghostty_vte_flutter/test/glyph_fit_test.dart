import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/src/glyph_fit.dart';

void main() {
  // The test font draws every glyph as a solid 1em box, so a large font size
  // stands in for a color emoji or symbol-font fallback wider than its cell.
  const canvasSize = Size(120, 60);
  const cellRect = Rect.fromLTWH(40, 20, 10, 20);

  TextPainter glyph(double fontSize) => TextPainter(
    text: TextSpan(
      text: 'M',
      style: TextStyle(
        fontSize: fontSize,
        height: 1,
        color: const Color(0xFFFFFFFF),
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();

  /// The extent of every pixel painted at least half opaque, so anti-aliased
  /// fringes don't count.
  Future<Rect?> paintedBounds(
    WidgetTester tester,
    TextPainter painter, {
    double slack = 0,
  }) async {
    final recorder = ui.PictureRecorder();
    paintGlyphInCells(Canvas(recorder), painter, cellRect, slack: slack);
    final picture = recorder.endRecording();
    final width = canvasSize.width.toInt();
    // Image work must run outside the test's fake-async zone or it never
    // completes.
    final bytes = (await tester.runAsync(() async {
      final image = await picture.toImage(width, canvasSize.height.toInt());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return bytes;
    }))!;
    picture.dispose();

    Rect? bounds;
    for (var pixel = 0; pixel < bytes.lengthInBytes ~/ 4; pixel++) {
      if (bytes.getUint8((pixel * 4) + 3) >= 128) {
        final dot = Rect.fromLTWH(
          (pixel % width).toDouble(),
          (pixel ~/ width).toDouble(),
          1,
          1,
        );
        bounds = bounds?.expandToInclude(dot) ?? dot;
      }
    }
    return bounds;
  }

  testWidgets('a glyph that fits paints unscaled at the cell origin', (
    tester,
  ) async {
    final bounds = await paintedBounds(tester, glyph(10));

    expect(bounds, isNotNull);
    expect(bounds!.left, cellRect.left);
    expect(bounds.width, 10);
  });

  testWidgets('a glyph within the snapping slack paints unscaled', (
    tester,
  ) async {
    // The font advances 11px but the cell was snapped to 10px: an ordinary
    // glyph, not an oversized one, so it keeps its size like run text does.
    final bounds = await paintedBounds(tester, glyph(11), slack: 1);

    expect(bounds, isNotNull);
    expect(bounds!.left, cellRect.left);
    expect(bounds.width, 11);
  });

  testWidgets('a glyph wider than its cell is scaled to fit and centered', (
    tester,
  ) async {
    final bounds = await paintedBounds(tester, glyph(30));

    expect(bounds, isNotNull);
    expect(bounds!.left, greaterThanOrEqualTo(cellRect.left));
    expect(bounds.right, lessThanOrEqualTo(cellRect.right));
    // Scaled, not clipped: the whole cell width is covered, and the square
    // glyph keeps its aspect ratio about the cell's vertical center.
    expect(bounds.width, closeTo(cellRect.width, 1));
    expect(bounds.height, closeTo(cellRect.width, 1));
    expect(bounds.center.dy, closeTo(cellRect.center.dy, 1));
  });
}
