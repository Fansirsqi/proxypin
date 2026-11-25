/*
 * Copyright 2023 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:proxypin/mcp/mcp_listen_options.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/ui/component/saved_theme.dart';
import 'package:proxypin/ui/component/theme_presets.dart';
import 'package:proxypin/ui/component/utils.dart' show DarkPalette;
import 'package:proxypin/utils/platform.dart';

/// @author wanghongen
/// 2024/1/1
class ColorMapping {
  static final Map<String, Color> colors = {
    "Blue": Color(0xFF4A6CF7),
    "Pink": Colors.pink,
    "Red": Colors.red,
    "Purple": Colors.deepPurple,
    "Green": Colors.green,
    "Teal": Colors.teal,
    "Cyan": Colors.cyan,
    "Orange": Colors.orange,
    "Yellow": Colors.yellow[900]!,
    "Grey": Colors.grey,
  };

  static Color getColor(String colorName) {
    return colors[colorName] ?? Colors.blue;
  }

  static String getColorName(Color color) {
    return colors.entries.firstWhere((entry) => entry.value == color).key;
  }
}

class ThemeModel {
  ThemeMode mode;
  bool useMaterial3;
  bool useAmoled;
  String primary;
  String? secondary;
  String? tertiary;
  String? surface;
  PaletteStyle style;
  ThemePreset preset;
  SavedTheme? saved;

  ThemeModel({
    this.mode = ThemeMode.system,
    this.useMaterial3 = true,
    this.useAmoled = false,
    this.primary = 'Blue',
    this.secondary,
    this.tertiary,
    this.surface,
    this.style = PaletteStyle.classic,
    this.preset = ThemePreset.custom,
  });

  factory ThemeModel.fromJson(Map<dynamic, dynamic> config) => ThemeModel(
        mode: ThemeMode.values.firstWhere((mode) => mode.name == config['mode'], orElse: () => ThemeMode.system),
        useMaterial3: config['useMaterial3'] != false,
        useAmoled: config['useAmoled'] == true,
        primary: parseColor(config['themeColor']) == null ? 'Blue' : config['themeColor'] as String,
        secondary: parseColor(config['themeSecondary']) == null ? null : config['themeSecondary'] as String,
        tertiary: parseColor(config['themeTertiary']) == null ? null : config['themeTertiary'] as String,
        surface: parseColor(config['themeSurface']) == null ? null : config['themeSurface'] as String,
        style: PaletteStyle.values
            .firstWhere((style) => style.name == config['paletteStyle'], orElse: () => PaletteStyle.classic),
        preset: ThemePreset.values
            .firstWhere((preset) => preset.name == config['themePreset'], orElse: () => ThemePreset.custom),
      );

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'useMaterial3': useMaterial3,
        'useAmoled': useAmoled,
        'themeColor': primary,
        if (secondary != null) 'themeSecondary': secondary,
        if (tertiary != null) 'themeTertiary': tertiary,
        if (surface != null) 'themeSurface': surface,
        'paletteStyle': style.name,
        'themePreset': preset.name,
      };

  static final _hexColor = RegExp(r'^#?[0-9a-fA-F]{6}$');

  static Color? parseColor(Object? value) {
    if (value is! String) return null;
    if (ColorMapping.colors[value] case final color?) return color;
    if (!_hexColor.hasMatch(value)) return null;
    return Color(0xFF000000 | int.parse(value.replaceFirst('#', ''), radix: 16));
  }

  Color get themeColor => parseColor(primary) ?? ColorMapping.getColor('Blue');

  ThemePreset get activePreset => saved ?? preset;

  bool get usesClassicSurfaces =>
      activePreset == ThemePreset.custom && style == PaletteStyle.classic && surface == null;

  ColorScheme colorScheme(Brightness brightness) {
    final colors = palette(brightness);
    if (!useAmoled || brightness != Brightness.dark) return colors;
    return colors.copyWith(
      surface: Colors.black,
      surfaceDim: Colors.black,
      surfaceBright: Colors.black,
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: Colors.black,
      surfaceContainer: Colors.black,
      surfaceContainerHigh: Colors.black,
      surfaceContainerHighest: Colors.black,
    );
  }

  ColorScheme palette(Brightness brightness) => activePreset.colorScheme(brightness) ?? _customColorScheme(brightness);

  ColorScheme _customColorScheme(Brightness brightness) {
    ColorScheme fromSeed(Color seed, DynamicSchemeVariant variant) =>
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness, dynamicSchemeVariant: variant);
    final scheme = fromSeed(themeColor, style.variant);
    final secondarySeed = parseColor(secondary);
    final tertiarySeed = parseColor(tertiary);
    final secondaryScheme = secondarySeed == null ? null : fromSeed(secondarySeed, style.variant);
    final tertiaryScheme = tertiarySeed == null ? null : fromSeed(tertiarySeed, style.variant);
    final surfaceSeed = parseColor(surface);
    final surfaceScheme = surfaceSeed == null ? null : fromSeed(surfaceSeed, DynamicSchemeVariant.fidelity);
    var colors = scheme.copyWith(
      surface: surfaceScheme?.surface,
      onSurface: surfaceScheme?.onSurface,
      onSurfaceVariant: surfaceScheme?.onSurfaceVariant,
      surfaceDim: surfaceScheme?.surfaceDim,
      surfaceBright: surfaceScheme?.surfaceBright,
      surfaceContainerLowest: surfaceScheme?.surfaceContainerLowest,
      surfaceContainerLow: surfaceScheme?.surfaceContainerLow,
      surfaceContainer: surfaceScheme?.surfaceContainer,
      surfaceContainerHigh: surfaceScheme?.surfaceContainerHigh,
      surfaceContainerHighest: surfaceScheme?.surfaceContainerHighest,
      outline: surfaceScheme?.outline,
      outlineVariant: surfaceScheme?.outlineVariant,
      inverseSurface: surfaceScheme?.inverseSurface,
      onInverseSurface: surfaceScheme?.onInverseSurface,
      secondary: secondaryScheme?.primary,
      onSecondary: secondaryScheme?.onPrimary,
      secondaryContainer: secondaryScheme?.primaryContainer,
      onSecondaryContainer: secondaryScheme?.onPrimaryContainer,
      secondaryFixed: secondaryScheme?.primaryFixed,
      secondaryFixedDim: secondaryScheme?.primaryFixedDim,
      onSecondaryFixed: secondaryScheme?.onPrimaryFixed,
      onSecondaryFixedVariant: secondaryScheme?.onPrimaryFixedVariant,
      tertiary: tertiaryScheme?.primary,
      onTertiary: tertiaryScheme?.onPrimary,
      tertiaryContainer: tertiaryScheme?.primaryContainer,
      onTertiaryContainer: tertiaryScheme?.onPrimaryContainer,
      tertiaryFixed: tertiaryScheme?.primaryFixed,
      tertiaryFixedDim: tertiaryScheme?.primaryFixedDim,
      onTertiaryFixed: tertiaryScheme?.onPrimaryFixed,
      onTertiaryFixedVariant: tertiaryScheme?.onPrimaryFixedVariant,
    );
    if (usesClassicSurfaces) {
      colors = brightness == Brightness.light
          ? colors.copyWith(
              surface: Colors.white,
              onSurface: const Color(0xFF1F2329),
              outlineVariant: const Color(0xFFE4E6EB),
              surfaceContainerLow: const Color(0xFFF5F6F8),
              surfaceContainer: const Color(0xFFF0F1F3),
              surfaceContainerHigh: const Color(0xFFE9EBEF),
              surfaceContainerHighest: const Color(0xFFE4E6EB),
            )
          : colors.copyWith(
              surface: DarkPalette.panel,
              onSurface: DarkPalette.text1,
              onSurfaceVariant: DarkPalette.text2,
              outlineVariant: DarkPalette.border,
              surfaceContainerLow: DarkPalette.bg,
              surfaceContainer: DarkPalette.panel,
              surfaceContainerHigh: DarkPalette.panel,
              surfaceContainerHighest: DarkPalette.panel,
            );
    }
    return colors;
  }
}

enum ThemeColorRole { primary, secondary, tertiary, surface }

enum PaletteStyle {
  classic(DynamicSchemeVariant.tonalSpot),
  soft(DynamicSchemeVariant.tonalSpot),
  vivid(DynamicSchemeVariant.fidelity),
  neutral(DynamicSchemeVariant.neutral);

  final DynamicSchemeVariant variant;

  const PaletteStyle(this.variant);
}

enum DetailTabAlignment { left, center, right }

enum DetailTabLabelAlignment { top, center, bottom }

enum HeaderDensity { comfortable, compact, dense }

enum DisplayDensitySetting {
  fontSize,
  interface,
  captureList;

  double get minimum => this == fontSize ? 60 : AppConfiguration.minimumDisplayDensity;
}

class _DisplayDensity extends ValueNotifier<double> {
  static const double legacyDense = 60;

  final DisplayDensitySetting setting;
  double committed = AppConfiguration.defaultDisplayDensity;
  _DisplayDensity(this.setting) : super(AppConfiguration.defaultDisplayDensity);

  @override
  set value(double density) => restore(density);

  void restore(Object? density) {
    committed = normalize(density);
    super.value = committed;
  }

  set preview(double density) => super.value = density;

  double normalize(Object? value) => switch (value) {
        'compact' => 80,
        'dense' => legacyDense,
        final num percent when percent.isFinite =>
          percent.clamp(setting.minimum, AppConfiguration.maximumDisplayDensity).toDouble(),
        _ => AppConfiguration.defaultDisplayDensity,
      };
}

enum WindowCloseAction {
  ask,
  minimize,
  tray,
  quit;

  static WindowCloseAction fromConfig(Map<String, dynamic> config) {
    for (final action in values) {
      if (action.name == config['windowCloseAction']) return action;
    }
    return switch (config['minimizeToTray']) {
      true => tray,
      false => quit,
      _ => ask,
    };
  }
}

typedef DetailLayout = ({
  DetailTabAlignment tabs,
  DetailTabLabelAlignment labels,
  HeaderDensity headers,
});

class _DetailPreferenceNotifier<T> extends ValueNotifier<T> {
  _DetailPreferenceNotifier(super.value, this._encode, this._decode);

  final Map<String, String> Function(T) _encode;
  final T Function(Map<String, dynamic>) _decode;
  final Map<String, int> _localRevisions = {};

  Map<String, String> get preferences => _encode(value);

  @override
  set value(T next) {
    if (next == value) return;
    final previous = preferences;
    for (final entry in _encode(next).entries) {
      if (previous[entry.key] != entry.value) {
        _localRevisions.update(entry.key, (revision) => revision + 1, ifAbsent: () => 1);
      }
    }
    super.value = next;
  }

  void restore(Map<String, dynamic> config) => value = _decode(config);

  void publish(Map<String, String> changes, Map<String, int> revisionsAtEnqueue) {
    final merged = preferences;
    merged.updateAll((key, value) {
      if (revisionsAtEnqueue[key] != _localRevisions[key]) return value;
      return changes[key] ?? value;
    });
    super.value = _decode(merged);
  }
}

class AppConfiguration {
  static const String version = "1.4.0";

  ValueNotifier<bool> globalChange = ValueNotifier(false);

  ThemeModel _theme = ThemeModel();
  final Map<String, SavedTheme> _savedThemes = {};
  Locale? _language;

  //是否显示更新内容公告
  bool upgradeNoticeV40 = true;

  /// 是否启用画中画
  ValueNotifier<bool> pipEnabled = ValueNotifier(Platform.isAndroid);

  /// 显示画中画图标
  ValueNotifier<bool> pipIcon = ValueNotifier(Platform.isAndroid);

  /// Headers展示模式: table(逐行) / text(原始文本)
  ValueNotifier<String> get headerViewMode => _headerViewMode;

  final _headerViewMode = _DetailPreferenceNotifier<String>(
    'table',
    (mode) => {'headerViewMode': mode},
    (config) => config['headerViewMode'] == 'text' ? 'text' : 'table',
  );

  static const DetailLayout defaultDetailLayout = (
    tabs: DetailTabAlignment.left,
    labels: DetailTabLabelAlignment.center,
    headers: HeaderDensity.compact,
  );

  ValueNotifier<DetailLayout> get detailLayout => _detailLayout;

  final _detailLayout = _DetailPreferenceNotifier<DetailLayout>(
    defaultDetailLayout,
    (layout) => {
      'detailTabAlignment': layout.tabs.name,
      'detailTabLabelAlignment': layout.labels.name,
      'detailHeaderDensity': layout.headers.name,
    },
    (config) => (
      tabs: DetailTabAlignment.values.firstWhere(
        (value) => value.name == config['detailTabAlignment'],
        orElse: () => defaultDetailLayout.tabs,
      ),
      labels: DetailTabLabelAlignment.values.firstWhere(
        (value) => value.name == config['detailTabLabelAlignment'],
        orElse: () => defaultDetailLayout.labels,
      ),
      headers: HeaderDensity.values.firstWhere(
        (value) => value.name == config['detailHeaderDensity'],
        orElse: () => defaultDetailLayout.headers,
      ),
    ),
  );

  /// 底部导航栏
  bool bottomNavigation = true;

  /// 内存清理
  int? memoryCleanupThreshold;

  ///自动已读
  bool autoReadEnabled = true;

  /// 清空抓包前确认
  bool clearConfirm = false;

  /// 抓包列表行密度百分比
  final _captureDensity = _DisplayDensity(DisplayDensitySetting.captureList);
  final _showCaptureRowDetails = ValueNotifier(true);
  late final Listenable captureDisplayChange =
      Listenable.merge([_captureDensity, _showCaptureRowDetails, _appFontSize]);
  late final Listenable _mobileDisplayChanges =
      Listenable.merge([globalChange, _captureDensity, _showCaptureRowDetails]);
  double get captureListDensity => _captureDensity.value;
  set captureListDensity(double value) => _captureDensity.value = value;

  bool get showCaptureRowDetails => _showCaptureRowDetails.value;
  set showCaptureRowDetails(bool value) => _showCaptureRowDetails.value = value;

  /// 代码窗口字体族（请求体/响应体/脚本编辑器等），null 或空表示跟随界面字体
  String? editorFontFamily;

  /// 代码窗口字号
  double editorFontSize = 13;

  EditorColorScheme editorColorScheme = EditorColorScheme.followTheme;

  /// 整体界面字体（不含代码窗口），null/空表示跟随系统默认字体
  String? appFontFamily;

  final _appFontSize = _DisplayDensity(DisplayDensitySetting.fontSize);
  ValueListenable<double> get appFontSizeChange => _appFontSize;
  double get appFontScale => _appFontSize.value / 100;
  set appFontScale(double value) => _appFontSize.value = value * 100;

  /// 整体界面密度百分比
  final _interfaceDensity = _DisplayDensity(DisplayDensitySetting.interface);
  ValueListenable<double> get uiDensityChange => _interfaceDensity;
  late final Listenable interfaceDisplayChange = Listenable.merge([_appFontSize, _interfaceDensity]);
  double get uiDensity => _interfaceDensity.value;
  set uiDensity(double value) => _interfaceDensity.value = value;

  //桌面window大小
  Size? windowSize;

  //桌面window位置
  Offset? windowPosition;

  //Windows保存窗口位置时使用的DPI比例
  double? windowPositionScale;

  //左侧面板占比
  double panelRatio = 0.3;

  bool desktopNavigationExpanded = false;

  WindowCloseAction windowCloseAction = WindowCloseAction.ask;

  /// 是否启用 MCP 服务
  bool mcpEnabled = false;

  /// 导出给 AI 时是否脱敏 Authorization/Cookie
  bool mcpRedactEnabled = true;

  /// 移动端是否要求客户端使用访问令牌鉴权，默认开启。
  bool mcpAuthEnabled = true;

  /// 移动端访问 token；关闭鉴权时保留，重新开启后可复用。
  String? mcpToken;

  /// 移动端监听地址，仅支持 127.0.0.1 和 0.0.0.0；桌面端忽略此配置。
  String mcpBindAddress = McpListenOptions.anyAddress;

  /// MCP 服务监听端口。为 null/非法时使用默认端口 9127，
  /// 被占用时由服务回退到系统随机端口。
  int? mcpPort;

  /// 桌面端工具栏已固定的快捷功能 id 列表
  static const List<String> defaultToolbarPins = ['requestRewrite', 'requestMap', 'script'];

  final ValueNotifier<List<String>> toolbarPins = ValueNotifier(defaultToolbarPins);

  static const double minimumDisplayDensity = 5;
  static const double defaultDisplayDensity = 100;
  static const double maximumDisplayDensity = 120;

  void setDisplayDensity(DisplayDensitySetting setting, double value, {required bool commit}) {
    final density = _densityFor(setting);
    value = density.normalize(value);
    final needsWrite = commit && value != density.committed;
    if (commit) {
      density.value = value;
    } else {
      density.preview = value;
      _previewSettingsDensity?.call(setting, value);
    }
    if (needsWrite) flushConfig();
  }

  _DisplayDensity _densityFor(DisplayDensitySetting setting) => switch (setting) {
        DisplayDensitySetting.fontSize => _appFontSize,
        DisplayDensitySetting.interface => _interfaceDensity,
        DisplayDensitySetting.captureList => _captureDensity,
      };

  void previewSettingsDensity(DisplayDensitySetting setting, double value) {
    final density = _densityFor(setting);
    density.preview = density.normalize(value);
  }

  void clearSettingsDensityPreviews() {
    for (final setting in DisplayDensitySetting.values) {
      final density = _densityFor(setting);
      density.value = density.committed;
    }
  }

  void setShowCaptureRowDetails(bool value) {
    if (showCaptureRowDetails == value) return;
    showCaptureRowDetails = value;
    flushConfig();
  }

  double get captureRowScale => captureListDensity / 100;

  VisualDensity get visualDensity {
    final percent = uiDensity;
    const dense = _DisplayDensity.legacyDense;
    if (percent < dense) {
      final progress = (percent - minimumDisplayDensity) / (dense - minimumDisplayDensity);
      final spacing = lerpDouble(-4, -2, progress)!;
      return VisualDensity(horizontal: spacing, vertical: spacing);
    }
    final spacing = percent <= defaultDisplayDensity
        ? lerpDouble(-2, 0, (percent - dense) / (defaultDisplayDensity - dense))!
        : 4 * (percent - defaultDisplayDensity) / (maximumDisplayDensity - defaultDisplayDensity);
    return VisualDensity(horizontal: spacing, vertical: spacing);
  }

  CaptureRowMetrics get captureRowMetrics {
    final scale = captureRowScale;
    final contentScale = scale.clamp(0.0, 1.0);
    final textScale = contentScale * appFontScale;
    final padding = 7 * contentScale + (scale - contentScale) * (showCaptureRowDetails ? 22 : 15);
    return CaptureRowMetrics(
      leftWithDomain: 12,
      leftIndent: 26,
      leftSelection: 6,
      right: 10,
      top: padding,
      bottom: padding,
      titleSize: 13 * textScale,
      metaSize: 11 * textScale,
      gap: 3 * contentScale,
      iconGap: 10,
      iconWidth: 18 * contentScale,
      iconSize: 16 * contentScale,
      imageSize: 19 * contentScale,
    );
  }

  /// 修改显示类配置后立即重建界面并落盘
  void applyDisplaySetting(VoidCallback mutate) {
    mutate();
    globalChange.value = !globalChange.value;
    flushConfig();
  }

  final File? _configFile;

  AppConfiguration._() : _configFile = null;

  @visibleForTesting
  AppConfiguration.withConfigFile(File configFile) : _configFile = configFile;

  /// 单例
  static AppConfiguration? _instance;

  static Future<AppConfiguration> get instance async {
    if (_instance == null) {
      try {
        AppConfiguration configuration = AppConfiguration._();
        await configuration.initConfig();
        _instance = configuration;
      } catch (e) {
        logger.e("load config error: $e");
        _instance = AppConfiguration._();
      }
    }
    return _instance!;
  }

  static AppConfiguration? get current => _instance;

  ThemeMode get themeMode => _theme.mode;

  set themeMode(ThemeMode mode) {
    if (mode == _theme.mode) return;
    _theme.mode = mode;
    globalChange.value = !globalChange.value;
    flushConfig();
  }

  ///Material3
  bool get useMaterial3 => _theme.useMaterial3;

  set useMaterial3(bool value) {
    if (value == useMaterial3) return;
    _theme.useMaterial3 = value;
    globalChange.value = !globalChange.value;
    flushConfig();
  }

  /// 深色模式下使用 AMOLED 纯黑背景
  bool get useAmoled => _theme.useAmoled;

  set useAmoled(bool value) {
    if (value == useAmoled) return;
    _theme.useAmoled = value;
    globalChange.value = !globalChange.value;
    flushConfig();
  }

  Color get themeColor => _theme.themeColor;

  set setThemeColor(String colorName) => setPaletteColor(ThemeColorRole.primary, colorName);

  String? paletteColor(ThemeColorRole role) => switch (role) {
        ThemeColorRole.primary => _theme.primary,
        ThemeColorRole.secondary => _theme.secondary,
        ThemeColorRole.tertiary => _theme.tertiary,
        ThemeColorRole.surface => _theme.surface,
      };

  void setPaletteColor(ThemeColorRole role, String? value) {
    if (value != null && ThemeModel.parseColor(value) == null) return;
    if (role == ThemeColorRole.primary) value ??= 'Blue';
    if (value == paletteColor(role)) return;
    switch (role) {
      case ThemeColorRole.primary:
        _theme.primary = value!;
      case ThemeColorRole.secondary:
        _theme.secondary = value;
      case ThemeColorRole.tertiary:
        _theme.tertiary = value;
      case ThemeColorRole.surface:
        _theme.surface = value;
    }
    globalChange.value = !globalChange.value;
    flushConfig();
  }

  ColorScheme colorScheme(Brightness brightness) => _theme.colorScheme(brightness);

  ThemePreset get themePreset => _theme.activePreset;

  set themePreset(ThemePreset value) {
    if (value == themePreset) return;
    if (value is SavedTheme && _savedThemes[_themeKey(value.name)] != value) return;
    applyDisplaySetting(() {
      _theme.saved = value is SavedTheme ? value : null;
      if (value is! SavedTheme) _theme.preset = value;
    });
  }

  static String _themeKey(String name) => name.toLowerCase();

  List<SavedTheme> get savedThemes => List.unmodifiable(_savedThemes.values);

  SavedTheme snapshotTheme(String name) => SavedTheme(
        name: name,
        light: _theme.palette(Brightness.light),
        dark: _theme.palette(Brightness.dark),
        lightString: themePreset.stringColor(Brightness.light),
        darkString: themePreset.stringColor(Brightness.dark),
      );

  bool canSaveTheme(String name, {SavedTheme? replacing}) {
    final existing = _savedThemes[_themeKey(name)];
    return SavedTheme.isValidName(name) &&
        (existing == null || existing == replacing) &&
        (replacing == null || _savedThemes[_themeKey(replacing.name)] == replacing);
  }

  Future<bool> saveTheme(SavedTheme theme, {SavedTheme? replacing}) {
    _pendingFlush = null;
    return _enqueueConfigWrite(() async {
      if (!canSaveTheme(theme.name, replacing: replacing)) return false;
      final themes = Map.of(_savedThemes);
      final key = _themeKey(theme.name);
      if (replacing != null && _themeKey(replacing.name) != key) {
        themes.remove(_themeKey(replacing.name));
      }
      themes[key] = theme;
      await writeConfig(_configJson(themes.values, theme));
      _savedThemes
        ..clear()
        ..addAll(themes);
      _theme.saved = theme;
      globalChange.value = !globalChange.value;
      return true;
    });
  }

  bool get usesClassicSurfaces => _theme.usesClassicSurfaces;

  PaletteStyle get paletteStyle => _theme.style;

  set paletteStyle(PaletteStyle value) {
    if (value == _theme.style) return;
    _theme.style = value;
    globalChange.value = !globalChange.value;
    flushConfig();
  }

  Map<String, dynamic> get themeSettings => {
        ..._theme.toJson(),
        'editorColorScheme': editorColorScheme.name,
        if (_theme.saved case final saved?) 'activeSavedTheme': saved.encoded,
      };

  Object get materialThemeSettings => (
        useMaterial3,
        useAmoled,
        themePreset,
        paletteStyle,
        _theme.primary,
        _theme.secondary,
        _theme.tertiary,
        _theme.surface,
        appFontFamily,
      );

  void applyThemeSettings(Map<dynamic, dynamic> settings) {
    final theme = ThemeModel.fromJson(settings);
    if (settings['activeSavedTheme'] case final String encoded) {
      try {
        theme.saved = SavedTheme.decode(encoded);
      } on FormatException {
        return;
      }
    }
    _theme = theme;
    editorColorScheme = EditorColorScheme.fromConfig(settings['editorColorScheme']);
    globalChange.value = !globalChange.value;
  }

  ///language
  Locale? get language => _language;

  set language(Locale? locale) {
    if (locale == _language) return;
    _language = locale;
    globalChange.value = !globalChange.value;
    flushConfig();
  }

  Future<File> get _path async {
    if (_configFile case final file?) return file;
    if (Platforms.isDesktop()) {
      var userHome = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      return File('$userHome${Platform.pathSeparator}.proxypin${Platform.pathSeparator}ui_config.json');
    }

    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}ui_config.json');
  }

  /// 初始化配置
  Future<void> initConfig() async {
    // 读取配置文件
    var file = await _path;
    logger.d(file);
    var exits = await file.exists();
    if (!exits) {
      return;
    }
    var json = await file.readAsString();
    if (json.isEmpty) {
      return;
    }

    try {
      Map<String, dynamic> config = jsonDecode(json);
      _theme = ThemeModel.fromJson(config);
      _savedThemes.clear();
      if (config['savedThemes'] case final List entries) {
        for (final entry in entries) {
          try {
            final saved = SavedTheme.fromJson(entry);
            _savedThemes.putIfAbsent(_themeKey(saved.name), () => saved);
          } on FormatException {
            continue;
          }
        }
      }
      if (config['activeSavedThemeName'] case final String name) {
        _theme.saved = _savedThemes[_themeKey(name)];
      }

      upgradeNoticeV40 = config['upgradeNoticeV40'] ?? true;
      _language = config['language'] == null
          ? null
          : Locale.fromSubtags(languageCode: config['language'], scriptCode: config['languageScript']);
      pipEnabled.value = config['pipEnabled'] ?? true;
      pipIcon.value = config['pipIcon'] ?? false;
      _headerViewMode.restore(config);
      _detailLayout.restore(config);
      bottomNavigation = config['bottomNavigation'] ?? true;
      memoryCleanupThreshold = config['memoryCleanupThreshold'];
      autoReadEnabled = config['autoReadEnabled'] ?? true;
      clearConfirm = config['clearConfirm'] ?? false;

      _captureDensity.restore(config['captureListDensity']);
      showCaptureRowDetails = switch (config['showCaptureRowDetails']) {
        final bool value => value,
        _ => config['alwaysShowCaptureRowDetails'] == true || captureListDensity >= 40,
      };

      var fontFamily = config['editorFontFamily'];
      editorFontFamily = fontFamily is String && fontFamily.trim().isNotEmpty ? fontFamily.trim() : null;
      var fontSize = config['editorFontSize'];
      editorFontSize = fontSize is num && fontSize >= 8 && fontSize <= 32 ? fontSize.toDouble() : 13;
      editorColorScheme = EditorColorScheme.fromConfig(config['editorColorScheme']);

      var appFont = config['appFontFamily'];
      appFontFamily = appFont is String && appFont.trim().isNotEmpty ? appFont.trim() : null;
      var appScale = config['appFontScale'];
      appFontScale = appScale is num ? appScale.toDouble() : 1.0;
      _interfaceDensity.restore(config['uiDensity']);

      windowSize =
          config['windowSize'] == null ? null : Size(config['windowSize']['width'], config['windowSize']['height']);
      windowPosition = config['windowPosition'] == null
          ? null
          : Offset(config['windowPosition']['dx'], config['windowPosition']['dy']);
      final positionScale = config['windowPositionScale'];
      windowPositionScale = positionScale is num ? positionScale.toDouble() : null;
      if (config['panelRatio'] != null) {
        panelRatio = config['panelRatio'];
      }
      desktopNavigationExpanded = config['desktopNavigationExpanded'] == true;
      windowCloseAction = WindowCloseAction.fromConfig(config);

      mcpEnabled = config['mcpEnabled'] ?? false;
      mcpRedactEnabled = config['mcpRedactEnabled'] ?? true;
      mcpAuthEnabled = config['mcpAuthEnabled'] ?? true;
      mcpToken = config['mcpToken'] as String?;
      mcpBindAddress = McpListenOptions.normalizeAddress(config['mcpBindAddress']);
      var port = config['mcpPort'];
      mcpPort = port is int && port > 0 && port <= 65535 ? port : null;
      var pins = config['toolbarPins'];
      if (pins is List) {
        toolbarPins.value = pins.map((e) => e.toString()).toList();
      }
    } catch (e) {
      logger.e(e);
    }
  }

  Future<void> _writeQueue = Future<void>.value();
  Object get configWriteToken => _writeQueue;
  Future<void>? _pendingFlush;
  Future<void> Function(Map<String, String>)? _forwardDetailPreferences;
  Map<String, String> _lastSavedDetailPreferences = {};

  static const _themePreferenceKeys = {
    'mode',
    'useMaterial3',
    'useAmoled',
    'themeColor',
    'themeSecondary',
    'themeTertiary',
    'themeSurface',
    'paletteStyle',
    'themePreset',
    'savedThemes',
    'activeSavedThemeName',
  };
  static const _settingsKeys = {
    ..._themePreferenceKeys,
    'language',
    'languageScript',
    'appFontFamily',
    'appFontScale',
    'uiDensity',
    'captureListDensity',
    'editorFontFamily',
    'editorFontSize',
    'editorColorScheme',
    'windowCloseAction',
    'clearConfirm',
    'memoryCleanupThreshold',
    'toolbarPins',
    'headerViewMode',
    'detailTabAlignment',
    'detailTabLabelAlignment',
    'detailHeaderDensity',
  };
  Future<void> Function(Map<String, dynamic>)? _forwardSettings;
  void Function(DisplayDensitySetting, double)? _previewSettingsDensity;
  Map<String, dynamic> _savedSettings = {};

  Map<String, dynamic> get desktopSettings {
    final config = toJson();
    return {for (final key in _settingsKeys) key: config[key]};
  }

  void forwardDesktopSettings(
    Map<String, dynamic> settings,
    Future<void> Function(Map<String, dynamic>) send,
    void Function(DisplayDensitySetting, double) preview,
  ) {
    _applyDesktopSettings(settings);
    _savedSettings = desktopSettings;
    _forwardSettings = send;
    _previewSettingsDensity = preview;
  }

  Future<void> saveDesktopSettings(Map<String, dynamic> changes) async {
    if (changes.keys.any((key) => !_settingsKeys.contains(key))) {
      throw const FormatException('Invalid desktop setting');
    }
    final detailRevisions = {..._headerViewMode._localRevisions, ..._detailLayout._localRevisions};
    _pendingFlush = null;
    await _enqueueConfigWrite(() async {
      await writeConfig({...toJson(), ...changes});
      _applyDesktopSettings(changes, detailRevisions: detailRevisions);
    });
  }

  void _applyDesktopSettings(Map<String, dynamic> changes, {Map<String, int>? detailRevisions}) {
    final current = {...desktopSettings, ...changes};
    if (changes.keys.any(_themePreferenceKeys.contains)) {
      _theme = ThemeModel.fromJson(current);
      _savedThemes.clear();
      if (current['savedThemes'] case final List entries) {
        for (final entry in entries) {
          final saved = SavedTheme.fromJson(entry);
          _savedThemes.putIfAbsent(_themeKey(saved.name), () => saved);
        }
      }
      if (current['activeSavedThemeName'] case final String name) {
        _theme.saved = _savedThemes[_themeKey(name)];
      }
    }
    if (changes.containsKey('language') || changes.containsKey('languageScript')) {
      _language = current['language'] == null
          ? null
          : Locale.fromSubtags(languageCode: current['language'], scriptCode: current['languageScript']);
    }
    if (changes.containsKey('appFontFamily')) appFontFamily = changes['appFontFamily'] as String?;
    if (changes.containsKey('appFontScale')) appFontScale = (changes['appFontScale'] as num).toDouble();
    if (changes.containsKey('uiDensity')) _interfaceDensity.restore(changes['uiDensity']);
    if (changes.containsKey('captureListDensity')) _captureDensity.restore(changes['captureListDensity']);
    if (changes.containsKey('editorFontFamily')) editorFontFamily = changes['editorFontFamily'] as String?;
    if (changes.containsKey('editorFontSize')) editorFontSize = (changes['editorFontSize'] as num).toDouble();
    if (changes.containsKey('editorColorScheme')) {
      editorColorScheme = EditorColorScheme.fromConfig(changes['editorColorScheme']);
    }
    if (changes.containsKey('windowCloseAction')) windowCloseAction = WindowCloseAction.fromConfig(changes);
    if (changes.containsKey('clearConfirm')) clearConfirm = changes['clearConfirm'] as bool;
    if (changes.containsKey('memoryCleanupThreshold')) {
      memoryCleanupThreshold = changes['memoryCleanupThreshold'] as int?;
    }
    if (changes['toolbarPins'] case final List pins) toolbarPins.value = pins.cast<String>();
    if (detailRevisions == null) {
      _headerViewMode.restore(current);
      _detailLayout.restore(current);
    } else {
      final detail = {
        for (final key in _detailPreferences.keys)
          if (changes.containsKey(key)) key: changes[key] as String,
      };
      _headerViewMode.publish(detail, detailRevisions);
      _detailLayout.publish(detail, detailRevisions);
    }
    if (changes.keys.any((key) =>
        _themePreferenceKeys.contains(key) ||
        const {'language', 'languageScript', 'appFontFamily', 'editorFontFamily', 'editorFontSize', 'editorColorScheme'}
            .contains(key))) {
      globalChange.value = !globalChange.value;
    }
  }

  void forwardDetailPreferences(Future<void> Function(Map<String, String>) send) {
    _lastSavedDetailPreferences = _detailPreferences;
    _forwardDetailPreferences = send;
  }

  Map<String, String> get _detailPreferences => {
        ..._headerViewMode.preferences,
        ..._detailLayout.preferences,
      };

  Future<void> saveWindowDetailPreferences(Map<dynamic, dynamic> changes) async {
    final preferences = <String, String>{};
    for (final entry in changes.entries) {
      final valid = switch (entry.key) {
        'headerViewMode' => entry.value == 'table' || entry.value == 'text',
        'detailTabAlignment' => DetailTabAlignment.values.any((value) => value.name == entry.value),
        'detailTabLabelAlignment' => DetailTabLabelAlignment.values.any((value) => value.name == entry.value),
        'detailHeaderDensity' => HeaderDensity.values.any((value) => value.name == entry.value),
        _ => false,
      };
      if (!valid) throw FormatException('Invalid detail preference: ${entry.key}');
      preferences[entry.key as String] = entry.value as String;
    }
    if (preferences.isEmpty) return;

    final revisionsAtEnqueue = {
      ..._headerViewMode._localRevisions,
      ..._detailLayout._localRevisions,
    };
    _pendingFlush = null;
    await _enqueueConfigWrite(() async {
      await writeConfig({...toJson(), ...preferences});
      _headerViewMode.publish(preferences, revisionsAtEnqueue);
      _detailLayout.publish(preferences, revisionsAtEnqueue);
    });
  }

  Future<T> _enqueueConfigWrite<T>(Future<T> Function() operation) {
    final result = _writeQueue.then((_) => operation());
    _writeQueue = result.then<void>((_) {}, onError: (Object error, StackTrace stackTrace) {
      logger.e('Failed to write UI configuration', error: error, stackTrace: stackTrace);
    });
    return result;
  }

  /// 刷新配置文件
  Future<void> flushConfig() {
    if (_pendingFlush case final pending?) return pending;
    late final Future<void> operation;
    operation = _enqueueConfigWrite(() async {
      if (identical(_pendingFlush, operation)) _pendingFlush = null;
      final send = _forwardDetailPreferences;
      if (send == null) {
        await writeConfig(toJson());
        return;
      }
      final changes = {
        for (final entry in _detailPreferences.entries)
          if (_lastSavedDetailPreferences[entry.key] != entry.value) entry.key: entry.value,
      };
      if (changes.isEmpty) return;
      await send(changes);
      _lastSavedDetailPreferences.addAll(changes);
    });
    return _pendingFlush = operation;
  }

  Future<void> flushConfigForClose() async {
    while (true) {
      final flush = flushConfig();
      final writes = _writeQueue;
      await flush;
      if (identical(writes, _writeQueue)) return;
    }
  }

  @protected
  Future<void> writeConfig(Map<String, dynamic> config) async {
    if (_forwardSettings case final send?) {
      final changes = {
        for (final key in _settingsKeys)
          if (jsonEncode(config[key]) != jsonEncode(_savedSettings[key])) key: config[key],
      };
      if (changes.isNotEmpty) {
        await send(changes);
        _savedSettings.addAll(changes);
      }
      return;
    }
    if (_forwardDetailPreferences != null) throw StateError('Only the main window can write UI configuration');
    var file = await _path;
    if (await FileSystemEntity.isLink(file.path)) {
      file = File(await file.resolveSymbolicLinks());
    }
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.ui-config-');
    try {
      final staged = File('${temporary.path}${Platform.pathSeparator}ui_config.json');
      if (await file.exists()) await file.copy(staged.path);
      await staged.writeAsString(jsonEncode(config), flush: true);
      await staged.rename(file.path);
    } finally {
      try {
        await temporary.delete(recursive: true);
      } on FileSystemException catch (error) {
        logger.w('Failed to remove temporary UI configuration directory', error: error);
      }
    }
  }

  Map<String, dynamic> toJson() => _configJson(_savedThemes.values, _theme.saved);

  Map<String, dynamic> _configJson(Iterable<SavedTheme> themes, SavedTheme? active) {
    return {
      ..._theme.toJson(),
      if (themes.isNotEmpty) 'savedThemes': [for (final saved in themes) saved.toJson()],
      if (active != null) 'activeSavedThemeName': active.name,
      'upgradeNoticeV40': upgradeNoticeV40,
      "language": _language?.languageCode,
      "languageScript": _language?.scriptCode,
      ..._detailPreferences,
      "autoReadEnabled": autoReadEnabled,
      "clearConfirm": clearConfirm,
      "captureListDensity": _captureDensity.committed,
      "showCaptureRowDetails": showCaptureRowDetails,
      "editorFontFamily": editorFontFamily,
      "editorFontSize": editorFontSize,
      "editorColorScheme": editorColorScheme.name,
      "appFontFamily": appFontFamily,
      "appFontScale": _appFontSize.committed / 100,
      "uiDensity": _interfaceDensity.committed,
      if (memoryCleanupThreshold != null) 'memoryCleanupThreshold': memoryCleanupThreshold,
      if (Platforms.isMobile()) 'pipEnabled': pipEnabled.value,
      if (Platforms.isMobile()) 'pipIcon': pipIcon.value ? true : null,
      if (Platforms.isMobile()) 'bottomNavigation': bottomNavigation,
      if (Platforms.isDesktop())
        "windowSize": windowSize == null ? null : {"width": windowSize?.width, "height": windowSize?.height},
      if (Platforms.isDesktop())
        "windowPosition": windowPosition == null ? null : {"dx": windowPosition?.dx, "dy": windowPosition?.dy},
      if (Platform.isWindows) 'windowPositionScale': windowPositionScale,
      if (Platforms.isDesktop()) 'panelRatio': panelRatio,
      if (Platforms.isDesktop()) 'desktopNavigationExpanded': desktopNavigationExpanded,
      if (Platforms.isDesktop()) 'windowCloseAction': windowCloseAction.name,
      if (Platforms.isDesktop()) 'toolbarPins': toolbarPins.value,
      // MCP 配置所有平台都写入
      'mcpEnabled': mcpEnabled,
      'mcpRedactEnabled': mcpRedactEnabled,
      'mcpAuthEnabled': mcpAuthEnabled,
      if (mcpToken != null) 'mcpToken': mcpToken,
      'mcpBindAddress': mcpBindAddress,
      if (mcpPort != null) 'mcpPort': mcpPort,
    };
  }
}

/// 抓包列表行的尺寸参数（由 [AppConfiguration.captureListDensity] 推导）
class CaptureRowMetrics {
  final double leftWithDomain;
  final double leftIndent;
  final double leftSelection;
  final double right;
  final double top;
  final double bottom;
  final double titleSize;
  final double metaSize;
  final double gap;
  final double iconGap;
  final double iconWidth;
  final double iconSize;
  final double imageSize;

  const CaptureRowMetrics({
    required this.leftWithDomain,
    required this.leftIndent,
    required this.leftSelection,
    required this.right,
    required this.top,
    required this.bottom,
    required this.titleSize,
    required this.metaSize,
    required this.gap,
    required this.iconGap,
    required this.iconWidth,
    required this.iconSize,
    required this.imageSize,
  });

  EdgeInsets padding({required bool displayDomain, required bool selectedInSelectionMode}) {
    final left = selectedInSelectionMode ? leftSelection : (displayDomain ? leftWithDomain : leftIndent);
    return EdgeInsets.only(left: left, right: right, top: top, bottom: bottom);
  }
}

class AppDisplaySettings extends InheritedNotifier<Listenable> {
  final AppConfiguration configuration;

  AppDisplaySettings(
      {super.key, required this.configuration, required Widget child, bool includeCaptureChanges = false})
      : super(
          notifier: includeCaptureChanges ? configuration._mobileDisplayChanges : configuration.globalChange,
          child: _CaptureDisplaySettings(configuration, child: child),
        );

  static AppConfiguration? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppDisplaySettings>()?.configuration ?? AppConfiguration.current;

  static AppConfiguration? captureOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CaptureDisplaySettings>()?.configuration ?? AppConfiguration.current;
}

class _CaptureDisplaySettings extends InheritedNotifier<Listenable> {
  final AppConfiguration configuration;

  _CaptureDisplaySettings(this.configuration, {required super.child})
      : super(notifier: configuration.captureDisplayChange);
}
