import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide DropdownMenu;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/search_condition.dart';
import 'package:proxypin/ui/component/selection_action_bar.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/content/panel.dart';
import 'package:proxypin/ui/desktop/request/list.dart';
import 'package:proxypin/ui/desktop/request/request.dart';
import 'package:proxypin/ui/desktop/request/request_sequence.dart';
import 'package:proxypin/ui/desktop/request/search.dart';
import 'package:proxypin/utils/listenable_list.dart';

Future<DesktopRequestListState> pumpCaptureList(
  WidgetTester tester, {
  required double width,
  required List<HttpRequest> requests,
  AppConfiguration? configuration,
  Locale locale = const Locale('en'),
  double textScale = 1,
}) async {
  await tester.runAsync(() => AppLocalizations.delegate.load(locale));
  final key = GlobalKey<DesktopRequestListState>();
  final proxy = ProxyServer(Configuration.fromJson({}));
  final panel = NetworkTabController(proxyServer: proxy);
  final captureList = DesktopRequestListWidget(
    key: key,
    proxyServer: proxy,
    list: ListenableList(requests),
    panel: panel,
  );
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Center(
      child: SizedBox(
        width: width,
        child:
            configuration == null ? captureList : AppDisplaySettings(configuration: configuration, child: captureList),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return key.currentState!;
}

HttpRequest sampleRequest(String path, {HttpMethod method = HttpMethod.get, String? type, List<int>? body}) {
  final request = HttpRequest(method, 'https://example.test/$path');
  if (type != null) {
    request.response = HttpResponse(HttpStatus.ok)
      ..headers.add('Content-Type', type)
      ..request = request
      ..body = body;
  }
  return request;
}

void main() {
  testWidgets('both tabs and the action menu stay reachable in a narrow translated capture pane', (tester) async {
    final request = sampleRequest('request');
    final state = await pumpCaptureList(
      tester,
      width: 142,
      requests: [request],
      locale: const Locale('es'),
      textScale: 1.25,
    );
    final localizations = AppLocalizations.of(state.context)!;
    final tabBar = find.byType(TabBar);
    final appBar = find.byType(AppBar);
    final search = find.byType(Search);
    expect(tester.getBottomLeft(appBar).dy, lessThanOrEqualTo(tester.getTopLeft(search).dy));
    expect(tester.getBottomLeft(search).dy, lessThanOrEqualTo(tester.getTopLeft(find.byType(TabBarView)).dy));

    final domainTab = find.descendant(of: tabBar, matching: find.text(localizations.captureDomains));
    final sequenceTab = find.descendant(of: tabBar, matching: find.text(localizations.captureRequests));
    for (final tab in [domainTab, sequenceTab]) {
      expect(tester.widget<Text>(tab).maxLines, 1);
      expect(tester.widget<Text>(tab).overflow, TextOverflow.ellipsis);
      expect(tester.getRect(tabBar).contains(tester.getCenter(tab)), isTrue);
    }
    expect(domainTab.hitTestable(), findsOneWidget);
    expect(sequenceTab.hitTestable(), findsOneWidget);
    expect(find.byIcon(Icons.more_vert_outlined).hitTestable(), findsOneWidget);
    expect(find.byIcon(Icons.filter_list).hitTestable(), findsOneWidget);

    await tester.tap(sequenceTab);
    await tester.pumpAndSettle();
    expect(find.byType(RequestSequence).hitTestable(), findsOneWidget);
    await tester.tap(domainTab);
    await tester.pumpAndSettle();
    expect(find.text(request.remoteDomain()!).hitTestable(), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('mouse users can cancel and confirm batch deletion in a narrow capture pane', (tester) async {
    final selected = sampleRequest('selected');
    final retained = sampleRequest('retained');
    final state = await pumpCaptureList(
      tester,
      width: 142,
      requests: [selected, retained],
      locale: const Locale('es'),
      textScale: 1.25,
    );
    final localizations = AppLocalizations.of(state.context)!;
    const mouse = PointerDeviceKind.mouse;
    await tester.tap(find.text(selected.remoteDomain()!), kind: mouse);
    await tester.pumpAndSettle();

    final selectedRow = find.byKey(ValueKey(selected.requestId));
    final delete = find.byTooltip(localizations.delete);
    final cancelSelection = find.byTooltip(localizations.cancel);
    final toolbar = find.byType(SelectionActionBar);
    final scrollbar = find.ancestor(of: toolbar, matching: find.byType(Scrollbar));
    final dialog = find.byType(AlertDialog);

    Future<void> selectAndRevealActions() async {
      await tester.tap(selectedRow, buttons: kSecondaryMouseButton, kind: mouse);
      await tester.pumpAndSettle();
      await tester.tap(find.text(localizations.select), kind: mouse);
      await tester.pumpAndSettle();
      expect(state.selectionController.contains(selected.requestId), isTrue);
      expect(tester.widget<Scrollbar>(scrollbar).thumbVisibility, isTrue);
      expect(delete.hitTestable(), findsNothing);
      final scrollbarBounds = tester.getRect(scrollbar);
      await tester.dragFrom(
        scrollbarBounds.bottomLeft + const Offset(16, -4),
        Offset(scrollbarBounds.width, 0),
        kind: mouse,
      );
      await tester.pumpAndSettle();
      expect(delete.hitTestable(), findsOneWidget);
      expect(cancelSelection.hitTestable(), findsOneWidget);
    }

    await selectAndRevealActions();
    await tester.tap(delete, kind: mouse);
    await tester.pumpAndSettle();
    expect(find.text('${localizations.delete} 1 ${localizations.request}?'), findsOneWidget);
    await tester.tap(find.descendant(of: dialog, matching: find.text(localizations.cancel)), kind: mouse);
    await tester.pumpAndSettle();
    expect(state.container, unorderedEquals([selected, retained]));
    expect(state.isSelectionMode, isTrue);
    await tester.tap(cancelSelection, kind: mouse);
    await tester.pumpAndSettle();
    expect(state.isSelectionMode, isFalse);

    await selectAndRevealActions();
    await tester.tap(delete, kind: mouse);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: dialog, matching: find.text(localizations.confirm)), kind: mouse);
    await tester.pumpAndSettle(const Duration(seconds: 3));
    expect(state.isSelectionMode, isFalse);
    expect(state.container, [retained]);
    expect(selectedRow, findsNothing);
    expect(find.byKey(ValueKey(retained.requestId)).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('expanded rows and domain headers follow capture density with a portrait response', (tester) async {
    final configuration = await tester.runAsync(() => AppConfiguration.instance);
    final previousDensity = configuration!.captureListDensity;
    addTearDown(() => configuration.captureListDensity = previousDensity);
    configuration.captureListDensity = 'comfortable';

    final portrait =
        base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAAgCAIAAABch4VNAAAADElEQVR4nGNgGFgAAACAAAH0EuoZAAAAAElFTkSuQmCC');
    final request = sampleRequest('portrait', type: 'image/png', body: portrait);
    await pumpCaptureList(tester, width: 320, configuration: configuration, requests: [request]);
    final header = find.text(request.remoteDomain()!);
    await tester.tap(header);
    await tester.pumpAndSettle();

    final image = find.descendant(of: find.byType(RequestWidget), matching: find.byType(Image));
    await tester.runAsync(() => precacheImage(MemoryImage(portrait), tester.element(image)));
    await tester.pumpAndSettle();
    final row = find.byType(RequestWidget);
    final headerHitArea = find.ancestor(of: header, matching: find.byType(InkWell)).first;
    final sizes = <(double, double)>[];
    for (final density in AppConfiguration.captureDensities) {
      configuration.captureListDensity = density;
      configuration.globalChange.value = !configuration.globalChange.value;
      await tester.pumpAndSettle();
      sizes.add((tester.getSize(headerHitArea).height, tester.getSize(row).height));
    }
    expect(sizes.map((size) => size.$1), [40, 32, 24]);
    expect(sizes[0].$2, greaterThan(sizes[1].$2));
    expect(sizes[1].$2, greaterThan(sizes[2].$2));
    expect(tester.getSize(image).height, lessThanOrEqualTo(configuration.captureRowMetrics.imageSize));

    await tester.tap(row, buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    final localizations = AppLocalizations.of(tester.element(row))!;
    expect(find.text(localizations.copyCurl), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('top search filters both tabs and keeps conditions and Escape available', (tester) async {
    final json = sampleRequest('alpha', type: 'application/json');
    final html = sampleRequest('beta', method: HttpMethod.post, type: 'text/html');
    final state = await pumpCaptureList(tester, width: 150, requests: [json, html], locale: const Locale('zh'));
    final localizations = AppLocalizations.of(state.context)!;
    final search = find.byType(Search);
    final keyword = find.descendant(of: search, matching: find.byType(TextField));

    await tester.enterText(keyword, 'alpha');
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.currentView(), [json]);

    await tester.tap(find.text(localizations.captureRequests));
    await tester.pumpAndSettle();
    final jsonRow = find.byKey(ValueKey(json.requestId));
    final htmlRow = find.byKey(ValueKey(html.requestId));
    expect(jsonRow.hitTestable(), findsOneWidget);
    expect(htmlRow.hitTestable(), findsNothing);

    await tester.enterText(keyword, '');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byIcon(Icons.filter_list));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HTML'));
    await tester.pumpAndSettle();
    expect(jsonRow.hitTestable(), findsNothing);
    expect(htmlRow.hitTestable(), findsOneWidget);

    await tester.tap(find.descendant(of: search, matching: find.byIcon(Icons.search)));
    await tester.pumpAndSettle();
    final conditions = find.byType(SearchConditions);
    expect(tester.getTopLeft(conditions).dy, greaterThan(tester.getBottomLeft(search).dy));
    expect(tester.getSize(conditions).width, greaterThan(tester.getSize(search).width));
    final confirm = find.text(localizations.confirm);
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(conditions, findsNothing);
    expect(htmlRow.hitTestable(), findsOneWidget);

    await tester.longPress(htmlRow);
    await tester.pumpAndSettle();
    expect(state.isSelectionMode, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(state.isSelectionMode, isFalse);

    await tester.enterText(keyword, 'no-match');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(RequestWidget).hitTestable(), findsNothing);
    expect(keyword.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
