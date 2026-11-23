import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:smart_wrong_notebook/src/features/capture/application/auto_question_crop_detector.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/image_crop_processor.dart';

/// Paints synthetic printed text strokes (alternating dark glyphs & micro-gaps)
/// inside `[left, right]` at vertical span `[yTop, yTop + lineHeight)` on [canvas].
void _drawPrintedLine(
  img.Image canvas, {
  required int left,
  required int right,
  required int yTop,
  int lineHeight = 8,
  int inkLuma = 32,
}) {
  final yEnd = (yTop + lineHeight).clamp(0, canvas.height);
  final xStart = left.clamp(0, canvas.width);
  final xEnd = right.clamp(0, canvas.width);
  for (var x = xStart; x < xEnd; x++) {
    // Realistic glyph cadence: 5px strokes separated by 2-3px character gaps.
    final phase = (x - xStart) % 8;
    if (phase >= 5) continue;
    for (var y = yTop.clamp(0, canvas.height); y < yEnd; y++) {
      // Leave slight vertical variation inside glyph cells.
      if ((y - yTop == 0 || y == yEnd - 1) && phase == 2) continue;
      canvas.setPixelRgb(x, y, inkLuma, inkLuma, inkLuma);
    }
  }
}

Uint8List _toRgba(img.Image image) {
  final out = Uint8List(image.width * image.height * 4);
  var i = 0;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final p = image.getPixel(x, y);
      out[i++] = p.r.toInt();
      out[i++] = p.g.toInt();
      out[i++] = p.b.toInt();
      out[i++] = 255;
    }
  }
  return out;
}

img.Image _blankPaper(int width, int height, {int luma = 245}) {
  final canvas = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      canvas.setPixelRgb(x, y, luma, luma, luma);
    }
  }
  return canvas;
}

