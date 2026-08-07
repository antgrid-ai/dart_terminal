import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/src/engine_palette.dart';

void main() {
  group('expandAnsiToEnginePalette', () {
    const ansi16 = <Color>[
      Color(0xFF0C0C0C),
      Color(0xFFC50F1F),
      Color(0xFF13A10E),
      Color(0xFFC19C00),
      Color(0xFF0037DA),
      Color(0xFF881798),
      Color(0xFF3A96DD),
      Color(0xFFCCCCCC),
      Color(0xFF767676),
      Color(0xFFE74856),
      Color(0xFF16C60C),
      Color(0xFFF9F1A5),
      Color(0xFF3B78FF),
      Color(0xFFB4009E),
      Color(0xFF61D6D6),
      Color(0xFFF2F2F2),
    ];

    test('returns exactly 256 entries', () {
      expect(expandAnsiToEnginePalette(ansi16).length, 256);
    });

    test('first 16 entries are the supplied ANSI colors', () {
      final p = expandAnsiToEnginePalette(ansi16);
      expect((p[1].r, p[1].g, p[1].b), (0xC5, 0x0F, 0x1F)); // red
      expect((p[15].r, p[15].g, p[15].b), (0xF2, 0xF2, 0xF2)); // bright white
    });

    test('cube index 16 is pure black, 231 is pure white', () {
      final p = expandAnsiToEnginePalette(ansi16);
      expect((p[16].r, p[16].g, p[16].b), (0, 0, 0));
      expect((p[231].r, p[231].g, p[231].b), (255, 255, 255));
    });

    test('cube uses xterm levels [0,95,135,175,215,255]', () {
      final p = expandAnsiToEnginePalette(ansi16);
      // index 16 + 36*1 = 52 -> red level index 1 = 95, green 0, blue 0
      expect((p[52].r, p[52].g, p[52].b), (95, 0, 0));
    });

    test('cube maps all three channels (index 110 -> 135,175,215)', () {
      final p = expandAnsiToEnginePalette(ansi16);
      // 110 = 16 + 36*2 + 6*3 + 4 -> levels[2],levels[3],levels[4]
      expect((p[110].r, p[110].g, p[110].b), (135, 175, 215));
    });

    test('grayscale ramp 232..255 is 8 + (i-232)*10', () {
      final p = expandAnsiToEnginePalette(ansi16);
      expect((p[232].r, p[232].g, p[232].b), (8, 8, 8));
      expect((p[255].r, p[255].g, p[255].b), (238, 238, 238));
    });

    test('requires 16 ansi colors', () {
      expect(
        () => expandAnsiToEnginePalette(const <Color>[]),
        throwsArgumentError,
      );
    });
  });

  test('colorToVtRgb extracts 8-bit channels', () {
    final c = colorToVtRgb(const Color(0xFF3A96DD));
    expect((c.r, c.g, c.b), (0x3A, 0x96, 0xDD));
  });
}
