import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:smart_wrong_notebook/src/features/capture/application/free_crop_geometry.dart';

/// Maximum working dimension (in pixels) used for fast local layout analysis.
const int kAutoDetectMaxDimension = 360;

/// Detects the normalized `[0, 1]` bounding rectangle of the question closest
/// to the center of [sourceImage] (after applying [quarterTurns]) using fast,
/// offline local layout analysis in a background isolate.
///
/// Returns `null` when no reliable single-question block can be isolated (for
/// example, blank paper, uniform scenes, or content already filling the frame),
/// signaling the caller to keep the full-frame crop bounds.
Future<ui.Rect?> detectCenterQuestionCropRect({
  required ui.Image sourceImage,
  int quarterTurns = 0,
}) async {
  final normalizedTurns = ((quarterTurns % 4) + 4) % 4;
  final spec = computeOutputCropSpec(
    sourceWidth: sourceImage.width,
    sourceHeight: sourceImage.height,
    quarterTurns: normalizedTurns,
    normalizedCropRect: fullNormalizedCropRect,
    maxOutputDimension: kAutoDetectMaxDimension,
  );

  final workW = spec.outputWidth;
  final workH = spec.outputHeight;
  if (workW < 24 || workH < 24) return null;

  final imageHandle = sourceImage.clone();
  ui.Picture? picture;
  ui.Image? smallImage;
  try {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.scale(workW / spec.cropWidth, workH / spec.cropHeight);

    switch (normalizedTurns) {
      case 1:
        canvas.translate(imageHandle.height.toDouble(), 0);
        canvas.rotate(math.pi / 2);
        break;
      case 2:
        canvas.translate(
          imageHandle.width.toDouble(),
          imageHandle.height.toDouble(),
        );
        canvas.rotate(math.pi);
        break;
      case 3:
        canvas.translate(0, imageHandle.width.toDouble());
        canvas.rotate(-math.pi / 2);
        break;
      case 0:
      default:
        break;
    }

    canvas.drawImage(
      imageHandle,
      ui.Offset.zero,
      ui.Paint()..filterQuality = ui.FilterQuality.low,
    );

    picture = recorder.endRecording();
    smallImage = await picture.toImage(workW, workH);
    final byteData =
        await smallImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return null;

    final rgbaCopy = Uint8List.fromList(
      byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      ),
    );
    final bounds = await Isolate.run(
      () => _detectCenterQuestionBoundsIsolate(
        rgba: rgbaCopy,
        width: workW,
        height: workH,
      ),
    );
    if (bounds == null) return null;
    return ui.Rect.fromLTRB(bounds[0], bounds[1], bounds[2], bounds[3]);
  } finally {
    smallImage?.dispose();
    picture?.dispose();
    imageHandle.dispose();
  }
}

/// Pure synchronous detector operating directly on an RGBA byte buffer in the
/// upright viewing orientation. Exposed for deterministic unit testing.
ui.Rect? detectCenterQuestionCropRectFromRgba({
  required Uint8List rgba,
  required int width,
  required int height,
}) {
  final bounds = _detectCenterQuestionBoundsIsolate(
    rgba: rgba,
    width: width,
    height: height,
  );
  if (bounds == null) return null;
  return ui.Rect.fromLTRB(bounds[0], bounds[1], bounds[2], bounds[3]);
}

