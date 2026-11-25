import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/component/widgets.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/desktop/left_menus/navigation.dart';
import 'package:proxypin/ui/desktop/setting/setting.dart';
import 'package:proxypin/ui/desktop/setting/settings_session.dart';
import 'package:proxypin/utils/system_fonts.dart';

void main() {
  late AppConfiguration configuration;
  setUpAll(() async {
    configuration = await AppConfiguration.instance;
    ProxyServer(Configuration.fromJson({'startup': false}));
    await Future.wait([SystemFonts.families(), SystemFonts.monospaceFamilies()]);
  });

  testWidgets('visited workspace panels receive the current theme and keep their form state', (tester) async {
    Future<void> show(Brightness brightness, int index) {
      return tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(
          body: Builder(builder: (context) {
            return LazyIndexedStack(index: index, children: [
              const SizedBox(),
              Material(
                key: const ValueKey('toolboxSurface'),
                color: Theme.of(context).colorScheme.surface,
                child: const TextField(),
              ),
            ]);
          }),
        ),
      ));
    }

    final surface = find.byKey(const ValueKey('toolboxSurface'));
    await show(Brightness.dark, 1);
    await tester.enterText(find.byType(TextField), 'draft');
    final dark = tester.widget<Material>(surface).color;
    await show(Brightness.light, 0);
    await show(Brightness.light, 1);
    await tester.pumpAndSettle();

    expect(tester.widget<Material>(surface).color, isNot(dark));
    expect(find.text('draft'), findsOneWidget);
  });

  Future<void> showWindow(
    WidgetTester tester,
    Widget home, {
    AppConfiguration? displayConfiguration,
    Size size = const Size(800, 600),
    double textScale = 1.0,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      theme: ThemeData(platform: TargetPlatform.linux),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => AppDisplaySettings(
        configuration: displayConfiguration ?? configuration,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
      home: home,
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openWorkspace(WidgetTester tester, ValueNotifier<int> selection) {
    addTearDown(selection.dispose);
    return showWindow(
      tester,
      Scaffold(
        body: Row(children: [
          LeftNavigationBar(appConfiguration: configuration, selectIndex: selection),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: selection,
              builder: (_, index, child) => Text('Selected $index'),
            ),
          ),
        ]),
      ),
    );
  }

  testWidgets('the sidebar keeps navigation selected when width changes', (tester) async {
    final previous = configuration.desktopNavigationExpanded;
    configuration.desktopNavigationExpanded = false;
    addTearDown(() => configuration.desktopNavigationExpanded = previous);
    final selection = ValueNotifier(0);
    await openWorkspace(tester, selection);

    final sidebar = find.byType(LeftNavigationBar);
    final settings = find.byTooltip('Settings');
    final favorites = find.byTooltip('Favorites');
    final settingsSize = tester.getSize(settings);
    expect(tester.getSize(sidebar).width, 48);
    expect(settingsSize, tester.getSize(favorites));
    expect(tester.getBottomLeft(settings).dy, tester.getBottomLeft(sidebar).dy - 6);
    expect(find.text('Favorites'), findsNothing);
    await tester.tap(find.byTooltip('Favorites'));
    await tester.pumpAndSettle();
    expect(find.text('Selected 1'), findsOneWidget);

    await tester.tap(find.byTooltip('Expand sidebar'));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 160);
    expect(tester.getSize(settings), settingsSize);
    expect(tester.getBottomLeft(settings).dy, tester.getBottomLeft(sidebar).dy - 6);
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Favorites'), findsOneWidget);
    expect(find.text('Selected 1'), findsOneWidget);
    expect(configuration.toJson()['desktopNavigationExpanded'], true);

    await tester.tap(find.byTooltip('Collapse sidebar'));
    await tester.pumpAndSettle();
    expect(tester.getSize(sidebar).width, 48);
    expect(configuration.toJson()['desktopNavigationExpanded'], false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings expose appearance, detail layout, proxy, rules and toolbar customization', (tester) async {
    final previousLayout = configuration.detailLayout.value;
    configuration.detailLayout.value = AppConfiguration.defaultDetailLayout;
    addTearDown(() => configuration.detailLayout.value = previousLayout);
    const windows = MethodChannel('mixin.one/desktop_multi_window');
    const router = MethodChannel('mixin.one/desktop_multi_window/channels');
    const windowManager = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windows, (_) async => {'windowId': 'settings', 'windowArgument': ''});
    messenger.setMockMethodCallHandler(windowManager, (_) async => null);
    messenger.setMockMethodCallHandler(router, (call) async {
      if (call.method == 'registerMethodHandler') return null;
      final message = call.arguments as Map;
      final method = message['method'] as String;
      if (method == 'saveDesktopSettings') return true;
      return handleDesktopSettingsMethod(method, null, 'settings');
    });
    addTearDown(() {
      for (final channel in [windows, router, windowManager]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    await DesktopMultiWindow.ensureInitialized(mainWindowId: 'main');
    final directory = Directory.systemTemp.createTempSync('proxypin-workspace-');
    addTearDown(() => directory.delete(recursive: true));
    final settingsConfiguration = AppConfiguration.withConfigFile(File('${directory.path}/ui_config.json'));
    final session = await DesktopSettingsSession.connect(settingsConfiguration);
    await showWindow(tester, Setting(windowId: 'settings', session: session),
        displayConfiguration: settingsConfiguration, size: const Size(420, 440), textScale: 1.25);
    final labels = AppLocalizations.of(tester.element(find.byType(Setting)))!;
    final closeAction = find.byType(DropdownButton<WindowCloseAction>);
    expect(closeAction.hitTestable(), findsOneWidget);
    await tester.tap(closeAction);
    await tester.pumpAndSettle();
    await tester.tap(find.text(labels.windowCloseMinimize).last);
    await tester.pumpAndSettle();
    expect(settingsConfiguration.windowCloseAction, WindowCloseAction.minimize);
    expect(find.text(labels.appFont), findsOneWidget);
    expect(find.text(labels.uiDensity), findsOneWidget);
    expect(find.text(labels.codeFont), findsOneWidget);

    Future<void> openSection(String title) async {
      final tab = find.widgetWithText(Tab, title);
      await tester.scrollUntilVisible(tab, 140,
          scrollable: find.descendant(
            of: find.byType(TabBar),
            matching: find.byType(Scrollable),
          ));
      await tester.tap(tab);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await openSection(labels.detailLayoutSettings);
    await tester.tap(find.byType(DropdownButton<DetailTabAlignment>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(labels.detailAlignRight).last);
    await tester.pumpAndSettle();
    expect(settingsConfiguration.detailLayout.value.tabs, DetailTabAlignment.right);
    expect(find.text(labels.detailHeaderDensity), findsOneWidget);

    await openSection(labels.proxy);
    expect(find.text(labels.proxyIgnoreDomain), findsOneWidget);
    final ssl = find.text(labels.httpsProxy);
    await tester.ensureVisible(ssl);
    await tester.pumpAndSettle();
    await tester.tap(ssl);
    await tester.pumpAndSettle();
    expect(find.text(labels.installCaLocal), findsOneWidget);
    await tester.tapAt(const Offset(4, 220));
    await tester.pumpAndSettle();

    await openSection(labels.trafficControl);
    expect(find.text(labels.requestRewrite), findsOneWidget);
    expect(find.text(labels.environmentVariables), findsOneWidget);

    await openSection(labels.customizeToolbar);
    expect(find.text(labels.restoreDefaults), findsOneWidget);
    expect(find.text(labels.pinToolsHint), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
