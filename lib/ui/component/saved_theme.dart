import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:proxypin/ui/component/theme_presets.dart';

class UnsupportedThemeVersion extends FormatException {
  const UnsupportedThemeVersion(int version) : super('Unsupported theme version', version);
}

class SavedTheme extends ThemePreset {
  static const _format = 'proxypin-theme';
  static const _version = 1;
  static const maxFileBytes = 16 * 1024;
  static const maxNameLength = 80;
  static final _invalidNameCodePoint = RegExp(
    r'[\x00-\x1F\x7F-\x9F\u2028-\u202E\u2066-\u2069\uD800-\uDFFF]',
    unicode: true,
  );
  static final _hex = RegExp(r'^#[0-9a-fA-F]{6}$');
  static final _jsonTokens = RegExp(r'"(?:[^"\\]|\\.)*"|[{}:]', dotAll: true);

  @override
  final String name;
  final ColorScheme light;
  final ColorScheme dark;
  final Color lightString;
  final Color darkString;

  SavedTheme({
    required this.name,
    required this.light,
    required this.dark,
    required this.lightString,
    required this.darkString,
  }) {
    if (!isValidName(name)) throw const FormatException('Invalid theme name');
  }

  static bool isValidName(String name) =>
      name.isNotEmpty &&
      name == name.trim() &&
      name.runes.length <= maxNameLength &&
      !_invalidNameCodePoint.hasMatch(name);

  @override
  String label(Brightness brightness) => name;

  @override
  ColorScheme colorScheme(Brightness brightness) => brightness == Brightness.dark ? dark : light;

  @override
  Color stringColor(Brightness brightness) => brightness == Brightness.dark ? darkString : lightString;

  late final Map<String, Object> _json = Map.unmodifiable({
    'format': _format,
    'version': _version,
    'name': name,
    'light': Map.unmodifiable(_encodePalette(light, lightString)),
    'dark': Map.unmodifiable(_encodePalette(dark, darkString)),
  });

  Map<String, Object> toJson() => _json;

  late final String encoded = const JsonEncoder.withIndent('  ').convert(_json);

  static SavedTheme decode(String source) {
    if (utf8.encode(source).length > maxFileBytes) throw const FormatException('Theme file is too large');
    final json = jsonDecode(source);
    final keys = <Set<String>>[];
    String? previous;
    for (final match in _jsonTokens.allMatches(source)) {
      final token = match[0]!;
      switch (token) {
        case '{':
          keys.add({});
        case '}':
          keys.removeLast();
        case ':' when !keys.last.add(jsonDecode(previous!) as String):
          throw const FormatException('Duplicate theme field');
      }
      previous = token;
    }
    return SavedTheme.fromJson(json);
  }

  factory SavedTheme.fromJson(Object? json) {
    if (json is! Map || json['format'] != _format) {
      throw const FormatException('Invalid theme format');
    }
    final version = json['version'];
    if (version is! int) throw const FormatException('Invalid theme version');
    if (version != _version) throw UnsupportedThemeVersion(version);
    final name = json['name'];
    if (json.length != 5 || name is! String) throw const FormatException('Invalid theme fields');
    final (light, lightString) = _decodePalette(json['light'], Brightness.light);
    final (dark, darkString) = _decodePalette(json['dark'], Brightness.dark);
    return SavedTheme(name: name, light: light, dark: dark, lightString: lightString, darkString: darkString);
  }

