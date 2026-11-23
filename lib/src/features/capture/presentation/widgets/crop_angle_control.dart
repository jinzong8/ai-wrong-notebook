import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Minimum and maximum fine-straightening angle in degrees.
const double kMinFineRotationDegrees = -45.0;
const double kMaxFineRotationDegrees = 45.0;

/// Compact angle-straightening bar (-45° to +45°) displayed above the crop
/// toolbar so users can level tilted worksheet photos without affecting 90°
/// coarse rotation.
class CropAngleControl extends StatelessWidget {
  const CropAngleControl({
    super.key,
    required this.angleDegrees,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.enabled = true,
  });

  final double angleDegrees;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;
  final bool enabled;

  static double snapAngle(double raw) {
    final clamped =
        raw.clamp(kMinFineRotationDegrees, kMaxFineRotationDegrees).toDouble();
    if (clamped.abs() <= 0.8) return 0.0;
    return (clamped * 2).round() / 2.0;
  }

  static String formatAngle(double degrees) {
    if (degrees.abs() < 0.05) return '0°';
    final sign = degrees > 0 ? '+' : '';
    final isWhole = (degrees - degrees.roundToDouble()).abs() < 0.05;
    return isWhole
        ? '$sign${degrees.round()}°'
        : '$sign${degrees.toStringAsFixed(1)}°';
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF818CF8);
    final isTilted = angleDegrees.abs() >= 0.05;
    final clamped = angleDegrees
        .clamp(kMinFineRotationDegrees, kMaxFineRotationDegrees)
        .toDouble();

    return IgnorePointer(
      ignoring: !enabled,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: Container(
          height: 44,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
          child: Row(
            children: <Widget>[
              InkWell(
                key: const Key('crop-angle-reset'),
                borderRadius: BorderRadius.circular(14),
                onTap: (!enabled || !isTilted) ? null : () => onChanged(0.0),
                child: Container(
                  width: 68,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isTilted
                        ? accent.withValues(alpha: 0.18)
                        : Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isTilted
                          ? accent.withValues(alpha: 0.55)
                          : Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Icon(
                        CupertinoIcons.compass,
                        size: 13,
                        color: isTilted ? accent : Colors.white60,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          formatAngle(clamped),
                          overflow: TextOverflow.clip,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                            color: isTilted ? accent : Colors.white70,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: CustomPaint(
                            painter: _AngleRulerPainter(
                              angleDegrees: clamped,
                              accentColor: accent,
                            ),
                          ),
                        ),
                      ),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        activeTrackColor: Colors.transparent,
                        inactiveTrackColor: Colors.transparent,
                        thumbColor: isTilted ? accent : Colors.white,
                        overlayColor: accent.withValues(alpha: 0.18),
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7.5,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 15,
                        ),
                      ),
                      child: Slider(
                        key: const Key('crop-angle-slider'),
                        min: kMinFineRotationDegrees,
                        max: kMaxFineRotationDegrees,
                        value: clamped,
                        onChangeStart: (_) {
                          if (enabled) onChangeStart?.call();
                        },
                        onChangeEnd: (_) {
                          if (enabled) onChangeEnd?.call();
                        },
                        onChanged: (v) {
                          if (enabled) onChanged(snapAngle(v));
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AngleRulerPainter extends CustomPainter {
  const _AngleRulerPainter({
    required this.angleDegrees,
    required this.accentColor,
  });

  final double angleDegrees;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final centerX = size.width / 2;
    const totalSpan = kMaxFineRotationDegrees - kMinFineRotationDegrees;

    // Draw subtle degree ticks every 5°, with taller ticks at 0° and ±15°/±30°/±45°.
    for (var deg = -45; deg <= 45; deg += 5) {
      final t = (deg - kMinFineRotationDegrees) / totalSpan;
      final x = t * size.width;
      final isCenter = deg == 0;
      final isMajor = deg % 15 == 0;
      final halfTick = isCenter ? 8.0 : (isMajor ? 5.5 : 3.2);
      final paint = Paint()
        ..color = isCenter
            ? Colors.white.withValues(alpha: 0.85)
            : Colors.white.withValues(alpha: isMajor ? 0.36 : 0.20)
        ..strokeWidth = isCenter ? 1.6 : 1.0
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(x, centerY - halfTick),
        Offset(x, centerY + halfTick),
        paint,
      );
    }

    // Highlight active angle deflection from 0° center mark to current value.
    if (angleDegrees.abs() >= 0.05) {
      final curT = (angleDegrees - kMinFineRotationDegrees) / totalSpan;
      final curX = curT * size.width;
      canvas.drawLine(
        Offset(centerX, centerY),
        Offset(curX, centerY),
        Paint()
          ..color = accentColor.withValues(alpha: 0.85)
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_AngleRulerPainter oldDelegate) {
    return oldDelegate.angleDegrees != angleDegrees ||
        oldDelegate.accentColor != accentColor;
  }
}
