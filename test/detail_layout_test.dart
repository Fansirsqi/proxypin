import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/search/highlight_text.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/content/detail_fields.dart';
import 'package:proxypin/ui/content/panel.dart';

void main() {
  late AppConfiguration configuration;

  setUpAll(() async {
    configuration = await AppConfiguration.instance;
  });

  testWidgets('request, response and Cookies use the shared table through the detail tabs', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    const cookieValue = 'second==';
    const setCookie = 'session=$cookieValue; Path=/; Secure; HttpOnly';
    final request = HttpRequest(HttpMethod.get, 'https://example.test/path?filter=first&filter=second%3D');
    request.headers.add('X-Request', 'request-id');
    request.headers.add('Cookie', 'session=first; session=$cookieValue');
    final response = HttpResponse(HttpStatus.ok);
    response.headers.add('X-Response', 'response-id');
    response.headers.add('Set-Cookie', setCookie);
    response.headers.add('Set-Cookie', 'session=third; Path=/other');
    String? clipboard;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final previousMode = configuration.headerViewMode.value;
    final previousLayout = configuration.detailLayout.value;
    final previousQueryExpanded = RequestParams.initiallyExpanded;
    configuration.headerViewMode.value = 'table';
    configuration.detailLayout.value = AppConfiguration.defaultDetailLayout;
    RequestParams.initiallyExpanded = false;
    addTearDown(() {
      configuration.headerViewMode.value = previousMode;
      configuration.detailLayout.value = previousLayout;
      RequestParams.initiallyExpanded = previousQueryExpanded;
    });

    final theme = ThemeData.dark();
    await tester.pumpWidget(MaterialApp(
      theme: theme.copyWith(
        textTheme: theme.textTheme.copyWith(bodySmall: const TextStyle(fontFamily: 'Detail Test', fontSize: 16)),
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Center(
        child: SizedBox(
          width: 310,
          child: NetworkTabController(httpRequest: request, httpResponse: response),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    Future<void> openTab(String label) async {
      final tab = find.text(label);
      await tester.ensureVisible(tab);
      await tester.tap(tab);
      await tester.pumpAndSettle();
      final controller = tester.widget<TabBar>(find.byType(TabBar)).controller!;
      expect(controller.index, ['Overview', 'Request', 'Response', 'Cookies'].indexOf(label));
    }

    Finder field(String name, String value) {
      return find.byWidgetPredicate((widget) => widget is DetailField && widget.name == name && widget.value == value);
    }

    Future<void> copy(Finder cell, String label, String expected) async {
      await tester.ensureVisible(cell);
      await tester.tap(cell, buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(clipboard, expected);
    }

    await openTab('Request');
    await tester.tap(find.text('Query Params'));
    await tester.pumpAndSettle();
    expect(field('filter', 'first'), findsOneWidget);
    expect(field('filter', 'second='), findsOneWidget);

    final heights = <String, List<double>>{};
    for (final density in ['Comfortable', 'Compact', 'Dense']) {
      await tester.tap(find.byTooltip('Detail layout'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Table row density'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(density));
      await tester.pumpAndSettle();
      expect(configuration.toJson()['detailHeaderDensity'], density.toLowerCase());

      for (final (tab, name, value) in [
        ('Request', 'X-Request', 'request-id'),
        ('Request', 'filter', 'second='),
        ('Response', 'X-Response', 'response-id'),
        ('Cookies', 'session', cookieValue),
        ('Cookies', 'session', 'third'),
      ]) {
        await openTab(tab);
        if (tab == 'Cookies' && field(name, value).evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            field(name, value),
            120,
            scrollable: find.descendant(of: find.byType(Cookies), matching: find.byType(Scrollable)).first,
          );
        }
        expect(field(name, value), findsWidgets, reason: '$tab: $name = $value at $density density');
        final row = field(name, value).first;
        heights.putIfAbsent(value, () => []).add(tester.getSize(row).height);
        for (final cell in [name, value]) {
          final editable = find.descendant(of: row, matching: find.text(cell));
          final style = tester.widget<EditableText>(editable).style;
          expect(style.fontFamily, 'Detail Test');
          expect(style.fontSize, 16);
        }
      }
    }
    for (final sizes in heights.values) {
      expect(sizes[0], greaterThan(sizes[1]));
      expect(sizes[1], greaterThan(sizes[2]));
    }

    for (final (tab, name, value) in [
      ('Request', 'X-Request', 'request-id'),
      ('Response', 'Set-Cookie', setCookie),
      ('Cookies', 'session', cookieValue),
    ]) {
      await openTab(tab);
      final row = field(name, value).first;
      await copy(find.descendant(of: row, matching: find.text(value)), 'Copy key', name);
      await copy(find.descendant(of: row, matching: find.text(name)), 'Copy value', value);
    }

    expect(field('session', 'first'), findsOneWidget);
    expect(field('session', cookieValue), findsNWidgets(2));
    expect(field('Path', '/other'), findsOneWidget);
    expect(field('Secure', ''), findsOneWidget);
    expect(field('HttpOnly', ''), findsOneWidget);
    for (final label in ['Request Cookies', 'Response Cookies']) {
      final header = find.text(label);
      await tester.scrollUntilVisible(
        header,
        label == 'Request Cookies' ? -120 : 120,
        scrollable: find.descendant(of: find.byType(Cookies), matching: find.byType(Scrollable)).first,
      );
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text(' · 2'), findsOneWidget);
      await tester.tap(header);
      await tester.pumpAndSettle();
    }

    await openTab('Request');
    await tester.tap(find.text('Headers'));
    await tester.pumpAndSettle();
    expect(field('X-Request', 'request-id'), findsNothing);
    await tester.tap(find.byTooltip('Show raw headers'));
    await tester.pumpAndSettle();
    expect(configuration.toJson()['headerViewMode'], 'text');
    final raw = find.byType(HighlightTextWidget);
    final rawEditor = tester.widget<EditableText>(find.descendant(of: raw, matching: find.byType(EditableText)));
    expect(rawEditor.style.fontFamily, 'Detail Test');
    expect(rawEditor.style.fontSize, 16);
    expect(tester.widget<HighlightTextWidget>(raw).text, contains('X-Request: request-id'));
    await openTab('Response');
    expect(tester.widget<HighlightTextWidget>(raw).text, contains('Set-Cookie: $setCookie'));
    await tester.tap(find.byTooltip('Show header table'));
    await tester.pumpAndSettle();
    expect(configuration.toJson()['headerViewMode'], 'table');
    await openTab('Request');
    expect(raw, findsNothing);
    expect(field('X-Request', 'request-id'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('short header and cookie rows match the overview and long values wrap', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 660));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final width = ValueNotifier(760.0);
    addTearDown(width.dispose);
    final previousMode = configuration.headerViewMode.value;
    final previousLayout = configuration.detailLayout.value;
    configuration.headerViewMode.value = 'table';
    configuration.detailLayout.value = AppConfiguration.defaultDetailLayout;
    addTearDown(() {
      configuration.headerViewMode.value = previousMode;
      configuration.detailLayout.value = previousLayout;
    });

    final longValue = '0123456789' * 26;
    final request = HttpRequest(HttpMethod.get, 'https://example.test/path');
    request.headers.add('Connection', 'keep-alive');
    request.headers.add('X-Request', longValue);
    request.headers.add('Cookie', 'mode=on; requestCookie=$longValue');
    final response = HttpResponse(HttpStatus.ok);
    response.headers.add('Date', 'Mon, 23 Nov 2026 05:34:17 GMT');
    response.headers.add('X-Response', longValue);
    response.headers.add('Set-Cookie', 'responseCookie=$longValue; Path=/end');

    final theme = ThemeData();
    await tester.pumpWidget(MaterialApp(
      theme: theme.copyWith(textTheme: theme.textTheme.copyWith(bodySmall: const TextStyle(fontSize: 14))),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Center(
        child: ValueListenableBuilder<double>(
          valueListenable: width,
          builder: (_, value, child) => SizedBox(width: value, child: child),
          child: NetworkTabController(httpRequest: request, httpResponse: response),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    Finder row(String name) => find.byWidgetPredicate((widget) => widget is DetailField && widget.name == name);
    final overviewHeight = tester.getSize(row('Status code')).height;

    for (final (tab, shortName, longNames) in [
      ('Request', 'Connection', ['X-Request']),
      ('Response', 'Date', ['X-Response']),
      ('Cookies', 'mode', ['requestCookie', 'responseCookie']),
    ]) {
      final tabLabel = find.text(tab);
      await tester.ensureVisible(tabLabel);
      await tester.tap(tabLabel);
      await tester.pumpAndSettle();
      if (tab == 'Response') expect(tester.getSize(row('Status code')).height, overviewHeight);
      expect(tester.getSize(row(shortName)).height, overviewHeight, reason: '$tab: $shortName');
      final view = tab == 'Cookies'
          ? find.descendant(of: find.byType(Cookies), matching: find.byType(CustomScrollView))
          : find.ancestor(of: row(shortName), matching: find.byType(CustomScrollView));
      final scrollable = find.descendant(of: view, matching: find.byType(Scrollable)).first;

      for (final name in longNames) {
        width.value = 310;
        await tester.pumpAndSettle();
        final field = row(name);
        await tester.scrollUntilVisible(field, 150, scrollable: scrollable);
        final cell = find.descendant(of: field, matching: find.byType(EditableText)).last;
        final narrowHeight = tester.getSize(cell).height;
        expect(narrowHeight, greaterThan(8 * 14 * 1.35));

        width.value = 760;
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(field, 150, scrollable: scrollable);
        expect(tester.getSize(cell).height, lessThan(narrowHeight));
      }
    }

    width.value = 310;
    await tester.pumpAndSettle();
    final path = find.descendant(of: find.byType(Cookies), matching: row('Path'));
    await tester.ensureVisible(path);
    await tester.pumpAndSettle();
    final viewport = tester.getRect(find.ancestor(of: path, matching: find.byType(CustomScrollView)));
    expect(viewport.contains(tester.getCenter(path)), isTrue);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('desktop tab group and labels align independently and tabs remain scrollable', (tester) async {
    final previousLayout = configuration.detailLayout.value;
    addTearDown(() => configuration.detailLayout.value = previousLayout);
    configuration.detailLayout.value = AppConfiguration.defaultDetailLayout;

    final request = HttpRequest(HttpMethod.get, 'https://example.test/path');
    final controller = NetworkTabController(httpRequest: request);
    final width = ValueNotifier(680.0);
    addTearDown(width.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Center(
        child: ValueListenableBuilder<double>(
          valueListenable: width,
          builder: (_, value, child) => SizedBox(width: value, child: child),
          child: controller,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Detail layout'));
    await tester.pumpAndSettle();
    expect(find.text('Tab bar alignment'), findsOneWidget);
    expect(find.text('Tab label alignment'), findsOneWidget);
    expect(find.text('Table row density'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    final overview = find.text('Overview');
    final left = tester.getTopLeft(overview);

    configuration.detailLayout.value = (
      tabs: DetailTabAlignment.center,
      labels: DetailTabLabelAlignment.top,
      headers: HeaderDensity.compact,
    );
    await tester.pumpAndSettle();
    final center = tester.getTopLeft(overview);
    expect(center.dx, greaterThan(left.dx));
    expect(center.dy, lessThan(left.dy));

    configuration.detailLayout.value = (
      tabs: DetailTabAlignment.right,
      labels: DetailTabLabelAlignment.bottom,
      headers: HeaderDensity.dense,
    );
    await tester.pumpAndSettle();
    final right = tester.getTopLeft(overview);
    expect(right.dx, greaterThan(center.dx));
    expect(right.dy, greaterThan(left.dy));
    expect(configuration.toJson()['detailTabAlignment'], 'right');
    expect(configuration.toJson()['detailTabLabelAlignment'], 'bottom');
    expect(configuration.toJson()['detailHeaderDensity'], 'dense');

    width.value = 215;
    await tester.pumpAndSettle();
    final tabBar = find.byType(TabBar);
    final drag = await tester.startGesture(tester.getCenter(tabBar), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(-25, 0));
    await tester.pump(const Duration(milliseconds: 25));
    await drag.moveBy(const Offset(-600, 0));
    await drag.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cookies'));
    await tester.pumpAndSettle();
    expect(tester.widget<TabBar>(tabBar).controller!.index, 3);
    expect(tester.takeException(), isNull);
  });
}
