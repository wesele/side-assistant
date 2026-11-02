import 'package:flutter/material.dart';

/// ChatGPT 手机端风格的全局主题：淡青/深青色调、大圆角、药丸按钮、无阴影。
class AppTheme {
  AppTheme._();

  static const Color accent = Color(0xFF00897B);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final isDark = b == Brightness.dark;
    final bg = isDark ? const Color(0xFF0F2F2B) : Colors.white;
    final fg = isDark ? const Color(0xFFECF5F3) : const Color(0xFF004D40);
    final fgSub = isDark ? const Color(0xFF9CC4BD) : const Color(0xFF3F7F76);
    final fill = isDark ? const Color(0xFF17463F) : const Color(0xFFE0F2F1);
    final fillHigh = isDark ? const Color(0xFF22605A) : const Color(0xFFB2DFDB);
    final divider = isDark ? const Color(0xFF1F5750) : const Color(0xFFCFE6E2);
    final primary = isDark ? Colors.white : const Color(0xFF004D40);
    final onPrimary = isDark ? const Color(0xFF004D40) : Colors.white;
    const danger = Color(0xFFE5484D);

    final scheme = ColorScheme(
      brightness: b,
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: fillHigh,
      onPrimaryContainer: fg,
      secondary: fgSub,
      onSecondary: bg,
      secondaryContainer: fill,
      onSecondaryContainer: fg,
      tertiary: accent,
      onTertiary: Colors.white,
      error: danger,
      onError: Colors.white,
      surface: bg,
      onSurface: fg,
      onSurfaceVariant: fgSub,
      surfaceContainerLowest: bg,
      surfaceContainerLow: fill,
      surfaceContainer: fill,
      surfaceContainerHigh: fillHigh,
      surfaceContainerHighest: fill,
      outline: fgSub,
      outlineVariant: divider,
      shadow: Colors.black,
      scrim: Colors.black54,
      surfaceTint: Colors.transparent,
    );

    const pill = StadiumBorder();

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      dividerColor: divider,
      splashFactory: InkRipple.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: fg,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: fg,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardTheme(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: fill,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerTheme: DividerThemeData(color: divider, space: 1, thickness: 0.5),
      listTileTheme: ListTileThemeData(
        iconColor: fg,
        textColor: fg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      expansionTileTheme: ExpansionTileThemeData(
        shape: const Border(),
        collapsedShape: const Border(),
        iconColor: fgSub,
        collapsedIconColor: fgSub,
        textColor: fg,
        collapsedTextColor: fg,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: isDark ? const Color(0xFF143B36) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        titleTextStyle:
            TextStyle(color: fg, fontSize: 18, fontWeight: FontWeight.w600),
        contentTextStyle: TextStyle(color: fgSub, fontSize: 15, height: 1.4),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? const Color(0xFF143B36) : Colors.white,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: isDark ? const Color(0xFF143B36) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor:
            isDark ? const Color(0xFFECF5F3) : const Color(0xFF004D40),
        contentTextStyle:
            TextStyle(color: isDark ? const Color(0xFF004D40) : Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          shape: pill,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          elevation: 0,
          shape: pill,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: fg,
          side: BorderSide(color: divider),
          shape: pill,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: fg,
          shape: pill,
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: fg),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? accent
                : (isDark ? const Color(0xFF3A7A72) : const Color(0xFF9CCCC5))),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: primary,
        inactiveTrackColor: fillHigh,
        thumbColor: primary,
        overlayColor: primary.withOpacity(0.08),
        trackHeight: 4,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: fg),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF123833) : Colors.white,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: TextStyle(color: fgSub),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: divider, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: divider, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStateProperty.all(
              isDark ? const Color(0xFF143B36) : Colors.white),
          surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
          shape: WidgetStateProperty.all(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: fill,
        side: BorderSide.none,
        shape: pill,
      ),
    );
  }
}
