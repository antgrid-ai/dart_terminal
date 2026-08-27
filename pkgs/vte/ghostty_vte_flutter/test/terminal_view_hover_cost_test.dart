import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'support/native_terminal.dart';

/// Hovering must not settle the styled formatter.
///
/// The formatter is three full-buffer passes plus a re-parse of the styled
/// output — tens of milliseconds on a real agent scrollback — and under
/// `renderState` the painter never reads it, so whatever asks for it pays the
/// whole cost alone. `_positionForOffset` used to ask, which put that rebuild
/// on every hover event and every selection-drag motion over a terminal that
/// was still producing output: the exact case the hyperlink affordance exists
/// for.
///
/// Timed rather than counted because the staleness flag is private to the
/// controller, and compared against the same loop WITHOUT the pointer move
/// rather than against a fixed millisecond bound. Both loops take the same
/// output and repaint the same frames, so the only difference between them is
/// the hover — which is what makes the ratio hold on any machine where an
/// absolute bound would drift with it.
void main() {
  testWidgets('hovering does not rebuild the transcript', (tester) async {
    if (!hasNativeTerminal) {
      return;
    }
    final controller = GhosttyTerminalController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 400,
            child: GhosttyTerminalView(
              controller: controller,
              autofocus: true,
              showHeader: false,
              onOpenHyperlink: (uri) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // What a full-screen agent does in its first frame: take the mouse.
    controller.appendOutputBytes(utf8.encode('\x1B[?1000h\x1B[?1006h'));

    final scrollback = StringBuffer();
    for (var i = 0; i < 3000; i++) {
      scrollback.write(
        '\x1B[32m[$i]\x1B[0m agent output with a '
        '\x1B]8;;https://example.com/$i\x07link\x1B]8;;\x07 in it\r\n',
      );
    }
    controller.appendOutputBytes(utf8.encode(scrollback.toString()));
    await tester.pumpAndSettle();

    final gesture = await tester.createGesture(
      kind: ui.PointerDeviceKind.mouse,
    );
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    const rounds = 40;

    // Output between frames is what marks the transcript stale, and it is the
    // normal state of an agent session — a hover with nothing new since the
    // last one finds it already settled and never showed this cost at all.
    Future<int> run({required bool movePointer, int count = rounds}) async {
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < count; i++) {
        controller.appendOutputBytes(utf8.encode('.'));
        if (movePointer) {
          await gesture.moveTo(Offset(40 + (i % 7).toDouble(), 30));
        }
        await tester.pump();
      }
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    }

    // Warm first and discard, so neither measurement carries the one-time cost
    // of the paths the other will then find warm.
    await run(movePointer: true, count: 5);
    // The control repaints the same frames from the same output; it just does
    // not move the pointer. Whatever separates the two IS the hover.
    final still = await run(movePointer: false);
    final hovering = await run(movePointer: true);

    expect(
      hovering,
      lessThan(still * 2 + 50),
      reason:
          '$rounds frames took ${hovering}ms with the pointer moving against '
          '${still}ms with it still — hovering is rebuilding the transcript '
          'again.',
    );
  });
}
