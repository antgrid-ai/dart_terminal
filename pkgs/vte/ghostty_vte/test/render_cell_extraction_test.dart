import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:ghostty_vte/ghostty_vte.dart';
import 'package:test/test.dart';

const _mixedCells =
    '\x1b[HASCII \x1b[1;3;4;38;2;200;30;50mS\x1b[0m '
    '\x1b[1"qP\x1b[0"q '
    '\x1b]8;;https://example.com\x1b\\L\x1b]8;;\x1b\\'
    '\x1b[2;1H界 e\u0301 👩🏽‍💻 🇮🇳 1️⃣ Z'
    '\x1b[3;1H\x1b[48;5;237m\x1b[2K\x1b[0m'
    '\x1b[4;1H\x1b[48;2;9;85;240m\x1b[2K\x1b[0m'
    '\x1b[5;1H\x1b]133;A\x07P\x1b]133;B\x07I\x1b]133;C\x07O\x1b]133;D\x07'
    '\x1b[6;48H界';

List<int>? _rgb(VtRgbColor? color) =>
    color == null ? null : [color.r, color.g, color.b];

List<Object?> _fields(VtCellSnapshot cell) => [
  cell.codepoint,
  cell.contentTag.value,
  cell.wide.value,
  cell.hasText,
  cell.hasStyling,
  cell.styleId,
  cell.hasHyperlink,
  cell.isProtected,
  cell.semanticContent.value,
  cell.colorPaletteIndex,
  _rgb(cell.colorRgb),
];

// The individual getters are the independent native oracle for the batch path;
// no packed-cell offsets or assumptions about the linked build's layout.
List<Object?> _individualFields(int cell) {
  final storage = calloc<ffi.Uint64>();
  try {
    void read(GhosttyCellData key) {
      expect(
        ghostty_cell_get(cell, key, storage.cast()),
        GhosttyResult.GHOSTTY_SUCCESS,
      );
    }

    int uint32(GhosttyCellData key) {
      read(key);
      return storage.cast<ffi.Uint32>().value;
    }

    bool boolean(GhosttyCellData key) {
      read(key);
      return storage.cast<ffi.Bool>().value;
    }

    final tag = uint32(GhosttyCellData.GHOSTTY_CELL_DATA_CONTENT_TAG);
    final codepoint = uint32(GhosttyCellData.GHOSTTY_CELL_DATA_CODEPOINT);
    final wide = uint32(GhosttyCellData.GHOSTTY_CELL_DATA_WIDE);
    final hasText = boolean(GhosttyCellData.GHOSTTY_CELL_DATA_HAS_TEXT);
    final hasStyling = boolean(GhosttyCellData.GHOSTTY_CELL_DATA_HAS_STYLING);
    read(GhosttyCellData.GHOSTTY_CELL_DATA_STYLE_ID);
    final styleId = storage.cast<ffi.Uint16>().value;
    final hyperlink = boolean(GhosttyCellData.GHOSTTY_CELL_DATA_HAS_HYPERLINK);
    final protected = boolean(GhosttyCellData.GHOSTTY_CELL_DATA_PROTECTED);
    final semantic = uint32(GhosttyCellData.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT);
    int? palette;
    List<int>? rgb;
    if (tag ==
        GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE.value) {
      read(GhosttyCellData.GHOSTTY_CELL_DATA_COLOR_PALETTE);
      palette = storage.cast<ffi.Uint8>().value;
    } else if (tag ==
        GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_BG_COLOR_RGB.value) {
      read(GhosttyCellData.GHOSTTY_CELL_DATA_COLOR_RGB);
      final native = storage.cast<GhosttyColorRgb>().ref;
      rgb = [native.r, native.g, native.b];
    }
    return [
      codepoint,
      tag,
      wide,
      hasText,
      hasStyling,
      styleId,
      hyperlink,
      protected,
      semantic,
      palette,
      rgb,
    ];
  } finally {
    calloc.free(storage);
  }
}

