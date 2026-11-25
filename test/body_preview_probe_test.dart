import 'dart:convert';

import 'package:code_forge/code_forge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/search/search_field.dart';
import 'package:proxypin/ui/content/body.dart';
import 'package:proxypin/ui/content/read_only_body.dart';

void main() {
  setUpAll(() => RustLib.init());

  Widget preview(String mime, String text) {
    final response = HttpResponse(HttpStatus.ok)..body = utf8.encode(text);
    response.headers.contentType = mime;
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: HttpBodyWidget(httpMessage: response, previewHeight: 245, hideRequestRewrite: true),
      ),
    );
  }

  Future<void> pause(WidgetTester tester, [int milliseconds = 10]) async {
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: milliseconds)));
    await tester.pump(Duration(milliseconds: milliseconds));
  }

  Future<void> until(WidgetTester tester, bool Function() complete) async {
    for (var attempt = 0; attempt < 500 && !complete(); attempt++) {
      await pause(tester);
    }
    expect(complete(), isTrue);
  }

  testWidgets('long HTML opening, rapid query and explicit actions', (tester) async {
    for (var run = 0; run < 3; run++) {
      final text = List.generate(2400, (index) {
        final label = index % 59 == 0 ? 'final-needle' : 'label-$index';
        return '<article data-name="$label"><p>${'abc' * 38}</p></article>';
      }).join('\n');
      final opening = Stopwatch()..start();
      await tester.pumpWidget(preview('text/html', text));
      final firstChunk = find.byKey(const ValueKey('virtualized-code-chunk-0'));
      await until(tester, () => firstChunk.evaluate().isNotEmpty);
      opening.stop();
      await tester.tap(find.byTooltip('Search'));
      await tester.pump();
      final controller = tester.widget<SearchField>(find.byType(SearchField)).searchController;
      final rapid = Stopwatch()..start();
      for (final pattern in [
        'a',
        'ar',
        'art',
        'arti',
        'artic',
        'article',
        'f',
        'fi',
        'fin',
        'final',
        'final-',
        'final-needle'
      ]) {
        controller.patternController.text = pattern;
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 16)));
      }
      await until(tester, () => controller.totalMatchCount.value == 41);
      rapid.stop();
      controller.closeSearch();
      await tester.pump();
      final formatting = find.text('Format').hitTestable();
      final highlighting = find.text('Highlight').hitTestable();
      int? explicitFormat;
      int? explicitHighlight;
      if (formatting.evaluate().isNotEmpty) {
        final stopwatch = Stopwatch()..start();
        await tester.tap(formatting);
        await tester.pump();
        await until(
            tester,
            () =>
                tester.widget<ReadOnlyBody>(find.byType(ReadOnlyBody)).text != text &&
                firstChunk.evaluate().isNotEmpty);
        explicitFormat = stopwatch.elapsedMilliseconds;
      }
      if (highlighting.evaluate().isNotEmpty) {
        final stopwatch = Stopwatch()..start();
        await tester.tap(highlighting);
        await tester.pump();
        await until(tester, () {
          final chunk = firstChunk.evaluate().firstOrNull?.widget as Text?;
          return (chunk?.textSpan as TextSpan?)
                  ?.children
                  ?.any((span) => span is TextSpan && span.text == 'article' && span.style?.color != null) ==
              true;
        });
        explicitHighlight = stopwatch.elapsedMilliseconds;
      }
      debugPrint('PROBE html run=$run open_ms=${opening.elapsedMilliseconds} rapid_ms=${rapid.elapsedMilliseconds} '
          'format_ms=$explicitFormat highlight_ms=$explicitHighlight');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  });

  for (final rows in [8, 16, 60]) {
    testWidgets('dense matches in $rows lines of plain text', (tester) async {
      const columns = 240;
      final text = List.filled(rows, '${'a' * columns}\n').join();
      await tester.pumpWidget(preview('text/plain', text));
      final editor = find.byType(CodeForge);
      final firstChunk = find.byKey(const ValueKey('virtualized-code-chunk-0'));
      await until(tester, () => editor.evaluate().isNotEmpty || firstChunk.evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Search'));
      await tester.pump();
      final stopwatch = Stopwatch()..start();
      final editorPath = editor.evaluate().isNotEmpty;
      final void Function() next;
      if (editorPath) {
        final controller = tester.widget<CodeForge>(editor).findController!;
        controller.findInputController.text = 'a';
        await until(tester, () => controller.matchCount == rows * columns);
        next = controller.next;
      } else {
        final controller = tester.widget<SearchField>(find.byType(SearchField)).searchController;
        controller.patternController.text = 'a';
        await until(tester, () => controller.totalMatchCount.value == rows * columns);
        next = controller.moveNext;
      }
      stopwatch.stop();
      final navigation = Stopwatch()..start();
      for (var index = 0; index < 20; index++) {
        next();
        await tester.pump(const Duration(milliseconds: 16));
      }
      navigation.stop();
      debugPrint('PROBE dense matches=${rows * columns} path=${editorPath ? 'editor' : 'virtual'} '
          'query_ms=${stopwatch.elapsedMilliseconds} next20_ms=${navigation.elapsedMilliseconds}');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