void main() {
  group('detectCenterQuestionCropRectFromRgba', () {
    test('isolates middle multi-line question from a 3-question portrait page',
        () {
      const w = 270;
      const h = 360;
      final page = _blankPaper(w, h);

      // Question 1 (top: y = 20..82)
      _drawPrintedLine(page, left: 22, right: 248, yTop: 22, lineHeight: 8);
      _drawPrintedLine(page, left: 22, right: 244, yTop: 36, lineHeight: 8);
      _drawPrintedLine(page, left: 22, right: 170, yTop: 50, lineHeight: 8);

      // Question 2 (middle: y = 148..208, straddles vertical center y = 180)
      _drawPrintedLine(page, left: 22, right: 246, yTop: 150, lineHeight: 8);
      _drawPrintedLine(page, left: 22, right: 240, yTop: 164, lineHeight: 8);
      _drawPrintedLine(page, left: 22, right: 235, yTop: 178, lineHeight: 8);
      _drawPrintedLine(page, left: 22, right: 190, yTop: 192, lineHeight: 8);

      // Question 3 (bottom: y = 276..330)
      _drawPrintedLine(page, left: 22, right: 246, yTop: 278, lineHeight: 8);
      _drawPrintedLine(page, left: 22, right: 242, yTop: 292, lineHeight: 8);
      _drawPrintedLine(page, left: 22, right: 185, yTop: 306, lineHeight: 8);

      final rect = detectCenterQuestionCropRectFromRgba(
        rgba: _toRgba(page),
        width: w,
        height: h,
      );

      expect(rect, isNotNull);
      // Must fully contain Q2 (150..200 -> 0.417..0.556)
      expect(rect!.top, lessThanOrEqualTo(150 / h));
      expect(rect.bottom, greaterThanOrEqualTo(200 / h));
      // Must exclude Q1 (ends at 58 -> 0.161) and Q3 (starts at 278 -> 0.772)
      expect(rect.top, greaterThan(90 / h));
      expect(rect.bottom, lessThan(260 / h));
      // Should cover the full horizontal extent of Q2 text
      expect(rect.left, lessThanOrEqualTo(24 / w));
      expect(rect.right, greaterThanOrEqualTo(242 / w));
    });

    test('isolates middle single-line equation among equally spaced questions',
        () {
      const w = 270;
      const h = 360;
      final page = _blankPaper(w, h);

      // Five equally spaced single-line calculation questions (gap = 46px).
      for (final yTop in <int>[30, 86, 174, 240, 300]) {
        _drawPrintedLine(page, left: 24, right: 220, yTop: yTop, lineHeight: 9);
      }

      final rect = detectCenterQuestionCropRectFromRgba(
        rgba: _toRgba(page),
        width: w,
        height: h,
      );

      expect(rect, isNotNull);
      // Isolates ONLY the middle single-line question around y = 174..183.
      expect(rect!.top, lessThanOrEqualTo(174 / h));
      expect(rect.bottom, greaterThanOrEqualTo(183 / h));
      expect(rect.top, greaterThan(120 / h));
      expect(rect.bottom, lessThan(225 / h));
      expect(rect.width / rect.height, greaterThan(2.5));
    });

    test('handles strong shadow gradient and dark desk border margins', () {
      const w = 270;
      const h = 360;
      final page = img.Image(width: w, height: h);

      // Dark wooden table around top 34px and left 28px; paper has strong
      // lighting gradient from 240 on the left down to 135 on the right.
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (y < 34 || x < 28) {
            page.setPixelRgb(x, y, 48, 40, 34);
          } else {
            final t = (x - 28) / (w - 28);
            final bg = (240 - t * 105).round();
            page.setPixelRgb(x, y, bg, bg - 4, bg - 10);
          }
        }
      }

      // Draw 3 questions with dark ink relative to the shaded background.
      _drawPrintedLine(page, left: 42, right: 252, yTop: 64, inkLuma: 35);
      _drawPrintedLine(page, left: 42, right: 245, yTop: 78, inkLuma: 35);

      _drawPrintedLine(page, left: 42, right: 252, yTop: 164, inkLuma: 35);
      _drawPrintedLine(page, left: 42, right: 250, yTop: 178, inkLuma: 35);
      _drawPrintedLine(page, left: 42, right: 210, yTop: 192, inkLuma: 35);

      _drawPrintedLine(page, left: 42, right: 252, yTop: 280, inkLuma: 35);
      _drawPrintedLine(page, left: 42, right: 240, yTop: 294, inkLuma: 35);

      final rect = detectCenterQuestionCropRectFromRgba(
        rgba: _toRgba(page),
        width: w,
        height: h,
      );

      expect(rect, isNotNull);
      expect(rect!.left, greaterThanOrEqualTo(28 / w));
      expect(rect.left, lessThanOrEqualTo(44 / w));
      expect(rect.right, greaterThanOrEqualTo(246 / w));
      expect(rect.top, lessThanOrEqualTo(164 / h));
      expect(rect.bottom, greaterThanOrEqualTo(200 / h));
      expect(rect.top, greaterThan(110 / h));
      expect(rect.bottom, lessThan(260 / h));
    });

    test('splits two-column exam paper and selects only the center column question',
        () {
      const w = 320;
      const h = 320;
      final page = _blankPaper(w, h);

      // Left column: x = 14..108, Gutter: x = 109..135 (27px), Right column: x = 136..304.
      // Image center x = 160 lies inside the right column!
      for (final blockTop in <int>[26, 132, 238]) {
        // Left column multi-line questions
        _drawPrintedLine(page, left: 16, right: 106, yTop: blockTop);
        _drawPrintedLine(page, left: 16, right: 104, yTop: blockTop + 14);
        _drawPrintedLine(page, left: 16, right: 96, yTop: blockTop + 28);
        _drawPrintedLine(page, left: 16, right: 92, yTop: blockTop + 42);

        // Right column multi-line questions
        _drawPrintedLine(page, left: 142, right: 300, yTop: blockTop + 6);
        _drawPrintedLine(page, left: 142, right: 296, yTop: blockTop + 20);
        _drawPrintedLine(page, left: 142, right: 290, yTop: blockTop + 34);
        _drawPrintedLine(page, left: 142, right: 250, yTop: blockTop + 48);
      }

      final rect = detectCenterQuestionCropRectFromRgba(
        rgba: _toRgba(page),
        width: w,
        height: h,
      );

      expect(rect, isNotNull);
      // Stays strictly inside the right column (excludes left column < 108/320).
      expect(rect!.left, greaterThan(120 / w));
      expect(rect.right, greaterThanOrEqualTo(294 / w));
      // Isolates the middle question (138..194) and excludes top & bottom blocks.
      expect(rect.top, lessThanOrEqualTo(138 / h));
      expect(rect.bottom, greaterThanOrEqualTo(194 / h));
      expect(rect.top, greaterThan(95 / h));
      expect(rect.bottom, lessThan(235 / h));
    });

    test('splits questions cleanly on printed horizontal divider rules', () {
      const w = 270;
      const h = 360;
      final page = _blankPaper(w, h);

      // Tight spacing separated by 2px full-width horizontal rules.
      _drawPrintedLine(page, left: 20, right: 245, yTop: 112);
      _drawPrintedLine(page, left: 20, right: 240, yTop: 126);
      for (var y = 142; y <= 143; y++) {
        for (var x = 15; x < 255; x++) {
          page.setPixelRgb(x, y, 40, 40, 40);
        }
      }
      _drawPrintedLine(page, left: 20, right: 248, yTop: 156);
      _drawPrintedLine(page, left: 20, right: 244, yTop: 170);
      _drawPrintedLine(page, left: 20, right: 200, yTop: 184);
      for (var y = 200; y <= 201; y++) {
        for (var x = 15; x < 255; x++) {
          page.setPixelRgb(x, y, 40, 40, 40);
        }
      }
      _drawPrintedLine(page, left: 20, right: 245, yTop: 214);
      _drawPrintedLine(page, left: 20, right: 230, yTop: 228);

      final rect = detectCenterQuestionCropRectFromRgba(
        rgba: _toRgba(page),
        width: w,
        height: h,
      );

      expect(rect, isNotNull);
      expect(rect!.top, greaterThanOrEqualTo(143 / h));
      expect(rect.bottom, lessThanOrEqualTo(201 / h));
      expect(rect.top, lessThanOrEqualTo(156 / h));
      expect(rect.bottom, greaterThanOrEqualTo(192 / h));
    });

    test('returns null for blank page, dark frame, or flat solid color bands',
        () {
      // Blank white paper
      final blank = _blankPaper(240, 320, luma: 245);
      expect(
        detectCenterQuestionCropRectFromRgba(
          rgba: _toRgba(blank),
          width: 240,
          height: 320,
        ),
        isNull,
      );

      // Pitch-dark camera frame
      final dark = _blankPaper(240, 320, luma: 18);
      expect(
        detectCenterQuestionCropRectFromRgba(
          rgba: _toRgba(dark),
          width: 240,
          height: 320,
        ),
        isNull,
      );

      // Flat solid 3-band color image (no text strokes)
      final bands = img.Image(width: 240, height: 360);
      for (var y = 0; y < 360; y++) {
        final r = y < 144 ? 220 : 20;
        final g = (y >= 144 && y < 216) ? 210 : 20;
        final b = y >= 216 ? 220 : 20;
        for (var x = 0; x < 240; x++) {
          bands.setPixelRgb(x, y, r, g, b);
        }
      }
      expect(
        detectCenterQuestionCropRectFromRgba(
          rgba: _toRgba(bands),
          width: 240,
          height: 360,
        ),
        isNull,
      );
    });
  });

  group('detectCenterQuestionCropRect (ui.Image + rotation)', () {
    test('detects middle question accurately after 90-degree rotation',
        () async {
      final tempDir =
          Directory.systemTemp.createTempSync('auto_crop_rotate_test_');
      try {
        // Build an upright 3-question page, then rotate it 90° CCW so the
        // stored image is sideways; passing quarterTurns: 1 restores upright.
        final upright = _blankPaper(270, 360);
        _drawPrintedLine(upright, left: 24, right: 244, yTop: 28);
        _drawPrintedLine(upright, left: 24, right: 230, yTop: 42);

        _drawPrintedLine(upright, left: 24, right: 244, yTop: 158);
        _drawPrintedLine(upright, left: 24, right: 238, yTop: 172);
        _drawPrintedLine(upright, left: 24, right: 210, yTop: 186);

        _drawPrintedLine(upright, left: 24, right: 244, yTop: 290);
        _drawPrintedLine(upright, left: 24, right: 225, yTop: 304);

        final sideways = img.copyRotate(upright, angle: -90);
        final file = File('${tempDir.path}/sideways.png');
        file.writeAsBytesSync(img.encodePng(sideways));

        final decoded = await decodeImageForCrop(file);
        try {
          final rect = await detectCenterQuestionCropRect(
            sourceImage: decoded,
            quarterTurns: 1,
          );
          expect(rect, isNotNull);
          expect(rect!.top, lessThanOrEqualTo(158 / 360));
          expect(rect.bottom, greaterThanOrEqualTo(194 / 360));
          expect(rect.top, greaterThan(90 / 360));
          expect(rect.bottom, lessThan(265 / 360));
        } finally {
          decoded.dispose();
        }
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