void main() {
  test(
    'standalone and reused cell extraction match individual native getters',
    () {
      // Each cleanup is registered as soon as its resource exists, so a failed
      // setup expectation still frees everything allocated before it.
      // Teardowns run in reverse order of registration.
      final handle = calloc<GhosttyTerminal>();
      addTearDown(() => calloc.free(handle));
      expect(
        ghostty_terminal_new(ffi.nullptr, handle, 48, 10),
        GhosttyResult.GHOSTTY_SUCCESS,
      );
      final native = handle.value;
      addTearDown(() => ghostty_terminal_free(native));
      final point = calloc<GhosttyPoint>();
      addTearDown(() => calloc.free(point));
      final ref = calloc<GhosttyGridRef>();
      addTearDown(() => calloc.free(ref));
      final raw = calloc<GhosttyCell>();
      addTearDown(() => calloc.free(raw));
      final terminal = GhosttyVt.newTerminal(cols: 48, rows: 10);
      addTearDown(terminal.close);
      final render = terminal.createRenderState();
      addTearDown(render.close);
      final tags = <GhosttyCellContentTag>{};
      var sawProtected = false, sawHyperlink = false, sawStyle = false;
      for (final output in [_mixedCells, '\x1bc$_mixedCells', '\x1bc']) {
        final bytes = utf8.encode(output);
        final buffer = calloc<ffi.Uint8>(bytes.length);
        try {
          buffer.asTypedList(bytes.length).setAll(0, bytes);
          ghostty_terminal_vt_write(native, buffer, bytes.length);
        } finally {
          calloc.free(buffer);
        }
        terminal.write(output);
        render.update();
        final snapshot = render.snapshot();
        for (var y = 0; y < 10; y++) {
          for (var x = 0; x < 48; x++) {
            point.ref
              ..tagAsInt = GhosttyPointTag.GHOSTTY_POINT_TAG_VIEWPORT.value
              ..value.coordinate.x = x
              ..value.coordinate.y = y;
            ref.ref.size = ffi.sizeOf<GhosttyGridRef>();
            expect(
              ghostty_terminal_grid_ref(native, point.ref, ref),
              GhosttyResult.GHOSTTY_SUCCESS,
            );
            expect(
              ghostty_grid_ref_cell(ref, raw),
              GhosttyResult.GHOSTTY_SUCCESS,
            );
            final expected = _individualFields(raw.value);
            expect(
              _fields(VtCellSnapshot.fromRaw(raw.value)),
              expected,
              reason: 'standalone $x,$y',
            );
            final actual = snapshot.cellAt(row: y, column: x).raw;
            expect(_fields(actual), expected, reason: 'render cursor $x,$y');
            tags.add(actual.contentTag);
            sawProtected |= actual.isProtected;
            sawHyperlink |= actual.hasHyperlink;
            sawStyle |= actual.hasStyling;
          }
        }
      }
      expect(
        tags,
        containsAll([
          GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_CODEPOINT,
          GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME,
          GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE,
          GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_BG_COLOR_RGB,
        ]),
      );
      expect(sawProtected && sawHyperlink && sawStyle, isTrue);
    },
  );

  for (final alternate in [false, true]) {
    test(
      'rendered graphemes match native grid refs across resize (alternate: $alternate)',
      () {
        final terminal = GhosttyVt.newTerminal(cols: 48, rows: 10);
        final render = terminal.createRenderState();
        addTearDown(() {
          render.close();
          terminal.close();
        });
        terminal.write('${alternate ? '\x1b[?1049h' : ''}$_mixedCells');
        for (final size in [(48, 10), (32, 8), (60, 12)]) {
          terminal.resize(cols: size.$1, rows: size.$2);
          render.update();
          final snapshot = render.snapshot();
          for (var y = 0; y < size.$2; y++) {
            for (var x = 0; x < size.$1; x++) {
              final cell = snapshot.cellAt(row: y, column: x);
              expect(
                cell.graphemes,
                terminal.viewportCell(x, y).graphemes,
                reason: '$x,$y at $size',
              );
            }
          }
        }
      },
    );
  }
}
