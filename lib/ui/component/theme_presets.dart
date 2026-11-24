import 'package:flutter/material.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

enum ThemePreset {
  custom,
  atomOne,
  catppuccin,
  rosePine;

  String label(Brightness brightness) => switch ((this, brightness)) {
        (atomOne, Brightness.dark) => 'Atom One Dark',
        (atomOne, _) => 'Atom One Light',
        (catppuccin, Brightness.dark) => 'Catppuccin Mocha',
        (catppuccin, _) => 'Catppuccin Latte',
        (rosePine, Brightness.dark) => 'Rosé Pine',
        (rosePine, _) => 'Rosé Pine Dawn',
        (custom, _) => '',
      };

  ColorScheme? colorScheme(Brightness brightness) => _palette(brightness)?.colorScheme(brightness);

  List<Color> swatches(Brightness brightness) {
    final palette = _palette(brightness);
    return palette == null
        ? const []
        : [
            Color(palette.surface),
            Color(palette.primary),
            Color(palette.secondary),
            Color(palette.tertiary),
          ];
  }

  Map<String, TextStyle> syntax(Brightness brightness) {
    final base = brightness == Brightness.dark ? atomOneDarkTheme : atomOneLightTheme;
    final palette = _palette(brightness);
    if (palette == null) return base;

    return {
      ...base,
      'root': base['root']!.copyWith(color: Color(palette.text), backgroundColor: Color(palette.surface)),
      for (final token in ['comment', 'quote']) token: base[token]!.copyWith(color: Color(palette.muted)),
      for (final token in ['keyword', 'selector-tag', 'literal', 'type'])
        token: TextStyle(color: Color(palette.primary)),
      for (final token in ['attr', 'attribute', 'property', 'title', 'name', 'built_in'])
        token: TextStyle(color: Color(palette.secondary)),
      for (final token in ['number', 'symbol', 'variable', 'params']) token: TextStyle(color: Color(palette.tertiary)),
      for (final token in ['string', 'regexp', 'addition']) token: TextStyle(color: Color(palette.string)),
      'deletion': TextStyle(color: Color(palette.error)),
    };
  }

  _PresetPalette? _palette(Brightness brightness) => switch ((this, brightness)) {
        (atomOne, Brightness.dark) => _atomOneDark,
        (atomOne, _) => _atomOneLight,
        (catppuccin, Brightness.dark) => _catppuccinMocha,
        (catppuccin, _) => _catppuccinLatte,
        (rosePine, Brightness.dark) => _rosePine,
        (rosePine, _) => _rosePineDawn,
        (custom, _) => null,
      };
}

class ActiveThemePreset extends ThemeExtension<ActiveThemePreset> {
  final ThemePreset preset;

  const ActiveThemePreset(this.preset);

  static ThemePreset of(BuildContext context) =>
      Theme.of(context).extension<ActiveThemePreset>()?.preset ?? ThemePreset.custom;

  @override
  ActiveThemePreset copyWith({ThemePreset? preset}) => ActiveThemePreset(preset ?? this.preset);

  @override
  ActiveThemePreset lerp(ActiveThemePreset? other, double t) => t < .5 ? this : other ?? this;
}

Map<String, TextStyle> codeEditorTheme(BuildContext context) {
  final theme = Theme.of(context);
  final preset = ActiveThemePreset.of(context);
  final syntax = preset.syntax(theme.brightness);
  if (preset == ThemePreset.custom && theme.brightness == Brightness.light) return syntax;

  return {
    ...syntax,
    'root': syntax['root']!.copyWith(backgroundColor: theme.colorScheme.surface),
  };
}

class _PresetPalette {
  final int surface;
  final int chrome;
  final int raised;
  final int border;
  final int text;
  final int muted;
  final int primary;
  final int secondary;
  final int tertiary;
  final int string;
  final int error;

  const _PresetPalette({
    required this.surface,
    required this.chrome,
    required this.raised,
    required this.border,
    required this.text,
    required this.muted,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.string,
    required this.error,
  });

