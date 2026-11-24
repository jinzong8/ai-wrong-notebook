import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:smart_wrong_notebook/src/shared/widgets/math_content_view.dart';

/// Semantic design tokens for the Study Paper & Deep Ink editorial UI.
class EditorialPalette {
  const EditorialPalette({
    required this.isDark,
    required this.canvas,
    required this.card,
    required this.subtle,
    required this.hairline,
    required this.inkPrimary,
    required this.inkSecondary,
    required this.inkMuted,
    required this.cobalt,
    required this.cobaltTint,
    required this.emerald,
    required this.emeraldTint,
    required this.terracotta,
    required this.terracottaTint,
    required this.ochre,
    required this.ochreTint,
    required this.danger,
    required this.dangerTint,
  });

  factory EditorialPalette.of(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isDark) {
      return const EditorialPalette(
        isDark: true,
        canvas: Color(0xFF0D1117),
        card: Color(0xFF161C24),
        subtle: Color(0xFF1E2631),
        hairline: Color(0xFF263040),
        inkPrimary: Color(0xFFF1F5F9),
        inkSecondary: Color(0xFF94A3B8),
        inkMuted: Color(0xFF64748B),
        cobalt: Color(0xFF60A5FA),
        cobaltTint: Color(0xFF1A2A42),
        emerald: Color(0xFF34D399),
        emeraldTint: Color(0xFF122C26),
        terracotta: Color(0xFFFB923C),
        terracottaTint: Color(0xFF2F1F15),
        ochre: Color(0xFFFBBF24),
        ochreTint: Color(0xFF2D2412),
        danger: Color(0xFFF87171),
        dangerTint: Color(0xFF30181A),
      );
    }
    return const EditorialPalette(
      isDark: false,
      canvas: Color(0xFFF6F5F0),
      card: Color(0xFFFFFFFF),
      subtle: Color(0xFFF1EFE9),
      hairline: Color(0xFFE6E3DB),
      inkPrimary: Color(0xFF141923),
      inkSecondary: Color(0xFF556070),
      inkMuted: Color(0xFF8A94A3),
      cobalt: Color(0xFF1D4ED8),
      cobaltTint: Color(0xFFEBF2FF),
      emerald: Color(0xFF0F766E),
      emeraldTint: Color(0xFFE6F4F1),
      terracotta: Color(0xFFC2410C),
      terracottaTint: Color(0xFFFFF1E8),
      ochre: Color(0xFFB45309),
      ochreTint: Color(0xFFFEF6E4),
      danger: Color(0xFFB91C1C),
      dangerTint: Color(0xFFFEF2F2),
    );
  }

  final bool isDark;
  final Color canvas;
  final Color card;
  final Color subtle;
  final Color hairline;
  final Color inkPrimary;
  final Color inkSecondary;
  final Color inkMuted;
  final Color cobalt;
  final Color cobaltTint;
  final Color emerald;
  final Color emeraldTint;
  final Color terracotta;
  final Color terracottaTint;
  final Color ochre;
  final Color ochreTint;
  final Color danger;
  final Color dangerTint;
}

/// Clean paper-surface card with subtle hairline border, gentle ambient depth,
/// and an optional restrained left marginalia accent bar (never garish colored
/// full borders).
class EditorialCard extends StatelessWidget {
  const EditorialCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.accentColor,
    this.backgroundColor,
    this.borderRadius = 16,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? accentColor;
  final Color? backgroundColor;
  final double borderRadius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    final bg = backgroundColor ?? p.card;
    final radius = BorderRadius.circular(borderRadius);

    Widget content = Padding(
      padding: padding,
      child: child,
    );
    if (accentColor != null) {
      content = Stack(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 3.5),
            child: content,
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 3.5,
            child: ColoredBox(color: accentColor!),
          ),
        ],
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: radius,
        border: Border.all(color: p.hairline, width: 1),
        boxShadow: p.isDark
            ? null
            : <BoxShadow>[
                BoxShadow(
                  color: const Color(0xFF0F172A).withValues(alpha: 0.035),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius - 1),
        child: onTap == null
            ? content
            : Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(borderRadius - 1),
                  child: content,
                ),
              ),
      ),
    );
  }
}

/// Quiet editorial section heading with a compact tonal icon badge and title.
class EditorialSectionHeader extends StatelessWidget {
  const EditorialSectionHeader({
    super.key,
    required this.title,
    this.icon,
    this.iconColor,
    this.iconBackground,
    this.trailing,
  });

  final String title;
  final IconData? icon;
  final Color? iconColor;
  final Color? iconBackground;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    final resolvedIconColor = iconColor ?? p.cobalt;
    final resolvedIconBg =
        iconBackground ?? resolvedIconColor.withValues(alpha: p.isDark ? 0.16 : 0.10);

    return Row(
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: resolvedIconBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 14.5, color: resolvedIconColor),
          ),
          const SizedBox(width: 9),
        ],
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.1,
              color: p.inkPrimary,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// Understated tonal pill for metadata (subject, mastery, tags).
class EditorialPill extends StatelessWidget {
  const EditorialPill({
    super.key,
    required this.label,
    required this.backgroundColor,
    required this.textColor,
    this.icon,
  });

  final String label;
  final Color backgroundColor;
  final Color textColor;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: textColor),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: textColor,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Clean tap-to-zoom original question photo card.
class EditorialPhotoPreview extends StatelessWidget {
  const EditorialPhotoPreview({
    super.key,
    required this.imagePath,
    this.maxHeight = 148,
    this.onTap,
  });

  final String imagePath;
  final double maxHeight;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    return GestureDetector(
      onTap: onTap ?? () => showEditorialFullImage(context, imagePath),
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(maxHeight: maxHeight, minHeight: 96),
        decoration: BoxDecoration(
          color: p.subtle,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: p.hairline),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Image.file(
                File(imagePath),
                width: double.infinity,
                height: maxHeight,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(CupertinoIcons.photo, size: 28, color: p.inkMuted),
                      const SizedBox(height: 6),
                      Text(
                        '图片加载失败',
                        style: TextStyle(fontSize: 12, color: p.inkMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(CupertinoIcons.zoom_in, size: 12, color: Colors.white),
                    SizedBox(width: 4),
                    Text(
                      '查看原图',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void showEditorialFullImage(BuildContext context, String imagePath) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text('原图', style: TextStyle(color: Colors.white)),
        ),
        body: Center(
          child: InteractiveViewer(
            minScale: 0.8,
            maxScale: 4.0,
            child: Image.file(File(imagePath)),
          ),
        ),
      ),
    ),
  );
}

/// Clean numbered solution steps list with refined typography and breathing room.
class EditorialStepTimeline extends StatelessWidget {
  const EditorialStepTimeline({
    super.key,
    required this.steps,
  });

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    return EditorialCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          EditorialSectionHeader(
            title: '解题步骤',
            icon: CupertinoIcons.list_number,
            iconColor: p.cobalt,
            trailing: Text(
              '共 ${steps.length} 步',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: p.inkMuted,
              ),
            ),
          ),
          const SizedBox(height: 14),
          ...steps.asMap().entries.map((entry) {
            final idx = entry.key;
            final isLast = idx == steps.length - 1;
            return Padding(
              padding: EdgeInsets.only(bottom: isLast ? 8 : 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Column(
                    children: <Widget>[
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: p.cobaltTint,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            '${idx + 1}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: p.cobalt,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 1.5),
                      child: MathContentView(
                        entry.value,
                        style: TextStyle(
                          fontSize: 14.5,
                          color: p.inkPrimary,
                          height: 1.6,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
