import 'package:flutter/material.dart';

/// SyncN Field Ops design tokens.
///
/// The accent deliberately flips between themes: Absolute Zero has the
/// contrast on white, turquoise is what stays legible on deep navy outdoors.
class SyncnColors {
  // Brand seeds.
  static const absoluteZero = Color(0xFF004BC0);
  static const turquoise = Color(0xFF40EEF3);
  static const azure = Color(0xFFF1FEFF);

  // Light - the "Console" treatment.
  static const lBg = Color(0xFFF6F8FC);
  static const lSurface = Color(0xFFFFFFFF);
  static const lSurface2 = Color(0xFFF3F6FA);
  static const lSurface3 = Color(0xFFEDF1F7);
  static const lInk = Color(0xFF0F1F3D);
  static const lMuted = Color(0xFF64748B);
  static const lLine = Color(0xFFE2E8F0);
  static const lLineSoft = Color(0xFFEEF2F7);
  static const lAccent = absoluteZero;
  static const lAccentInk = Color(0xFFFFFFFF);
  static const lAccentWash = Color(0xFFE3ECFF);

  // Dark - the "field" treatment.
  static const dBg = Color(0xFF04102A);
  static const dSurface = Color(0xFF071838);
  static const dSurface2 = Color(0xFF0A1E42);
  static const dSurface3 = Color(0xFF0F2650);
  static const dInk = Color(0xFFE4F1FF);
  static const dMuted = Color(0xFF9CB4D8);

  /// Bright glass edge - for panel borders that must read against blur.
  static const dOutline = Color(0xFF3D5A93);

  /// Flat hairline between rows and sections. Using [dOutline] everywhere
  /// makes the UI look wireframed.
  static const dOutlineVariant = Color(0xFF22345C);
  static const dLineSoft = Color(0xFF14264D);
  static const dAccent = turquoise;
  static const dAccentInk = Color(0xFF00363D);
  static const dAccentWash = Color(0xFF00337F);

  // Semantic colour is separate from the accent and never borrows it.
  static const success = Color(0xFF16A34A);
  static const warning = Color(0xFFD97706);
  static const errorLight = Color(0xFFDC2626);
  static const errorDark = Color(0xFFFF6B6B);
}

/// Corner radii.
class SyncnRadius {
  static const double def = 8;
  static const double lg = 16;
  static const double xl = 24;
}

/// Theme-aware colours resolved for the current brightness, so widgets do not
/// each re-derive "which navy am I on".
class SyncnPalette extends ThemeExtension<SyncnPalette> {
  const SyncnPalette({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.ink,
    required this.muted,
    required this.line,
    required this.lineSoft,
    required this.accent,
    required this.accentInk,
    required this.accentWash,
    required this.success,
    required this.warning,
    required this.danger,
    required this.isDark,
  });

  final Color bg;
  final Color surface;
  final Color surface2;
  final Color surface3;
  final Color ink;
  final Color muted;
  final Color line;
  final Color lineSoft;
  final Color accent;
  final Color accentInk;
  final Color accentWash;
  final Color success;
  final Color warning;
  final Color danger;
  final bool isDark;

  static const light = SyncnPalette(
    bg: SyncnColors.lBg,
    surface: SyncnColors.lSurface,
    surface2: SyncnColors.lSurface2,
    surface3: SyncnColors.lSurface3,
    ink: SyncnColors.lInk,
    muted: SyncnColors.lMuted,
    line: SyncnColors.lLine,
    lineSoft: SyncnColors.lLineSoft,
    accent: SyncnColors.lAccent,
    accentInk: SyncnColors.lAccentInk,
    accentWash: SyncnColors.lAccentWash,
    success: SyncnColors.success,
    warning: SyncnColors.warning,
    danger: SyncnColors.errorLight,
    isDark: false,
  );

  static const dark = SyncnPalette(
    bg: SyncnColors.dBg,
    surface: SyncnColors.dSurface,
    surface2: SyncnColors.dSurface2,
    surface3: SyncnColors.dSurface3,
    ink: SyncnColors.dInk,
    muted: SyncnColors.dMuted,
    line: SyncnColors.dOutlineVariant,
    lineSoft: SyncnColors.dLineSoft,
    accent: SyncnColors.dAccent,
    accentInk: SyncnColors.dAccentInk,
    accentWash: SyncnColors.dAccentWash,
    success: SyncnColors.success,
    warning: SyncnColors.warning,
    danger: SyncnColors.errorDark,
    isDark: true,
  );