List<double>? _detectCenterQuestionBoundsIsolate({
  required Uint8List rgba,
  required int width,
  required int height,
}) {
  if (width < 24 || height < 24 || rgba.length < width * height * 4) {
    return null;
  }

  // 1. Grayscale conversion + 2D integral image for fast O(1) local box means.
  final pixelCount = width * height;
  final gray = Uint8List(pixelCount);
  final stride = width + 1;
  final integral = Int32List(stride * (height + 1));

  for (var y = 0; y < height; y++) {
    var rowSum = 0;
    final rowOffset = y * width;
    final intRowOffset = (y + 1) * stride;
    final prevIntRowOffset = y * stride;
    for (var x = 0; x < width; x++) {
      final p = (rowOffset + x) << 2;
      final luma = (77 * rgba[p] + 150 * rgba[p + 1] + 29 * rgba[p + 2]) >> 8;
      gray[rowOffset + x] = luma;
      rowSum += luma;
      integral[intRowOffset + x + 1] =
          integral[prevIntRowOffset + x + 1] + rowSum;
    }
  }

  int boxMean(int x0, int y0, int x1, int y1) {
    final ax = x0 < 0 ? 0 : (x0 >= width ? width - 1 : x0);
    final ay = y0 < 0 ? 0 : (y0 >= height ? height - 1 : y0);
    final bx = x1 < 0 ? 0 : (x1 >= width ? width - 1 : x1);
    final by = y1 < 0 ? 0 : (y1 >= height ? height - 1 : y1);
    final area = (bx - ax + 1) * (by - ay + 1);
    if (area <= 0) return 0;
    final sum = integral[(by + 1) * stride + (bx + 1)] -
        integral[ay * stride + (bx + 1)] -
        integral[(by + 1) * stride + ax] +
        integral[ay * stride + ax];
    return sum ~/ area;
  }

  // 2. Estimate paper luminance in the central region & trim dark desk borders.
  final paperLuma = _estimateCenterPaperLuma(gray, width, height);
  if (paperLuma < 55) return null;

  final paperBounds = _detectPaperBounds(
    width: width,
    height: height,
    paperLuma: paperLuma,
    boxMean: boxMean,
  );
  final paperLeft = paperBounds.$1;
  final paperTop = paperBounds.$2;
  final paperRight = paperBounds.$3;
  final paperBottom = paperBounds.$4;
  final paperW = paperRight - paperLeft + 1;
  final paperH = paperBottom - paperTop + 1;
  if (paperW < 20 || paperH < 20) return null;

  // 3. Adaptive local-background ink mask (robust to shadows & warm paper).
  final radius = math.max(10, math.min(width, height) ~/ 18);
  final inkMask = Uint8List(pixelCount);
  var totalInk = 0;

  for (var y = paperTop; y <= paperBottom; y++) {
    final rowOffset = y * width;
    for (var x = paperLeft; x <= paperRight; x++) {
      final bg = boxMean(x - radius, y - radius, x + radius, y + radius);
      final diff = bg - gray[rowOffset + x];
      final thresh = math.max(16, (bg * 0.095).round());
      if (diff >= thresh) {
        inkMask[rowOffset + x] = 1;
        totalInk++;
      }
    }
  }

  final inkRatio = totalInk / (paperW * paperH);
  if (inkRatio < 0.004 || inkRatio > 0.65) return null;

  // 4. Optional two-column exam paper detection around the vertical mid-band.
  final activeColumn = _selectActiveColumn(
    inkMask: inkMask,
    width: width,
    height: height,
    paperLeft: paperLeft,
    paperTop: paperTop,
    paperRight: paperRight,
    paperBottom: paperBottom,
  );
  final colLeft = activeColumn.$1;
  final colRight = activeColumn.$2;
  final colW = colRight - colLeft + 1;
  if (colW < 16) return null;

  // 5. Horizontal row projection inside the active column.
  final rowInk = Int32List(height);
  final rowTransitions = Int32List(height);
  final isRuleRow = Uint8List(height);
  final isSolidBandRow = Uint8List(height);

  for (var y = paperTop; y <= paperBottom; y++) {
    final rowOffset = y * width;
    var count = 0;
    var transitions = 0;
    var prev = 0;
    for (var x = colLeft; x <= colRight; x++) {
      final cur = inkMask[rowOffset + x];
      if (cur != 0) {
        count++;
        if (prev == 0) transitions++;
      }
      prev = cur;
    }
    rowInk[y] = count;
    rowTransitions[y] = transitions;
  }

  // Classify horizontal divider lines (thin 1-4px solid rules) vs flat shading
  // step-edge artifacts (thick >=5px solid bars with almost zero transitions).
  var yCursor = paperTop;
  while (yCursor <= paperBottom) {
    if (rowInk[yCursor] >= (colW * 0.72).round() &&
        rowTransitions[yCursor] <= 3) {
      final runStart = yCursor;
      while (yCursor <= paperBottom &&
          rowInk[yCursor] >= (colW * 0.72).round() &&
          rowTransitions[yCursor] <= 3) {
        yCursor++;
      }
      final runLen = yCursor - runStart;
      if (runLen <= 4) {
        for (var r = runStart; r < yCursor; r++) {
          isRuleRow[r] = 1;
        }
      } else {
        for (var r = runStart; r < yCursor; r++) {
          isSolidBandRow[r] = 1;
        }
      }
    } else {
      yCursor++;
    }
  }

  // 6. Group active text/diagram rows into horizontal bands.
  final minRowInk = math.max(2, (colW * 0.012).round());
  final maxIntraLineGap = math.max(1, (paperH * 0.004).round());
  final bands = <_RowBand>[];

  var y = paperTop;
  while (y <= paperBottom) {
    if (isRuleRow[y] == 0 &&
        isSolidBandRow[y] == 0 &&
        rowInk[y] >= minRowInk) {
      final bandTop = y;
      var bandBottom = y;
      var bandInk = rowInk[y];
      y++;
      while (y <= paperBottom) {
        if (isRuleRow[y] != 0 || isSolidBandRow[y] != 0) break;
        if (rowInk[y] >= minRowInk) {
          bandBottom = y;
          bandInk += rowInk[y];
          y++;
        } else {
          // Peek ahead across micro-gaps inside characters/fractions.
          var gapEnd = y;
          while (gapEnd <= paperBottom &&
              gapEnd - y < maxIntraLineGap &&
              isRuleRow[gapEnd] == 0 &&
              isSolidBandRow[gapEnd] == 0 &&
              rowInk[gapEnd] < minRowInk) {
            gapEnd++;
          }
          if (gapEnd <= paperBottom &&
              isRuleRow[gapEnd] == 0 &&
              isSolidBandRow[gapEnd] == 0 &&
              rowInk[gapEnd] >= minRowInk) {
            y = gapEnd;
          } else {
            break;
          }
        }
      }

      final bandHeight = bandBottom - bandTop + 1;
      if (bandHeight == 1 && bandInk < math.max(4, (colW * 0.02).round())) {
        continue;
      }

      final (left, right) = _computeBandHorizontalSpan(
        inkMask: inkMask,
        width: width,
        top: bandTop,
        bottom: bandBottom,
        colLeft: colLeft,
        colRight: colRight,
      );
      if (right >= left) {
        bands.add(
          _RowBand(
            top: bandTop,
            bottom: bandBottom,
            left: left,
            right: right,
            inkSum: bandInk,
          ),
        );
      }
    } else {
      y++;
    }
  }

  if (bands.isEmpty) return null;

  // 7. Segment bands into question blocks using adaptive gap thresholds.
  final lineH = _estimateTypicalLineHeight(bands, paperH);
  final gaps = <int>[
    for (var i = 0; i < bands.length - 1; i++)
      math.max(0, bands[i + 1].top - bands[i].bottom - 1),
  ];

  double intraGap = lineH * 0.65;
  if (gaps.isNotEmpty) {
    final sortedGaps = List<int>.from(gaps)..sort();
    final p35Index = ((sortedGaps.length - 1) * 0.35).floor();
    intraGap = math.max(2.0, sortedGaps[p35Index].toDouble());
  }

  final minBreakGap = math.max(5.0, paperH * 0.022);
  final relativeBreakThreshold = math.max(minBreakGap, intraGap * 1.75);
  final absoluteBreakThreshold = math.max(paperH * 0.032, lineH * 1.35);

  final blocks = <_QuestionBlock>[];
  var groupStart = 0;
  for (var i = 0; i < bands.length; i++) {
    final isLast = i == bands.length - 1;
    var splitAfter = isLast;
    if (!isLast) {
      final cur = bands[i];
      final next = bands[i + 1];
      final gap = next.top - cur.bottom - 1;

      var hasDividerBetween = false;
      for (var r = cur.bottom + 1; r < next.top; r++) {
        if (isRuleRow[r] != 0 || isSolidBandRow[r] != 0) {
          hasDividerBetween = true;
          break;
        }
      }

      final isRelativeBreak =
          gap >= relativeBreakThreshold && gap >= lineH * 0.65;
      final isAbsoluteBreak = gap >= absoluteBreakThreshold;
      final endsShort = cur.right < colLeft + colW * 0.62;
      final startsNearLeft = next.left < colLeft + colW * 0.25;
      final isParagraphBreak = endsShort &&
          startsNearLeft &&
          gap >= math.max(minBreakGap * 0.85, intraGap * 1.45) &&
          gap >= lineH * 0.55;

      splitAfter = hasDividerBetween ||
          isRelativeBreak ||
          isAbsoluteBreak ||
          isParagraphBreak;
    }

    if (splitAfter) {
      final block = _mergeBands(bands, groupStart, i);
      final area = block.width * block.height;
      final density = area > 0 ? block.inkSum / area : 1.0;
      if (block.height >= 4 &&
          block.width >= colW * 0.10 &&
          block.inkSum >= 15 &&
          density <= 0.62) {
        blocks.add(block);
      }
      groupStart = i + 1;
    }
  }

  if (blocks.isEmpty) return null;

  // 8. Select the question block covering (or nearest to) the vertical center.
  final centerY = height * 0.5;
  final containTol = lineH * 0.5;
  var bestIdx = -1;
  var bestDist = double.infinity;

  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    final double dist;
    if (centerY >= b.top - containTol && centerY <= b.bottom + containTol) {
      dist = 0.0;
    } else if (centerY < b.top) {
      dist = b.top - centerY;
    } else {
      dist = centerY - b.bottom;
    }

    if (dist < bestDist) {
      bestDist = dist;
      bestIdx = i;
    } else if (dist == bestDist && bestIdx >= 0) {
      // Break ties by preferring the block whose center is closer to centerY.
      final curCenterDist = ((b.top + b.bottom) * 0.5 - centerY).abs();
      final bestCenterDist =
          ((blocks[bestIdx].top + blocks[bestIdx].bottom) * 0.5 - centerY)
              .abs();
      if (curCenterDist < bestCenterDist) {
        bestIdx = i;
      }
    }
  }

  if (bestIdx < 0 || bestDist > height * 0.30) {
    return null;
  }

  // 9. Add safe breathing room that never encroaches into neighboring questions.
  final target = blocks[bestIdx];
  final gapAbove = bestIdx > 0
      ? (target.top - blocks[bestIdx - 1].bottom).toDouble()
      : (target.top - paperTop).toDouble();
  final gapBelow = bestIdx < blocks.length - 1
      ? (blocks[bestIdx + 1].top - target.bottom).toDouble()
      : (paperBottom - target.bottom).toDouble();

  final desiredPadV = math.max(height * 0.022, lineH * 0.75);
  final padTop = math.min(math.max(0.0, gapAbove * 0.42), desiredPadV);
  final padBottom = math.min(math.max(0.0, gapBelow * 0.42), desiredPadV);

  final basePadH = math.max(width * 0.03, lineH * 0.8);
  final wideLineBoost = target.width >= colW * 0.72 ? 1.35 : 1.0;
  final padH = basePadH * wideLineBoost;

  final leftPx = math.max(colLeft.toDouble(), target.left - padH);
  final rightPx = math.min(colRight.toDouble(), target.right + padH);
  final topPx = math.max(paperTop.toDouble(), target.top - padTop);
  final bottomPx = math.min(paperBottom.toDouble(), target.bottom + padBottom);

  final normLeft = (leftPx / width).clamp(0.0, 1.0);
  final normTop = (topPx / height).clamp(0.0, 1.0);
  final normRight = ((rightPx + 1.0) / width).clamp(0.0, 1.0);
  final normBottom = ((bottomPx + 1.0) / height).clamp(0.0, 1.0);

  final normW = normRight - normLeft;
  final normH = normBottom - normTop;
  if (normW < 0.14 || normH < 0.045) return null;
  if (normW * normH > 0.90) return null;

  return <double>[normLeft, normTop, normRight, normBottom];
}

