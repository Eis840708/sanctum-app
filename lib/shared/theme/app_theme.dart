import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class SanctumTheme {
  static const Color bg        = Color(0xFF0A0A0F);
  static const Color bg2       = Color(0xFF111118);
  static const Color bg3       = Color(0xFF1A1A24);
  static const Color bg4       = Color(0xFF22222F);
  static const Color border    = Color(0x12FFFFFF);
  static const Color border2   = Color(0x22FFFFFF);
  static const Color gold      = Color(0xFFC9A84C);
  static const Color gold2     = Color(0xFFE8C97A);
  static const Color goldDim   = Color(0x26C9A84C);
  static const Color textPrimary   = Color(0xFFE8E6E0);
  static const Color textSecondary = Color(0xFF9896A0);
  static const Color textTertiary  = Color(0xFF5A5868);
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

  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: bg,
    colorScheme: const ColorScheme.dark(
      primary: gold,
      secondary: gold2,
      surface: bg2,
      error: red,
    ),
    textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
    appBarTheme: const AppBarTheme(
      backgroundColor: bg2,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(color: textPrimary, fontSize: 17, fontWeight: FontWeight.w600),
      iconTheme: IconThemeData(color: textSecondary),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: bg3,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0x66C9A84C)),
      ),
      hintStyle: const TextStyle(color: textTertiary, fontSize: 14),
      labelStyle: const TextStyle(color: textSecondary, fontSize: 12),
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
      color: bg2,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: border),
      ),
    ),
    dividerTheme: const DividerThemeData(color: border, thickness: 0.5),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: bg2,
      selectedItemColor: gold2,
      unselectedItemColor: textTertiary,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
  );
}

class SanctumDecor {
  static BoxDecoration card({Color? borderColor}) => BoxDecoration(
    color: SanctumTheme.bg2,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: borderColor ?? SanctumTheme.border, width: 0.5),
  );

  static BoxDecoration surface({double radius = 10}) => BoxDecoration(
    color: SanctumTheme.bg3,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: SanctumTheme.border, width: 0.5),
  );

  static LinearGradient goldGradient() => const LinearGradient(
    colors: [Color(0xFFE8C97A), Color(0xFFC9A84C)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
