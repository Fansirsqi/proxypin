import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/ui/configuration.dart';

void main() {
  late File file;
  late AppConfiguration primary;
  late AppConfiguration settings;

  setUp(() async {
    final directory = await Directory.systemTemp.createTemp('proxypin-settings-window-');
    addTearDown(() => directory.delete(recursive: true));
    file = File('${directory.path}/ui_config.json');
    primary = AppConfiguration.withConfigFile(file);
    settings = AppConfiguration.withConfigFile(file);
    settings.forwardDesktopSettings(
        primary.desktopSettings, primary.saveDesktopSettings, primary.previewSettingsDensity);
  });

  test('settings forwards changed fields without overwriting newer main-window preferences', () async {
    primary.windowSize = const Size(1100, 820);
    primary.panelRatio = 0.42;
    primary.setShowCaptureRowDetails(false);
    primary.headerViewMode.value = 'text';
    await primary.flushConfig();

    settings.language = const Locale('zh');
    settings.themeMode = ThemeMode.dark;
    settings.toolbarPins.value = ['script'];
    settings.setDisplayDensity(DisplayDensitySetting.fontSize, 85, commit: true);
    await settings.flushConfigForClose();

    expect(primary.headerViewMode.value, 'text');
    expect(primary.windowSize, const Size(1100, 820));
    expect(primary.panelRatio, 0.42);
    expect(primary.showCaptureRowDetails, isFalse);
    expect(primary.language, const Locale('zh'));
    expect(primary.themeMode, ThemeMode.dark);
    expect(primary.toolbarPins.value, ['script']);
    expect(primary.appFontScale, 0.85);
    final reopened = AppConfiguration.withConfigFile(file);
    await reopened.initConfig();
    expect(reopened.themeMode, ThemeMode.dark);
    expect(reopened.appFontScale, 0.85);
    expect(reopened.showCaptureRowDetails, isFalse);
    expect(reopened.headerViewMode.value, 'text');
  });

  test('density preview is live and only a committed value survives reopening', () async {
    settings.setDisplayDensity(DisplayDensitySetting.captureList, 50, commit: false);
    expect(primary.captureListDensity, 50);
    await settings.flushConfigForClose();
    expect(await file.exists(), isFalse);

    settings.setDisplayDensity(DisplayDensitySetting.captureList, 65, commit: true);
    await settings.flushConfigForClose();
    settings.setDisplayDensity(DisplayDensitySetting.captureList, 100, commit: false);
    expect(primary.captureListDensity, 100);
    primary.clearSettingsDensityPreviews();
    expect(primary.captureListDensity, 65);
  });

  test('named themes and clearing optional values survive a settings-window save', () async {
    final original = settings.snapshotTheme('Original');
    expect(await settings.saveTheme(original), isTrue);
    expect(primary.themePreset.name, 'Original');
    expect(primary.savedThemes.map((theme) => theme.encoded), [original.encoded]);

    settings.memoryCleanupThreshold = 512;
    await settings.flushConfigForClose();
    expect(primary.memoryCleanupThreshold, 512);
    settings.memoryCleanupThreshold = null;
    await settings.flushConfigForClose();
    expect(primary.memoryCleanupThreshold, isNull);
    final reopened = AppConfiguration.withConfigFile(file);
    await reopened.initConfig();
    expect(reopened.themePreset.name, 'Original');
    expect(reopened.memoryCleanupThreshold, isNull);
  });
}