int _estimateCenterPaperLuma(Uint8List gray, int width, int height) {
  final hist = Int32List(256);
  final x0 = (width * 0.25).round();
  final x1 = (width * 0.75).round();
  final y0 = (height * 0.25).round();
  final y1 = (height * 0.75).round();
  var count = 0;

  for (var y = y0; y < y1; y++) {
    final rowOffset = y * width;
    for (var x = x0; x < x1; x++) {
      hist[gray[rowOffset + x]]++;
      count++;
    }
  }
  if (count == 0) return 0;

  // 75th percentile represents clean paper luminance even over dense text.
  final target = (count * 0.75).round();
  var cumulative = 0;
  for (var v = 0; v < 256; v++) {
    cumulative += hist[v];
    if (cumulative >= target) return v;
  }
  return 255;
}

(int, int, int, int) _detectPaperBounds({
  required int width,
  required int height,
  required int paperLuma,
  required int Function(int x0, int y0, int x1, int y1) boxMean,
}) {
  final darkBorderThreshold = (paperLuma * 0.62).round();
  final maxTrimX = (width * 0.30).round();
  final maxTrimY = (height * 0.30).round();
  final sampleY0 = (height * 0.20).round();
  final sampleY1 = (height * 0.80).round();
  final sampleX0 = (width * 0.20).round();
  final sampleX1 = (width * 0.80).round();

  var left = 0;
  while (left < maxTrimX &&
      boxMean(left, sampleY0, left, sampleY1) < darkBorderThreshold) {
    left++;
  }
  var right = width - 1;
  while (width - 1 - right < maxTrimX &&
      boxMean(right, sampleY0, right, sampleY1) < darkBorderThreshold) {
    right--;
  }
  var top = 0;
  while (top < maxTrimY &&
      boxMean(sampleX0, top, sampleX1, top) < darkBorderThreshold) {
    top++;
  }
  var bottom = height - 1;
  while (height - 1 - bottom < maxTrimY &&
      boxMean(sampleX0, bottom, sampleX1, bottom) < darkBorderThreshold) {
    bottom--;
  }

  // Step slightly past any trimmed paper/desk edge so edge contrast isn't ink.
  const edgeInset = 3;
  if (left > 0) left = math.min(width - 1, left + edgeInset);
  if (right < width - 1) right = math.max(0, right - edgeInset);
  if (top > 0) top = math.min(height - 1, top + edgeInset);
  if (bottom < height - 1) bottom = math.max(0, bottom - edgeInset);

  if (right - left + 1 < width * 0.4 || bottom - top + 1 < height * 0.4) {
    return (0, 0, width - 1, height - 1);
  }
  return (left, top, right, bottom);
}

