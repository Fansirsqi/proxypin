import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/component/saved_theme.dart';
import 'package:proxypin/ui/component/theme_presets.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/desktop/theme_palette.dart';

class _TestConfiguration extends AppConfiguration {
  _TestConfiguration() : super.withConfigFile(File('unused'));

  Future<void> Function(Map<String, dynamic>)? onWrite;

  @override
  Future<void> writeConfig(Map<String, dynamic> config) async {
    await onWrite?.call(config);
  }
}

final class _ThemeFile extends PlatformFile {
  final Uint8List bytes;

  _ThemeFile(this.bytes);

  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThemeFilePicker extends FilePickerPlatform {
  PlatformFile? selection;
  Uint8List? exported;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    expect(type, FileType.custom);
    expect(allowedExtensions, ['json']);
    return selection;
  }

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    expect(fileName, 'proxypin-theme.json');
    expect(mimeType, 'application/json');
    exported = bytes;
    return Uri.file(fileName);
  }
}

double _contrast(Color foreground, Color background) {
  final luminances = [foreground.computeLuminance(), background.computeLuminance()]..sort();
  return (luminances.last + .05) / (luminances.first + .05);
}

Future<void> _openSettings(WidgetTester tester, AppConfiguration config) async {
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('brand palettes keep accents and syntax readable on actual surfaces in both modes', () {
    const brands = [ThemePreset.claudeCode, ThemePreset.apple, ThemePreset.gmail, ThemePreset.figma];
    for (final brightness in Brightness.values) {
      final primaryColors = <Color>{};
      for (final preset in brands) {
        final scheme = preset.colorScheme(brightness)!;
        final syntax = preset.syntax(brightness);
        primaryColors.add(scheme.primary);
        expect(syntax['keyword']!.color, scheme.primary);
        expect(syntax['attr']!.color, scheme.secondary);
        expect(syntax['number']!.color, scheme.tertiary);
        expect(syntax['string']!.color, preset.stringColor(brightness));
        final surfaces = [
          scheme.surface,
          scheme.surfaceContainerLow,
          scheme.surfaceContainer,
          scheme.surfaceContainerHigh,
          scheme.surfaceContainerHighest,
        ];
        for (final (text, background) in [
          for (final surface in surfaces)
            for (final color in [
              scheme.onSurface,
              scheme.onSurfaceVariant,
              scheme.primary,
              scheme.secondary,
              scheme.tertiary,
              scheme.error,
              preset.stringColor(brightness),
            ])
              (color, surface),
          (scheme.onPrimaryContainer, scheme.primaryContainer),
          (scheme.onSecondaryContainer, scheme.secondaryContainer),
          (scheme.onTertiaryContainer, scheme.tertiaryContainer),
          (scheme.onErrorContainer, scheme.errorContainer),
          (scheme.onInverseSurface, scheme.inverseSurface),
          (scheme.onPrimaryFixed, scheme.primaryFixedDim),
          (scheme.onPrimaryFixedVariant, scheme.primaryFixedDim),
        ]) {
          expect(_contrast(text, background), greaterThanOrEqualTo(4.5),
              reason: '${preset.label(brightness)} $text on $background');
        }
      }
      expect(primaryColors, hasLength(brands.length));
    }
  });

  test('theme JSON preserves both palettes and rejects malformed, duplicate, or unsupported fields', () {
    final config = _TestConfiguration()..themePreset = ThemePreset.figma;
    final saved = config.snapshotTheme('工作🎨');
    final roundTrip = SavedTheme.decode(saved.encoded);
    expect(roundTrip.name, saved.name);
    expect(roundTrip.encoded, saved.encoded);
    final payload = jsonDecode(saved.encoded) as Map<String, dynamic>;
    expect(payload.keys, unorderedEquals(['format', 'version', 'name', 'light', 'dark']));
    final light = payload['light'] as Map;
    for (final invalid in [
      '{',
      '[]',
      saved.encoded.replaceFirst('"name":', '"na\\u006De":"extra", "name":'),
      saved.encoded.replaceFirst('"primary":', '"primary":"#101010","primary":'),
      jsonEncode({...payload, 'themeMode': 'dark'}),
      jsonEncode({...payload, 'name': ' '}),
      jsonEncode({...payload, 'name': 'bad\nname'}),
      jsonEncode({...payload, 'name': 'A' * (SavedTheme.maxNameLength + 1)}),
      jsonEncode({...payload, 'dark': []}),
      jsonEncode({
        ...payload,
        'light': {...light, 'primary': '#AABBCCDD'}
      }),
      jsonEncode({
        ...payload,
        'light': {...light, 'primary': '#AABBCC\n'}
      }),
      jsonEncode({...payload, 'light': Map.of(light)..remove('onPrimary')}),
      jsonEncode({
        ...payload,
        'light': {...light, 'unexpected': '#000000'}
      }),
      jsonEncode({...payload, 'version': 1.0}),
      '${' ' * SavedTheme.maxFileBytes}${saved.encoded}',
    ]) {
      expect(() => SavedTheme.decode(invalid), throwsFormatException);
    }
    expect(
      () => SavedTheme.decode(jsonEncode({...payload, 'version': 2})),
      throwsA(isA<UnsupportedThemeVersion>()),
    );
  });

  test('named themes persist edits, custom choices and mode, and sync only the active theme', () async {
    final directory = await Directory.systemTemp.createTemp('proxypin-theme-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/ui_config.json');
    await file.writeAsString(jsonEncode({
      'themeColor': 'Teal',
      'themeSecondary': '#146B57',
      'mode': 'system',
      'useMaterial3': false,
      'useAmoled': true,
      'language': 'es',
      'appFontScale': 1.2,
    }));
    final main = AppConfiguration.withConfigFile(file);
    final child = AppConfiguration.withConfigFile(File('${directory.path}/child.json'));
    await main.initConfig();

    final custom = main.snapshotTheme('Custom colors');
    expect(custom.dark.surface, isNot(Colors.black));
    expect(await main.saveTheme(custom), isTrue);
    final edited = SavedTheme(
      name: 'Work',
      light: custom.light.copyWith(primary: const Color(0xFF26348B)),
      dark: custom.dark,
      lightString: custom.lightString,
      darkString: custom.darkString,
    );
    expect(await main.saveTheme(edited, replacing: custom), isTrue);
    expect(await main.saveTheme(main.snapshotTheme('work')), isFalse);

    final restored = AppConfiguration.withConfigFile(file);
    await restored.initConfig();
    expect(restored.savedThemes.single.encoded, edited.encoded);
    expect(restored.themePreset, same(restored.savedThemes.single));
    expect(restored.paletteColor(ThemeColorRole.secondary), '#146B57');
    expect(restored.language, const Locale('es'));
    expect(restored.appFontScale, 1.2);
    expect(restored.useMaterial3, isFalse);
    expect(restored.themeMode, ThemeMode.system);
    expect(restored.colorScheme(Brightness.dark).surface, Colors.black);

    child.applyThemeSettings(jsonDecode(jsonEncode(restored.themeSettings)) as Map);
    expect(child.themePreset, isA<SavedTheme>());
    expect(child.savedThemes, isEmpty);
    expect(child.colorScheme(Brightness.light).primary, const Color(0xFF26348B));
    expect(child.colorScheme(Brightness.dark).surface, Colors.black);
    expect(child.themeMode, ThemeMode.system);
    expect(child.language, isNull);
    final childSelection = child.themePreset;
    child.applyThemeSettings({...restored.themeSettings, 'activeSavedTheme': '{}'});
    expect(child.themePreset, same(childSelection));

    restored.themePreset = ThemePreset.apple;
    child.applyThemeSettings(restored.themeSettings);
    expect(child.themePreset, ThemePreset.apple);
    restored.themePreset = restored.savedThemes.single;
    child.applyThemeSettings(restored.themeSettings);
    expect(child.colorScheme(Brightness.light).primary, const Color(0xFF26348B));
    await restored.flushConfig();
  });

  test('a failed rename keeps the saved theme and selection until a retry reaches disk', () async {
    final directory = await Directory.systemTemp.createTemp('proxypin-theme-write-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/ui_config.json');
    final config = AppConfiguration.withConfigFile(file);
    final original = config.snapshotTheme('Original');
    expect(await config.saveTheme(original), isTrue);
    final before = await file.readAsString();
    final replacement = config.snapshotTheme('Renamed');
    final published = <String>[];
    config.globalChange.addListener(() => published.add(file.readAsStringSync()));

    final backup = await file.rename('${directory.path}/backup.json');
    final blocked = await Directory(file.path).create();
    await expectLater(config.saveTheme(replacement, replacing: original), throwsA(isA<FileSystemException>()));
    expect(config.savedThemes, [original]);
    expect(config.themePreset, same(original));
    expect(published, isEmpty);
    expect(await backup.readAsString(), before);
    expect(await directory.list().map((entry) => entry.path).toList(), unorderedEquals([backup.path, blocked.path]));

    await blocked.delete();
    await backup.rename(file.path);
    expect(await config.saveTheme(replacement, replacing: original), isTrue);
    expect(config.themePreset, same(replacement));
    expect(jsonDecode(published.single)['activeSavedThemeName'], 'Renamed');
    final restored = AppConfiguration.withConfigFile(file);
    await restored.initConfig();
    expect(restored.savedThemes.single.encoded, replacement.encoded);
    expect(restored.themePreset, same(restored.savedThemes.single));
  });

  test('serializes ordinary flushes around theme saves and continues after a write failure', () async {
    final config = _TestConfiguration();
    final writes = <Map<String, dynamic>>[];
    final firstStarted = Completer<void>();
    final firstWrite = Completer<void>();
    final themeStarted = Completer<void>();
    final themeWrite = Completer<void>();
    config.onWrite = (data) async {
      writes.add(data);
      if (writes.length == 1) {
        firstStarted.complete();
        await firstWrite.future;
      } else if (writes.length == 2) {
        themeStarted.complete();
        await themeWrite.future;
      }
    };
    config.appFontScale = 1.25;
    final firstFlush = config.flushConfig();
    final failed = expectLater(firstFlush, throwsA(isA<FileSystemException>()));
    await firstStarted.future;

    final candidate = config.snapshotTheme('Queued');
    final saved = config.saveTheme(candidate);
    config.appFontScale = 1.5;
    final lastFlush = config.flushConfig();
    expect(config.flushConfig(), same(lastFlush));
    expect(writes, hasLength(1));
    firstWrite.completeError(const FileSystemException('Test write failure'));
    await failed;
    await themeStarted.future;

    expect(config.savedThemes, isEmpty);
    expect(config.themePreset, ThemePreset.custom);
    expect(writes[1]['activeSavedThemeName'], 'Queued');
    expect(writes[1]['appFontScale'], 1.5);
    config.appFontScale = 1.75;
    expect(config.flushConfig(), same(lastFlush));
    expect(writes, hasLength(2));
    themeWrite.complete();

    expect(await saved, isTrue);
    await lastFlush;
    expect(writes.map((data) => data['appFontScale']), [1.25, 1.5, 1.75]);
    expect(writes.last['activeSavedThemeName'], 'Queued');
    expect(config.themePreset, same(candidate));
  });

  test('broadcasts a named palette and subsequent preset selection to existing child windows', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const windowChannel = MethodChannel('mixin.one/desktop_multi_window');
    const routerChannel = MethodChannel('mixin.one/desktop_multi_window/channels');
    final parent = _TestConfiguration()..themePreset = ThemePreset.gmail;
    final child = _TestConfiguration();
    var updates = 0;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      expect(call.method, 'getAllWindows');
      return [
        {'windowId': 'child', 'windowArgument': ''},
      ];
    });
    messenger.setMockMethodCallHandler(routerChannel, (call) async {
      expect(call.method, 'invokeMethod');
      final message = call.arguments as Map;
      expect(message['channel'], 'mixin.one/window_controller/child');
      expect(message['method'], 'applyTheme');
      child.applyThemeSettings(message['arguments'] as Map);
      updates++;
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(routerChannel, null);
    });

    final saved = parent.snapshotTheme('Shared palette');
    expect(await parent.saveTheme(saved), isTrue);
    await DesktopMultiWindow.updateTheme(parent.themeSettings);
    expect(child.themePreset.name, saved.name);
    expect(child.colorScheme(Brightness.dark).primary, saved.dark.primary);

    parent.themePreset = ThemePreset.apple;
    await DesktopMultiWindow.updateTheme(parent.themeSettings);
    expect(child.themePreset, ThemePreset.apple);
    expect(updates, 2);
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
    await _openSettings(tester, config);
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

  testWidgets('creates, edits, exports and imports themes through the settings and file picker', (tester) async {
    final config = _TestConfiguration()..themePreset = ThemePreset.figma;
    final originalDark = config.colorScheme(Brightness.dark);
    final previousPicker = FilePickerPlatform.instance;
    final picker = _ThemeFilePicker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previousPicker);
    await _openSettings(tester, config);

    await tester.tap(find.text('Save as theme'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(TextButton, 'Save');
    expect(tester.widget<TextButton>(save).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Desk');
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(config.savedThemes.single.name, 'Desk');
    expect(config.themePreset, config.savedThemes.single);
    expect(config.colorScheme(Brightness.dark), originalDark);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit theme'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Edited Desk');
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Primary'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '#C4A618');
    await tester.pump();
    await tester.tap(save.last);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(config.savedThemes.single.name, 'Edited Desk');
    expect(config.colorScheme(Brightness.light).primary, ThemePreset.figma.colorScheme(Brightness.light)!.primary);
    expect(config.colorScheme(Brightness.dark).primary, const Color(0xFFC4A618));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Export theme'));
    await tester.pumpAndSettle();
    final exported = SavedTheme.decode(utf8.decode(picker.exported!));
    expect(exported.encoded, config.savedThemes.single.encoded);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    Future<void> importBytes(Uint8List? bytes) async {
      picker.selection = bytes == null ? null : _ThemeFile(bytes);
      await tester.tap(find.text('Import theme'));
      await tester.pumpAndSettle();
    }

    final before = config.themeSettings;
    await importBytes(null);
    await importBytes(Uint8List.fromList([0xFF]));
    expect(find.text('Invalid theme file.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await importBytes(utf8.encode(exported.encoded.replaceFirst('"version": 1', '"version": 2')));
    expect(find.text('This theme file version is unsupported.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await importBytes(picker.exported);
    expect(find.text('A theme with this name already exists.'), findsOneWidget);
    expect(config.savedThemes, hasLength(1));
    expect(config.themeSettings, before);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await importBytes(utf8.encode(exported.encoded.replaceFirst('Edited Desk', 'Imported')));
    expect(config.savedThemes, hasLength(2));
    expect(config.themePreset.name, 'Imported');
    expect(config.colorScheme(Brightness.dark).primary, const Color(0xFFC4A618));
    await tester.tap(find.text('Imported'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edited Desk').last);
    await tester.pumpAndSettle();
    expect(config.themePreset.name, 'Edited Desk');
    expect(tester.takeException(), isNull);
  });

  testWidgets('creation, rename and import publish only after saving and can be retried', (tester) async {
    final config = _TestConfiguration()..themePreset = ThemePreset.figma;
    await config.flushConfig();
    var notifications = 0;
    config.globalChange.addListener(() => notifications++);
    final previousPicker = FilePickerPlatform.instance;
    final picker = _ThemeFilePicker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previousPicker);
    await _openSettings(tester, config);

    final save = find.widgetWithText(TextButton, 'Save');
    final saveSuccess = find.text('Saved successfully');
    final importSuccess = find.text('Import successful');

    Future<void> failWrite(Finder action, Finder success, VoidCallback expectBeforeCommit) async {
      final pending = Completer<void>();
      config.onWrite = (_) => pending.future;
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(action).onPressed, isNull);
      expect(success, findsNothing);
      expectBeforeCommit();
      pending.completeError(const FileSystemException('Test write failure'));
      await tester.pumpAndSettle();
      expect(success, findsNothing);
      expectBeforeCommit();
      config.onWrite = null;
    }

    Future<void> dismissMessage() async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('Save as theme'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Desk');
    await tester.pump();
    await failWrite(save, saveSuccess, () {
      expect(notifications, 0);
      expect(config.savedThemes, isEmpty);
      expect(config.themePreset, ThemePreset.figma);
    });
    expect(find.text('fail'), findsOneWidget);
    expect(find.text('Desk'), findsOneWidget);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saveSuccess, findsOneWidget);
    expect(notifications, 1);
    final original = config.savedThemes.single;
    await dismissMessage();

    await tester.tap(find.text('Edit theme'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Renamed');
    await tester.pump();
    await failWrite(save, saveSuccess, () {
      expect(notifications, 1);
      expect(config.savedThemes, [original]);
      expect(config.themePreset, same(original));
    });
    expect(find.text('fail'), findsOneWidget);
    expect(find.text('Renamed'), findsOneWidget);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saveSuccess, findsOneWidget);
    expect(notifications, 2);
    final renamed = config.savedThemes.single;
    expect(renamed.name, 'Renamed');
    await dismissMessage();

    picker.selection = _ThemeFile(utf8.encode(config.snapshotTheme('Imported').encoded));
    final import = find.widgetWithText(TextButton, 'Import theme');
    await failWrite(import, importSuccess, () {
      expect(notifications, 2);
      expect(config.savedThemes, [renamed]);
      expect(config.themePreset, same(renamed));
    });
    expect(find.text('Import failed'), findsOneWidget);
    await dismissMessage();
    await tester.tap(import);
    await tester.pumpAndSettle();
    expect(importSuccess, findsOneWidget);
    expect(notifications, 3);
    expect(config.savedThemes.map((theme) => theme.name), ['Renamed', 'Imported']);
    expect(config.themePreset.name, 'Imported');
    expect(tester.takeException(), isNull);
  });
}
