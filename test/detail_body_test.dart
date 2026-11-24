import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/search/highlight_text.dart';
import 'package:proxypin/ui/component/search/search_field.dart';
import 'package:proxypin/ui/component/search/virtualized_highlight_text.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/content/body.dart';
import 'package:proxypin/ui/content/panel.dart';

const desktop = TargetPlatformVariant({TargetPlatform.linux});

void main() {
  testWidgets('Ctrl-wheel zooms request and response code while plain wheel scrolls', (tester) async {
    final text = List.generate(400, (index) => 'entry $index').join('\n');
    await _openDetail(tester, 'text/plain', utf8.encode(text), requestHasBody: true, initialTab: 1);

    final code = find.byType(VirtualizedHighlightText);
    final codeScroll = find.descendant(of: code, matching: find.byType(Scrollable));
    for (final tab in ['Request', 'Response', 'Overview']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      final offset = tester.getCenter(code);
      final position = tester.state<ScrollableState>(codeScroll.first).position;
      final style = tester.widget<VirtualizedHighlightText>(code).style!;
      double fontSize() => MediaQuery.textScalerOf(tester.element(code)).scale(style.fontSize!);
      final initialSize = fontSize();

      void scroll(double delta) => tester.binding.handlePointerEvent(
            PointerScrollEvent(position: offset, kind: PointerDeviceKind.mouse, scrollDelta: Offset(0, delta)),
          );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      scroll(-100);
      await tester.pumpAndSettle();
      expect(fontSize(), closeTo(initialSize + 1, 0.001));
      scroll(100);
      await tester.pumpAndSettle();
      expect(fontSize(), closeTo(initialSize, 0.001));
      expect(position.pixels, 0);
      expect(tester.widget<VirtualizedHighlightText>(code).style, style);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      scroll(120);
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));
      expect(fontSize(), closeTo(initialSize, 0.001));
    }
  }, variant: desktop);

  testWidgets('Ctrl-wheel also scales selectable text in a short body', (tester) async {
    await _openDetail(tester, 'text/plain', utf8.encode('Short response'), initialTab: 2);
    final body = find.byType(HighlightTextWidget);
    final text = find.descendant(of: body, matching: find.byType(EditableText));
    final size = tester.widget<EditableText>(text).style.fontSize!;
    double renderedFontSize() => tester.state<EditableTextState>(text).renderEditable.textScaler.scale(size);
    final initialSize = renderedFontSize();
    final offset = tester.getCenter(text);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlRight);
    tester.binding.handlePointerEvent(
      PointerScrollEvent(position: offset, kind: PointerDeviceKind.mouse, scrollDelta: const Offset(0, -100)),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlRight);
    await tester.pumpAndSettle();

    expect(renderedFontSize(), closeTo(initialSize + 1, 0.001));
  }, variant: desktop);

  testWidgets('response actions have independent hover bounds and formats keep the same text style', (tester) async {
    await _openDetail(tester, 'text/css', utf8.encode('body { color: red; }'), initialTab: 2);
    final body = find.byType(HttpBodyWidget);
    final toolbar = find.descendant(of: body, matching: find.byType(IconButton));
    expect(toolbar, findsNWidgets(5));
    final buttons = List.generate(5, toolbar.at);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    for (final button in buttons) {
      final bounds = tester.getRect(button);
      expect(bounds.size, const Size(28, 28));
      for (final other in buttons.where((other) => other != button)) {
        expect(bounds.overlaps(tester.getRect(other)), isFalse);
      }
      await mouse.moveTo(bounds.center);
      await tester.pumpAndSettle();
      final ink = find.descendant(of: button, matching: find.byType(InkWell));
      expect(tester.getRect(ink), bounds);
    }

    final text = find.descendant(of: body, matching: find.byType(HighlightTextWidget));
    final plain = tester.widget<HighlightTextWidget>(text);
    expect(plain.language, isNull);
    await tester.tap(find.text('CSS'));
    await tester.pumpAndSettle();
    final highlighted = tester.widget<HighlightTextWidget>(text);
    expect(highlighted.language, 'css');
    expect(highlighted.style, plain.style);
    expect(highlighted.style?.fontFamily, 'Body Test');
    expect(tester.takeException(), isNull);
  }, variant: desktop);

  testWidgets('the overview and response resize their highlighted body with the available panel', (tester) async {
    final size = ValueNotifier(500.0);
    addTearDown(size.dispose);
    final json = jsonEncode(List.generate(2400, (index) => 'Line $index ${'content ' * 7}'));
    await _openDetail(tester, 'application/json', utf8.encode(json), panelHeight: size);

    final preview = find.byType(VirtualizedHighlightText);
    await _waitForPreview(tester, preview);
    final overview = tester.widget<VirtualizedHighlightText>(preview);
    final compact = tester.getSize(preview).height;
    expect(overview.language, 'json');
    size.value = 760;
    await tester.pumpAndSettle();
    expect(tester.getSize(preview).height, greaterThan(compact + 150));

    await tester.tap(find.text('Response'));
    await tester.pumpAndSettle();
    await _waitForPreview(tester, preview);
    final response = tester.widget<VirtualizedHighlightText>(preview);
    expect(response.language, overview.language);
    expect(response.style, overview.style);
    expect(response.text, overview.text);
    expect(tester.takeException(), isNull);
  }, variant: desktop);

  testWidgets('request, response and overview virtualize a multiline body below 16 KiB', (tester) async {
    final text = List.generate(400, (index) => 'entry ${index + 1}').join('\n');
    await _openDetail(tester, 'text/plain', utf8.encode(text), requestHasBody: true, initialTab: 1);

    final preview = find.byType(VirtualizedHighlightText);
    final firstChunk = find.byKey(const ValueKey('virtualized-code-chunk-0'));
    final lastChunk = find.byKey(const ValueKey('virtualized-code-chunk-16'));
    final request = tester.widget<VirtualizedHighlightText>(preview);
    expect(request.text, text);
    expect(firstChunk, findsOneWidget);
    expect(lastChunk, findsNothing);
    final bodyScroll = find.descendant(of: preview, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(lastChunk, 350, scrollable: bodyScroll.first);
    expect(lastChunk, findsOneWidget);

    for (final tab in ['Response', 'Overview']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      final body = tester.widget<VirtualizedHighlightText>(preview);
      expect(body.text, request.text);
      expect(body.style, request.style);
      expect(body.chunkLines, request.chunkLines);
      expect(firstChunk, findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  }, variant: desktop);

  testWidgets('compressed form requests use the decoded text viewer and keep the raw format available', (tester) async {
    final lines = List.generate(1800, (index) => 'entry ${index + 1}');
    final raw = 'payload=${lines.map(Uri.encodeComponent).join('%0A')}';
    await _openDetail(
      tester,
      'application/x-www-form-urlencoded',
      gzip.encode(utf8.encode(raw)),
      initialTab: 1,
      requestHasBody: true,
      contentEncoding: 'gzip',
    );

    final preview = find.byType(VirtualizedHighlightText);
    final firstChunk = find.byKey(const ValueKey('virtualized-code-chunk-0'));
    await _waitForPreview(tester, firstChunk);
    expect(tester.widget<VirtualizedHighlightText>(preview).text, 'payload=${lines.join('\n')}');

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), lines.last);
    await tester.pumpAndSettle();
    await _waitForPreview(tester, find.text('1 / 1'));
    await _waitForPreview(tester, find.text(lines.last).hitTestable().first);
    await tester.tap(find.descendant(of: find.byType(SearchField), matching: find.byIcon(Icons.close)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Text'));
    await tester.pumpAndSettle();
    await _waitForPreview(tester, firstChunk);
    expect(tester.widget<VirtualizedHighlightText>(preview).text, raw);
    expect(tester.takeException(), isNull);
  }, variant: desktop);

  testWidgets('both tabs show captured images and offer Hex when video bytes cannot be played', (tester) async {
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aVZsAAAAASUVORK5CYII=';
    final detail = await _openDetail(tester, 'image/png', base64Decode(png));
    Finder image() => find.descendant(of: find.byType(HttpBodyWidget), matching: find.byType(Image));
    expect(tester.widget<Image>(image()).image, isA<MemoryImage>());

    await tester.tap(find.text('Response'));
    await tester.pumpAndSettle();
    expect(tester.widget<Image>(image()).image, isA<MemoryImage>());

    final video = HttpResponse(HttpStatus.ok)..body = utf8.encode('#EXTM3U\nhttps://example.test/video.mp4');
    video.headers.contentType = 'video/mp4';
    detail.change(detail.request.get(), video);
    await tester.pumpAndSettle();
    expect(find.text('Media preview unavailable'), findsOneWidget);
    await tester.tap(find.text('Hex'));
    await tester.pumpAndSettle();
    expect(find.byType(HexViewer), findsOneWidget);
    expect(find.text('Media preview unavailable'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: desktop);
  testWidgets('code preferences update the current body and carry over to other tabs', (tester) async {
    final configuration = (await tester.runAsync(() => AppConfiguration.instance))!;
    final previousFamily = configuration.editorFontFamily;
    final previousSize = configuration.editorFontSize;
    addTearDown(() {
      configuration.editorFontFamily = previousFamily;
      configuration.editorFontSize = previousSize;
    });

    final lines = List.generate(400, (index) => 'entry $index').join('\n');
    await _openDetail(
      tester,
      'text/plain',
      utf8.encode(lines),
      initialTab: 1,
      requestHasBody: true,
      configuration: configuration,
    );
    final preview = find.byType(VirtualizedHighlightText);
    configuration.editorFontFamily = 'Custom Code Test';
    configuration.editorFontSize = 17;
    configuration.globalChange.value = !configuration.globalChange.value;
    await tester.pumpAndSettle();
    expect(tester.widget<VirtualizedHighlightText>(preview).style?.fontFamily, 'Custom Code Test');

    for (final tab in ['Response', 'Overview', 'Request']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      final style = tester.widget<VirtualizedHighlightText>(preview).style!;
      expect(style.fontFamily, 'Custom Code Test');
      expect(style.fontSize, 17);
      expect(style.height, 1.4);
    }
  }, variant: desktop);
}

Future<void> _waitForPreview(WidgetTester tester, Finder preview) async {
  for (var attempt = 0; attempt < 50 && preview.evaluate().isEmpty; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }
  expect(preview, findsOneWidget);
}

Future<NetworkTabController> _openDetail(
  WidgetTester tester,
  String contentType,
  List<int> bytes, {
  int initialTab = 0,
  ValueNotifier<double>? panelHeight,
  bool requestHasBody = false,
  String? contentEncoding,
  AppConfiguration? configuration,
}) async {
  await tester.binding.setSurfaceSize(const Size(960, 820));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final request = HttpRequest(HttpMethod.get, 'https://example.test/resource');
  final response = HttpResponse(HttpStatus.ok)..body = bytes;
  response.headers.contentType = contentType;
  if (requestHasBody) {
    request.body = bytes;
    request.headers.contentType = contentType;
    if (contentEncoding != null) request.headers.set('Content-Encoding', contentEncoding);
  }
  final detail = NetworkTabController(httpRequest: request, httpResponse: response, initialTab: initialTab);
  final theme = ThemeData();
  await tester.pumpWidget(MaterialApp(
    theme: theme.copyWith(
      textTheme: theme.textTheme.copyWith(bodyMedium: const TextStyle(fontSize: 14, fontFamily: 'Body Test')),
    ),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (_, child) =>
        configuration == null ? child! : AppDisplaySettings(configuration: configuration, child: child!),
    home: panelHeight == null
        ? detail
        : Align(
            alignment: Alignment.topCenter,
            child: ValueListenableBuilder<double>(
              valueListenable: panelHeight,
              builder: (context, height, child) => SizedBox(height: height, child: child),
              child: detail,
            ),
          ),
  ));
  await tester.pumpAndSettle();
  return detail;
}