(int, int) _selectActiveColumn({
  required Uint8List inkMask,
  required int width,
  required int height,
  required int paperLeft,
  required int paperTop,
  required int paperRight,
  required int paperBottom,
}) {
  final paperW = paperRight - paperLeft + 1;
  final centerY = height ~/ 2;
  final sampleTop = math.max(paperTop, centerY - (height * 0.35).round());
  final sampleBottom = math.min(paperBottom, centerY + (height * 0.35).round());
  final sampleH = sampleBottom - sampleTop + 1;
  if (sampleH < 16 || paperW < 60) return (paperLeft, paperRight);

  final colInk = Int32List(width);
  for (var y = sampleTop; y <= sampleBottom; y++) {
    final rowOffset = y * width;
    for (var x = paperLeft; x <= paperRight; x++) {
      if (inkMask[rowOffset + x] != 0) colInk[x]++;
    }
  }

  final searchStart = paperLeft + (paperW * 0.22).round();
  final searchEnd = paperRight - (paperW * 0.22).round();
  final emptyColLimit = math.max(1, (sampleH * 0.015).round());

  // Look for either (a) a clean whitespace column gutter or (b) a tall vertical
  // ruling line dividing a two-column exam paper.
  var bestSplitStart = -1;
  var bestSplitEnd = -1;
  var bestSplitScore = 0;

  var x = searchStart;
  while (x <= searchEnd) {
    if (colInk[x] <= emptyColLimit) {
      final start = x;
      while (x <= searchEnd && colInk[x] <= emptyColLimit) {
        x++;
      }
      final end = x - 1;
      final gutterW = end - start + 1;
      if (gutterW >= math.max(7, (paperW * 0.035).round()) &&
          gutterW > bestSplitScore) {
        bestSplitScore = gutterW;
        bestSplitStart = start;
        bestSplitEnd = end;
      }
    } else if (colInk[x] >= (sampleH * 0.55).round()) {
      final start = x;
      while (x <= searchEnd && colInk[x] >= (sampleH * 0.55).round()) {
        x++;
      }
      final end = x - 1;
      final ruleW = end - start + 1;
      if (ruleW <= 4) {
        // Confirm low-ink margins on at least one immediate side of the divider.
        final leftQuiet = start - 2 >= paperLeft &&
            colInk[start - 2] <= (sampleH * 0.08).round();
        final rightQuiet = end + 2 <= paperRight &&
            colInk[end + 2] <= (sampleH * 0.08).round();
        if ((leftQuiet || rightQuiet) && sampleH > bestSplitScore) {
          bestSplitScore = sampleH;
          bestSplitStart = math.max(paperLeft, start - 2);
          bestSplitEnd = math.min(paperRight, end + 2);
        }
      }
    } else {
      x++;
    }
  }

  if (bestSplitStart < 0) return (paperLeft, paperRight);

  final leftW = bestSplitStart - paperLeft;
  final rightW = paperRight - bestSplitEnd;
  if (leftW < paperW * 0.24 || rightW < paperW * 0.24) {
    return (paperLeft, paperRight);
  }

  // Verify both halves have multi-row text content so a single-column question
  // with a small side diagram is not falsely split.
  var leftActiveRows = 0;
  var rightActiveRows = 0;
  final minLeftInk = math.max(2, (leftW * 0.015).round());
  final minRightInk = math.max(2, (rightW * 0.015).round());

  for (var y = sampleTop; y <= sampleBottom; y++) {
    final rowOffset = y * width;
    var lc = 0;
    for (var cx = paperLeft; cx < bestSplitStart; cx++) {
      if (inkMask[rowOffset + cx] != 0) lc++;
    }
    if (lc >= minLeftInk) leftActiveRows++;

    var rc = 0;
    for (var cx = bestSplitEnd + 1; cx <= paperRight; cx++) {
      if (inkMask[rowOffset + cx] != 0) rc++;
    }
    if (rc >= minRightInk) rightActiveRows++;
  }

  if (leftActiveRows < sampleH * 0.20 || rightActiveRows < sampleH * 0.20) {
    return (paperLeft, paperRight);
  }

  final centerX = width * 0.5;
  final gutterMid = (bestSplitStart + bestSplitEnd) * 0.5;
  if (centerX < gutterMid) {
    return (paperLeft, math.max(paperLeft, bestSplitStart - 1));
  }
  return (math.min(paperRight, bestSplitEnd + 1), paperRight);
}

