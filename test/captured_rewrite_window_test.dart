import 'dart:io';

import 'package:code_forge/code_forge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/main.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/component/standalone_window_payload.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/desktop/setting/request_rewrite.dart';

void main() {
  setUpAll(() => RustLib.init());

  testWidgets('independent Linux rewrite coalesces transient widths and wraps at a settled width', (tester) async {
    const wide = Size(1150, 780);
    const narrow = Size(800, 780);
    const windowId = 'resize-rewrite';
    const url = 'https://example.invalid/resize';
    const windowManager = MethodChannel('window_manager');
    const windows = MethodChannel('mixin.one/desktop_multi_window');
    const router = MethodChannel('mixin.one/desktop_multi_window/channels');
    final messenger = tester.binding.defaultBinaryMessenger;
    var draftRequests = 0;
    messenger.setMockMethodCallHandler(windowManager, (call) async => call.method == 'isMaximized' ? false : null);
    messenger.setMockMethodCallHandler(windows, (_) async => {'windowId': windowId, 'windowArgument': ''});
    messenger.setMockMethodCallHandler(router, (call) async {
      if (call.method == 'registerMethodHandler') return null;
      expect((call.arguments as Map)['method'], 'getCapturedRewrite');
      draftRequests++;
      return {'rule': RequestRewriteRule(url: url, type: RuleType.responseReplace).toJson()};
    });
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      for (final channel in [windowManager, windows, router]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    await tester.binding.setSurfaceSize(wide);
    await DesktopMultiWindow.ensureInitialized(mainWindowId: 'main-window');
    final response = HttpResponse(HttpStatus.ok)
      ..body = List.filled(100, List.filled(200, 'x').join()).join('\n').codeUnits;
    final request = HttpRequest(HttpMethod.get, url);
    await tester.pumpWidget(FluentApp(
      multiWindow(windowId, {
        'name': RewriteRuleEdit.windowName,
        'request': request,
        'response': response,
        'ruleType': 'responseReplace',
      }),
      AppConfiguration.withConfigFile(File('${Directory.systemTemp.path}/unused-resize-config.json')),
      independentWindow: true,
      toolTitle: 'Rewrite',
    ));
    final editor = find.byType(CodeForge);
    for (var frame = 0; frame < 30 && editor.evaluate().isEmpty; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(editor, findsOneWidget);
    final wideEditorWidth = tester.getSize(editor).width;
    expect(wideEditorWidth, 1108);
    await tester.pump(const Duration(milliseconds: 500));
    final initial = tester.widget<CodeForge>(editor);
    final element = tester.element(editor);
    final scroll = initial.verticalScrollController!;
    initial.findController!.findInputController.text = 'xxx';
    initial.focusNode!.requestFocus();
    const selection = TextSelection(baseOffset: 2, extentOffset: 9);
    initial.controller!.selection = selection;
    await tester.pump();
    scroll.jumpTo(500);
    await tester.pump();
    final baseline = scroll.position.maxScrollExtent;
    final matches = initial.findController!.matchCount;
    expect(matches, greaterThan(0));

    Future<void> resize(Size size) async {
      await tester.binding.setSurfaceSize(size);
      await tester.pump();
    }

    await resize(narrow);
    expect(tester.getSize(find.byType(RewriteRuleEdit)).width, narrow.width);
    expect(tester.getSize(editor).width, wideEditorWidth);
    await tester.pump(const Duration(milliseconds: 40));
    await resize(wide);
    await tester.pump(const Duration(milliseconds: 111));
    final afterOldTimer = scroll.position.maxScrollExtent;
    await tester.pump(const Duration(milliseconds: 150));
    expect(afterOldTimer, baseline);
    expect(scroll.position.maxScrollExtent, baseline);
    expect(scroll.offset, 500);

    await resize(const Size(1000, 780));
    await tester.pump(const Duration(milliseconds: 60));
    await resize(const Size(900, 780));
    await tester.pump(const Duration(milliseconds: 60));
    await resize(narrow);
    await tester.pump(const Duration(milliseconds: 149));
    expect(tester.getSize(editor).width, wideEditorWidth);
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.getSize(editor).width, 758);
    await tester.pump(const Duration(milliseconds: 150));
    final narrowExtent = scroll.position.maxScrollExtent;
    expect(narrowExtent, greaterThan(baseline));
    expect(draftRequests, 1);
    expect(tester.element(editor), same(element));
    final current = tester.widget<CodeForge>(editor);
    expect(current.controller, same(initial.controller));
    expect(current.controller!.selection, selection);
    expect(current.focusNode, same(initial.focusNode));
    expect(current.focusNode!.hasFocus, isTrue);
    expect(current.findController, same(initial.findController));
    expect(current.findController!.findInputController.text, 'xxx');
    expect(current.findController!.matchCount, matches);
    expect(current.verticalScrollController, same(scroll));
    expect(scroll.offset, 500);
    print('rewrite width=$wideEditorWidth fast_reversal_extent=$baseline->$afterOldTimer '
        'settled_narrow_extent=$narrowExtent settle_ms=300 matches=$matches');

    await resize(wide);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isLinux);

  testWidgets('the independent rewrite editor prefills the response and updates the saved rule by path',
      (tester) async {
    const windowId = 'rewrite-window';
    const windowManager = MethodChannel('window_manager');
    const windows = MethodChannel('mixin.one/desktop_multi_window');
    const router = MethodChannel('mixin.one/desktop_multi_window/channels');
    const path = '/rewrite/existing.json';
    const url = 'https://example.test/path';
    final response = HttpResponse(HttpStatus.ok)..body = '{"value":"response"}'.codeUnits;
    final request = HttpRequest(HttpMethod.get, url)..body = '{"value":"request"}'.codeUnits;
    final calls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowManager, (call) async {
      if (call.method == 'close') calls.add('close');
      return null;
    });
    messenger.setMockMethodCallHandler(windows, (_) async => {'windowId': windowId, 'windowArgument': ''});
    messenger.setMockMethodCallHandler(router, (call) async {
      if (call.method == 'registerMethodHandler') return null;
      final message = call.arguments as Map;
      final method = message['method'] as String;
      final args = (message['arguments'] as Map)['__arguments'] as Map;
      calls.add(method);
      if (method == 'getCapturedRewrite') {
        expect(args, {'method': 'GET', 'url': url, 'protocolVersion': 'HTTP/1.1', 'type': 'responseReplace'});
        return {
          'rule': RequestRewriteRule(url: url, type: RuleType.responseReplace, rewritePath: path).toJson(),
        };
      }
      expect(method, 'refreshRequestRewrite');
      expect(args['operation'], 'update');
      expect(args['capturedEditor'], isTrue);
      expect((args['rule'] as Map)['rewritePath'], path);
      final items = (args['items'] as List).map((item) => RewriteItem.fromJson(item as Map));
      expect(items.singleWhere((item) => item.type == RewriteType.replaceResponseBody).body, '{"value":"response"}');
      return path;
    });
    addTearDown(() {
      for (final channel in [windowManager, windows, router]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    await DesktopMultiWindow.ensureInitialized(mainWindowId: 'main-window');
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: multiWindow(windowId, {
        'name': RewriteRuleEdit.windowName,
        'request': request.toJson(),
        'response': response.toJson(),
        'ruleType': 'responseReplace',
      }),
    ));
    for (var frame = 0; frame < 30 && find.byType(RewriteRuleEdit).evaluate().isEmpty; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(calls, ['getCapturedRewrite']);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(RewriteRuleEdit), findsOneWidget);
    final editor = find.byType(CodeForge);
    final initialHeight = tester.getSize(editor).height;
    await tester.binding.setSurfaceSize(const Size(1000, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pump();
    expect(tester.getSize(editor).height, greaterThan(initialHeight));
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    for (var frame = 0; frame < 30 && !calls.contains('close'); frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(calls, ['getCapturedRewrite', 'refreshRequestRewrite', 'close']);
  });

  testWidgets('a transferred rewrite keeps the saved replacement and switches to the captured request', (tester) async {
    const windowId = 'restored-rewrite';
    const url = 'https://example.invalid/restore';
    const windows = MethodChannel('mixin.one/desktop_multi_window');
    const router = MethodChannel('mixin.one/desktop_multi_window/channels');
    const manager = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(manager, (_) async => null);
    messenger.setMockMethodCallHandler(windows, (_) async => {'windowId': windowId, 'windowArgument': ''});
    messenger.setMockMethodCallHandler(router, (call) async {
      if (call.method == 'registerMethodHandler') return null;
      expect((call.arguments as Map)['method'], 'getCapturedRewrite');
      return {
        'rule': RequestRewriteRule(url: url, type: RuleType.responseReplace).toJson(),
        'items': [(RewriteItem(RewriteType.replaceResponseBody, true)..body = 'saved replacement').toJson()],
      };
    });
    addTearDown(() {
      for (final channel in [manager, windows, router]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    await DesktopMultiWindow.ensureInitialized(mainWindowId: 'main-window');
    final captured = StandaloneWindowPayload(
      HttpRequest(HttpMethod.post, url)..body = 'captured request'.codeUnits,
      HttpResponse(HttpStatus.ok)..body = 'captured response'.codeUnits,
    );
    final payload = await tester.runAsync(() async => StandaloneWindowPayload.decode(await captured.encode()));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: multiWindow(windowId, {'name': RewriteRuleEdit.windowName, 'ruleType': 'responseReplace', ...payload!}),
    ));
    final editor = find.byType(CodeForge);
    for (var frame = 0; frame < 30 && editor.evaluate().isEmpty; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(editor, findsOneWidget);
    String text() => tester.widget<CodeForge>(editor).controller!.text;
    expect(text(), 'saved replacement');

    final dropdown = find.byType(DropdownButtonFormField<RuleType>);
    await tester.tap(dropdown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('requestReplace').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(text(), 'captured request');

    await tester.tap(dropdown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('responseReplace').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(text(), 'saved replacement');
  });
}
