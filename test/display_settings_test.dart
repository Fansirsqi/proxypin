import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/main.dart';
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
  int themeComputations = 0;

  @override
  Future<void> writeConfig(Map<String, dynamic> config) async => writes.add(config);

  @override
  ColorScheme colorScheme(Brightness brightness) {
    themeComputations++;
    return super.colorScheme(brightness);
  }
}

Widget _settings(AppConfiguration config, Widget child) =>
    FluentApp(Scaffold(body: child), config, resizeBorder: false);

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
    final densityKey = switch (setting) {
      DisplayDensitySetting.fontSize => 'appFontScale',
      DisplayDensitySetting.interface => 'uiDensity',
      DisplayDensitySetting.captureList => 'captureListDensity',
    };
    final tile = switch (setting) {
      DisplayDensitySetting.fontSize => const AppFontScaleTile(titleStyle: TextStyle(fontSize: 14)),
      DisplayDensitySetting.interface => const UiDensityTile(),
      DisplayDensitySetting.captureList => const CaptureDensityTile(),
    };

    testWidgets('$densityKey previews during drag and commits on release', (tester) async {
      final config = _RecordingConfiguration();
      addTearDown(config.globalChange.dispose);
      final minimum = setting == DisplayDensitySetting.fontSize ? 60.0 : 5.0;
      double density() => switch (setting) {
            DisplayDensitySetting.fontSize => config.appFontScale * 100,
            DisplayDensitySetting.interface => config.uiDensity,
            DisplayDensitySetting.captureList => config.captureListDensity,
          };
      double spacing() => switch (setting) {
            DisplayDensitySetting.fontSize =>
              Theme.of(tester.element(find.byType(Slider))).textTheme.bodyMedium!.fontSize!,
            DisplayDensitySetting.interface => config.visualDensity.vertical,
            DisplayDensitySetting.captureList => config.captureRowMetrics.top,
          };
      double persist(double percent) => setting == DisplayDensitySetting.fontSize ? percent / 100 : percent;
      await tester.pumpWidget(_settings(
        config,
        Column(children: [
          SizedBox(width: 328, child: tile),
        ]),
      ));
      await tester.pumpAndSettle();
      final slider = find.byType(Slider);
      final bounds = tester.getRect(slider);
      expect(bounds.width, 328);
      expect(tester.widget<Slider>(slider).min, minimum);
      expect(tester.widget<Slider>(slider).max, 120);
      expect(tester.widget<Slider>(slider).divisions, isNull);
      final gesture = await tester.startGesture(bounds.centerLeft + const Offset(57, 0));
      await gesture.moveTo(bounds.centerLeft + const Offset(43, 0));
      await tester.pump();
      final firstDensity = density();
      final firstSpacing = spacing();
      expect(firstDensity, inExclusiveRange(minimum, 100));
      expect(config.writes, isEmpty);
      await gesture.moveBy(const Offset(-4, 0));
      await tester.pump();
      expect(density(), lessThan(firstDensity));
      expect(spacing(), lessThan(firstSpacing));
      await gesture.moveTo(bounds.centerLeft);
      await tester.pumpAndSettle();
      expect(density(), minimum);
      expect(find.text('${minimum.round()}%'), findsOneWidget);

      config.applyDisplaySetting(() => config.editorFontSize = 14);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(config.writes.single[densityKey], persist(100));
      expect(config.writes.single['editorFontSize'], 14);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(config.writes, hasLength(2));
      expect(config.writes.last[densityKey], persist(minimum));

      await tester.tapAt(tester.getRect(slider).centerRight - const Offset(2, 0));
      await tester.pumpAndSettle();
      expect(density(), 120);
      expect(spacing(), greaterThan(firstSpacing));
      expect(config.writes.last[densityKey], persist(120));
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
      bounds.centerLeft + Offset(bounds.width * .12, 0),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(bounds.centerLeft + Offset(bounds.width * .08, 0));
    await gesture.moveBy(const Offset(-4, 0));
    await tester.pumpAndSettle();
    expect(config.uiDensity, lessThan(100));
    expect(workspaceSpacing, lessThan(0));
    expect(tester.getRect(uiSlider), bounds);
    await gesture.moveTo(bounds.centerLeft);
    await tester.pumpAndSettle();
    expect(config.uiDensity, 5);
    expect(tester.getRect(uiSlider), bounds);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(config.writes.single['uiDensity'], 5);

    final captureSlider = find.descendant(of: find.byType(CaptureDensityTile), matching: find.byType(Slider));
    await tester.ensureVisible(captureSlider);
    await tester.pumpAndSettle();
    final captureBounds = tester.getRect(captureSlider);
    final captureGesture = await tester.startGesture(
      captureBounds.centerLeft + Offset(captureBounds.width * .28, 0),
      kind: PointerDeviceKind.mouse,
    );
    final interfaceSpacing = workspaceSpacing;
    await captureGesture.moveTo(captureBounds.centerLeft);
    await tester.pumpAndSettle();
    expect(config.captureListDensity, 5);
    expect(workspaceSpacing, interfaceSpacing);
    expect(tester.getRect(captureSlider), captureBounds);
    expect(config.writes, hasLength(1));
    await captureGesture.up();
    await tester.pumpAndSettle();
    expect(config.writes.last['captureListDensity'], 5);

    final fontSlider = find.descendant(of: find.byType(AppFontScaleTile), matching: find.byType(Slider));
    await tester.ensureVisible(fontSlider);
    await tester.pumpAndSettle();
    final fontBounds = tester.getRect(fontSlider);
    final fontGesture = await tester.startGesture(fontBounds.center, kind: PointerDeviceKind.mouse);
    await fontGesture.moveTo(fontBounds.centerRight - const Offset(2, 0));
    await tester.pumpAndSettle();
    expect(config.appFontScale, 1.2);
    expect(tester.getRect(fontSlider), fontBounds);
    expect(tester.takeException(), isNull);
    await fontGesture.up();
    await tester.pumpAndSettle();
    expect(config.writes.last['appFontScale'], 1.2);
  });

  testWidgets('density previews reach their dependents with zero root rebuilds and theme computations', (tester) async {
    final config = _RecordingConfiguration();
    addTearDown(config.globalChange.dispose);
    var appBuilds = 0;
    var themeBuilds = 0;
    var configBuilds = 0;
    var captureBuilds = 0;
    await tester.pumpWidget(_settings(
      config,
      Column(children: [
        const UiDensityTile(),
        const CaptureDensityTile(),
        Builder(builder: (context) {
          themeBuilds++;
          Theme.of(context);
          return const SizedBox.shrink();
        }),
        Builder(builder: (context) {
          configBuilds++;
          AppDisplaySettings.of(context);
          return const SizedBox.shrink();
        }),
        Builder(builder: (context) {
          captureBuilds++;
          AppDisplaySettings.captureOf(context);
          return const SizedBox.shrink();
        }),
      ]),
    ));
    await tester.pumpAndSettle();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    final previousHook = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      if (element.widget is MaterialApp) appBuilds++;
      previousHook?.call(element, builtOnce);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = previousHook);
    final initial = (themeBuilds, configBuilds, captureBuilds, config.themeComputations);
    for (final density in [25.0, 39.9, 40.0, 80.0, 100.0, 105.0, 110.0, 120.0]) {
      config.setDisplayDensity(DisplayDensitySetting.captureList, density, commit: false);
      await tester.pump();
    }
    expect((appBuilds, themeBuilds, configBuilds, captureBuilds, config.themeComputations),
        (0, initial.$1, initial.$2, initial.$3 + 8, initial.$4));
    for (final density in [5.0, 80.0, 120.0]) {
      config.setDisplayDensity(DisplayDensitySetting.interface, density, commit: false);
      await tester.pump();
    }
    expect((appBuilds, themeBuilds, configBuilds, captureBuilds, config.themeComputations),
        (0, initial.$1 + 3, initial.$2, initial.$3 + 8, initial.$4));
    debugPrint('Density previews: MaterialApp builds=$appBuilds, theme computations='
        '${config.themeComputations - initial.$4}, '
        'Theme.of builds=${themeBuilds - initial.$1}, capture builds=${captureBuilds - initial.$3}, '
        'general settings builds=${configBuilds - initial.$2}');
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)), same(app));
    expect(config.writes, isEmpty);

    config.applyThemeSettings({'mode': 'dark', 'themeColor': 'Green'});
    await tester.pumpAndSettle();
    expect(appBuilds, greaterThan(0));
    expect(config.themeComputations, initial.$4 + 2);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);
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

  testWidgets('capture details visibility is independent of row height on both layouts', (tester) async {
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
              AppDisplaySettings(
                configuration: config,
                includeCaptureChanges: true,
                child: mobile.RequestRow(
                    request: request,
                    proxyServer: proxy,
                    index: 1,
                    selectionController: selection,
                    selectionHandlers: handlers),
              ),
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
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    config.setDisplayDensity(DisplayDensitySetting.captureList, 39.9, commit: false);
    await tester.pumpAndSettle();
    expect(details, findsNWidgets(2));
    expect(tester.widgetList<Text>(titles).map((title) => title.maxLines), [1, 1]);
    expect(config.writes, isEmpty);

    config.setDisplayDensity(DisplayDensitySetting.captureList, 39.9, commit: true);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(details, findsNothing);
    expect(tester.widgetList<Text>(titles).map((title) => title.maxLines), [1, 1]);
    expect(config.writes.last['showCaptureRowDetails'], isFalse);

    config.setDisplayDensity(DisplayDensitySetting.captureList, 100, commit: false);
    await tester.pumpAndSettle();
    expect(details, findsNothing);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(details, findsNWidgets(2));
    expect(config.writes.last['showCaptureRowDetails'], isTrue);
  });

  test('display preferences round-trip through the existing config fields', () async {
    final directory = await Directory.systemTemp.createTemp('proxypin-display-settings-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/ui_config.json');
    await file.writeAsString(jsonEncode({'uiDensity': 'compact', 'captureListDensity': 'dense', 'appFontScale': 9.99}));
    final configuration = AppConfiguration.withConfigFile(file);
    await configuration.initConfig();
    expect(configuration.uiDensity, 80);
    expect(configuration.captureListDensity, 60);
    expect(configuration.appFontScale, 1.2);
    expect(configuration.showCaptureRowDetails, isTrue);
    expect(configuration.editorColorScheme, EditorColorScheme.followTheme);

    configuration.applyDisplaySetting(() {
      configuration.editorColorScheme = EditorColorScheme.catppuccinMocha;
      configuration.uiDensity = 112.5;
      configuration.captureListDensity = 38.25;
      configuration.showCaptureRowDetails = true;
      configuration.appFontScale = 1.15;
    });
    await configuration.flushConfig();
    final restored = AppConfiguration.withConfigFile(file);
    await restored.initConfig();
    expect(restored.uiDensity, 112.5);
    expect(restored.captureListDensity, 38.25);
    expect(restored.showCaptureRowDetails, isTrue);
    expect(restored.appFontScale, 1.15);
    expect(restored.editorColorScheme, EditorColorScheme.catppuccinMocha);

    await file.writeAsString(jsonEncode({
      'editorColorScheme': 'unknown',
      'uiDensity': 1000,
      'captureListDensity': 1,
      'appFontScale': 0.01,
    }));
    await restored.initConfig();
    expect(restored.editorColorScheme, EditorColorScheme.followTheme);
    expect(restored.uiDensity, 120);
    expect(restored.captureListDensity, 5);
    expect(restored.appFontScale, .60);
    expect(restored.showCaptureRowDetails, isFalse);
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
