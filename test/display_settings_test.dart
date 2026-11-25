import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/app_appearance_setting.dart';
import 'package:proxypin/ui/component/code_font_setting.dart';
import 'package:proxypin/ui/component/multi_select_controller.dart';
import 'package:proxypin/ui/component/saved_theme.dart';
import 'package:proxypin/ui/component/theme_presets.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/desktop/preference.dart';
import 'package:proxypin/ui/desktop/request/request.dart';
import 'package:proxypin/ui/mobile/request/request.dart' as mobile;
import 'package:proxypin/utils/system_fonts.dart';

class _RecordingConfiguration extends AppConfiguration {
  _RecordingConfiguration() : super.withConfigFile(File('unused'));

  final writes = <Map<String, dynamic>>[];

  @override
  Future<void> writeConfig(Map<String, dynamic> config) async => writes.add(config);
}

Widget _settings(AppConfiguration config, Widget child) => ValueListenableBuilder(
      valueListenable: config.globalChange,
      builder: (_, __, ___) => MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: _theme(config, Brightness.light),
        darkTheme: _theme(config, Brightness.dark),
        themeMode: config.themeMode,
        home: Scaffold(body: AppDisplaySettings(configuration: config, child: child)),
      ),
    );

ThemeData _theme(AppConfiguration config, Brightness brightness) => ThemeData(
      colorScheme: config.colorScheme(brightness),
      visualDensity: config.visualDensity,
      extensions: [ActiveThemePreset(config.themePreset)],
    );

double _contrast(Color foreground, Color background) {
  final values = [foreground.computeLuminance(), background.computeLuminance()]..sort();
  return (values.last + .05) / (values.first + .05);
}

