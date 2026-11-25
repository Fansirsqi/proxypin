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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:code_forge/code_forge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/manager/environment_manager.dart';
import 'package:proxypin/ui/component/chinese_font.dart';
import 'package:proxypin/ui/component/independent_window_frame.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/component/theme_presets.dart';
import 'package:proxypin/ui/component/window_resize_border.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/desktop/desktop.dart';
import 'package:proxypin/ui/mobile/mobile.dart';
import 'package:proxypin/utils/desktop_support.dart';
import 'package:proxypin/utils/navigator.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:window_manager/window_manager.dart';

import 'l10n/app_localizations.dart';

///主入口
///@author wanghongen
void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await RustLib.init();
  } catch (e) {
    // code_forge Rust FFI initialization may fail on iOS 14.x due to
    // deployment-target / cargokit-build incompatibilities. Degrade
    // gracefully instead of crashing the whole app at startup.
    print('RustLib.init failed: $e');
  }

  final windowController = Platforms.isDesktop() ? await DesktopMultiWindow.ensureInitialized() : null;

  var instance = AppConfiguration.instance;

  //多窗口
  final standaloneWindow = args.firstOrNull == DesktopMultiWindow.standaloneWindowArgument;
  if (args.firstOrNull == 'multi_window' || standaloneWindow) {
    final controller = windowController!;
    final windowArguments =
        standaloneWindow ? await DesktopMultiWindow.readStandaloneWindowArguments(stdin) : controller.arguments;
    final argument =
        windowArguments.isEmpty ? <String, dynamic>{} : jsonDecode(windowArguments) as Map<String, dynamic>;
    DesktopMultiWindow.initializeFromArguments(argument);
    var appConfiguration = await instance;
    appConfiguration.forwardDetailPreferences(DesktopMultiWindow.saveDetailPreferences);
    DesktopMultiWindow.onThemeChanged = appConfiguration.applyThemeSettings;
    if (DesktopMultiWindow.themeSettings case final settings?) {
      appConfiguration.applyThemeSettings(settings);
    }
    if (standaloneWindow) {
      await DesktopMultiWindow.prepareStandaloneClose(appConfiguration.flushConfig);
      unawaited(DesktopMultiWindow.listenForStandaloneEvents());
    }

    if (Platform.isMacOS) {
      windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }
    DesktopMultiWindow.prepareWindow();
    runApp(FluentApp(
      multiWindow(controller.windowId, argument),
      appConfiguration,
      independentWindow: true,
      resizeBorder: standaloneWindow,
      toolTitle: standaloneWindow ? DesktopMultiWindow.windowTitle : null,
    ));
    return;
  }

  var configuration = Configuration.instance;
  // 预热环境变量,避免第一个请求命中时才 IO
  unawaited(EnvironmentManager.preload());
  //移动端
  if (Platforms.isMobile()) {
    var appConfiguration = await instance;
    runApp(FluentApp(MobileHomePage((await configuration), appConfiguration), appConfiguration));
    return;
  }

  var appConfiguration = await instance;
  if (Platforms.isDesktop()) {
    DesktopMultiWindow.onSaveDetailPreferences = appConfiguration.saveWindowDetailPreferences;
    await DesktopSupport.initialize(appConfiguration);
    Map<String, dynamic>? lastTheme;
    void syncTheme() {
      final current = appConfiguration.themeSettings;
      if (mapEquals(lastTheme, current)) return;
      lastTheme = current;
      unawaited(DesktopMultiWindow.updateTheme(current));
    }

    syncTheme();
    appConfiguration.globalChange.addListener(syncTheme);
  }

  runApp(FluentApp(DesktopHomePage(await configuration, appConfiguration), appConfiguration));
}

class FluentApp extends StatelessWidget {
  final Widget home;
  final AppConfiguration appConfiguration;
  final bool independentWindow;
  final bool resizeBorder;
  final String? toolTitle;

