import 'dart:async';

import 'package:ghostty_vte/ghostty_vte.dart';

typedef MouseModes = (GhosttyMouseTrackingMode, GhosttyMouseFormat);

MouseModes terminalMouseModes(VtTerminal? terminal) {
  bool enabled(VtMode mode) => terminal?.getMode(mode) ?? false;
  final tracking = enabled(VtModes.anyMouse)
      ? GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_ANY
      : enabled(VtModes.buttonMouse)
      ? GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_BUTTON
      : enabled(VtModes.normalMouse)
      ? GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_NORMAL
      : enabled(VtModes.x10Mouse)
      ? GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_X10
      : GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_NONE;
  final format = enabled(VtModes.sgrPixelsMouse)
      ? GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR_PIXELS
      : enabled(VtModes.sgrMouse)
      ? GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR
      : enabled(VtModes.urxvtMouse)
      ? GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_URXVT
      : enabled(VtModes.utf8Mouse)
      ? GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_UTF8
      : GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_X10;
  return (tracking, format);
}

final class MouseReport {
  const MouseReport({
    required this.action,
    required this.button,
    required this.mods,
    required this.position,
    required this.size,
    required this.modes,
    required this.trackingMode,
    required this.format,
    required this.anyButtonPressed,
    required this.trackLastCell,
  });

  final GhosttyMouseAction action;
  final GhosttyMouseButton? button;
  final int mods;
  final VtMousePosition position;
  final VtMouseEncoderSize size;
  final MouseModes modes;
  final GhosttyMouseTrackingMode trackingMode;
  final GhosttyMouseFormat format;
  final bool anyButtonPressed;
  final bool trackLastCell;

  Object get geometry => (
    size.screenWidth,
    size.screenHeight,
    size.cellWidth,
    size.cellHeight,
    size.paddingTop,
    size.paddingBottom,
    size.paddingRight,
    size.paddingLeft,
  );
}

/// Keeps deferred input bounded to the newest position in one reporting epoch.
final class MouseInput {
  MouseInput({
    required this.interval,
    required this.readModes,
    required this.writeBytes,
  });

  final Duration interval;
  final MouseModes Function() readModes;
  final bool Function(List<int>) writeBytes;
  VtMouseEncoder? _encoder;
  MouseModes? _modes;
  Object? _configuration;
  Object? _buttonState;
  Timer? _cooldown;
  MouseReport? _pending;
  int _generation = 0;

  void synchronizeModes() {
    final modes = readModes();
    if (_modes != modes) {
      cancel();
      _modes = modes;
    }
  }

  bool send(MouseReport report) {
    synchronizeModes();
    if (report.action != GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_MOTION) {
      flush();
      return _emit(report);
    }
    final eligible = switch (report.trackingMode) {
      GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_ANY => true,
      GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_BUTTON =>
        report.anyButtonPressed,
      _ => false,
    };
    if (!eligible) {
      cancel();
      return false;
    }
    // Geometry and reporting-mode changes must not leave an older position
    // eligible for a later click or timer.
    if (_pending != null &&
        (_pending!.geometry != report.geometry ||
            _pending!.trackingMode != report.trackingMode ||
            _pending!.format != report.format)) {
      cancel();
    }
    if (interval == Duration.zero || _cooldown == null) {
      return _emitMotion(report);
    }
    _pending = report;
    return true;
  }

  bool _emitMotion(MouseReport report) {
    final generation = _generation;
    final sent = _emit(report);
    if (sent && generation == _generation && interval > Duration.zero) {
      _cooldown = Timer(interval, () {
        _cooldown = null;
        flush();
      });
    }
    return sent;
  }

  bool _emit(MouseReport report) {
    if (readModes() != report.modes) {
      cancel();
      return false;
    }
    final encoder = _encoder ??= VtMouseEncoder();
    final configuration = (report.trackingMode, report.format, report.geometry);
    if (_configuration != configuration) {
      // Setting SIZE and copying terminal options clear Ghostty's last cell.
      // Reapplying them for each event defeats native motion deduplication.
      encoder
        ..trackingMode = report.trackingMode
        ..format = report.format
        ..size = report.size;
      _configuration = configuration;
    }
    final buttonState = (report.button, report.mods, report.anyButtonPressed);
    if (_buttonState != buttonState) {
      encoder.reset();
      _buttonState = buttonState;
    }
    encoder
      ..anyButtonPressed = report.anyButtonPressed
      ..trackLastCell = report.trackLastCell;
    final event = VtMouseEvent();
    try {
      event
        ..action = report.action
        ..button = report.button
        ..mods = report.mods
        ..position = report.position;
      final bytes = encoder.encode(event);
      if (bytes.isEmpty) return false;
      final sent = writeBytes(bytes);
      if (!sent) cancel();
      return sent;
    } finally {
      event.close();
    }
  }

  void flush() {
    final report = _pending;
    _pending = null;
    if (report == null) return;
    _cooldown?.cancel();
    _cooldown = null;
    _emitMotion(report);
  }

  void cancel() {
    _generation++;
    _cooldown?.cancel();
    _cooldown = null;
    _pending = null;
    _encoder?.reset();
    _configuration = null;
    _buttonState = null;
  }

  void dispose() {
    cancel();
    _encoder?.close();
    _encoder = null;
  }
}
