import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:screen_retriever/screen_retriever.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const windowManagerChannel = MethodChannel('window_manager');
  const windowsChannel = MethodChannel('mixin.one/desktop_multi_window');
  const windowRouterChannel = MethodChannel('mixin.one/desktop_multi_window/channels');
  const screenChannel = MethodChannel('dev.leanflutter.plugins/screen_retriever');

  tearDown(() {
    DesktopMultiWindow.onThemeChanged = null;
    messenger.setMockMethodCallHandler(windowManagerChannel, null);
    messenger.setMockMethodCallHandler(windowsChannel, null);
    messenger.setMockMethodCallHandler(windowRouterChannel, null);
    messenger.setMockMethodCallHandler(screenChannel, null);
  });

  Display display(Offset physicalOrigin, Size physicalSize, double scale) {
    return Display(
      id: physicalOrigin.toString(),
      size: physicalSize / scale,
      visiblePosition: physicalOrigin / scale,
      visibleSize: physicalSize / scale,
      scaleFactor: scale,
    );
  }

  final primary = display(Offset.zero, const Size(2560, 1392), 1);
  final secondary125 = display(const Offset(2560, 0), const Size(1920, 1032), 1.25);
  final primary150 = display(Offset.zero, const Size(3840, 2160), 1.5);
  final rightSecondary125 = display(const Offset(3840, 0), const Size(2400, 1350), 1.25);

  group('child window display selection', () {
    test('uses the display containing the parent window center with mixed DPI', () {
      final screen = DesktopMultiWindow.displayRectForWindow(
        windowBounds: const Rect.fromLTWH(4000, 100, 1000, 700),
        displays: [primary150, rightSecondary125],
      );

      expect(screen, const Rect.fromLTWH(3840, 0, 2400, 1350));
    });

    test('does not confuse overlapping logical display ranges', () {
      final screen = DesktopMultiWindow.displayRectForWindow(
        windowBounds: const Rect.fromLTWH(2700, 100, 800, 600),
        displays: [primary, secondary125],
      );

      expect(screen, const Rect.fromLTWH(2560, 0, 1920, 1032));
    });

    test('supports a parent window on a display with negative coordinates', () {
      final leftSecondary = display(const Offset(-1920, 0), const Size(1920, 1080), 1);
      final screen = DesktopMultiWindow.displayRectForWindow(
        windowBounds: const Rect.fromLTWH(-1700, 100, 1000, 700),
        displays: [primary150, leftSecondary],
      );

      expect(screen, const Rect.fromLTWH(-1920, 0, 1920, 1080));
    });

    test('uses the largest overlap when the parent center is outside every display', () {
      final left = display(Offset.zero, const Size(1000, 1000), 1);
      final right = display(const Offset(2000, 0), const Size(1000, 1000), 1);
      final screen = DesktopMultiWindow.displayRectForWindow(
        windowBounds: const Rect.fromLTWH(500, 100, 1600, 500),
        displays: [left, right],
      );

      expect(screen, const Rect.fromLTWH(0, 0, 1000, 1000));
    });

    test('ignores displays without a usable scale and invalid window bounds', () {
      final invalidDisplay = Display(
        id: 'invalid',
        size: const Size(1920, 1080),
        visiblePosition: const Offset(3840, 0),
        visibleSize: const Size(1920, 1080),
        scaleFactor: 0,
      );
      final screen = DesktopMultiWindow.displayRectForWindow(
        windowBounds: const Rect.fromLTWH(4000, 100, 1000, 700),
        displays: [invalidDisplay],
      );

      expect(screen, isNull);
      expect(
        DesktopMultiWindow.displayRectForWindow(
          windowBounds: Rect.zero,
          displays: [primary],
        ),
        isNull,
      );
    });
  });

  group('child window centering', () {
    test('centers the physical child window size in the parent display work area', () {
      final position = DesktopMultiWindow.centeredWindowPosition(
        const Rect.fromLTWH(2560, 0, 1920, 1032),
        const Size(1440, 750),
      );

      expect(position, const Offset(2800, 141));
    });

    test('centers within a display to the left of the primary display', () {
      final position = DesktopMultiWindow.centeredWindowPosition(
        const Rect.fromLTWH(-1920, 0, 1920, 1080),
        const Size(800, 600),
      );

      expect(position, const Offset(-1360, 240));
    });

    test('keeps an oversized window centered instead of clamping to a corner', () {
      final position = DesktopMultiWindow.centeredWindowPosition(
        const Rect.fromLTWH(3840, 0, 1000, 800),
        const Size(1200, 900),
      );

      expect(position, const Offset(3740, -50));
    });
  });

  group('child window startup lifecycle', () {
    test('retries focus while the child window channel is starting', () async {
      var attempts = 0;
      messenger.setMockMethodCallHandler(windowRouterChannel, (call) async {
        expect(call.method, 'invokeMethod');
        attempts++;
        if (attempts < 3) {
          throw PlatformException(code: 'CHANNEL_UNREGISTERED', message: 'child engine is starting');
        }
        return null;
      });

      await WindowController.fromWindowId('42').focus();

      expect(attempts, 3);
    });

    testWidgets('shows the window when positioning fails', (tester) async {
      var showCalls = 0;
      messenger.setMockMethodCallHandler(windowManagerChannel, (call) async {
        if (call.method == 'getBounds') {
          throw PlatformException(code: 'TEST_ERROR', message: 'positioning failed');
        }
        if (call.method == 'isMinimized') return false;
        if (call.method == 'show') showCalls++;
        return null;
      });

      DesktopMultiWindow.prepareWindow();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pump();

      expect(showCalls, 1);
    });

    testWidgets('closes the hidden window when showing it also fails', (tester) async {
      var closeCalls = 0;
      messenger.setMockMethodCallHandler(windowManagerChannel, (call) async {
        if (call.method == 'getBounds' || call.method == 'show') {
          throw PlatformException(code: 'TEST_ERROR', message: '${call.method} failed');
        }
        if (call.method == 'isMinimized') return false;
        if (call.method == 'close') closeCalls++;
        return null;
      });

      DesktopMultiWindow.prepareWindow();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pump();

      expect(closeCalls, 1);
    });
  });

  group('native child window theme and close', () {
    const mainId = 'theme-main';
    const childId = 'theme-child';
    const light = {'mode': 'light', 'themeColor': 'Blue'};
    const dark = {'mode': 'dark', 'themeColor': 'Green'};

    setUp(() {
      messenger.setMockMethodCallHandler(windowsChannel, (call) async {
        expect(call.method, 'getWindowDefinition');
        return {'windowId': childId, 'windowArgument': ''};
      });
      messenger.setMockMethodCallHandler(screenChannel, (call) async {
        return switch (call.method) {
          'getPrimaryDisplay' => primary.toJson(),
          'getAllDisplays' => {
              'displays': [primary.toJson()]
            },
          'getCursorScreenPoint' => {'dx': 0.0, 'dy': 0.0},
          _ => throw MissingPluginException(call.method),
        };
      });
    });

    Object? nativeWindowReply(MethodCall call) => switch (call.method) {
          'getBounds' => {'x': 10.0, 'y': 20.0, 'width': 850.0, 'height': 900.0},
          'isMinimized' => false,
          _ => null,
        };

    Future<void> deliverTheme(Map<String, dynamic> settings) async {
      final reply = await messenger.handlePlatformMessage(
        windowRouterChannel.name,
        windowRouterChannel.codec.encodeMethodCall(MethodCall('methodCall', {
          'channel': 'mixin.one/window_controller/$childId',
          'method': 'applyTheme',
          'arguments': settings,
        })),
        null,
      );
      windowRouterChannel.codec.decodeEnvelope(reply!);
    }

    testWidgets('applies the main window theme before showing when a startup broadcast was missed', (tester) async {
      final events = <String>[];
      messenger.setMockMethodCallHandler(windowManagerChannel, (call) async {
        if (call.method == 'show') events.add('show');
        return nativeWindowReply(call);
      });
      messenger.setMockMethodCallHandler(windowRouterChannel, (call) async {
        if (call.method == 'registerMethodHandler') return null;
        expect(call.method, 'invokeMethod');
        expect(call.arguments['channel'], 'proxypin/main_window');
        expect(call.arguments['method'], 'getThemeSettings');
        return dark;
      });

      await DesktopMultiWindow.ensureInitialized(mainWindowId: mainId);
      DesktopMultiWindow.initializeFromArguments({'__theme': light});
      DesktopMultiWindow.onThemeChanged = (settings) {
        expect(settings, dark);
        events.add('theme');
      };
      DesktopMultiWindow.prepareWindow();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      expect(events, ['theme', 'show']);
    });

    testWidgets('keeps a live broadcast that overtakes the startup theme response', (tester) async {
      final startup = Completer<Map<String, dynamic>>();
      final applied = <Map<dynamic, dynamic>>[];
      messenger.setMockMethodCallHandler(windowManagerChannel, (call) async => nativeWindowReply(call));
      messenger.setMockMethodCallHandler(windowRouterChannel, (call) async {
        if (call.method == 'registerMethodHandler') return null;
        expect(call.arguments['method'], 'getThemeSettings');
        return startup.future;
      });

      await DesktopMultiWindow.ensureInitialized(mainWindowId: mainId);
      DesktopMultiWindow.onThemeChanged = applied.add;
      DesktopMultiWindow.prepareWindow();
      await tester.pumpWidget(const SizedBox());
      await deliverTheme(dark);
      startup.complete(light);
      await tester.pumpAndSettle();

      expect(applied, [dark]);
      expect(DesktopMultiWindow.themeSettings, dark);
    });

    test('closes the local native window through its window manager', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(windowManagerChannel, (call) async {
        calls.add(call.method);
        return null;
      });
      messenger.setMockMethodCallHandler(windowRouterChannel, (call) async {
        expect(call.method, 'registerMethodHandler');
        return null;
      });
      final controller = await DesktopMultiWindow.ensureInitialized(mainWindowId: mainId);
      calls.clear();

      await controller.close();

      expect(calls, ['close']);
    });
  });

  test('standalone title bar close retries a failed save and drains both queued edits before destroying once',
      () async {
    final directory = await Directory.systemTemp.createTemp('proxypin-close-queue-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/ui_config.json');
    await file.writeAsString(jsonEncode({'headerViewMode': 'table', 'detailHeaderDensity': 'compact'}));
    final primary = AppConfiguration.withConfigFile(file);
    final child = AppConfiguration.withConfigFile(file);
    await primary.initConfig();
    await child.initConfig();

    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final secondStarted = Completer<void>();
    final releaseSecond = Completer<void>();
    final destroyed = Completer<Map<String, dynamic>>();
    var failFirstSave = true;
    final events = <String>[];
    child.forwardDetailPreferences((changes) => DesktopMultiWindow.saveStandaloneChanges(() async {
          if (failFirstSave) {
            failFirstSave = false;
            events.add('save failed');
            throw PlatformException(code: 'standalone_window', message: 'Saving failed');
          }
          if (changes.containsKey('headerViewMode')) {
            firstStarted.complete();
            await releaseFirst.future;
          } else {
            secondStarted.complete();
            await releaseSecond.future;
          }
          await primary.saveWindowDetailPreferences(changes);
          events.add('saved ${changes.keys.single}');
        }));

    messenger.setMockMethodCallHandler(windowManagerChannel, (call) async {
      events.add(call.method);
      if (call.method == 'setPreventClose') {
        expect(call.arguments, {'isPreventClose': true});
      } else if (call.method == 'destroy') {
        destroyed.complete(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      }
      return null;
    });
    await DesktopMultiWindow.prepareStandaloneClose(child.flushConfig);

    final closeEvent =
        const StandardMethodCodec().encodeMethodCall(const MethodCall('onEvent', {'eventName': 'close'}));
    child.headerViewMode.value = 'text';
    await messenger.handlePlatformMessage(windowManagerChannel.name, closeEvent, null);
    await pumpEventQueue();
    expect(events, ['setPreventClose', 'save failed']);
    expect(jsonDecode(await file.readAsString())['headerViewMode'], 'table');

    final first = child.flushConfig();
    await firstStarted.future;
    child.detailLayout.value = (
      tabs: child.detailLayout.value.tabs,
      labels: child.detailLayout.value.labels,
      headers: HeaderDensity.dense,
    );
    final second = child.flushConfig();

    await messenger.handlePlatformMessage(windowManagerChannel.name, closeEvent, null);
    await messenger.handlePlatformMessage(windowManagerChannel.name, closeEvent, null);
    releaseFirst.complete();
    await secondStarted.future;
    await pumpEventQueue();
    final closedEarly = events.contains('destroy');
    releaseSecond.complete();
    await Future.wait([first, second]);
    final snapshot = await destroyed.future;
    await pumpEventQueue();

    expect(closedEarly, isFalse);
    expect(snapshot['headerViewMode'], 'text');
    expect(snapshot['detailHeaderDensity'], 'dense');
    await messenger.handlePlatformMessage(windowManagerChannel.name, closeEvent, null);
    await pumpEventQueue();
    expect(events, ['setPreventClose', 'save failed', 'saved headerViewMode', 'saved detailHeaderDensity', 'destroy']);
  });
}
