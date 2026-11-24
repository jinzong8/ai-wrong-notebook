import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';

/// Editorial Study Paper & Deep Ink Light Theme.
///
/// Designed for calm, long-form reading of math formulas and study notes:
/// warm paper canvas (`#F6F5F0`), crisp white cards (`#FFFFFF`), restrained
/// hairline dividers, and deep academic cobalt (`#1D4ED8`) accents.
ThemeData buildLightTheme() {
  const cobalt = Color(0xFF1D4ED8);
  const paperCanvas = Color(0xFFF6F5F0);
  const surfaceWhite = Color(0xFFFFFFFF);
  const subtleSurface = Color(0xFFEFEDE7);
  const inkPrimary = Color(0xFF141923);
  const inkSecondary = Color(0xFF556070);
  const hairline = Color(0xFFE5E2DA);

  final base = FlexThemeData.light(
    colors: const FlexSchemeColor(
      primary: cobalt,
      primaryContainer: Color(0xFFEBF2FF),
      secondary: Color(0xFF0F766E),
      secondaryContainer: Color(0xFFE6F4F1),
      tertiary: Color(0xFFB45309),
      tertiaryContainer: Color(0xFFFEF3E2),
      appBarColor: paperCanvas,
      error: Color(0xFFB91C1C),
    ),
    useMaterial3: true,
    surfaceMode: FlexSurfaceMode.levelSurfacesLowScaffold,
    scaffoldBackground: paperCanvas,
    surface: surfaceWhite,
    appBarBackground: paperCanvas,
    appBarElevation: 0,
    subThemesData: const FlexSubThemesData(
      blendOnLevel: 0,
      blendOnColors: false,
      useM2StyleDividerInM3: true,
      inputDecoratorBorderType: FlexInputBorderType.outline,
      inputDecoratorRadius: 12,
      chipRadius: 10,
      navigationBarIndicatorRadius: 12,
      navigationBarSelectedLabelSchemeColor: SchemeColor.primary,
      navigationBarIndicatorSchemeColor: SchemeColor.primaryContainer,
    ),
  );

  final colorScheme = base.colorScheme.copyWith(
    primary: cobalt,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFEBF2FF),
    onPrimaryContainer: const Color(0xFF1E3A8A),
    surface: surfaceWhite,
    onSurface: inkPrimary,
    onSurfaceVariant: inkSecondary,
    surfaceContainerHighest: subtleSurface,
    outlineVariant: hairline,
  );

  return base.copyWith(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: paperCanvas,
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: paperCanvas,
      surfaceTintColor: Colors.transparent,
      foregroundColor: inkPrimary,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      titleTextStyle: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: inkPrimary,
      ),
    ),
    iconTheme: const IconThemeData(
      color: inkSecondary,
      size: 22,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: cobalt,
        foregroundColor: Colors.white,
        elevation: 0,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: inkPrimary,
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        side: const BorderSide(color: hairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF18202C),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: surfaceWhite,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: const Color(0xFFEBF2FF),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11.5,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? cobalt : inkSecondary,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const IconThemeData(color: cobalt, size: 22);
        }
        return const IconThemeData(color: inkSecondary, size: 22);
      }),
    ),
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        color: inkPrimary,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: inkPrimary,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: 15.5,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        color: inkPrimary,
      ),
      titleSmall: base.textTheme.titleSmall?.copyWith(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: inkPrimary,
      ),
    ),
  );
}

/// Editorial Ink Slate Dark Theme.
///
/// Uses clean slate neutrals (`#0D1117` / `#161C24`) paired with legible sky
/// cobalt (`#60A5FA`) accents — intentionally avoiding purple-on-dark glare.
ThemeData buildDarkTheme() {
  const skyCobalt = Color(0xFF60A5FA);
  const darkCanvas = Color(0xFF0D1117);
  const darkCard = Color(0xFF161C24);
  const darkSubtle = Color(0xFF1F2733);
  const darkBorder = Color(0xFF263040);
  const darkText = Color(0xFFF1F5F9);
  const darkMuted = Color(0xFF94A3B8);

  final base = FlexThemeData.dark(
    colors: const FlexSchemeColor(
      primary: skyCobalt,
      primaryContainer: Color(0xFF1B2E4B),
      secondary: Color(0xFF34D399),
      secondaryContainer: Color(0xFF132E29),
      tertiary: Color(0xFFFBBF24),
      tertiaryContainer: Color(0xFF312614),
      appBarColor: darkCanvas,
      error: Color(0xFFF87171),
    ),
    useMaterial3: true,
    surfaceMode: FlexSurfaceMode.levelSurfacesLowScaffold,
    scaffoldBackground: darkCanvas,
    surface: darkCard,
    appBarBackground: darkCanvas,
    appBarElevation: 0,
    subThemesData: const FlexSubThemesData(
      blendOnLevel: 0,
      useM2StyleDividerInM3: true,
      inputDecoratorBorderType: FlexInputBorderType.outline,
      inputDecoratorRadius: 12,
      chipRadius: 10,
      navigationBarIndicatorRadius: 12,
      navigationBarSelectedLabelSchemeColor: SchemeColor.primary,
      navigationBarIndicatorSchemeColor: SchemeColor.primaryContainer,
    ),
  );

  final colorScheme = base.colorScheme.copyWith(
    primary: skyCobalt,
    onPrimary: const Color(0xFF0B1526),
    primaryContainer: const Color(0xFF1B2E4B),
    onPrimaryContainer: const Color(0xFFDBEAFE),
    surface: darkCard,
    onSurface: darkText,
    onSurfaceVariant: darkMuted,
    surfaceContainerHighest: darkSubtle,
    outlineVariant: darkBorder,
  );

  return base.copyWith(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: darkCanvas,
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: darkCanvas,
      surfaceTintColor: Colors.transparent,
      foregroundColor: darkText,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      titleTextStyle: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: darkText,
      ),
    ),
    iconTheme: const IconThemeData(
      color: darkMuted,
      size: 22,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: skyCobalt,
        foregroundColor: const Color(0xFF0B1526),
        elevation: 0,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: darkText,
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        side: const BorderSide(color: darkBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xFF232C3B),
      contentTextStyle: const TextStyle(color: darkText, fontSize: 13.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: darkCard,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: const Color(0xFF1B2E4B),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11.5,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: selected ? skyCobalt : darkMuted,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return const IconThemeData(color: skyCobalt, size: 22);
        }
        return const IconThemeData(color: darkMuted, size: 22);
      }),
    ),
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        color: darkText,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: darkText,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: 15.5,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        color: darkText,
      ),
      titleSmall: base.textTheme.titleSmall?.copyWith(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: darkText,
      ),
    ),
  );
}