void main() {
  setUpAll(() async {
    await AppLocalizations.delegate.load(const Locale('en'));
  });

  testWidgets('long UI and code font names stay on one line', (tester) async {
    const family = 'Agave Nerd Font Mono with a very long family name';
    final settings = _RecordingConfiguration()
      ..appFontFamily = family
      ..editorFontFamily = family;
    addTearDown(settings.globalChange.dispose);
    await tester.runAsync(() => Future.wait([SystemFonts.families(), SystemFonts.monospaceFamilies()]));
    await tester.pumpWidget(_settings(
      settings,
      const Column(children: [AppFontFamilyTile(), CodeFontFamilyTile()]),
    ));
    await tester.pumpAndSettle();
    final names = find.text(family);
    expect(names, findsNWidgets(2));
    for (final name in tester.widgetList<Text>(names)) {
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
    }
    expect(find.byTooltip(family), findsNWidgets(2));
  });

  for (final setting in DisplayDensitySetting.values) {
    final interface = setting == DisplayDensitySetting.interface;
    final densityKey = interface ? 'uiDensity' : 'captureListDensity';
    final otherKey = interface ? 'captureListDensity' : 'uiDensity';

    testWidgets('$densityKey previews during drag and commits on release', (tester) async {
      final config = _RecordingConfiguration();
      addTearDown(config.globalChange.dispose);
      double density() => interface ? config.uiDensity : config.captureListDensity;
      double spacing() => interface ? config.visualDensity.vertical : config.captureRowMetrics.top;
      await tester.pumpWidget(_settings(
        config,
        Column(children: [
          SizedBox(width: 328, child: interface ? const UiDensityTile() : const CaptureDensityTile()),
        ]),
      ));
      await tester.pumpAndSettle();
      final slider = find.byType(Slider);
      final bounds = tester.getRect(slider);
      expect(bounds.width, 328);
      expect(tester.widget<Slider>(slider).min, 25);
      expect(tester.widget<Slider>(slider).max, 300);
      expect(tester.widget<Slider>(slider).divisions, isNull);
      final gesture = await tester.startGesture(bounds.centerLeft + Offset(bounds.width * .28, 0));
      await gesture.moveTo(bounds.centerLeft + Offset(bounds.width * .22, 0));
      await tester.pump();
      final firstDensity = density();
      final firstSpacing = spacing();
      expect(firstDensity, inExclusiveRange(60, 100));
      expect(config.writes, isEmpty);
      await gesture.moveBy(const Offset(-4, 0));
      await tester.pump();
      expect(density(), lessThan(firstDensity));
      expect(spacing(), lessThan(firstSpacing));
      await gesture.moveTo(bounds.centerLeft);
      await tester.pumpAndSettle();
      expect(density(), 25);
      expect(find.text('25%'), findsOneWidget);

      config.applyDisplaySetting(() => config.appFontScale = 1.1);
      await tester.pump();
      expect(config.writes.single[densityKey], 100);
      expect(config.writes.single['appFontScale'], 1.1);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(config.writes, hasLength(2));
      expect(config.writes.last[densityKey], 25);
      expect(config.writes.last[otherKey], 100);

      await tester.tapAt(bounds.centerRight - const Offset(2, 0));
      await tester.pumpAndSettle();
      expect(density(), 300);
      expect(spacing(), greaterThan(firstSpacing));
      expect(config.writes.last[densityKey], 300);
    });
  }

  testWidgets('desktop settings keep the density slider aligned with the mouse during preview', (tester) async {
    final config = _RecordingConfiguration();
    addTearDown(config.globalChange.dispose);
    await tester.runAsync(() => Future.wait([SystemFonts.families(), SystemFonts.monospaceFamilies()]));
    double? workspaceSpacing;
    await tester.pumpWidget(_settings(
      config,
      Column(children: [
        Builder(builder: (context) {
          workspaceSpacing = Theme.of(context).visualDensity.vertical;
          return const SizedBox.shrink();
        }),
        Expanded(
          child: SingleChildScrollView(child: Preference(config, Configuration.fromJson({'startup': false}))),
        ),
      ]),
    ));
    await tester.pumpAndSettle();
    final uiSlider = find.descendant(of: find.byType(UiDensityTile), matching: find.byType(Slider));
    await tester.ensureVisible(uiSlider);
    await tester.pumpAndSettle();
    final bounds = tester.getRect(uiSlider);
    final gesture = await tester.startGesture(
      bounds.centerLeft + Offset(bounds.width * .28, 0),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(bounds.centerLeft + Offset(bounds.width * .22, 0));
    await gesture.moveBy(const Offset(-4, 0));
    await tester.pumpAndSettle();
    expect(config.uiDensity, lessThan(100));
    expect(workspaceSpacing, lessThan(0));
    expect(tester.getRect(uiSlider), bounds);
    await gesture.moveTo(bounds.centerLeft);
    await tester.pumpAndSettle();
    expect(config.uiDensity, 25);
    expect(tester.getRect(uiSlider), bounds);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(config.writes.single['uiDensity'], 25);
  });

  testWidgets('density sliders support keyboard and localized semantic adjustments', (tester) async {
    final config = _RecordingConfiguration();
    addTearDown(config.globalChange.dispose);
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(_settings(config, const Column(children: [UiDensityTile(), CaptureDensityTile()])));
      await tester.pumpAndSettle();
      final sliders = find.byType(Slider);
      final localizations = AppLocalizations.of(tester.element(sliders.at(1)))!;

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(config.writes.single['uiDensity'], inExclusiveRange(25, 100));

      final captureSemantics = find.semantics.byPredicate((node) {
        final data = node.getSemanticsData();
        return data.label.contains(localizations.captureListDensity) && data.value.endsWith('%');
      });
      final node = captureSemantics.evaluate().single;
      expect(node.getSemanticsData().value, '100%');
      final decreased = node.getSemanticsData().decreasedValue;
      expect(decreased, isNot('100%'));
      tester.semantics.performAction(captureSemantics, SemanticsAction.decrease);
      await tester.pumpAndSettle();
      expect(captureSemantics.evaluate().single.getSemanticsData().value, decreased);
      expect(config.writes.last['captureListDensity'], inExclusiveRange(25, 100));
      expect(config.writes.last['uiDensity'], config.writes.first['uiDensity']);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('compact capture rows hide details on both layouts until the override is enabled', (tester) async {
    final config = _RecordingConfiguration()..captureListDensity = 40;
    addTearDown(config.globalChange.dispose);
    final request = HttpRequest(HttpMethod.get, 'https://example.test/a/long/path/for/a/narrow/capture/pane');
    request.response = HttpResponse(HttpStatus.ok)..request = request;
    final proxy = ProxyServer(Configuration.fromJson({}));
    final selection = MultiSelectController();
    const handlers = RequestSelectionHandlers();
    await tester.pumpWidget(_settings(
      config,
      Center(
        child: SizedBox(
          width: 280,
          child: Column(
            children: [
              const CaptureDensityTile(),
              RequestWidget(request,
                  proxyServer: proxy, index: 1, multiSelectController: selection, selectionHandlers: handlers),
              mobile.RequestRow(
                  request: request,
                  proxyServer: proxy,
                  index: 1,
                  selectionController: selection,
                  selectionHandlers: handlers),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final details = find.textContaining('[200]', findRichText: true);
    final titles = find.byWidgetPredicate(
      (widget) => widget is Text && widget.textSpan?.toPlainText().replaceAll('\u200B', '').startsWith('GET ') == true,
    );
    final toggle = find.byType(SwitchListTile);
    expect(details, findsNWidgets(2));
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    config.setDisplayDensity(DisplayDensitySetting.captureList, 39.9, commit: false);
    await tester.pumpAndSettle();
    expect(details, findsNothing);
    expect(find.text('39%'), findsOneWidget);
    expect(tester.widgetList<Text>(titles).map((title) => title.maxLines), [1, 1]);
    expect(config.writes, isEmpty);

    config.setDisplayDensity(DisplayDensitySetting.captureList, 39.9, commit: true);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(details, findsNWidgets(2));
    expect(tester.widgetList<Text>(titles).map((title) => title.maxLines), [1, 1]);
    expect(config.writes.last['alwaysShowCaptureRowDetails'], isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(details, findsNothing);
    expect(config.writes.last['alwaysShowCaptureRowDetails'], isFalse);
  });

  test('display preferences round-trip through the existing config fields', () async {
    final directory = await Directory.systemTemp.createTemp('proxypin-display-settings-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/ui_config.json');
    await file.writeAsString(jsonEncode({'uiDensity': 'compact', 'captureListDensity': 'dense'}));
    final configuration = AppConfiguration.withConfigFile(file);
    await configuration.initConfig();
    expect(configuration.uiDensity, 80);
    expect(configuration.captureListDensity, 60);
    expect(configuration.alwaysShowCaptureRowDetails, isFalse);
    expect(configuration.editorColorScheme, EditorColorScheme.followTheme);

    configuration.applyDisplaySetting(() {
      configuration.editorColorScheme = EditorColorScheme.catppuccinMocha;
      configuration.uiDensity = 212.5;
      configuration.captureListDensity = 38.25;
      configuration.alwaysShowCaptureRowDetails = true;
    });
    await configuration.flushConfig();
    final restored = AppConfiguration.withConfigFile(file);
    await restored.initConfig();
    expect(restored.uiDensity, 212.5);
    expect(restored.captureListDensity, 38.25);
    expect(restored.alwaysShowCaptureRowDetails, isTrue);
    expect(restored.editorColorScheme, EditorColorScheme.catppuccinMocha);

    await file.writeAsString(jsonEncode({
      'editorColorScheme': 'unknown',
      'uiDensity': 400,
      'captureListDensity': 10,
    }));
    await restored.initConfig();
    expect(restored.editorColorScheme, EditorColorScheme.followTheme);
    expect(restored.uiDensity, 300);
    expect(restored.captureListDensity, 25);
    expect(restored.alwaysShowCaptureRowDetails, isFalse);
  });

  testWidgets('editor palettes update live and fixed schemes keep contrast across app themes', (tester) async {
    final config = _RecordingConfiguration();
    addTearDown(config.globalChange.dispose);
    Map<String, TextStyle>? editorTheme;
    await tester.pumpWidget(_settings(
      config,
      Column(children: [
        const EditorColorSchemeTile(),
        Builder(builder: (context) {
          editorTheme = codeEditorTheme(context);
          return const SizedBox.shrink();
        }),
      ]),
    ));
    await tester.pumpAndSettle();
    final initial = editorTheme;
    await tester.tap(find.byType(DropdownButton<EditorColorScheme>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atom One Dark').last);
    await tester.pumpAndSettle();
    expect(config.writes.single['editorColorScheme'], 'atomOneDark');
    expect(editorTheme, isNot(equals(initial)));
    expect(editorTheme!['root']!.backgroundColor, const Color(0xFF282C34));

    for (final choice in EditorColorScheme.values) {
      config.applyDisplaySetting(() => config.editorColorScheme = choice);
      final palettes = <Map<String, TextStyle>>[];
      for (final brightness in Brightness.values) {
        config.themeMode = brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
        await tester.pumpAndSettle();
        final palette = editorTheme!;
        final background = palette['root']!.backgroundColor!;
        palettes.add(palette);
        for (final entry in palette.entries) {
          final style = entry.value;
          if (style.color == null) continue;
          expect(_contrast(style.color!, style.backgroundColor ?? background), greaterThanOrEqualTo(4.5),
              reason: '${choice.name}, ${brightness.name}, ${entry.key}');
        }
      }
      if (choice == EditorColorScheme.followTheme) {
        expect(palettes.first, isNot(equals(palettes.last)));
      } else {
        expect(palettes.first, palettes.last);
      }
    }
  });

  testWidgets('theme snapshots hot-update the editor while portable themes exclude the preference', (tester) async {
    final primary = _RecordingConfiguration();
    final child = _RecordingConfiguration();
    addTearDown(primary.globalChange.dispose);
    addTearDown(child.globalChange.dispose);
    primary.themePreset = ThemePreset.gmail;
    final saved = primary.snapshotTheme('Shared');
    expect(await primary.saveTheme(saved), isTrue);
    final exported = saved.encoded;
    const preview = Key('editor-preview');
    await tester.pumpWidget(_settings(
      child,
      Builder(
          builder: (context) => ColoredBox(key: preview, color: codeEditorTheme(context)['root']!.backgroundColor!)),
    ));
    child.applyThemeSettings(primary.themeSettings);
    await tester.pumpAndSettle();
    expect(tester.widget<ColoredBox>(find.byKey(preview)).color, saved.light.surface);

    primary.applyDisplaySetting(() => primary.editorColorScheme = EditorColorScheme.atomOneDark);
    child.applyThemeSettings(primary.themeSettings);
    await tester.pumpAndSettle();
    expect(tester.widget<ColoredBox>(find.byKey(preview)).color, const Color(0xFF282C34));
    expect(child.themePreset.name, saved.name);
    expect(child.writes, isEmpty);
    expect(primary.snapshotTheme(saved.name).encoded, exported);
    expect(jsonDecode(exported), isNot(contains('editorColorScheme')));
    final import = jsonDecode(exported) as Map<String, dynamic>;
    import['name'] = 'Imported';
    expect(await primary.saveTheme(SavedTheme.decode(jsonEncode(import))), isTrue);
    expect(primary.editorColorScheme, EditorColorScheme.atomOneDark);
  });
}