(int, int) _computeBandHorizontalSpan({
  required Uint8List inkMask,
  required int width,
  required int top,
  required int bottom,
  required int colLeft,
  required int colRight,
}) {
  final colW = colRight - colLeft + 1;
  final colCounts = Int32List(colW);
  for (var y = top; y <= bottom; y++) {
    final rowOffset = y * width;
    for (var x = colLeft; x <= colRight; x++) {
      if (inkMask[rowOffset + x] != 0) {
        colCounts[x - colLeft]++;
      }
    }
  }

  // Ignore tiny isolated single-pixel speckles detached far from main ink.
  final maxGapToDiscard = math.max(12, (colW * 0.07).round());
  var leftIdx = 0;
  while (leftIdx < colW && colCounts[leftIdx] == 0) {
    leftIdx++;
  }
  if (leftIdx >= colW) return (colRight, colLeft);

  var rightIdx = colW - 1;
  while (rightIdx > leftIdx && colCounts[rightIdx] == 0) {
    rightIdx--;
  }

  // Trim isolated 1-2px edge noise specks separated by a wide blank gap.
  while (leftIdx < rightIdx && colCounts[leftIdx] <= 1) {
    var next = leftIdx + 1;
    while (next <= rightIdx && colCounts[next] == 0) {
      next++;
    }
    if (next - leftIdx > maxGapToDiscard) {
      leftIdx = next;
    } else {
      break;
    }
  }
  while (rightIdx > leftIdx && colCounts[rightIdx] <= 1) {
    var prev = rightIdx - 1;
    while (prev >= leftIdx && colCounts[prev] == 0) {
      prev--;
    }
    if (rightIdx - prev > maxGapToDiscard) {
      rightIdx = prev;
    } else {
      break;
    }
  }

  return (colLeft + leftIdx, colLeft + rightIdx);
}