  static SyncnPalette of(BuildContext context) =>
      Theme.of(context).extension<SyncnPalette>() ?? light;

  @override
  SyncnPalette copyWith() => this;

  @override
  SyncnPalette lerp(ThemeExtension<SyncnPalette>? other, double t) =>
      t < 0.5 ? this : (other as SyncnPalette? ?? this);
}

/// The defining surface of the system: a solid card on a desk in light, and
/// frosted glass over navy on a phone at a job site at night.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = SyncnRadius.lg,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final p = SyncnPalette.of(context);

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: p.isDark
            ? const Color(0xFF16305F).withValues(alpha: 0.5)
            : p.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: borderColor ??
              (p.isDark
                  ? SyncnColors.dOutline.withValues(alpha: 0.45)
                  : p.line),
        ),
        boxShadow: p.isDark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x0F0F1F3D),
                  blurRadius: 2,
                  offset: Offset(0, 1),
                ),
                BoxShadow(
                  color: Color(0x0D0F1F3D),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
      ),
      child: child,
    );
  }
}

/// Builds the Material themes from the tokens above.
class SyncnTheme {
  static const _font = 'Poppins';

  static TextTheme _text(Color ink, Color muted) => TextTheme(
        displayLarge: TextStyle(
            fontSize: 48, height: 52 / 48, fontWeight: FontWeight.w900, color: ink, letterSpacing: -1),
        displayMedium: TextStyle(
            fontSize: 36, height: 40 / 36, fontWeight: FontWeight.w900, color: ink, letterSpacing: -0.5),
        displaySmall: TextStyle(
            fontSize: 30, height: 36 / 30, fontWeight: FontWeight.w700, color: ink),
        headlineLarge: TextStyle(
            fontSize: 24, height: 30 / 24, fontWeight: FontWeight.w700, color: ink),
        headlineMedium: TextStyle(
            fontSize: 20, height: 26 / 20, fontWeight: FontWeight.w600, color: ink),
        headlineSmall: TextStyle(
            fontSize: 18, height: 24 / 18, fontWeight: FontWeight.w600, color: ink),
        titleLarge: TextStyle(
            fontSize: 18, height: 24 / 18, fontWeight: FontWeight.w700, color: ink),
        titleMedium: TextStyle(
            fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w600, color: ink),
        titleSmall: TextStyle(
            fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w600, color: ink),
        bodyLarge: TextStyle(fontSize: 16, height: 24 / 16, color: ink),
        bodyMedium: TextStyle(fontSize: 14, height: 20 / 14, color: ink),
        bodySmall: TextStyle(fontSize: 12, height: 16 / 12, color: muted),
        labelLarge: TextStyle(
            fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w500, color: ink, letterSpacing: 0.3),
        labelMedium: TextStyle(
            fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500, color: muted, letterSpacing: 0.4),
        labelSmall: TextStyle(
            fontSize: 11, height: 14 / 11, fontWeight: FontWeight.w500, color: muted, letterSpacing: 0.5),
      );

  static ThemeData _build(SyncnPalette p) {
    final scheme = ColorScheme(
      brightness: p.isDark ? Brightness.dark : Brightness.light,
      primary: p.accent,
      onPrimary: p.accentInk,
      primaryContainer: p.accentWash,
      onPrimaryContainer: p.isDark ? p.ink : p.accent,
      secondary: p.accent,
      onSecondary: p.accentInk,
      surface: p.surface,
      onSurface: p.ink,
      surfaceContainerHighest: p.surface3,
      outline: p.line,
      outlineVariant: p.lineSoft,
      error: p.danger,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      fontFamily: _font,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg,
      canvasColor: p.bg,
      textTheme: _text(p.ink, p.muted),
      dividerTheme: DividerThemeData(color: p.lineSoft, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        foregroundColor: p.ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: _font,
          fontSize: 18,
          height: 24 / 18,
          fontWeight: FontWeight.w700,
          color: p.ink,
        ),
      ),
      // Primary button: translucent accent fill with a matching border.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: p.accentInk,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SyncnRadius.def),
          ),
          textStyle: const TextStyle(
            fontFamily: _font,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.ink,
          minimumSize: const Size.fromHeight(48),
          side: BorderSide(color: p.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SyncnRadius.def),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: p.accent),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SyncnRadius.lg),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.accent,
        linearTrackColor: p.isDark ? p.surface3 : p.surface3,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.accent : p.muted,
        ),
      ),
      extensions: [p],
    );
  }

  static ThemeData get light => _build(SyncnPalette.light);
  static ThemeData get dark => _build(SyncnPalette.dark);
}
