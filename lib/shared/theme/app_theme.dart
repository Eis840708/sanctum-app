import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ── SanctumColors ThemeExtension ──────────────────────────────
// Theme-aware colors (change between dark/light).
// Access via: context.sc.bg  (shorthand)
class SanctumColors extends ThemeExtension<SanctumColors> {
  final Color bg, bg2, bg3, bg4;
  final Color border, border2;
  final Color textPrimary, textSecondary, textTertiary;

  const SanctumColors({
    required this.bg,
    required this.bg2,
    required this.bg3,
    required this.bg4,
    required this.border,
    required this.border2,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
  });

  // ── Dark variant ────────────────────────────────────────────
  static const dark = SanctumColors(
    bg:            Color(0xFF0A0A0F),
    bg2:           Color(0xFF111118),
    bg3:           Color(0xFF1A1A24),
    bg4:           Color(0xFF22222F),
    border:        Color(0x12FFFFFF),
    border2:       Color(0x22FFFFFF),
    textPrimary:   Color(0xFFE8E6E0),
    textSecondary: Color(0xFF9896A0),
    textTertiary:  Color(0xFF5A5868),
  );

  // ── Light variant ───────────────────────────────────────────
  static const light = SanctumColors(
    bg:            Color(0xFFF5F4F0),  // warm off-white
    bg2:           Color(0xFFFFFFFF),  // white cards
    bg3:           Color(0xFFF0EFF8),  // light lavender-grey (inputs)
    bg4:           Color(0xFFE6E5F0),  // active state / tabs
    border:        Color(0x12000000),  // subtle dark border
    border2:       Color(0x20000000),
    textPrimary:   Color(0xFF1A1820),
    textSecondary: Color(0xFF5C5A70),
    textTertiary:  Color(0xFF9896A8),
  );

  @override
  SanctumColors copyWith({
    Color? bg, Color? bg2, Color? bg3, Color? bg4,
    Color? border, Color? border2,
    Color? textPrimary, Color? textSecondary, Color? textTertiary,
  }) => SanctumColors(
    bg:            bg            ?? this.bg,
    bg2:           bg2           ?? this.bg2,
    bg3:           bg3           ?? this.bg3,
    bg4:           bg4           ?? this.bg4,
    border:        border        ?? this.border,
    border2:       border2       ?? this.border2,
    textPrimary:   textPrimary   ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textTertiary:  textTertiary  ?? this.textTertiary,
  );

  @override
  SanctumColors lerp(SanctumColors? other, double t) {
    if (other == null) return this;
    return SanctumColors(
      bg:            Color.lerp(bg,            other.bg,            t)!,
      bg2:           Color.lerp(bg2,           other.bg2,           t)!,
      bg3:           Color.lerp(bg3,           other.bg3,           t)!,
      bg4:           Color.lerp(bg4,           other.bg4,           t)!,
      border:        Color.lerp(border,        other.border,        t)!,
      border2:       Color.lerp(border2,       other.border2,       t)!,
      textPrimary:   Color.lerp(textPrimary,   other.textPrimary,   t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary:  Color.lerp(textTertiary,  other.textTertiary,  t)!,
    );
  }
}

// ── BuildContext shorthand ────────────────────────────────────
extension SanctumContext on BuildContext {
  SanctumColors get sc => Theme.of(this).extension<SanctumColors>()!;
}

// ── Static accent colors (same in both themes) ─────────────
class SanctumTheme {
  // Accent colors — never change between themes
  static const Color gold      = Color(0xFFC9A84C);
  static const Color gold2     = Color(0xFFE8C97A);
  static const Color goldDim   = Color(0x26C9A84C);
  static const Color purple    = Color(0xFF7C6FF7);
  static const Color purpleDim = Color(0x1F7C6FF7);
  static const Color red       = Color(0xFFE05C5C);
  static const Color redDim    = Color(0x1FE05C5C);
  static const Color green     = Color(0xFF5CC98A);
  static const Color greenDim  = Color(0x1F5CC98A);
  static const Color blue      = Color(0xFF5CA8E0);
  static const Color blueDim   = Color(0x1F5CA8E0);
  static const Color amber     = Color(0xFFE0A85C);
  static const Color amberDim  = Color(0x1FE0A85C);

  // ── Dark ThemeData ──────────────────────────────────────────
  static ThemeData get dark => _buildTheme(
    brightness: Brightness.dark,
    colors: SanctumColors.dark,
    colorScheme: const ColorScheme.dark(
      primary: gold,
      secondary: gold2,
      surface: Color(0xFF111118),
      error: red,
    ),
  );

  // ── Light ThemeData ─────────────────────────────────────────
  static ThemeData get light => _buildTheme(
    brightness: Brightness.light,
    colors: SanctumColors.light,
    colorScheme: const ColorScheme.light(
      primary: gold,
      secondary: gold2,
      surface: Color(0xFFFFFFFF),
      error: red,
    ),
  );

  static ThemeData _buildTheme({
    required Brightness brightness,
    required SanctumColors colors,
    required ColorScheme colorScheme,
  }) {
    final baseText = brightness == Brightness.dark
        ? ThemeData.dark().textTheme
        : ThemeData.light().textTheme;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: colors.bg,
      colorScheme: colorScheme,
      extensions: [colors],
      textTheme: GoogleFonts.interTextTheme(baseText),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.bg2,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: colors.border,
        titleTextStyle: TextStyle(
          color: colors.textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: colors.textSecondary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.bg3,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0x66C9A84C)),
        ),
        hintStyle: TextStyle(color: colors.textTertiary, fontSize: 14),
        labelStyle: TextStyle(color: colors.textSecondary, fontSize: 12),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: gold,
          foregroundColor: const Color(0xFF1A1400),
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      cardTheme: CardThemeData(
        color: colors.bg2,
        elevation: brightness == Brightness.light ? 1 : 0,
        shadowColor: colors.border,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colors.border),
        ),
      ),
      dividerTheme: DividerThemeData(color: colors.border, thickness: 0.5),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: colors.bg2,
        selectedItemColor: gold2,
        unselectedItemColor: colors.textTertiary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
    );
  }
}

// ── Decoration helpers ────────────────────────────────────────
class SanctumDecor {
  static BoxDecoration card(BuildContext context, {Color? borderColor}) => BoxDecoration(
    color: context.sc.bg2,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: borderColor ?? context.sc.border, width: 0.5),
  );

  static BoxDecoration surface(BuildContext context, {double radius = 10}) => BoxDecoration(
    color: context.sc.bg3,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: context.sc.border, width: 0.5),
  );

  static LinearGradient goldGradient() => const LinearGradient(
    colors: [Color(0xFFE8C97A), Color(0xFFC9A84C)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
