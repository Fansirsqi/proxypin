import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/component/saved_theme.dart';
import 'package:proxypin/ui/component/theme_presets.dart';
import 'package:proxypin/ui/configuration.dart';

class _PrimaryConfiguration extends AppConfiguration {
  _PrimaryConfiguration(super.configFile) : super.withConfigFile();

  Future<void> Function(Map<String, dynamic>)? beforeWrite;

  @override
  Future<void> writeConfig(Map<String, dynamic> config) async {
    await beforeWrite?.call(config);
    await super.writeConfig(config);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const windowManager = MethodChannel('window_manager');
  const windows = MethodChannel('mixin.one/desktop_multi_window');
  const router = MethodChannel('mixin.one/desktop_multi_window/channels');

  late File file;
  late _PrimaryConfiguration primary;
  late AppConfiguration detail;
  late String engine;
  late List<Map<dynamic, dynamic>> requests;

  Future<AppConfiguration> reload() async {
    final config = AppConfiguration.withConfigFile(file);
    await config.initConfig();
    return config;
  }

  Future<void> selectEngine(String id) async {
    engine = id;
    await DesktopMultiWindow.ensureInitialized();
  }

  Future<void> synchronizeTheme() async {
    await selectEngine('main');
    await DesktopMultiWindow.updateTheme(primary.themeSettings);
    await selectEngine('detail');
  }

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp('proxypin-theme-windows-');
    addTearDown(() => directory.delete(recursive: true));
    file = File('${directory.path}/ui_config.json');
    await file.writeAsString(jsonEncode({
      'themePreset': 'gmail',
      'mode': 'system',
      'language': 'es',
      'panelRatio': 0.4,
      'appFontScale': 1.1,
      'headerViewMode': 'table',
      'detailTabAlignment': 'left',
      'detailTabLabelAlignment': 'center',
      'detailHeaderDensity': 'compact',
    }));
    primary = _PrimaryConfiguration(file);
    await primary.initConfig();
    detail = await reload();
    requests = [];

    messenger.setMockMethodCallHandler(windowManager, (_) async => null);
    messenger.setMockMethodCallHandler(windows, (call) async {
      Map<String, String> definition(String id) => {'windowId': id, 'windowArgument': ''};
      return switch (call.method) {
        'getWindowDefinition' => definition(engine),
        'getAllWindows' => [definition('main'), definition('detail')],
        _ => throw MissingPluginException(call.method),
      };
    });
    messenger.setMockMethodCallHandler(router, (call) async {
      if (call.method == 'registerMethodHandler') return null;
      expect(call.method, 'invokeMethod');
      final message = call.arguments as Map;
      if (message['method'] == 'saveDetailPreferences') {
        expect(message['channel'], 'proxypin/main_window');
        final envelope = message['arguments'] as Map;
        expect(envelope['__fromWindowId'], anyOf('detail', 'other'));
        requests.add(envelope['__arguments'] as Map);
      }
      final response = await messenger.handlePlatformMessage(
        router.name,
        router.codec.encodeMethodCall(MethodCall('methodCall', message)),
        null,
      );
      return router.codec.decodeEnvelope(response!);
    });
    addTearDown(() {
      DesktopMultiWindow.onSaveDetailPreferences = null;
      DesktopMultiWindow.onThemeChanged = null;
      for (final channel in [router, windows, windowManager]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    await selectEngine('main');
    DesktopMultiWindow.onSaveDetailPreferences = primary.saveWindowDetailPreferences;
    await DesktopMultiWindow.setMethodHandler((call, _) async => throw MissingPluginException(call.method));
    await selectEngine('detail');
    DesktopMultiWindow.onThemeChanged = detail.applyThemeSettings;
    detail.forwardDetailPreferences(DesktopMultiWindow.saveDetailPreferences);
  });

  test('a detail window opened before create and rename preserves both palettes and ordinary preferences', () async {
    final original = primary.snapshotTheme('Original');
    final shared = SavedTheme(
      name: 'Shared',
      light: original.light.copyWith(primary: const Color(0xFF223344)),
      dark: original.dark.copyWith(primary: const Color(0xFF99AABB)),
      lightString: original.lightString,
      darkString: original.darkString,
    );
    expect(await primary.saveTheme(original), isTrue);
    expect(await primary.saveTheme(shared), isTrue);
    await synchronizeTheme();
    expect(detail.savedThemes, isEmpty);
    expect(detail.colorScheme(Brightness.light).primary, shared.light.primary);
    expect(detail.colorScheme(Brightness.dark).primary, shared.dark.primary);
    detail.headerViewMode.value = 'text';
    await detail.flushConfig();
    expect((await reload()).themePreset.name, 'Shared');

    primary.detailLayout.value =
        (tabs: DetailTabAlignment.right, labels: DetailTabLabelAlignment.center, headers: HeaderDensity.compact);
    primary.appFontScale = 1.2;
    await primary.flushConfig();
    final renamed = primary.snapshotTheme('Renamed');
    expect(await primary.saveTheme(renamed, replacing: shared), isTrue);
    await synchronizeTheme();
    expect(detail.themePreset.name, renamed.name);
    expect(detail.colorScheme(Brightness.light).primary, renamed.light.primary);
    expect(detail.colorScheme(Brightness.dark).primary, renamed.dark.primary);
    detail.headerViewMode.value = 'table';
    detail.detailLayout.value =
        (tabs: DetailTabAlignment.left, labels: DetailTabLabelAlignment.bottom, headers: HeaderDensity.dense);
    await detail.flushConfig();

    final restored = await reload();
    expect(restored.savedThemes.map((theme) => theme.name), ['Original', 'Renamed']);
    expect(restored.themePreset.name, 'Renamed');
    expect(restored.themeMode, ThemeMode.system);
    expect(restored.headerViewMode.value, 'table');
    expect(restored.detailLayout.value,
        (tabs: DetailTabAlignment.right, labels: DetailTabLabelAlignment.bottom, headers: HeaderDensity.dense));
    expect(restored.appFontScale, 1.2);
    expect(restored.panelRatio, 0.4);
    expect(restored.language, const Locale('es'));
    expect(requests, [
      {'headerViewMode': 'text'},
      {'headerViewMode': 'table', 'detailTabLabelAlignment': 'bottom', 'detailHeaderDensity': 'dense'},
    ]);
  });

  test('overlapping detail saves, primary flush and theme save share one file write queue', () async {
    final other = await reload();
    other.forwardDetailPreferences(DesktopMultiWindow.saveDetailPreferences);
    final started = Completer<void>();
    final release = Completer<void>();
    final received = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final writes = <Map<String, dynamic>>[];
    primary.beforeWrite = (config) async {
      writes.add(config);
      if (writes.length == 1) {
        started.complete();
        await release.future;
      }
    };
    DesktopMultiWindow.onSaveDetailPreferences = (changes) {
      final save = primary.saveWindowDetailPreferences(changes);
      if (changes.containsKey('detailTabAlignment')) received.complete();
      return save;
    };

    detail.headerViewMode.value = 'text';
    final first = detail.flushConfig();
    await started.future;
    final theme = primary.snapshotTheme('Concurrent');
    final saved = primary.saveTheme(theme);
    await selectEngine('other');
    other.detailLayout.value =
        (tabs: DetailTabAlignment.center, labels: DetailTabLabelAlignment.center, headers: HeaderDensity.compact);
    final second = other.flushConfig();
    await received.future;
    primary.appFontScale = 1.25;
    final primaryFlush = primary.flushConfig();
    expect(writes, hasLength(1));
    expect((await reload()).themePreset, ThemePreset.gmail);
    release.complete();

    expect(await saved, isTrue);
    await Future.wait([first, second, primaryFlush]);
    expect(writes.map((config) => config['activeSavedThemeName']), [null, 'Concurrent', 'Concurrent', 'Concurrent']);
    expect(writes.map((config) => config['detailTabAlignment']), ['left', 'left', 'center', 'center']);
    final restored = await reload();
    expect(restored.savedThemes.single.encoded, theme.encoded);
    expect(restored.themePreset.name, 'Concurrent');
    expect(restored.headerViewMode.value, 'text');
    expect(restored.detailLayout.value.tabs, DetailTabAlignment.center);
    expect(restored.appFontScale, 1.25);
  });

  test('pending detail commits preserve newer local changes field by field', () async {
    final other = await reload();
    other.forwardDetailPreferences(DesktopMultiWindow.saveDetailPreferences);
    final firstWrite = Completer<void>();
    final secondWrite = Completer<void>();
    final otherReceived = Completer<void>();
    final releaseFirst = Completer<void>();
    final releaseSecond = Completer<void>();
    addTearDown(() {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
      if (!releaseSecond.isCompleted) releaseSecond.complete();
    });
    final writes = <Map<String, dynamic>>[];
    primary.beforeWrite = (config) async {
      writes.add(config);
      if (writes.length == 1) {
        firstWrite.complete();
        await releaseFirst.future;
      }
      if (writes.length == 2) {
        secondWrite.complete();
        await releaseSecond.future;
      }
    };
    DesktopMultiWindow.onSaveDetailPreferences = (changes) {
      final save = primary.saveWindowDetailPreferences(changes);
      if (changes.containsKey('detailHeaderDensity') && !otherReceived.isCompleted) otherReceived.complete();
      return save;
    };

    detail.headerViewMode.value = 'text';
    detail.detailLayout.value =
        (tabs: DetailTabAlignment.center, labels: DetailTabLabelAlignment.top, headers: HeaderDensity.compact);
    final first = detail.flushConfig();
    await firstWrite.future;
    expect(primary.headerViewMode.value, 'table');
    expect(primary.detailLayout.value, AppConfiguration.defaultDetailLayout);
    expect((await reload()).detailLayout.value, AppConfiguration.defaultDetailLayout);

    await selectEngine('other');
    other.detailLayout.value =
        (tabs: DetailTabAlignment.right, labels: DetailTabLabelAlignment.bottom, headers: HeaderDensity.dense);
    final second = other.flushConfig();
    await otherReceived.future;
    primary.headerViewMode.value = 'text';
    primary.headerViewMode.value = 'table';
    primary.detailLayout.value =
        (tabs: DetailTabAlignment.right, labels: DetailTabLabelAlignment.center, headers: HeaderDensity.compact);
    final intermediateFlush = primary.flushConfig();
    primary.detailLayout.value = AppConfiguration.defaultDetailLayout;
    final localFlush = primary.flushConfig();

    releaseFirst.complete();
    await first;
    await secondWrite.future;
    expect(primary.headerViewMode.value, 'table');
    expect(primary.detailLayout.value,
        (tabs: DetailTabAlignment.left, labels: DetailTabLabelAlignment.top, headers: HeaderDensity.compact));
    final firstPersisted = await reload();
    expect(firstPersisted.headerViewMode.value, 'text');
    expect(firstPersisted.detailLayout.value.tabs, DetailTabAlignment.center);
    expect(firstPersisted.detailLayout.value.labels, DetailTabLabelAlignment.top);

    releaseSecond.complete();
    await Future.wait([second, intermediateFlush, localFlush]);
    expect(identical(intermediateFlush, localFlush), isTrue);
    expect(writes.map((config) => config['detailTabAlignment']), ['center', 'right', 'left']);
    final restored = await reload();
    expect(restored.headerViewMode.value, 'table');
    expect(restored.detailLayout.value,
        (tabs: DetailTabAlignment.left, labels: DetailTabLabelAlignment.bottom, headers: HeaderDensity.dense));
    expect(primary.detailLayout.value, restored.detailLayout.value);

    other.detailLayout.value =
        (tabs: DetailTabAlignment.center, labels: DetailTabLabelAlignment.bottom, headers: HeaderDensity.dense);
    await other.flushConfig();
    expect((await reload()).detailLayout.value, other.detailLayout.value);
    expect(primary.detailLayout.value, other.detailLayout.value);
  });

  test('a failed child write can retry and cannot replace the theme library', () async {
    final theme = primary.snapshotTheme('Original');
    expect(await primary.saveTheme(theme), isTrue);
    await synchronizeTheme();
    final before = await file.readAsString();
    await expectLater(
      DesktopMultiWindow.saveDetailPreferences({'headerViewMode': 'text', 'activeSavedThemeName': 'Unknown'}),
      throwsA(isA<WindowChannelException>()),
    );
    expect(primary.headerViewMode.value, 'table');
    expect(await file.readAsString(), before);
    final backup = await file.rename('${file.path}.backup');
    final blocker = await Directory(file.path).create();

    detail.headerViewMode.value = 'text';
    await expectLater(detail.flushConfig(), throwsA(isA<WindowChannelException>()));
    expect(await backup.readAsString(), before);
    expect(primary.headerViewMode.value, 'table');
    expect(primary.themePreset, same(theme));
    expect(detail.themePreset.name, theme.name);
    await blocker.delete();
    await backup.rename(file.path);

    await detail.flushConfig();
    expect(requests.skip(1), [
      {'headerViewMode': 'text'},
      {'headerViewMode': 'text'}
    ]);
    final restored = await reload();
    expect(restored.headerViewMode.value, 'text');
    expect(restored.savedThemes.single.encoded, theme.encoded);
    expect(restored.themePreset, same(restored.savedThemes.single));
  });

  test('reverting a failed detail edit keeps it out of subsequent theme commits', () async {
    final theme = primary.snapshotTheme('Original');
    expect(await primary.saveTheme(theme), isTrue);
    await synchronizeTheme();

    final before = await file.readAsString();
    final backup = await file.rename('${file.path}.backup');
    final blocker = await Directory(file.path).create();
    detail.headerViewMode.value = 'text';
    await expectLater(detail.flushConfig(), throwsA(isA<WindowChannelException>()));
    expect(await backup.readAsString(), before);
    await blocker.delete();
    await backup.rename(file.path);

    detail.headerViewMode.value = 'table';
    await detail.flushConfig();
    expect(requests, [
      {'headerViewMode': 'text'},
    ]);
    expect((await reload()).headerViewMode.value, 'table');

    final next = primary.snapshotTheme('Next');
    expect(await primary.saveTheme(next), isTrue);
    final restored = await reload();
    expect(restored.savedThemes.map((theme) => theme.name), ['Original', 'Next']);
    expect(restored.themePreset.name, 'Next');
    expect(restored.headerViewMode.value, 'table');
  });
}
