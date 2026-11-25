import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/http/content_type.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/websocket.dart';
import 'package:proxypin/ui/component/model/search_model.dart';
import 'package:proxypin/ui/content/body.dart';
import 'package:proxypin/ui/content/panel.dart';
import 'package:proxypin/ui/desktop/request/domains.dart';
import 'package:proxypin/ui/desktop/request/list.dart';
import 'package:proxypin/ui/desktop/widgets/status_bar.dart';
import 'package:proxypin/utils/listenable_list.dart';

const baseline = bool.fromEnvironment('CAPTURE_BASELINE');

Widget app(Widget child) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

HttpRequest request(int index) => HttpRequest(HttpMethod.get, 'https://example.test/path/$index')
  ..hostAndPort = HostAndPort.of('https://example.test');

HttpResponse response(HttpRequest request, String type) {
  final message = HttpResponse(HttpStatus.ok)..request = request;
  message.headers.contentType = type;
  request.response = message;
  return message;
}

String label(int index) => '[row-${index.toString().padLeft(3, '0')}] abcdefghijklmnop';

WebSocketFrame frame(String text) {
  final bytes = Uint8List.fromList(utf8.encode(text));
  return WebSocketFrame(
      fin: true, opcode: 1, mask: false, payloadLength: bytes.length, maskingKey: 0, payloadData: bytes);
}

Future<DesktopRequestListState> capture(WidgetTester tester, List<HttpRequest> requests) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1100, 700);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<DesktopRequestListState>();
  final proxy = ProxyServer(Configuration.fromJson({}));
  final source = ListenableList<HttpRequest>(List.of(requests));
  await tester.pumpWidget(app(Column(children: [
    Expanded(child: DesktopRequestListWidget(key: key, proxyServer: proxy, list: source, panel: NetworkTabController())),
    DesktopStatusBar(proxyServer: proxy, container: source, requestListStateKey: key),
  ])));
  await tester.pumpAndSettle();
  return key.currentState!;
}

ScrollPosition position(WidgetTester tester, Finder list) =>
    tester.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable))).position;

