import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/http/content_type.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/websocket.dart';
import 'package:proxypin/ui/component/model/search_model.dart';
import 'package:proxypin/ui/content/body.dart';
import 'package:proxypin/ui/content/panel.dart';
import 'package:proxypin/ui/desktop/request/list.dart';
import 'package:proxypin/ui/desktop/widgets/status_bar.dart';
import 'package:proxypin/utils/listenable_list.dart';

const _baseline = bool.fromEnvironment('CAPTURE_BASELINE');

class _Channel implements Channel {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountingSearch extends SearchModel {
  _CountingSearch([super.keyword]);

  int calls = 0;

  @override
  bool filter(HttpRequest request, HttpResponse? response) {
    calls++;
    return super.filter(request, response);
  }
}

class _CountingFrame extends WebSocketFrame {
  _CountingFrame(int index, {int length = 256})
      : super(
          fin: true,
          opcode: 1,
          mask: false,
          maskingKey: 0,
          payloadLength: length,
          payloadData: Uint8List.fromList(utf8.encode(label(index, length))),
          time: DateTime.fromMillisecondsSinceEpoch(index * 1000),
        );

  static String label(int index, int length) => 'frame $index ${'x' * (length - 8)}';
  static int reads = 0;

  @override
  String get payloadDataAsString {
    reads++;
    return super.payloadDataAsString;
  }
}

class _ObservedRequestList extends DesktopRequestListWidget {
  const _ObservedRequestList({
    required super.key,
    required super.proxyServer,
    required super.list,
    required super.panel,
  });

  @override
  _ObservedRequestListState createState() => _ObservedRequestListState();
}

class _ObservedRequestListState extends DesktopRequestListState {
  final snapshots = <int>[];

  @override
  List<HttpRequest>? currentView() {
    final view = super.currentView();
    if (view != null) snapshots.add(view.length);
    return view;
  }
}

Widget _app(Widget child, {ThemeData? theme, double fontScale = 1}) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(fontScale)),
        child: child!,
      ),
      home: Scaffold(body: child),
    );

HttpRequest _request(int index) => HttpRequest(HttpMethod.get, 'https://example.test/needle/$index');

Future<_ObservedRequestListState> _capture(WidgetTester tester, List<HttpRequest> retained) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1100, 700);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final key = GlobalKey<_ObservedRequestListState>();
  final proxy = ProxyServer(Configuration.fromJson({}));
  final requests = ListenableList<HttpRequest>(retained);
  await tester.pumpWidget(_app(Column(children: [
    Expanded(child: _ObservedRequestList(key: key, proxyServer: proxy, list: requests, panel: NetworkTabController())),
    DesktopStatusBar(proxyServer: proxy, container: requests, requestListStateKey: key),
  ])));
  await tester.pumpAndSettle();
  return key.currentState!;
}

HttpResponse _respond(HttpRequest request, String type) {
  final response = HttpResponse(HttpStatus.ok)..request = request;
  response.headers.contentType = type;
  request.response = response;
  return response;
}

