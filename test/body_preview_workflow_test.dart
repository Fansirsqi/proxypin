import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/components/js/script_engine.dart';
import 'package:proxypin/network/http/content_type.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/search/highlight_text_document.dart';
import 'package:proxypin/ui/component/search/search_controller.dart';
import 'package:proxypin/ui/component/search/search_field.dart';
import 'package:proxypin/ui/content/body.dart';
import 'package:proxypin/ui/content/read_only_body.dart';
import 'package:proxypin/utils/xml_formatter.dart';
import 'package:scrollable_positioned_list_nic/scrollable_positioned_list_nic.dart';

void main() {
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><title>图</title>'
      '<rect width="32" height="32" fill="#ff0000"/></svg>';
  final reader = find.byType(ReadOnlyBody);
  const listKey = ValueKey('virtualized-highlight-text');
  const firstChunkKey = ValueKey('virtualized-code-chunk-0');

  test('SVG and +xml are text in JS while other images keep bytes', () async {
    for (final mime in ['IMAGE/SVG+XML ; Charset="UTF-8"', 'image/svg+xml', 'application/vnd.example+xml']) {
      final response = _response(mime, svg);
      expect(response.contentType, ContentType.xml);
      expect(response.isSvg, mime.toLowerCase().startsWith('image/'));
      final js = await JavaScriptEngine.convertJsResponse(response);
      expect(js['body'], svg);
      expect(js['rawBody'], utf8.encode(svg));
    }
    for (final mime in ['image/png; charset=utf-8', 'image/webp', 'image/svg+xml-custom', 'image/custom+xml']) {
      final response = HttpResponse(HttpStatus.ok)..body = [255, 0, 150, 8];
      response.headers.contentType = mime;
      expect(response.contentType, ContentType.image);
      expect(response.isSvg, isFalse);
      expect((await JavaScriptEngine.convertJsResponse(response))['body'], response.body);
    }
  });

  testWidgets('compressed SVG offers image, XML and exact text views', (tester) async {
    final response = _response('Image/SVG+XML; charset=utf-8', svg)..body = gzip.encode(utf8.encode(svg));
    response.headers.set('Content-Encoding', 'gzip');
    await tester.pumpWidget(_app(response));
    final picture = find.byWidgetPredicate(
      (widget) => widget is SvgPicture && widget.bytesLoader == const SvgStringLoader(svg),
    );
    await _wait(tester, () => picture.evaluate().isNotEmpty);
    await tester.tap(find.text('XML'));
    await _wait(tester, () => reader.evaluate().isNotEmpty);
    expect(tester.widget<ReadOnlyBody>(reader).text, XML.pretty(svg));
    expect(tester.widget<ReadOnlyBody>(reader).language, 'xml');
    await tester.tap(find.text('Text'));
    await _wait(tester, () => reader.evaluate().isNotEmpty && tester.widget<ReadOnlyBody>(reader).text == svg);
    expect(tester.widget<ReadOnlyBody>(reader).text, svg);
    expect(tester.widget<ReadOnlyBody>(reader).language, isNull);
    await tester.tap(find.text('Image'));
    await _wait(tester, () => picture.evaluate().isNotEmpty);
    expect(picture, findsOneWidget);

    await tester.pumpWidget(_app(_response('application/atom+xml', svg)));
    await _wait(tester, () => reader.evaluate().isNotEmpty);
    expect(find.text('Image'), findsNothing);
    expect(tester.widget<ReadOnlyBody>(reader).language, 'xml');
    await tester.pumpWidget(_app(_response('image/png', svg)));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('XML'), findsNothing);
    expect(find.text('Text'), findsNothing);
  });

  testWidgets('long HTML, XML, JS and CSS open with raw text and opt-in syntax', (tester) async {
    for (final (mime, language, line) in [
      ('text/html', 'html', '<article><p>example</p></article>'),
      ('application/xml', 'xml', '<article><p>example</p></article>'),
      ('application/javascript', 'javascript', 'const example={value:42};'),
      ('text/css', 'css', '.example{border:0;color:red}'),
    ]) {
      final text = List.filled(84, line).join('\n');
      await tester.pumpWidget(_app(_response(mime, text)));
      await _wait(tester, () => reader.evaluate().isNotEmpty);
      final preview = tester.widget<ReadOnlyBody>(reader);
      expect(preview.text, text);
      expect(preview.language, isNull);
      expect(preview.virtualized, isTrue);
      await tester.tap(find.text('Highlight'));
      await tester.pump();
      expect(tester.widget<ReadOnlyBody>(reader).language, language);
      expect(tester.widget<ReadOnlyBody>(reader).text, text);
      await tester.tap(find.text('Text'));
      await tester.pump();
      expect(tester.widget<ReadOnlyBody>(reader).text, text);
      expect(tester.widget<ReadOnlyBody>(reader).language, isNull);
      expect(find.text('Format'), findsNothing);
    }
  });

  testWidgets('explicit format changes display and copy while Text keeps the source', (tester) async {
    final text = '<items>\n${List.filled(95, '<row><entry>value</entry></row>').join('\n')}\n</items>';
    final formatted = XML.pretty(text);
    expect(formatted, isNot(text));
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(_app(_response('application/xml', text)));
    await _wait(tester, () => reader.evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('Copy'));
    await tester.pump();
    expect(copied, text);
    await tester.tap(find.text('Format'));
    await tester.pump();
    await _wait(tester, () => tester.widget<ReadOnlyBody>(reader).text == formatted);
    expect(tester.widget<ReadOnlyBody>(reader).language, isNull);
    await tester.tap(find.byTooltip('Copy'));
    await tester.pump();
    expect(copied, formatted);
    await tester.tap(find.text('Text'));
    await tester.pump();
    expect(tester.widget<ReadOnlyBody>(reader).text, text);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('rapid virtual search cancels old results and keeps search focus', (tester) async {
    final text = List.generate(800, (index) => index % 401 == 0 ? 'target' : 'old line $index').join('\n');
    await tester.pumpWidget(_app(_response('text/plain', text)));
    await _wait(tester, () => find.byKey(firstChunkKey).evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    final search = tester.widget<SearchField>(find.byType(SearchField)).searchController;
    final field = tester.widget<TextField>(find.byType(TextField));
    for (final pattern in ['o', 'ol', 'old', 'old line', 't', 'ta', 'tar', 'target']) {
      search.patternController.text = pattern;
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(search.totalMatchCount.value, 0);
    await _wait(tester, () => search.totalMatchCount.value == 2);
    expect(field.focusNode!.hasFocus, isTrue);
    search.moveNext();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('virtualized-code-chunk-401')).hitTestable(), findsOneWidget);
    search.patternController.text = 'old line';
    await tester.pump(const Duration(milliseconds: 100));
    search.removeSearchOverlay();
    await tester.pump(const Duration(seconds: 3));
    expect(search.totalMatchCount.value, 0);
    expect(find.byType(SearchField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing the captured response closes a populated finder', (tester) async {
    final text = List.filled(100, 'target').join('\n');
    await tester.pumpWidget(_app(_response('text/plain', text)));
    await _wait(tester, () => find.byKey(firstChunkKey).evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    final search = tester.widget<SearchField>(find.byType(SearchField)).searchController;
    search.patternController.text = 'target';
    await _wait(tester, () => search.totalMatchCount.value == 100);
    await tester.pumpWidget(_app(_response('text/plain', '$text updated')));
    await tester.pump();
    expect(find.byType(SearchField), findsNothing);
    expect(search.totalMatchCount.value, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scroll back reuses recent spans and evicts distant chunks', (tester) async {
    final text = List.generate(880, (index) => 'line $index ${'abcdefgh ' * 5}').join('\n');
    await tester.pumpWidget(_app(_response('text/plain', text)));
    final first = find.byKey(firstChunkKey);
    await _wait(tester, () => first.evaluate().isNotEmpty);
    final original = tester.widget<Text>(first).textSpan;
    final items = tester.widget<ScrollablePositionedList>(find.byKey(listKey)).itemScrollController!;
    items.jumpTo(index: 5);
    await tester.pumpAndSettle();
    expect(first, findsNothing);
    items.jumpTo(index: 0);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(first).textSpan, same(original));
    for (final index in [5, 10, 15, 20, 25, 30, 35]) {
      items.jumpTo(index: index);
      await tester.pumpAndSettle();
    }
    items.jumpTo(index: 0);
    await tester.pumpAndSettle();
    expect(identical(tester.widget<Text>(first).textSpan, original), isFalse);
    expect(tester.widget<Text>(first).textSpan!.toPlainText(), original!.toPlainText());
  });

  testWidgets('oversized chunks are rebuilt when scrolling back', (tester) async {
    final text = List.generate(300, (index) => index == 0 ? 'x' * 5000 : 'line $index').join('\n');
    await tester.pumpWidget(_app(_response('text/plain', text)));
    final first = find.byKey(firstChunkKey);
    await _wait(tester, () => first.evaluate().isNotEmpty);
    final original = tester.widget<Text>(first).textSpan;
    final items = tester.widget<ScrollablePositionedList>(find.byKey(listKey)).itemScrollController!;
    items.jumpTo(index: 5);
    await tester.pumpAndSettle();
    expect(first, findsNothing);
    items.jumpTo(index: 0);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(first).textSpan, isNot(same(original)));
    expect(tester.widget<Text>(first).textSpan!.toPlainText(), original!.toPlainText());
  });

  test('a stalled regex is canceled and the next search can finish', () async {
    final slow = PreviewTask.start(
      findHighlightMatches,
      ('${'a' * 16000}!', const SearchSettings(isCaseSensitive: true, isRegExp: true, pattern: r'(a+)+$')),
      timeout: const Duration(milliseconds: 100),
    );
    expect(await slow.result, isNull);
    final next = PreviewTask.start(
      findHighlightMatches,
      ('aaa\nbbb', const SearchSettings(isCaseSensitive: true, isRegExp: false, pattern: 'bbb')),
      timeout: const Duration(seconds: 1),
    );
    expect((await next.result)!.single.start, 4);
  });
}

HttpResponse _response(String mime, String text) {
  final response = HttpResponse(HttpStatus.ok)..body = utf8.encode(text);
  response.headers.contentType = mime;
  return response;
}

Widget _app(HttpResponse response) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: HttpBodyWidget(httpMessage: response, previewHeight: 245, hideRequestRewrite: true)),
    );

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 100 && !ready(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue);
}
