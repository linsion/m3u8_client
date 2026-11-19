import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class AppThemePalette {
  final String id;
  final String name;
  final String subtitle;
  final Brightness brightness;
  final Color bgPrimary;
  final Color bgElevated;
  final Color bgCard;
  final Color bgHover;
  final Color bgInput;
  final Color borderSubtle;
  final Color borderStrong;
  final Color accent;
  final Color accentHover;
  final Color badgeHot;
  final Color success;
  final Color warning;
  final Color danger;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  const AppThemePalette({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.brightness,
    required this.bgPrimary,
    required this.bgElevated,
    required this.bgCard,
    required this.bgHover,
    required this.bgInput,
    required this.borderSubtle,
    required this.borderStrong,
    required this.accent,
    required this.accentHover,
    required this.badgeHot,
    required this.success,
    required this.warning,
    required this.danger,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
  });
}

/// Conventional video streaming platform design tokens (Bilibili / Infuse / Netflix / iQIYI style).
/// Supports multiple switchable dark & light themes with zero AI-generated visual clichés.
class VideoPlatformTheme {
  static const List<AppThemePalette> presets = [
    AppThemePalette(
      id: 'ocean_dark',
      name: '爆米花暗黑',
      subtitle: '网易爆米花同款影院黑金配色',
      brightness: Brightness.dark,
      bgPrimary: Color(0xFF0B0C10),
      bgElevated: Color(0xFF12141C),
      bgCard: Color(0xFF191C26),
      bgHover: Color(0xFF232736),
      bgInput: Color(0xFF1E222E),
      borderSubtle: Color(0xFF232734),
      borderStrong: Color(0xFF343A4D),
      accent: Color(0xFFFF9F0A),
      accentHover: Color(0xFFFFB340),
      badgeHot: Color(0xFFFF5C38),
      success: Color(0xFF30D158),
      warning: Color(0xFFFFB800),
      danger: Color(0xFFFF453A),
      textPrimary: Color(0xFFF5F6FA),
      textSecondary: Color(0xFFA2A7B8),
      textMuted: Color(0xFF696F82),
    ),
    AppThemePalette(
      id: 'amber_gold',
      name: '深空蓝',
      subtitle: '经典暗黑蓝青配色',
      brightness: Brightness.dark,
      bgPrimary: Color(0xFF0F1014),
      bgElevated: Color(0xFF17181E),
      bgCard: Color(0xFF1D1F27),
      bgHover: Color(0xFF252833),
      bgInput: Color(0xFF22242E),
      borderSubtle: Color(0xFF262934),
      borderStrong: Color(0xFF343846),
      accent: Color(0xFF00AEEC),
      accentHover: Color(0xFF26BEFF),
      badgeHot: Color(0xFFFF5C38),
      success: Color(0xFF2EBE70),
      warning: Color(0xFFF5A623),
      danger: Color(0xFFE54D42),
      textPrimary: Color(0xFFF1F2F5),
      textSecondary: Color(0xFF9EA3B0),
      textMuted: Color(0xFF686D7A),
    ),
    AppThemePalette(
      id: 'cinema_red',
      name: '剧院红',
      subtitle: '沉浸式纯黑影院风格',
      brightness: Brightness.dark,
      bgPrimary: Color(0xFF0B0B0D),
      bgElevated: Color(0xFF141418),
      bgCard: Color(0xFF1B1B21),
      bgHover: Color(0xFF24242C),
      bgInput: Color(0xFF202028),
      borderSubtle: Color(0xFF272730),
      borderStrong: Color(0xFF383845),
      accent: Color(0xFFE5222E),
      accentHover: Color(0xFFFF3B47),
      badgeHot: Color(0xFFFF7A29),
      success: Color(0xFF2EBE70),
      warning: Color(0xFFF5A623),
      danger: Color(0xFFE54D42),
      textPrimary: Color(0xFFF4F4F6),
      textSecondary: Color(0xFFA3A3AE),
      textMuted: Color(0xFF6E6E7A),
    ),
    AppThemePalette(
      id: 'jade_night',
      name: '翡翠绿',
      subtitle: '低疲劳夜间护眼暗色',
      brightness: Brightness.dark,
      bgPrimary: Color(0xFF0C110F),
      bgElevated: Color(0xFF131A17),
      bgCard: Color(0xFF1A231F),
      bgHover: Color(0xFF222E29),
      bgInput: Color(0xFF1E2924),
      borderSubtle: Color(0xFF24322C),
      borderStrong: Color(0xFF32463D),
      accent: Color(0xFF14B866),
      accentHover: Color(0xFF2CD17E),
      badgeHot: Color(0xFFFF6438),
      success: Color(0xFF2EBE70),
      warning: Color(0xFFF5A623),
      danger: Color(0xFFE54D42),
      textPrimary: Color(0xFFEEF4F1),
      textSecondary: Color(0xFF98AAA2),
      textMuted: Color(0xFF63756D),
    ),
    AppThemePalette(
      id: 'daylight_clean',
      name: '晴空白',
      subtitle: '清爽日间桌面浅色模式',
      brightness: Brightness.light,
      bgPrimary: Color(0xFFF3F5F8),
      bgElevated: Color(0xFFFFFFFF),
      bgCard: Color(0xFFFFFFFF),
      bgHover: Color(0xFFEAECEF),
      bgInput: Color(0xFFF0F2F5),
      borderSubtle: Color(0xFFE2E5EC),
      borderStrong: Color(0xFFCFD4DF),
      accent: Color(0xFF0098D4),
      accentHover: Color(0xFF00AEEC),
      badgeHot: Color(0xFFFF522B),
      success: Color(0xFF1FA85F),
      warning: Color(0xFFE08E0B),
      danger: Color(0xFFD9382E),
      textPrimary: Color(0xFF18191C),
      textSecondary: Color(0xFF59606D),
      textMuted: Color(0xFF8A919F),
    ),
  ];

