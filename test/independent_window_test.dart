import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/independent_window_frame.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/content/panel.dart';
import 'package:proxypin/ui/desktop/widgets/windows_toolbar.dart';

void main() {
  test('the detached detail uses the shared panel and restores its request and response relationship', () {
    final request = HttpRequest(HttpMethod.get, 'https://example.test/path?filter=value')
      ..requestTime = DateTime.fromMillisecondsSinceEpoch(1000)
      ..body = [0, 128, 255];
    final response = HttpResponse(HttpStatus.ok)
      ..request = request
      ..responseTime = DateTime.fromMillisecondsSinceEpoch(1220)
      ..body = [255, 128, 0];
    response.headers.add('X-Detail', 'detached');
    final payload = jsonDecode(jsonEncode({
      'name': 'RequestDetailPage',
      'request': request,
      'response': response,
    })) as Map<String, dynamic>;

    final panel = multiWindow('detail-window', payload) as NetworkTabController;
    final detachedRequest = panel.request.get()!;
    final detachedResponse = panel.response.get()!;

    expect(panel.windowId, 'detail-window');
    expect(panel.showLayoutSettings, isTrue);
    expect(detachedRequest.requestUrl, request.requestUrl);
    expect(detachedRequest.body, request.body);
    expect(detachedResponse.body, response.body);
    expect(detachedResponse.headers.toJson(), response.headers.toJson());
    expect(detachedRequest.response, same(detachedResponse));
    expect(detachedResponse.request, same(detachedRequest));
    expect(detachedResponse.costTime(), '220ms');
  });

  for (final standalone in [false, true]) {
    final description = standalone
        ? 'standalone detached detail Ctrl+W retries a failed save and destroys once'
        : 'native detached detail Ctrl+W closes through the local window manager once';
    testWidgets(description, (tester) async {
      const windowId = 'detail-window';
      const windowManagerChannel = MethodChannel('window_manager');
      const windowsChannel = MethodChannel('mixin.one/desktop_multi_window');
      const routerChannel = MethodChannel('mixin.one/desktop_multi_window/channels');
      final calls = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(windowManagerChannel, (call) async {
        if (call.method == 'close' || call.method == 'destroy') calls.add(call.method);
        return null;
      });
      messenger.setMockMethodCallHandler(windowsChannel, (_) async => {'windowId': windowId, 'windowArgument': ''});
      messenger.setMockMethodCallHandler(routerChannel, (call) async {
        expect(call.method, 'registerMethodHandler');
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(windowManagerChannel, null);
        messenger.setMockMethodCallHandler(windowsChannel, null);
        messenger.setMockMethodCallHandler(routerChannel, null);
      });

      await DesktopMultiWindow.ensureInitialized(mainWindowId: 'main-window');
      final pendingConfig = Completer<void>();
      var flushAttempts = 0;
      if (standalone) {
        await DesktopMultiWindow.readStandaloneWindowArguments(Stream.value(utf8.encode('{}\n')));
        await DesktopMultiWindow.prepareStandaloneClose(() async {
          if (++flushAttempts == 1) throw PlatformException(code: 'standalone_window', message: 'Saving failed');
          await pendingConfig.future;
        });
      }
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: multiWindow(windowId, {'name': 'RequestDetailPage'}),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(NetworkTabController), findsOneWidget);
      final keyboard = HardwareKeyboard.instance;
      Future<bool> pressCloseShortcut({bool repeat = false}) async {
        keyboard.handleKeyEvent(const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.controlLeft,
          logicalKey: LogicalKeyboardKey.controlLeft,
          timeStamp: Duration.zero,
        ));
        final handled = keyboard.handleKeyEvent(const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyW,
          logicalKey: LogicalKeyboardKey.keyW,
          timeStamp: Duration.zero,
        ));
        await tester.pump();
        if (repeat) {
          keyboard.handleKeyEvent(const KeyRepeatEvent(
            physicalKey: PhysicalKeyboardKey.keyW,
            logicalKey: LogicalKeyboardKey.keyW,
            timeStamp: Duration.zero,
          ));
          await tester.pump();
        }
        keyboard.handleKeyEvent(const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.keyW,
          logicalKey: LogicalKeyboardKey.keyW,
          timeStamp: Duration.zero,
        ));
        keyboard.handleKeyEvent(const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.controlLeft,
          logicalKey: LogicalKeyboardKey.controlLeft,
          timeStamp: Duration.zero,
        ));
        await tester.pump();
        return handled;
      }

      expect(await pressCloseShortcut(repeat: standalone), isTrue);
      if (standalone) {
        expect(flushAttempts, 1);
        expect(calls, isEmpty);
        expect(find.byType(NetworkTabController), findsOneWidget);
        expect(await pressCloseShortcut(), isTrue);
        expect(await pressCloseShortcut(), isTrue);
        expect(flushAttempts, 2);
        expect(calls, isEmpty);
        pendingConfig.complete();
        await tester.pump();
      }
      expect(calls, [standalone ? 'destroy' : 'close']);

      expect(await pressCloseShortcut(), standalone);
      expect(flushAttempts, standalone ? 2 : 0);
      expect(calls, [standalone ? 'destroy' : 'close']);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(await pressCloseShortcut(), isFalse);
    });
  }

  testWidgets('the frame follows the theme and keeps the standalone toolbar and content', (tester) async {
    const windowManager = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(windowManager, (call) async {
      if (call.method == 'isMaximized') return false;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(windowManager, null));

    const content = SizedBox(key: ValueKey('detail-content'));
    final theme = ValueNotifier(ThemeMode.light);
    addTearDown(theme.dispose);
    await tester.pumpWidget(ValueListenableBuilder(
      valueListenable: theme,
      builder: (context, mode, child) => MaterialApp(
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        themeMode: mode,
        home: const IndependentWindowFrame(toolTitle: 'Capture detail', child: content),
      ),
    ));
    await tester.pumpAndSettle();

    Color borderColor() {
      final frame = find.byType(IndependentWindowFrame);
      final border = tester.widget<DecoratedBox>(find.descendant(
          of: frame,
          matching: find.byWidgetPredicate(
              (widget) => widget is DecoratedBox && widget.position == DecorationPosition.foreground)));
      return ((border.decoration as BoxDecoration).border! as Border).top.color;
    }

    final lightBorder = borderColor();
    final detail = tester.element(find.byKey(content.key!));
    expect(find.byType(WindowsToolbar), findsOneWidget);
    expect(find.text('Capture detail'), findsOneWidget);

    theme.value = ThemeMode.dark;
    await tester.pumpAndSettle();

    expect(borderColor(), isNot(lightBorder));
    expect(tester.element(find.byKey(content.key!)), same(detail));
    expect(find.byType(WindowsToolbar), findsOneWidget);
  });
}