double _estimateTypicalLineHeight(List<_RowBand> bands, int paperH) {
  final textHeights = <int>[];
  final maxTextLineH = math.max(8, (paperH * 0.14).round());
  for (final band in bands) {
    if (band.height <= maxTextLineH) {
      textHeights.add(band.height);
    }
  }
  final source = textHeights.isNotEmpty
      ? textHeights
      : <int>[for (final band in bands) band.height];
  source.sort();
  final median = source[source.length ~/ 2].toDouble();
  return median.clamp(math.max(4.0, paperH * 0.015), paperH * 0.09);
}

_QuestionBlock _mergeBands(List<_RowBand> bands, int start, int end) {
  var left = bands[start].left;
  var right = bands[start].right;
  final top = bands[start].top;
  final bottom = bands[end].bottom;
  var inkSum = 0;
  for (var i = start; i <= end; i++) {
    if (bands[i].left < left) left = bands[i].left;
    if (bands[i].right > right) right = bands[i].right;
    inkSum += bands[i].inkSum;
  }
  return _QuestionBlock(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    inkSum: inkSum,
  );
}

class _RowBand {
  const _RowBand({
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
    required this.inkSum,
  });

  final int top;
  final int bottom;
  final int left;
  final int right;
  final int inkSum;

  int get height => bottom - top + 1;
}

class _QuestionBlock {
  const _QuestionBlock({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.inkSum,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;
  final int inkSum;

  int get width => right - left + 1;
  int get height => bottom - top + 1;
}
