import 'package:code_forge/code_forge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/desktop/setting/request_rewrite.dart';

void main() {
  setUpAll(() => RustLib.init());

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
}
