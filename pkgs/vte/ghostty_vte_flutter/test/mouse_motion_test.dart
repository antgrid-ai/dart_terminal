import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

import 'support/native_terminal.dart';

const _interval = Duration(milliseconds: 50);
const _size = VtMouseEncoderSize(
  screenWidth: 800,
  screenHeight: 600,
  cellWidth: 10,
  cellHeight: 20,
);

void main() {
  test('required native mouse engine is available', () {
    if (const bool.fromEnvironment('requireNativeTerminal')) {
      expect(hasNativeTerminal, isTrue);
    }
  });

  testWidgets('synchronous transport cancellation does not rearm cooldown', (
    tester,
  ) async {
    if (!hasNativeTerminal) return;
    final h = _MouseHarness();
    addTearDown(h.controller.dispose);
    h.controller.attachExternalTransport(
      writeBytes: (bytes) {
        h.sent.add(utf8.decode(bytes));
        h.controller.cancelPendingMouseMotion();
        return true;
      },
      forwardGuestQueryReplies: false,
    );

    expect(h.motion(15), isTrue);
    expect(h.sent, ['\x1b[<35;2;2M']);
  });

  testWidgets('normal ignores motion and button tracking reports only drag', (
    tester,
  ) async {
    if (!hasNativeTerminal) return;
    final h = _MouseHarness();
    addTearDown(h.controller.dispose);
    h.controller.appendOutputBytes(utf8.encode('\x1b[?1003l\x1b[?1000h'));
    expect(h.motion(15), isFalse);
    await tester.pump(_interval);
    expect(h.sent, isEmpty);

    h.controller.appendOutputBytes(utf8.encode('\x1b[?1000l\x1b[?1002h'));
    expect(h.motion(15), isFalse);
    bool report(double x, {required bool pressed}) => h.controller.sendMouse(
      action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION,
      position: VtMousePosition(x: x, y: 25),
      size: _size,
      trackingMode: GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_BUTTON,
      format: GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR,
      button: pressed ? GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT : null,
      anyButtonPressed: pressed,
    );

    expect(report(15, pressed: true), isTrue);
    expect(h.sent, ['\x1b[<32;2;2M']);
    expect(report(25, pressed: true), isTrue);
    expect(report(35, pressed: false), isFalse);
    await tester.pump(_interval);
    expect(h.sent, hasLength(1));
  });
  testWidgets('motion sends immediately then coalesces the trailing position', (
    tester,
  ) async {
    if (!hasNativeTerminal) return;
    final h = _MouseHarness();
    addTearDown(h.controller.dispose);

    expect(h.motion(15), isTrue);
    expect(h.sent, ['\x1b[<35;2;2M']);
    await tester.pump(const Duration(milliseconds: 10));
    expect(h.motion(25), isTrue);
    await tester.pump(const Duration(milliseconds: 20));
    h.motion(45);
    await tester.pump(const Duration(milliseconds: 19));
    expect(h.sent, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(h.sent, ['\x1b[<35;2;2M', '\x1b[<35;5;2M']);
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.sent, hasLength(2));
  });

  testWidgets('continuous motion produces twenty reports per second', (
    tester,
  ) async {
    if (!hasNativeTerminal) return;
    final h = _MouseHarness();
    addTearDown(h.controller.dispose);
    h.motion(5);

    for (var tick = 1; tick < 200; tick++) {
      await tester.pump(const Duration(milliseconds: 5));
      h.motion((tick % 70) * 10.0 + 5);
    }
    expect(h.sent, hasLength(20));
    await tester.pump(const Duration(milliseconds: 5));
    expect(h.sent, hasLength(21));
    expect(h.sent.last, '\x1b[<35;60;2M');
    await tester.pump(_interval);
    expect(h.sent, hasLength(21));
  });

  testWidgets('default interval preserves immediate motion delivery', (
    tester,
  ) async {
    if (!hasNativeTerminal) return;
    final h = _MouseHarness(interval: Duration.zero);
    addTearDown(h.controller.dispose);
    h.motion(15);
    h.motion(25);
    h.motion(35);
    expect(h.sent, hasLength(3));
    await tester.pump(_interval);
    expect(h.sent, hasLength(3));
  });

  testWidgets(
    'same-cell motion is suppressed but modifiers and buttons differ',
    (tester) async {
      if (!hasNativeTerminal) return;
      final h = _MouseHarness();
      addTearDown(h.controller.dispose);
      h.motion(11);
      await tester.pump(_interval);
      h.motion(19);
      await tester.pump(_interval);
      expect(h.sent, hasLength(1));
      h.motion(19, mods: GhosttyModsMask.ctrl);
      await tester.pump(_interval);
      expect(h.sent, hasLength(2));
      h.motion(19, button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT);
      await tester.pump(_interval);
      expect(h.sent, hasLength(3));
      expect(h.sent.toSet(), hasLength(3));
    },
  );

  testWidgets('pixel reporting retains distinct positions within one cell', (
    tester,
  ) async {
    if (!hasNativeTerminal) return;
    final h = _MouseHarness(pixel: true);
    addTearDown(h.controller.dispose);
    h.motion(11);
    h.motion(19);
    expect(h.sent, hasLength(1));
    await tester.pump(_interval);
    expect(h.sent, hasLength(2));
    expect(h.sent[0], isNot(h.sent[1]));
    await tester.pump(_interval);
    expect(h.sent, hasLength(2));
  });

  for (final boundary in [
    'press',
    'release',
    'wheel',
    'bytes',
    'text',
    'key',
  ]) {
    testWidgets('$boundary flushes pending motion before immediate input', (
      tester,
    ) async {
      if (!hasNativeTerminal) return;
      final h = _MouseHarness();
      addTearDown(h.controller.dispose);
      h.motion(15);
      h.motion(25);
      switch (boundary) {
        case 'press':
          h.mouse(GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS);
        case 'release':
          h.mouse(GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_RELEASE);
        case 'wheel':
          h.mouse(
            GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
            button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_FOUR,
          );
        case 'bytes':
          h.controller.writeBytes(utf8.encode('bytes'));
        case 'text':
          h.controller.write('paste');
        case 'key':
          h.controller.sendKey(key: GhosttyKey.GHOSTTY_KEY_ENTER);
      }
      expect(h.sent, hasLength(3));
      expect(h.sent[1], '\x1b[<35;3;2M');
      expect(h.sent[2], isNot(h.sent[1]));
      await tester.pump(_interval);
      expect(h.sent, hasLength(3));
    });
  }

  for (final cancellation in [
    'cancel',
    'detach',
    'resize',
    'disable',
    'inactive',
    'blur',
    'dispose',
  ]) {
    testWidgets('$cancellation drops pending motion without timer replay', (
      tester,
    ) async {
      if (!hasNativeTerminal) return;
      final h = _MouseHarness();
      if (cancellation != 'dispose') addTearDown(h.controller.dispose);
      h.motion(15);
      h.motion(25);
      switch (cancellation) {
        case 'cancel':
          h.controller.cancelPendingMouseMotion();
        case 'detach':
          h.controller.detachExternalTransport();
          h.attach();
        case 'resize':
          h.controller.resize(cols: 81, rows: 30);
        case 'disable':
          h.controller.appendOutputBytes(utf8.encode('\x1b[?1003l'));
          h.controller.appendOutputBytes(utf8.encode('\x1b[?1003h'));
        case 'inactive':
          h.controller.setSessionRunning(false);
          h.controller.setSessionRunning(true);
        case 'blur':
          h.controller.setFocused(false);
          h.controller.setFocused(true);
        case 'dispose':
          h.controller.dispose();
      }
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.sent, hasLength(1));
    });
  }

  testWidgets('explicit flush sends pending motion once', (tester) async {
    if (!hasNativeTerminal) return;
    final h = _MouseHarness();
    addTearDown(h.controller.dispose);
    h.motion(15);
    h.motion(25);
    h.controller.flushPendingMouseMotion();
    expect(h.sent, ['\x1b[<35;2;2M', '\x1b[<35;3;2M']);
    await tester.pump(_interval);
    expect(h.sent, hasLength(2));
  });

  testWidgets('refused motion is not replayed when transport recovers', (
    tester,
  ) async {
    if (!hasNativeTerminal) return;
    final h = _MouseHarness();
    addTearDown(h.controller.dispose);
    h.motion(15);
    h.motion(25);
    h.accept = false;
    await tester.pump(_interval);
    expect(h.attempted, hasLength(2));
    expect(h.sent, hasLength(1));
    h.accept = true;
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.attempted, hasLength(2));
    h.motion(25);
    expect(h.sent.last, '\x1b[<35;3;2M');
    await tester.pump(_interval);
  });
}