  static Map<String, String> _encodePalette(ColorScheme scheme, Color string) => {
        'primary': hex(scheme.primary),
        'onPrimary': hex(scheme.onPrimary),
        'primaryContainer': hex(scheme.primaryContainer),
        'onPrimaryContainer': hex(scheme.onPrimaryContainer),
        'primaryFixed': hex(scheme.primaryFixed),
        'primaryFixedDim': hex(scheme.primaryFixedDim),
        'onPrimaryFixed': hex(scheme.onPrimaryFixed),
        'onPrimaryFixedVariant': hex(scheme.onPrimaryFixedVariant),
        'secondary': hex(scheme.secondary),
        'onSecondary': hex(scheme.onSecondary),
        'secondaryContainer': hex(scheme.secondaryContainer),
        'onSecondaryContainer': hex(scheme.onSecondaryContainer),
        'secondaryFixed': hex(scheme.secondaryFixed),
        'secondaryFixedDim': hex(scheme.secondaryFixedDim),
        'onSecondaryFixed': hex(scheme.onSecondaryFixed),
        'onSecondaryFixedVariant': hex(scheme.onSecondaryFixedVariant),
        'tertiary': hex(scheme.tertiary),
        'onTertiary': hex(scheme.onTertiary),
        'tertiaryContainer': hex(scheme.tertiaryContainer),
        'onTertiaryContainer': hex(scheme.onTertiaryContainer),
        'tertiaryFixed': hex(scheme.tertiaryFixed),
        'tertiaryFixedDim': hex(scheme.tertiaryFixedDim),
        'onTertiaryFixed': hex(scheme.onTertiaryFixed),
        'onTertiaryFixedVariant': hex(scheme.onTertiaryFixedVariant),
        'error': hex(scheme.error),
        'onError': hex(scheme.onError),
        'errorContainer': hex(scheme.errorContainer),
        'onErrorContainer': hex(scheme.onErrorContainer),
        'surface': hex(scheme.surface),
        'onSurface': hex(scheme.onSurface),
        'surfaceDim': hex(scheme.surfaceDim),
        'surfaceBright': hex(scheme.surfaceBright),
        'surfaceContainerLowest': hex(scheme.surfaceContainerLowest),
        'surfaceContainerLow': hex(scheme.surfaceContainerLow),
        'surfaceContainer': hex(scheme.surfaceContainer),
        'surfaceContainerHigh': hex(scheme.surfaceContainerHigh),
        'surfaceContainerHighest': hex(scheme.surfaceContainerHighest),
        'onSurfaceVariant': hex(scheme.onSurfaceVariant),
        'outline': hex(scheme.outline),
        'outlineVariant': hex(scheme.outlineVariant),
        'shadow': hex(scheme.shadow),
        'scrim': hex(scheme.scrim),
        'inverseSurface': hex(scheme.inverseSurface),
        'onInverseSurface': hex(scheme.onInverseSurface),
        'inversePrimary': hex(scheme.inversePrimary),
        'surfaceTint': scheme.surfaceTint.a == 0 ? '#00000000' : hex(scheme.surfaceTint),
        'string': hex(string),
      };

  static String hex(Color color) => '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  static (ColorScheme, Color) _decodePalette(Object? json, Brightness brightness) {
    if (json is! Map) throw const FormatException('Invalid palette');
    final fields = Map.of(json);
    Color read(String name) {
      final value = fields.remove(name);
      if (name == 'surfaceTint' && value == '#00000000') return Colors.transparent;
      if (value is! String || value.length != 7 || !_hex.hasMatch(value)) {
        throw const FormatException('Invalid palette color');
      }
      return Color(0xFF000000 | int.parse(value.substring(1), radix: 16));
    }

    final scheme = ColorScheme(
      brightness: brightness,
      primary: read('primary'),
      onPrimary: read('onPrimary'),
      primaryContainer: read('primaryContainer'),
      onPrimaryContainer: read('onPrimaryContainer'),
      primaryFixed: read('primaryFixed'),
      primaryFixedDim: read('primaryFixedDim'),
      onPrimaryFixed: read('onPrimaryFixed'),
      onPrimaryFixedVariant: read('onPrimaryFixedVariant'),
      secondary: read('secondary'),
      onSecondary: read('onSecondary'),
      secondaryContainer: read('secondaryContainer'),
      onSecondaryContainer: read('onSecondaryContainer'),
      secondaryFixed: read('secondaryFixed'),
      secondaryFixedDim: read('secondaryFixedDim'),
      onSecondaryFixed: read('onSecondaryFixed'),
      onSecondaryFixedVariant: read('onSecondaryFixedVariant'),
      tertiary: read('tertiary'),
      onTertiary: read('onTertiary'),
      tertiaryContainer: read('tertiaryContainer'),
      onTertiaryContainer: read('onTertiaryContainer'),
      tertiaryFixed: read('tertiaryFixed'),
      tertiaryFixedDim: read('tertiaryFixedDim'),
      onTertiaryFixed: read('onTertiaryFixed'),
      onTertiaryFixedVariant: read('onTertiaryFixedVariant'),
      error: read('error'),
      onError: read('onError'),
      errorContainer: read('errorContainer'),
      onErrorContainer: read('onErrorContainer'),
      surface: read('surface'),
      onSurface: read('onSurface'),
      surfaceDim: read('surfaceDim'),
      surfaceBright: read('surfaceBright'),
      surfaceContainerLowest: read('surfaceContainerLowest'),
      surfaceContainerLow: read('surfaceContainerLow'),
      surfaceContainer: read('surfaceContainer'),
      surfaceContainerHigh: read('surfaceContainerHigh'),
      surfaceContainerHighest: read('surfaceContainerHighest'),
      onSurfaceVariant: read('onSurfaceVariant'),
      outline: read('outline'),
      outlineVariant: read('outlineVariant'),
      shadow: read('shadow'),
      scrim: read('scrim'),
      inverseSurface: read('inverseSurface'),
      onInverseSurface: read('onInverseSurface'),
      inversePrimary: read('inversePrimary'),
      surfaceTint: read('surfaceTint'),
    );
    final string = read('string');
    if (fields.isNotEmpty) throw const FormatException('Unexpected palette field');
    return (scheme, string);
  }
}