void main() {
  testWidgets('three status updates with 10,000 retained requests', (tester) async {
    final state = await _capture(tester, List.generate(10000, _request));
    state.snapshots.clear();
    for (var frame = 0; frame < 3; frame++) {
      for (var event = 0; event < 4; event++) {
        state.add(_Channel(), _request(10000 + frame * 4 + event));
      }
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(state.snapshots, _baseline ? [10004, 10008, 10012] : isEmpty);
    print('status frames=3 additions=12 snapshots=${state.snapshots}');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(const SizedBox());
  });

  for (final retained in [1000, 10000]) {
    for (final expanded in [false, true]) {
      testWidgets('four matching arrivals with $retained retained, expanded=$expanded', (tester) async {
        final state = await _capture(tester, List.generate(retained, _request));
        final domain = state.domainListKey.currentState!;
        if (expanded) {
          domain.containerMap.values.single.toggleExpanded();
          await tester.pumpAndSettle();
        }
        final model = _CountingSearch('needle');
        domain.search(model);
        await tester.pump();
        final initial = model.calls;
        model.calls = 0;
        for (var event = 0; event < 4; event++) {
          state.add(_Channel(), _request(retained + event));
        }
        final immediate = model.calls;
        final pump = Stopwatch()..start();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        pump.stop();
        expect(immediate, 4);
        expect(model.calls - immediate, _baseline ? retained + 5 : 0);
        expect(domain.currentView(), hasLength(retained + 4));
        print('domain retained=$retained expanded=$expanded initial=$initial per_burst=$immediate '
            'rebuild=${model.calls - immediate} pump_us=${pump.elapsedMicroseconds}');
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('late responses, query changes and deletions update order, status and selection', (tester) async {
    final older = _request(1);
    final middle = _request(2);
    final newer = _request(3);
    final other = HttpRequest(HttpMethod.get, 'https://other.test/other');
    final state = await _capture(tester, [older, middle, newer, other]);
    final domain = state.domainListKey.currentState!;
    final labels = AppLocalizations.of(state.context)!;
    Finder status(String label, int count) => find.text('$label $count');
    final context = ChannelContext();
    final model = _CountingSearch()..responseContentTypes = {ContentType.json};
    void respond(HttpRequest request, String type) => state.addResponse(context, _respond(request, type));

    expect(status(labels.request, 4), findsOneWidget);
    state.search(model);
    await tester.pump();
    expect(status(labels.filtered, 4), findsOneWidget);
    expect(domain.currentView(), isEmpty);
    model.calls = 0;
    respond(newer, 'application/json');
    respond(older, 'application/json');
    respond(middle, 'application/json');
    await tester.pump();
    expect(status(labels.filtered, 1), findsOneWidget);
    expect(domain.currentView(), [newer, middle, older]);
    expect(model.calls, 3);
    domain.containerMap.values.first.toggleExpanded();
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey(middle.requestId)), findsOneWidget);
    domain.sort(false);
    await tester.pump();
    expect(domain.currentView(), [older, middle, newer]);
    state.selectionController.selectOnly(middle.requestId);
    await tester.pump();

    respond(middle, 'text/plain');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(domain.currentView(), [older, newer]);
    expect(status(labels.filtered, 2), findsOneWidget);
    expect(state.selectionController.selectedIds, isEmpty);
    expect(find.byKey(ValueKey(middle.requestId)), findsNothing);

    state.remove([newer]);
    await tester.pump();
    expect(status(labels.request, 3), findsOneWidget);
    expect(status(labels.filtered, 2), findsOneWidget);
    respond(newer, 'application/json');
    expect(domain.currentView(), [older]);
    domain.deleteHost('https://other.test');
    await tester.pump();
    expect(status(labels.request, 2), findsOneWidget);
    expect(status(labels.filtered, 1), findsOneWidget);

    state.search(SearchModel('other'));
    await tester.pump();
    expect(status(labels.filtered, 2), findsOneWidget);
    state.search(SearchModel());
    await tester.pump();
    expect(domain.currentView(), [older, middle]);
    expect(status(labels.filtered, 2), findsNothing);
    state.clean();
    await tester.pumpAndSettle();
    expect(status(labels.request, 0), findsOneWidget);
    expect(domain.currentView(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  }, skip: _baseline);

  testWidgets('capture arrivals keep the applied keyword while the next edit is pending', (tester) async {
    final original = _request(1);
    final state = await _capture(tester, [original]);
    final search = find.byType(TextField);
    final channel = _Channel();
    await tester.enterText(search, 'needle');
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.currentView(), [original]);

    await tester.enterText(search, 'replacement');
    final matchingApplied = _request(2);
    final matchingDraft = HttpRequest(HttpMethod.get, 'https://example.test/replacement');
    state.add(channel, matchingApplied);
    state.add(channel, matchingDraft);
    expect(state.currentView(), [matchingApplied, original]);
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.currentView(), [matchingDraft]);
    await tester.pumpWidget(const SizedBox());
  }, skip: _baseline);

  for (final websocket in [false, true]) {
    for (final retained in [100, 1000]) {
      testWidgets('${websocket ? 'WS' : 'SSE'} selected body with $retained retained frames', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1100, 700);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final request = _request(1);
        final response = _respond(request, websocket ? 'application/octet-stream' : 'text/event-stream');
        if (websocket) {
          request.headers.set('Upgrade', 'websocket');
          response.headers.set('Upgrade', 'websocket');
        }
        response.messages.addAll(List.generate(retained, _CountingFrame.new));
        final controller = NetworkTabController(httpRequest: request, httpResponse: response, initialTab: 2);
        _CountingFrame.reads = 0;
        await tester.pumpWidget(_app(controller));
        await tester.pumpAndSettle();
        final initial = _CountingFrame.reads;
        expect(find.text('Data'), findsOneWidget);

        _CountingFrame.reads = 0;
        response.messages.add(_CountingFrame(retained));
        controller.changeState();
        final append = Stopwatch()..start();
        await tester.pump();
        append.stop();
        final appendReads = _CountingFrame.reads;
        _CountingFrame.reads = 0;
        tester.view.physicalSize = const Size(830, 700);
        final resize = Stopwatch()..start();
        await tester.pump();
        resize.stop();
        final resizeReads = _CountingFrame.reads;
        final bound = _baseline ? retained + 1 : lessThan(30);
        expect(appendReads, bound);
        expect(resizeReads, bound);
        print('${websocket ? 'ws' : 'sse'} retained=$retained initial=$initial append=$appendReads '
            'resize=$resizeReads append_us=${append.elapsedMicroseconds} resize_us=${resize.elapsedMicroseconds}');

        controller.change(null, null);
        await tester.pumpAndSettle();
        _CountingFrame.reads = 0;
        response.messages.add(_CountingFrame(retained + 1));
        await tester.pump();
        expect(_CountingFrame.reads, 0);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('stream follows the tail and preserves history on append', (tester) async {
    final response = _respond(_request(1), 'text/event-stream');
    response.messages.addAll(List.generate(1000, (index) => _CountingFrame(index, length: 12 + index % 37)));
    final key = GlobalKey<HttpBodyState>();
    Widget app({double width = 480, double fontScale = 1, ThemeData? theme}) => _app(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: HttpBodyWidget(key: key, httpMessage: response, previewHeight: 230, hideRequestRewrite: true),
            ),
          ),
          fontScale: fontScale,
          theme: theme,
        );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    expect(list, findsOneWidget);
    ScrollPosition position() =>
        tester.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable))).position;
    expect(position().pixels, 0);
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
    final history = position().pixels;
    expect(history, greaterThan(0));
    response.messages.add(_CountingFrame(1000, length: 80));
    await tester.pumpWidget(app());
    expect(position().pixels, history);

    for (var correction = 0; correction < 8 && position().extentAfter > 0; correction++) {
      position().jumpTo(position().maxScrollExtent);
      await tester.pumpAndSettle();
    }
    expect(position().extentAfter, 0);
    expect(find.text(_CountingFrame.label(1000, 80)), findsOneWidget);
    response.messages.add(_CountingFrame(1001, length: 128));
    _CountingFrame.reads = 0;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(position().extentAfter, 0);
    expect(find.text(_CountingFrame.label(1001, 128)).hitTestable(), findsOneWidget);
    final tailAppendReads = _CountingFrame.reads;
    expect(tailAppendReads, lessThan(30));
    _CountingFrame.reads = 0;
    await tester.pumpWidget(app(width: 340, fontScale: 1.2, theme: ThemeData.dark()));
    await tester.pumpAndSettle();
    expect(position().extentAfter, 0);
    expect(find.text(_CountingFrame.label(1001, 128)).hitTestable(), findsOneWidget);
    final tailResizeReads = _CountingFrame.reads;
    expect(tailResizeReads, lessThan(45));
    print('sse tail append=$tailAppendReads resize=$tailResizeReads');
    await tester.drag(list, const Offset(0, 120));
    await tester.pumpAndSettle();
    expect(position().extentAfter, greaterThan(0));
  }, skip: _baseline);

  testWidgets('stream keeps partial selection across scrolling and copies all on demand', (tester) async {
    final response = _respond(_request(1), 'text/event-stream');
    response.messages.addAll(List.generate(1000, (index) => _CountingFrame(index, length: 12 + index % 37)));
    final key = GlobalKey<HttpBodyState>();
    await tester.pumpWidget(_app(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 480,
          child: HttpBodyWidget(key: key, httpMessage: response, previewHeight: 230, hideRequestRewrite: true),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final region = tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    void copySelection() =>
        Actions.invoke(tester.element(find.byType(ShrinkWrappingViewport)), CopySelectionTextIntent.copy);

    final start = tester.getTopLeft(find.text(_CountingFrame.label(0, 12))) + const Offset(1, 8);
    final end = tester.getTopLeft(find.text(_CountingFrame.label(1, 13))) + const Offset(120, 8);
    final mouse = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(end);
    await tester.pumpAndSettle();
    await mouse.up();
    await tester.pump();
    copySelection();
    await tester.pump();
    final partial = clipboard;
    expect(partial, startsWith(_CountingFrame.label(0, 12)));
    expect(partial, contains('frame 1'));
    final scroller = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable));
    tester.state<ScrollableState>(scroller).position.jumpTo(1200);
    await tester.pumpAndSettle();
    expect(find.text(_CountingFrame.label(0, 12)).hitTestable(), findsNothing);
    clipboard = null;
    copySelection();
    await tester.pump();
    expect(clipboard, partial);

    region.selectAll();
    final readsBeforeCopy = _CountingFrame.reads;
    copySelection();
    await tester.pump();
    expect(_CountingFrame.reads - readsBeforeCopy, response.messages.length);
    expect(clipboard, startsWith(_CountingFrame.label(0, 12)));
    expect(clipboard, endsWith(_CountingFrame.label(999, 12 + 999 % 37)));
    expect(clipboard, isNot(contains('Data')));

    final labels = AppLocalizations.of(key.currentContext!)!;
    await tester.tap(find.byTooltip(labels.copy));
    await tester.pumpAndSettle();
    expect(clipboard, startsWith('${_CountingFrame.label(0, 12)}\n${_CountingFrame.label(1, 13)}'));
    expect(clipboard, endsWith(_CountingFrame.label(999, 12 + 999 % 37)));
    await tester.tap(find.byTooltip(labels.search));
    await tester.pumpAndSettle();
    expect(key.currentState!.searchController.isSearchOverlayVisible, isTrue);
    key.currentState!.hideSearchOverlay();
    await tester.pumpAndSettle();
  }, skip: _baseline);

  testWidgets('reverse stream selection copies exact offsets and decodes only the selected frames', (tester) async {
    final response = _respond(_request(1), 'text/event-stream');
    String label(int index) => _CountingFrame.label(index, 18);
    response.messages.addAll(List.generate(1000, (index) => _CountingFrame(index, length: 18)));
    await tester.pumpWidget(_app(Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 480,
        child: HttpBodyWidget(httpMessage: response, previewHeight: 180, hideRequestRewrite: true),
      ),
    )));
    await tester.pumpAndSettle();
    final list = find.byType(ListView);
    final scroll = tester.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable))).position;
    scroll.jumpTo(440);
    await tester.pumpAndSettle();
    final visible = List.generate(50, (index) => index)
        .where((index) => find.text(label(index)).hitTestable().evaluate().isNotEmpty);
    final anchor = visible.elementAt(2);
    expect(anchor, greaterThan(10));

    Offset caret(int index, int offset) {
      final render = tester.renderObject<RenderParagraph>(find.descendant(
        of: find.text(label(index)),
        matching: find
            .byElementPredicate((element) => element is RenderObjectElement && element.renderObject is RenderParagraph),
      ));
      final local = render.getOffsetForCaret(TextPosition(offset: offset), Rect.zero) + const Offset(1, 8);
      expect(render.getPositionForOffset(local).offset, offset);
      return render.localToGlobal(local);
    }

    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final mouse = await tester.startGesture(caret(anchor, 8), kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(caret(anchor - 1, 4));
    await tester.pump();
    await tester.sendEventToBinding(PointerScrollEvent(
        kind: PointerDeviceKind.mouse, position: tester.getCenter(list), scrollDelta: const Offset(0, -440)));
    await tester.pumpAndSettle();
    expect(find.text(label(anchor)), findsNothing);
    await mouse.moveTo(caret(0, 4));
    await tester.pumpAndSettle();
    await mouse.up();

    final reads = _CountingFrame.reads;
    Actions.invoke(tester.element(find.text(label(0))), CopySelectionTextIntent.copy);
    await tester.pump();
    expect(
        clipboard,
        [
          label(0).substring(4),
          for (var index = 1; index < anchor; index++) label(index),
          label(anchor).substring(0, 8)
        ].join());
    expect(_CountingFrame.reads - reads, anchor + 1);
    print('reverse selection selected=${anchor + 1} copy_reads=${_CountingFrame.reads - reads} retained=1000');
  }, skip: _baseline);
}