void main() {
  for (final lateResponse in [false, true]) {
    testWidgets('scrolling an expanded domain immediately after ${lateResponse ? 'match exits' : 'deletion'}',
        (tester) async {
      final requests = List.generate(120, request);
      for (final item in requests) {
        response(item, 'application/json');
      }
      final state = await capture(tester, requests);
      if (lateResponse) {
        state.search(SearchModel()..responseContentTypes = {ContentType.json});
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('https://example.test'));
      await tester.pumpAndSettle();
      final list = find.descendant(of: find.byType(DomainList), matching: find.byType(ListView));
      final scroll = position(tester, list);
      expect(scroll.maxScrollExtent, greaterThan(1000));
      scroll.jumpTo(scroll.maxScrollExtent);
      await tester.pump();
      expect(tester.takeException(), isNull);
      final removed = requests.skip(2).toList();
      if (lateResponse) {
        for (final item in removed) {
          state.addResponse(ChannelContext(), response(item, 'text/plain'));
        }
      } else {
        state.remove(removed);
      }
      scroll.jumpTo(scroll.pixels - 300);
      await tester.pump(const Duration(milliseconds: 16));
      final error = tester.takeException();
      print('domain lateResponse=$lateResponse firstFrameError=$error');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpWidget(const SizedBox());
      expect(error, isNull);
    });
  }

  testWidgets('domain order, range selection and expansion survive late responses and clearing', (tester) async {
    final captured = List.generate(5, request);
    final state = await capture(tester, captured);
    final domain = state.domainListKey.currentState!;
    final host = find.text('https://example.test');
    Finder row(int index) => find.descendant(
        of: find.byType(DomainList), matching: find.byKey(ValueKey(captured[index].requestId)));
    void respond(int index, String type) => state.addResponse(ChannelContext(), response(captured[index], type));
    state.search(SearchModel()..responseContentTypes = {ContentType.json});
    for (final index in [4, 1, 3, 2]) {
      respond(index, 'application/json');
    }
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(domain.currentView(), [captured[4], captured[3], captured[2], captured[1]]);
    expect(row(3), findsNothing);
    await tester.tap(host);
    await tester.pumpAndSettle();
    expect(row(3), findsOneWidget);
    state.selectionController.selectOnly(captured[4].requestId);
    domain.selectRange(captured[1]);
    expect(domain.selectedRequests(), [captured[4], captured[3], captured[2], captured[1]]);
    respond(2, 'text/plain');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(domain.selectedRequests(), [captured[4], captured[3], captured[1]]);
    await tester.tap(host);
    await tester.pumpAndSettle();
    expect(row(3), findsNothing);
    domain.sort(false);
    await tester.tap(host);
    await tester.pumpAndSettle();
    expect(row(3), findsOneWidget);
    expect(domain.selectedRequests(), [captured[1], captured[3], captured[4]]);
    respond(0, 'application/json');
    state.clean();
    respond(0, 'application/json');
    await tester.pump(const Duration(milliseconds: 500));
    expect(host, findsNothing);
    expect(domain.currentView(), isEmpty);
    expect(state.selectionController.selectedIds, isEmpty);
    final labels = AppLocalizations.of(state.context)!;
    expect(find.text('${labels.request} 0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, skip: baseline);

  for (final websocket in [false, true]) {
    testWidgets('${websocket ? 'WS' : 'SSE'} replacement, tail, history and full copy', (tester) async {
      final captured = request(1);
      final message = response(captured, websocket ? 'application/octet-stream' : 'text/event-stream');
      if (websocket) {
        captured.headers.set('Upgrade', 'websocket');
        message.headers.set('Upgrade', 'websocket');
      }
      message.messages.addAll(List.generate(100, (index) => frame(label(index))));
      Widget view() => app(Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 460,
              child: HttpBodyWidget(httpMessage: message, previewHeight: 180, hideRequestRewrite: true),
            ),
          ));
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      final list = find.byType(ListView);
      final scroll = position(tester, list);
      expect(scroll.pixels, 0);
      expect(find.text(label(0)).hitTestable(), findsOneWidget);
      message.messages[0] = frame('replacement frame');
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.text(label(0)), findsNothing);
      expect(find.text('replacement frame').hitTestable(), findsOneWidget);
      for (var index = 0; index < 8 && scroll.extentAfter > 0; index++) {
        scroll.jumpTo(scroll.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      expect(scroll.extentAfter, 0);
      message.messages.add(frame(label(100)));
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(find.text(label(100)).hitTestable(), findsOneWidget);
      await tester.drag(list, const Offset(0, 250));
      await tester.pumpAndSettle();
      final history = scroll.pixels;
      expect(scroll.extentAfter, greaterThan(0));
      message.messages.add(frame(label(101)));
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(scroll.pixels, history);

      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      tester.state<SelectableRegionState>(find.byType(SelectableRegion)).selectAll();
      Actions.invoke(tester.element(find.byType(ShrinkWrappingViewport)), CopySelectionTextIntent.copy);
      await tester.pump();
      expect(clipboard, message.messages.map((entry) => entry.payloadDataAsString).join());
      await tester.tap(find.byTooltip('Copy'));
      await tester.pumpAndSettle();
      expect(clipboard, message.messagesText);
      await tester.pump(const Duration(seconds: 2));
    }, skip: baseline);
  }

  testWidgets('drag a partial selection across a viewport with one large wheel tick', (tester) async {
    final message = response(request(0), 'text/event-stream');
    message.messages.addAll(List.generate(100, (index) => frame(label(index))));
    final outer = ScrollController();
    addTearDown(outer.dispose);
    await tester.pumpWidget(app(Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 460,
        height: 260,
        child: SingleChildScrollView(
          key: const ValueKey('outer'),
          controller: outer,
          child: HttpBodyWidget(httpMessage: message, previewHeight: 180, hideRequestRewrite: true),
        ),
      ),
    )));
    await tester.pumpAndSettle();
    final viewport = baseline ? find.byKey(const ValueKey('outer')) : find.byType(ListView);
    final scroll = baseline ? outer.position : position(tester, viewport);
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final row = find.text(label(0));
    final start = tester.getTopLeft(row) + const Offset(1, 8);
    final mouse = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.text(label(1))) - const Offset(60, 0));
    await tester.pump();
    Actions.invoke(tester.element(find.text(label(1))), CopySelectionTextIntent.copy);
    await tester.pump();
    expect(clipboard, contains(label(0)));
    clipboard = null;
    final wheelAt = tester.getCenter(viewport);
    await tester.sendEventToBinding(PointerScrollEvent(
        kind: PointerDeviceKind.mouse, position: wheelAt, scrollDelta: const Offset(0, 600)));
    await tester.pumpAndSettle();
    expect(scroll.pixels, 600);
    final endpoint = List.generate(90, (index) => index + 10)
        .firstWhere((index) => find.text(label(index)).hitTestable().evaluate().isNotEmpty);
    await mouse.moveTo(tester.getTopLeft(find.text(label(endpoint))) + const Offset(120, 8));
    await tester.pumpAndSettle();
    await mouse.up();
    Actions.invoke(tester.element(find.text(label(endpoint))), CopySelectionTextIntent.copy);
    await tester.pump();
    final missing = List.generate(endpoint, (index) => index)
        .where((index) => !(clipboard ?? '').contains(label(index)))
        .toList();
    print('partial endpoint=$endpoint missing=$missing clipboard=$clipboard');
    expect(missing, isEmpty);
  });

  testWidgets('independent Body window retains the first selected text after wheel scroll and drag', (tester) async {
    final message = response(request(0), 'text/event-stream');
    message.messages.addAll(List.generate(100, (index) => frame(label(index))));
    await tester.pumpWidget(app(Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 460, height: 260, child: HttpBodyWidget(httpMessage: message, inNewWindow: true)),
    )));
    await tester.pumpAndSettle();
    final viewport = find.byType(ListView).last;
    final scroll = position(tester, viewport);
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final start = tester.getTopLeft(find.text(label(0))) + const Offset(1, 8);
    final mouse = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.text(label(1))) - const Offset(60, 0));
    await tester.pump();
    Actions.invoke(tester.element(find.text(label(1))), CopySelectionTextIntent.copy);
    await tester.pump();
    expect(clipboard, contains(label(0)));
    clipboard = null;
    await tester.sendEventToBinding(PointerScrollEvent(
        kind: PointerDeviceKind.mouse, position: tester.getCenter(viewport), scrollDelta: const Offset(0, 600)));
    await tester.pumpAndSettle();
    expect(scroll.pixels, 600);
    final endpoint = List.generate(90, (index) => index + 10)
        .firstWhere((index) => find.text(label(index)).hitTestable().evaluate().isNotEmpty);
    await mouse.moveTo(tester.getTopLeft(find.text(label(endpoint))) + const Offset(120, 8));
    await tester.pumpAndSettle();
    await mouse.up();
    Actions.invoke(tester.element(find.text(label(endpoint))), CopySelectionTextIntent.copy);
    await tester.pump();
    print('independent Body has first row=${clipboard?.contains(label(0))} endpoint=$endpoint clipboard=$clipboard');
    expect(clipboard, contains(label(0)));
  });
}
