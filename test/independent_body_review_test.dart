import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:code_forge/code_forge.dart';
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/components/js/script_engine.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/search/search_field.dart';
import 'package:proxypin/ui/content/body.dart';
import 'package:proxypin/ui/content/read_only_body.dart';

const firstSvg = '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32">'
    '<title>第一幅</title><rect width="32" height="32" fill="red"/></svg>';
const secondSvg = '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32">'
    '<title>第二幅</title><rect width="32" height="32" fill="blue"/></svg>';

void main() {
  setUpAll(() => RustLib.init());

  testWidgets('navigation reveals the next match inside a wrapped line', (tester) async {
    final text = 'needle ${'x' * 2034} needle';
    expect(text.length, 2048);
    await tester.pumpWidget(preview(response('text/plain', text)));
    final editor = find.byType(CodeForge);
    final list = find.byKey(const ValueKey('virtualized-highlight-text'));
    await waitFor(tester, () => editor.evaluate().isNotEmpty || list.evaluate().isNotEmpty);
    String? copied;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.tap(find.byTooltip('Copy'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(copied, text);
    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    if (editor.evaluate().isNotEmpty) {
      final native = tester.widget<CodeForge>(editor);
      final finder = native.findController!;
      finder.findInputController.text = 'needle';
      await waitFor(tester, () => finder.matchCount == 2);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      final scroll = native.verticalScrollController!;
      scroll.jumpTo(scroll.position.minScrollExtent);
      await tester.pump();
      final before = scroll.offset;
      finder.next();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      final after = scroll.offset;
      debugPrint('NAV native current=${finder.currentMatchIndex} before=$before '
          'after=$after max=${scroll.position.maxScrollExtent}');
      expect(finder.currentMatchIndex, 1);
      expect(after, greaterThan(before + 100));
    } else {
      final finder = tester.widget<SearchField>(find.byType(SearchField)).searchController;
      finder.patternController.text = 'needle';
      await waitFor(tester, () => finder.totalMatchCount.value == 2);
      await tester.pumpAndSettle();
      finder.moveNext();
      await tester.pumpAndSettle();
      expect(finder.currentMatchIndex.value, 1);
      expectVisibleMatch(tester, list, 0, text.length - 6, text.length);
      finder.movePrevious();
      await tester.pumpAndSettle();
      expect(finder.currentMatchIndex.value, 0);
      expectVisibleMatch(tester, list, 0, 0, 6);
    }
  });

  testWidgets('navigation reveals a wrapped match on a distant unmounted row', (tester) async {
    final lastLine = '${'😀' * 1000} needle';
    final text = 'needle\n${List.filled(180, 'intervening row\n').join()}$lastLine';
    final list = find.byKey(const ValueKey('virtualized-highlight-text'));
    await tester.pumpWidget(preview(response('text/plain', text)));
    await waitFor(tester, () => list.evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    final finder = tester.widget<SearchField>(find.byType(SearchField)).searchController;
    finder.patternController.text = 'needle';
    await waitFor(tester, () => finder.totalMatchCount.value == 2);
    expect(find.byKey(const ValueKey('virtualized-code-chunk-181')), findsNothing);

    finder.moveNext();
    await tester.pumpAndSettle();
    expectVisibleMatch(tester, list, 181, lastLine.length - 6, lastLine.length);

    finder.movePrevious();
    await tester.pumpAndSettle();
    expectVisibleMatch(tester, list, 0, 0, 6);
  });

  testWidgets('switching SVGs clears the preceding preview while decode is pending', (tester) async {
    await tester.pumpWidget(preview(response('image/svg+xml', firstSvg)));
    final first = picture(firstSvg);
    await waitFor(tester, () => first.evaluate().isNotEmpty);
    final decoded = Completer<String>();
    final next = PendingSvgResponse(decoded.future)..body = gzip.encode(utf8.encode(secondSvg));
    next.headers.contentType = 'image/svg+xml';
    next.headers.set('Content-Encoding', 'gzip');
    await tester.pumpWidget(preview(next));
    final staleWhilePending = first.evaluate().isNotEmpty;
    decoded.complete(secondSvg);
    await waitFor(tester, () => picture(secondSvg).evaluate().isNotEmpty);
    expect(first, findsNothing);
    expect(staleWhilePending, isFalse,
        reason: 'The preceding response must not appear under the newly selected response');
  });

  testWidgets('gzip SVG is decoded for JS and preview and saves usable SVG bytes', (tester) async {
    final incoming = response('IMAGE/SVG+XML; Charset="UTF-8"', firstSvg)..body = gzip.encode(utf8.encode(firstSvg));
    incoming.headers.set('Content-Encoding', 'gzip');
    final js = await tester.runAsync(() => JavaScriptEngine.convertJsResponse(incoming));
    expect(js!['body'], firstSvg);
    final raw = List<int>.of(incoming.body!);
    expect(js['rawBody'], raw);
    final originalPicker = FilePickerPlatform.instance;
    final picker = CapturingPicker();
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = originalPicker);
    await tester.pumpWidget(preview(incoming, width: 800));
    await waitFor(tester, () => picture(firstSvg).evaluate().isNotEmpty);
    await tester.tap(find.text('Text'));
    await waitFor(tester, () => find.byType(ReadOnlyBody).evaluate().isNotEmpty);
    expect(tester.widget<ReadOnlyBody>(find.byType(ReadOnlyBody)).text, firstSvg);
    await tester.tap(find.text('Image'));
    await waitFor(tester, () => picture(firstSvg).evaluate().isNotEmpty);
    final context = tester.element(find.byType(HttpBodyWidget));
    await tester.tap(find.byTooltip(AppLocalizations.of(context)!.saveImage));
    await waitFor(tester, () => picker.name != null);
    expect(picker.name, endsWith('.svg'));
    expect(picker.mime, 'image/svg+xml');
    debugPrint('SVG save prefix=${picker.bytes!.take(4).toList()}');
    expect(picker.bytes, utf8.encode(firstSvg));
    await tester.tap(find.text('Hex'));
    await tester.pump();
    expect(tester.widget<HexViewer>(find.byType(HexViewer)).data, raw);
    expect(incoming.body, raw);
  });

  test('decoded content bytes preserve the SVG declaration and charset', () async {
    final source = latin1.encode(
      '<?xml version="1.0" encoding="ISO-8859-1"?><svg xmlns="http://www.w3.org/2000/svg"><title>été</title></svg>',
    );
    final incoming = HttpResponse(HttpStatus.ok)
      ..headers.contentType = 'image/svg+xml; charset=iso-8859-1'
      ..headers.set('Content-Encoding', 'deflate')
      ..body = zlib.encode(source);
    expect(await incoming.decodeBodyBytes(), source);
    incoming.body = ZLibCodec(raw: true).encode(source);
    expect(await incoming.decodeBodyBytes(), source);
    incoming.body = [0xff, 0xff, 0xff];
    expect(await incoming.decodeBodyBytes(), isNull);
  });
}

void expectVisibleMatch(WidgetTester tester, Finder list, int line, int start, int end) {
  final chunk = find.byKey(ValueKey('virtualized-code-chunk-$line'));
  final rich = find.descendant(of: chunk, matching: find.byType(RichText));
  final paragraph = tester.renderObject<RenderParagraph>(rich);
  final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end));
  expect(boxes, isNotEmpty);
  final match = paragraph.localToGlobal(boxes.first.toRect().center);
  final viewport = tester.getRect(list);
  debugPrint('NAV virtual line=$line match=$match viewport=$viewport');
  expect(viewport.contains(match), isTrue, reason: 'The selected match must be inside the viewport');
}

class PendingSvgResponse extends HttpResponse {
  final Future<String> decoded;

  PendingSvgResponse(this.decoded) : super(HttpStatus.ok);

  @override
  Future<String> decodeBodyString({bool offload = false}) => decoded;
}

class CapturingPicker extends FilePickerPlatform {
  String? name;
  String? mime;
  Uint8List? bytes;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    name = fileName;
    mime = mimeType;
    this.bytes = bytes;
    return null;
  }
}

HttpResponse response(String mime, String text) => HttpResponse(HttpStatus.ok)
  ..headers.contentType = mime
  ..body = utf8.encode(text);

Finder picture(String svg) => find.byWidgetPredicate(
      (widget) => widget is SvgPicture && widget.bytesLoader == SvgStringLoader(svg),
    );

Widget preview(HttpResponse message, {double width = 420}) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: HttpBodyWidget(httpMessage: message, previewHeight: 170, hideRequestRewrite: true),
          ),
        ),
      ),
    );

Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 150 && !ready(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue);
}