  static AppThemePalette _currentPalette = presets.first;

  static AppThemePalette get currentPalette => _currentPalette;

  static AppThemePalette paletteById(String id) {
    for (final p in presets) {
      if (p.id == id) return p;
    }
    return presets.first;
  }

  static void setTheme(String id) {
    _currentPalette = paletteById(id);
  }

  static bool get isDark => _currentPalette.brightness == Brightness.dark;

  // Core surfaces
  static Color get bgPrimary => _currentPalette.bgPrimary;
  static Color get bgElevated => _currentPalette.bgElevated;
  static Color get bgCard => _currentPalette.bgCard;
  static Color get bgHover => _currentPalette.bgHover;
  static Color get bgInput => _currentPalette.bgInput;

  // Borders & dividers
  static Color get borderSubtle => _currentPalette.borderSubtle;
  static Color get borderStrong => _currentPalette.borderStrong;

  // Brand & status colors
  static Color get accent => _currentPalette.accent;
  static Color get accentHover => _currentPalette.accentHover;
  static Color get badgeHot => _currentPalette.badgeHot;
  static Color get success => _currentPalette.success;
  static Color get warning => _currentPalette.warning;
  static Color get danger => _currentPalette.danger;

  // Text hierarchy
  static Color get textPrimary => _currentPalette.textPrimary;
  static Color get textSecondary => _currentPalette.textSecondary;
  static Color get textMuted => _currentPalette.textMuted;

  static ThemeData buildDarkTheme() => buildTheme(_currentPalette.id);

  static ThemeData buildTheme([String? themeId]) {
    if (themeId != null) {
      _currentPalette = paletteById(themeId);
    }
    final p = _currentPalette;
    final isLight = p.brightness == Brightness.light;
    final colorScheme = isLight
        ? ColorScheme.light(
            primary: p.accent,
            secondary: p.accent,
            surface: p.bgElevated,
            error: p.danger,
            onPrimary: Colors.white,
            onSecondary: Colors.white,
            onSurface: p.textPrimary,
            onError: Colors.white,
          )
        : ColorScheme.dark(
            primary: p.accent,
            secondary: p.accent,
            surface: p.bgElevated,
            error: p.danger,
            onPrimary: Colors.white,
            onSecondary: Colors.white,
            onSurface: p.textPrimary,
            onError: Colors.white,
          );

    return ThemeData(
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      brightness: p.brightness,
      scaffoldBackgroundColor: p.bgPrimary,
      colorScheme: colorScheme,
      dividerColor: p.borderSubtle,
      focusColor: p.accent.withValues(alpha: 0.36),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: p.bgElevated,
        foregroundColor: p.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: p.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: p.bgCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: p.borderSubtle, width: 1),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.bgElevated,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: p.borderStrong, width: 1),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.bgInput,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        hintStyle: TextStyle(color: p.textMuted, fontSize: 13),
        labelStyle: TextStyle(color: p.textSecondary, fontSize: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: p.borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: p.borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(color: p.accent, width: 2.2),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: WidgetStateProperty.all(const Size(44, 34)),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return p.bgHover;
            }
            if (states.contains(WidgetState.focused) ||
                states.contains(WidgetState.hovered)) {
              return p.accentHover;
            }
            return p.accent;
          }),
          foregroundColor: WidgetStateProperty.all(Colors.white),
          elevation: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused) ? 8 : 0,
          ),
          shadowColor: WidgetStateProperty.all(p.accent.withValues(alpha: 0.85)),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(color: Colors.white, width: 2.2);
            }
            return BorderSide.none;
          }),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          textStyle: WidgetStateProperty.all(
            const TextStyle(
              fontSize: 12.5,
              height: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: WidgetStateProperty.all(const Size(44, 34)),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return p.accent.withValues(alpha: 0.34);
            }
            if (states.contains(WidgetState.hovered)) {
              return p.bgHover;
            }
            return Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return Colors.white;
            }
            return p.textPrimary;
          }),
          elevation: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused) ? 6 : 0,
          ),
          shadowColor: WidgetStateProperty.all(p.accent.withValues(alpha: 0.7)),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(color: Colors.white, width: 2.2);
            }
            return BorderSide(color: p.borderStrong);
          }),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          textStyle: WidgetStateProperty.all(
            const TextStyle(
              fontSize: 12.5,
              height: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: WidgetStateProperty.all(const Size(40, 32)),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return p.accent.withValues(alpha: 0.34);
            }
            if (states.contains(WidgetState.hovered)) {
              return p.bgHover;
            }
            return Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return Colors.white;
            }
            return p.textSecondary;
          }),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(color: Colors.white, width: 2.0);
            }
            return BorderSide.none;
          }),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          ),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          textStyle: WidgetStateProperty.all(
            const TextStyle(
              fontSize: 12.5,
              height: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        labelStyle: TextStyle(
          fontSize: 12,
          height: 1.2,
          color: p.textPrimary,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return p.accent.withValues(alpha: 0.38);
            }
            if (states.contains(WidgetState.hovered)) {
              return p.bgHover;
            }
            return Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return Colors.white;
            }
            return p.textPrimary;
          }),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.focused)) {
              return const BorderSide(color: Colors.white, width: 2.4);
            }
            return BorderSide.none;
          }),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.bgCard,
        contentTextStyle: TextStyle(color: p.textPrimary, fontSize: 13),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: p.borderStrong),
        ),
      ),
    );
  }
}
