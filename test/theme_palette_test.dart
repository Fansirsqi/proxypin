import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/component/theme_presets.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/desktop/theme_palette.dart';

class _TestConfiguration implements AppConfiguration {
  final colors = <ThemeColorRole, String?>{};

  @override
  final globalChange = ValueNotifier(false);

  @override
  PaletteStyle paletteStyle = PaletteStyle.classic;

  ThemePreset _preset = ThemePreset.custom;

  @override
  ThemePreset get themePreset => _preset;

  @override
  set themePreset(ThemePreset value) {
    _preset = value;
    globalChange.value = !globalChange.value;
  }

  @override
  String? paletteColor(ThemeColorRole role) => colors[role];

  @override
  void setPaletteColor(ThemeColorRole role, String? value) {
    colors[role] = value;
    globalChange.value = !globalChange.value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('loads legacy theme settings and ignores invalid palette values', () {
    final theme = ThemeModel.fromJson({
      'themeColor': 'Teal',
      'mode': 'dark',
      'useMaterial3': false,
      'themeSecondary': 'invalid',
      'themeTertiary': 42,
      'paletteStyle': 'unknown',
    });
    expect(theme.themeColor, Colors.teal);
    expect(theme.mode, ThemeMode.dark);
    expect(theme.useMaterial3, isFalse);
    expect(theme.secondary, isNull);
    expect(theme.tertiary, isNull);
    expect(theme.style, PaletteStyle.classic);
    expect(theme.preset, ThemePreset.custom);
    expect(ThemeModel.fromJson({}).colorScheme(Brightness.light).surface, Colors.white);
  });

  for (final brightness in Brightness.values) {
    test('palette styles generate distinct $brightness color schemes', () {
      final schemes = [
        for (final style in PaletteStyle.values) ThemeModel(style: style).colorScheme(brightness),
      ];
      expect(schemes.toSet(), hasLength(PaletteStyle.values.length));
      expect(schemes.every((scheme) => scheme.brightness == brightness), isTrue);
    });

    test('custom $brightness roles are independent and survive serialization', () {
      final original = ThemeModel(style: PaletteStyle.vivid).colorScheme(brightness);
      final theme = ThemeModel.fromJson(ThemeModel(
        style: PaletteStyle.vivid,
        secondary: '#006A58',
        tertiary: '#AD225A',
        surface: '#392817',
      ).toJson());
      final scheme = theme.colorScheme(brightness);
      expect(scheme.primary, original.primary);
      expect(scheme.secondary, isNot(original.secondary));
      expect(scheme.tertiary, isNot(original.tertiary));
      expect(scheme.surface, isNot(original.surface));
      for (final (text, background) in [
        (scheme.onSecondary, scheme.secondary),
        (scheme.onTertiaryContainer, scheme.tertiaryContainer),
        (scheme.onSurface, scheme.surface),
      ]) {
        final luminances = [text.computeLuminance(), background.computeLuminance()]..sort();
        expect((luminances.last + .05) / (luminances.first + .05), greaterThanOrEqualTo(4.5));
      }
    });
  }

  test('preset round trips and leaves custom colors available', () {
    final custom = ThemeModel(primary: '#642877', secondary: '#146B57', surface: '#262233');
    final restored = ThemeModel.fromJson((custom..preset = ThemePreset.atomOne).toJson());
    expect(restored.preset, ThemePreset.atomOne);
    expect(restored.usesClassicSurfaces, isFalse);
    expect(restored.colorScheme(Brightness.dark).surface, const Color(0xFF282C34));
    expect(restored.colorScheme(Brightness.light).surface, const Color(0xFFFAFAFA));
    restored.preset = ThemePreset.custom;
    expect(restored.primary, '#642877');
    expect(restored.secondary, '#146B57');
    expect(restored.surface, '#262233');
  });

  test('presets provide readable accents, text and code in both modes', () {
    for (final preset in ThemePreset.values.skip(1)) {
      for (final brightness in Brightness.values) {
        final scheme = preset.colorScheme(brightness)!;
        final syntax = preset.syntax(brightness);
        for (final (foreground, background) in [
          (scheme.onSurface, scheme.surface),
          (scheme.onSurfaceVariant, scheme.surfaceContainer),
          (scheme.primary, scheme.surfaceContainer),
          (scheme.onPrimary, scheme.primary),
          (scheme.onSecondary, scheme.secondary),
          (scheme.onTertiary, scheme.tertiary),
          (scheme.onError, scheme.error),
          for (final token in ['root', 'attr', 'string', 'number', 'literal', 'comment'])
            (syntax[token]!.color!, scheme.surface),
        ]) {
          final luminances = [foreground.computeLuminance(), background.computeLuminance()]..sort();
          expect(
            (luminances.last + .05) / (luminances.first + .05),
            greaterThanOrEqualTo(4.5),
            reason: '${preset.label(brightness)} $foreground on $background',
          );
        }
      }
    }
  });

  test('AMOLED overrides surfaces in dark mode and preserves the custom seed', () {
    final theme = ThemeModel(surface: '#392817', useAmoled: true);
    final light = theme.colorScheme(Brightness.light);
    final dark = theme.colorScheme(Brightness.dark);
    expect(dark.surface, Colors.black);
    expect(dark.surfaceContainerHighest, Colors.black);
    expect(theme.toJson()['themeSurface'], '#392817');
    theme.useAmoled = false;
    expect(theme.colorScheme(Brightness.light), light);
    expect(theme.colorScheme(Brightness.dark).surface, isNot(Colors.black));
  });

  testWidgets('narrow settings support a custom HEX color and restoring automatic color', (tester) async {
    final config = _TestConfiguration();
    addTearDown(config.globalChange.dispose);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 245,
            child: ValueListenableBuilder(
              valueListenable: config.globalChange,
              builder: (_, __, ___) => ThemePaletteSettings(configuration: config),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Secondary'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(TextButton, 'Save');
    await tester.enterText(find.byType(TextField), '#123');
    await tester.pump();
    expect(tester.widget<TextButton>(save).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '#146B57');
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(config.paletteColor(ThemeColorRole.secondary), '#146B57');
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atom One Light').last);
    await tester.pumpAndSettle();
    expect(config.themePreset, ThemePreset.atomOne);
    expect(find.text('Secondary'), findsNothing);
    await tester.tap(find.text('Atom One Light'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom').last);
    await tester.pumpAndSettle();
    expect(config.paletteColor(ThemeColorRole.secondary), '#146B57');
    await tester.tap(find.text('Secondary'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Automatic'));
    await tester.pumpAndSettle();
    expect(config.paletteColor(ThemeColorRole.secondary), isNull);
    expect(tester.takeException(), isNull);
  });
}