  const FluentApp(this.home, this.appConfiguration,
      {super.key, this.independentWindow = false, this.resizeBorder = true, this.toolTitle});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
        valueListenable: appConfiguration.globalChange,
        builder: (_, current, __) {
          return MaterialApp(
            title: 'ProxyPin',
            debugShowCheckedModeBanner: false,
            navigatorKey: navigatorHelper.navigatorKey,
            theme: theme(Brightness.light),
            darkTheme: theme(Brightness.dark),
            themeMode: appConfiguration.themeMode,
            locale: appConfiguration.language,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) {
              Widget content = child!;
              if (independentWindow) {
                content = IndependentWindowFrame(toolTitle: toolTitle, child: content);
              }
              return AppDisplaySettings(
                configuration: appConfiguration,
                child: resizeBorder ? WindowResizeBorder(child: content) : content,
              );
            },
            home: home,
          );
        });
  }

  ThemeData theme(Brightness brightness) {
    bool isDark = brightness == Brightness.dark;
    bool useAmoled = isDark && appConfiguration.useAmoled;
    final colorScheme = appConfiguration.colorScheme(brightness);
    final preset = appConfiguration.themePreset;
    final hasPreset = preset != ThemePreset.custom;
    var themeData = ThemeData(
      brightness: brightness,
      useMaterial3: appConfiguration.useMaterial3,
      colorScheme: colorScheme,
      extensions: [ActiveThemePreset(preset)],
      canvasColor: hasPreset ? colorScheme.surface : null,
      cardColor: hasPreset ? colorScheme.surfaceContainer : null,
      hintColor: hasPreset ? colorScheme.onSurfaceVariant : null,
      scaffoldBackgroundColor: appConfiguration.usesClassicSurfaces && !isDark && Platforms.isMobile()
          ? colorScheme.surface
          : colorScheme.surfaceContainerLow,
      dividerColor: colorScheme.outlineVariant,
    );

    if (Platform.isWindows) {
      themeData = themeData.useSystemChineseFont();
    }

    final fontFamily = appConfiguration.appFontFamily;
    final fontScale = appConfiguration.appFontScale;
    final typography = themeData.typography;
    themeData = themeData.copyWith(
      textTheme: themeData.textTheme.apply(
        fontFamily: fontFamily,
        fontSizeFactor: fontScale,
        bodyColor: hasPreset ? colorScheme.onSurface : null,
        displayColor: hasPreset ? colorScheme.onSurface : null,
      ),
      primaryTextTheme: themeData.primaryTextTheme.apply(fontFamily: fontFamily, fontSizeFactor: fontScale),
      typography: typography.copyWith(
        englishLike: typography.englishLike.apply(fontSizeFactor: fontScale),
        dense: typography.dense.apply(fontSizeFactor: fontScale),
        tall: typography.tall.apply(fontSizeFactor: fontScale),
      ),
      visualDensity: appConfiguration.visualDensity,
    );

    if (!appConfiguration.useMaterial3) {
      themeData = themeData.copyWith(
        appBarTheme: themeData.appBarTheme.copyWith(
          iconTheme: themeData.iconTheme.copyWith(size: 20),
          backgroundColor: themeData.canvasColor,
          elevation: 0,
          titleTextStyle: themeData.textTheme.titleMedium,
        ),
        tabBarTheme: themeData.tabBarTheme.copyWith(
          labelColor: themeData.colorScheme.primary,
          indicatorColor: colorScheme.primary,
          unselectedLabelColor: themeData.textTheme.titleMedium?.color,
        ),
      );
    }

    if (useAmoled) {
      themeData = themeData.copyWith(
        canvasColor: Colors.black,
        cardColor: Colors.black,
        appBarTheme: themeData.appBarTheme.copyWith(backgroundColor: Colors.black, surfaceTintColor: Colors.black),
        cardTheme: themeData.cardTheme.copyWith(color: Colors.black, surfaceTintColor: Colors.black),
        bottomAppBarTheme: themeData.bottomAppBarTheme.copyWith(color: Colors.black, surfaceTintColor: Colors.black),
        bottomSheetTheme:
            themeData.bottomSheetTheme.copyWith(backgroundColor: Colors.black, surfaceTintColor: Colors.black),
        drawerTheme: themeData.drawerTheme.copyWith(backgroundColor: Colors.black, surfaceTintColor: Colors.black),
        popupMenuTheme: themeData.popupMenuTheme.copyWith(color: Colors.black, surfaceTintColor: Colors.black),
        navigationBarTheme:
            themeData.navigationBarTheme.copyWith(backgroundColor: Colors.black, surfaceTintColor: Colors.black),
        navigationRailTheme: themeData.navigationRailTheme.copyWith(backgroundColor: Colors.black),
      );
    }

    return themeData.copyWith(
        popupMenuTheme: hasPreset ? themeData.popupMenuTheme.copyWith(color: colorScheme.surfaceContainer) : null,
        dialogTheme: themeData.dialogTheme.copyWith(
            backgroundColor: useAmoled || hasPreset ? colorScheme.surface : null,
            surfaceTintColor: useAmoled ? Colors.black : null,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))));
  }
}