  ColorScheme colorScheme(Brightness brightness) {
    final base = Color(surface);
    final foreground = Color(text);
    final primaryColor = Color(primary);
    final secondaryColor = Color(secondary);
    final tertiaryColor = Color(tertiary);
    final errorColor = Color(error);
    final dark = brightness == Brightness.dark;
    Color tint(Color color) => Color.alphaBlend(color.withValues(alpha: dark ? .16 : .09), base);
    Color onAccent(Color color) => color.computeLuminance() > .179 ? Colors.black : Colors.white;

    return ColorScheme.fromSeed(seedColor: primaryColor, brightness: brightness).copyWith(
      primary: primaryColor,
      onPrimary: onAccent(primaryColor),
      primaryContainer: tint(primaryColor),
      onPrimaryContainer: foreground,
      secondary: secondaryColor,
      onSecondary: onAccent(secondaryColor),
      secondaryContainer: tint(secondaryColor),
      onSecondaryContainer: foreground,
      tertiary: tertiaryColor,
      onTertiary: onAccent(tertiaryColor),
      tertiaryContainer: tint(tertiaryColor),
      onTertiaryContainer: foreground,
      error: errorColor,
      onError: onAccent(errorColor),
      errorContainer: tint(errorColor),
      onErrorContainer: foreground,
      surface: base,
      surfaceTint: Colors.transparent,
      surfaceDim: Color(chrome),
      surfaceBright: dark ? Color(raised) : base,
      surfaceContainerLowest: dark ? Color(chrome) : base,
      surfaceContainerLow: Color(chrome),
      surfaceContainer: Color(raised),
      surfaceContainerHigh: Color.lerp(Color(raised), Color(border), .35),
      surfaceContainerHighest: Color(border),
      onSurface: foreground,
      onSurfaceVariant: Color(muted),
      outline: Color(muted),
      outlineVariant: Color(border),
    );
  }
}

const _atomOneDark = _PresetPalette(
  surface: 0xFF282C34,
  chrome: 0xFF21252B,
  raised: 0xFF2A2F38,
  border: 0xFF3B414D,
  text: 0xFFABB2BF,
  muted: 0xFF98A1B1,
  primary: 0xFFC678DD,
  secondary: 0xFF61AFEF,
  tertiary: 0xFFE5C07B,
  string: 0xFF98C379,
  error: 0xFFE87982,
);

const _atomOneLight = _PresetPalette(
  surface: 0xFFFAFAFA,
  chrome: 0xFFF0F0F1,
  raised: 0xFFF5F5F6,
  border: 0xFFDFE1E5,
  text: 0xFF383A42,
  muted: 0xFF62656F,
  primary: 0xFFA626A4,
  secondary: 0xFF2754B5,
  tertiary: 0xFF8A5D00,
  string: 0xFF397531,
  error: 0xFFCA1243,
);

const _catppuccinMocha = _PresetPalette(
  surface: 0xFF1E1E2E,
  chrome: 0xFF181825,
  raised: 0xFF252536,
  border: 0xFF45475A,
  text: 0xFFCDD6F4,
  muted: 0xFFA6ADC8,
  primary: 0xFFB4BEFE,
  secondary: 0xFF94E2D5,
  tertiary: 0xFFFAB387,
  string: 0xFFA6E3A1,
  error: 0xFFF38BA8,
);

const _catppuccinLatte = _PresetPalette(
  surface: 0xFFEFF1F5,
  chrome: 0xFFE6E9EF,
  raised: 0xFFE9EBF1,
  border: 0xFFCCD0DA,
  text: 0xFF4C4F69,
  muted: 0xFF5C5F77,
  primary: 0xFF7629D0,
  secondary: 0xFF167178,
  tertiary: 0xFF9D5315,
  string: 0xFF347225,
  error: 0xFFC20E34,
);

const _rosePine = _PresetPalette(
  surface: 0xFF191724,
  chrome: 0xFF14121E,
  raised: 0xFF1F1D2E,
  border: 0xFF403D52,
  text: 0xFFE0DEF4,
  muted: 0xFFA09BB8,
  primary: 0xFFC4A7E7,
  secondary: 0xFF9CCFD8,
  tertiary: 0xFFEBBCBA,
  string: 0xFFF6C177,
  error: 0xFFEB6F92,
);

const _rosePineDawn = _PresetPalette(
  surface: 0xFFFAF4ED,
  chrome: 0xFFF2E9E1,
  raised: 0xFFF6EFE8,
  border: 0xFFDFDAD9,
  text: 0xFF575279,
  muted: 0xFF68627E,
  primary: 0xFF82558F,
  secondary: 0xFF286983,
  tertiary: 0xFF96534B,
  string: 0xFF816022,
  error: 0xFF944A64,
);