class _MouseHarness {
  _MouseHarness({Duration interval = _interval, bool pixel = false})
    : controller = GhosttyTerminalController(
        mouseMotionReportInterval: interval,
      ) {
    attach();
    controller.appendOutputBytes(
      utf8.encode('\x1b[?1003h\x1b[?1006h${pixel ? '\x1b[?1016h' : ''}'),
    );
  }

  final GhosttyTerminalController controller;
  final sent = <String>[];
  final attempted = <String>[];
  bool accept = true;

  void attach() {
    controller.attachExternalTransport(
      writeBytes: (bytes) {
        final report = utf8.decode(bytes);
        attempted.add(report);
        if (accept) sent.add(report);
        return accept;
      },
      forwardGuestQueryReplies: false,
    );
  }

  bool motion(double x, {int mods = 0, GhosttyMouseButton? button}) =>
      controller.sendMouse(
        action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION,
        position: VtMousePosition(x: x, y: 25),
        size: _size,
        mods: mods,
        button: button,
        trackingMode: button == null
            ? null
            : GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_ANY,
        format: button == null
            ? null
            : GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR,
        anyButtonPressed: button == null ? null : true,
      );

  bool mouse(
    GhosttyMouseAction action, {
    GhosttyMouseButton button = GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
  }) => controller.sendMouse(
    action: action,
    position: const VtMousePosition(x: 25, y: 25),
    size: _size,
    button: button,
  );
}
