import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/ui/component/window_resize_border.dart';
import 'package:proxypin/ui/desktop/widgets/windows_toolbar.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const mouse = PointerDeviceKind.mouse;
  const windowChannel = MethodChannel('window_manager');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final windowActions = <String>[];
  var maximized = false;
  var iconClicks = 0;

  setUp(() {
    windowActions.clear();
    maximized = false;
    iconClicks = 0;
    messenger.setMockMethodCallHandler(windowChannel, (call) async {
      switch (call.method) {
        case 'isMaximized':
          return maximized;
        case 'isMinimized':
          return false;
        case 'maximize':
          maximized = true;
        case 'unmaximize':
          maximized = false;
      }
      windowActions.add(call.method);
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(windowChannel, null));

  Widget buildApp({Widget? title}) {
    return MaterialApp(
      builder: (_, child) => WindowResizeBorder(child: child!),
      home: Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: SizedBox(
            height: 52,
            child: WindowsToolbar(
              title: title ??
                  Row(children: [
                    IconButton(icon: const Icon(Icons.delete), onPressed: () => iconClicks++),
                    const Spacer(),
                    IconButton(icon: const Icon(Icons.settings), onPressed: () => iconClicks++),
                  ]),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> doubleTap(WidgetTester tester, Offset position, {int buttons = kPrimaryMouseButton}) async {
    await tester.tapAt(position, kind: mouse, buttons: buttons);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(position, kind: mouse, buttons: buttons);
    await tester.pump(kDoubleTapMinTime);
  }

  testWidgets('双击空白区域最大化和还原，每次只发送一个窗口指令', (tester) async {
    await tester.pumpWidget(buildApp());
    final blank = tester.getCenter(find.byType(Spacer));

    await tester.tapAt(blank, kind: mouse);
    expect(windowActions, isEmpty);
    await tester.pump(const Duration(milliseconds: 100));
    final second = await tester.startGesture(blank, kind: mouse);
    await tester.pump();
    expect(windowActions, isEmpty);
    await second.moveBy(const Offset(3, 0));
    await second.up();
    await tester.pump();
    expect(windowActions, ['maximize']);

    await doubleTap(tester, blank);
    expect(windowActions, ['maximize', 'unmaximize']);
  });

  testWidgets('双击图标立即执行按钮回调，图标和空白不能组成双击', (tester) async {
    await tester.pumpWidget(buildApp());
    final button = find.widgetWithIcon(IconButton, Icons.delete);
    final icon = tester.getCenter(button);
    final buttonBounds = tester.getRect(button);
    final blank = buttonBounds.centerRight + const Offset(2, 0);
    final inside = buttonBounds.centerRight - const Offset(2, 0);

    await tester.tapAt(icon, kind: mouse);
    expect(iconClicks, 1);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(icon, kind: mouse);
    expect(iconClicks, 2);
    expect(windowActions, isEmpty);

    await tester.pump(kDoubleTapTimeout);
    await tester.tapAt(inside, kind: mouse);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(blank, kind: mouse);
    await tester.pump();
    expect(windowActions, isEmpty);
    expect(iconClicks, 3);

    await tester.pump(kDoubleTapTimeout);
    await tester.tapAt(blank, kind: mouse);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(inside, kind: mouse);
    await tester.pump();
    expect(windowActions, isEmpty);
    expect(iconClicks, 4);
  });

  testWidgets('相邻图标的即时点击打断两次空白点击', (tester) async {
    await tester.pumpWidget(buildApp());
    final button = tester.getRect(find.widgetWithIcon(IconButton, Icons.delete));
    final blank = button.centerRight + const Offset(2, 0);
    final inside = button.centerRight - const Offset(2, 0);
    const interval = Duration(milliseconds: 70);

    await tester.tapAt(blank, kind: mouse);
    await tester.pump(interval);
    await tester.tapAt(inside, kind: mouse);
    expect(iconClicks, 1);
    expect(windowActions, isEmpty);
    await tester.pump(interval);
    await tester.tapAt(blank, kind: mouse);
    await tester.pump();
    expect(windowActions, isEmpty);

    await tester.pump(interval);
    await tester.tapAt(blank, kind: mouse);
    await tester.pump(kDoubleTapMinTime);
    expect(windowActions, ['maximize']);
  });

  testWidgets('系统标题按钮打断空白点击序列', (tester) async {
    await tester.pumpWidget(buildApp(title: const Text('工具窗口')));
    final minimize = find.byType(WindowCaptionButton).first;
    final blank = tester.getRect(minimize).centerLeft - const Offset(2, 0);
    const interval = Duration(milliseconds: 70);

    await tester.tapAt(blank, kind: mouse);
    await tester.pump(interval);
    await tester.tap(minimize, kind: mouse);
    await tester.pump();
    expect(windowActions, ['minimize']);
    await tester.pump(interval);
    await tester.tapAt(blank, kind: mouse);
    await tester.pump(kDoubleTapMinTime);
    expect(windowActions, ['minimize']);
  });

  testWidgets('空白区单击后继续拖动只移动窗口', (tester) async {
    await tester.pumpWidget(buildApp());
    final blank = tester.getCenter(find.byType(Spacer));

    await tester.tapAt(blank, kind: mouse);
    await tester.pump(const Duration(milliseconds: 100));
    final drag = await tester.startGesture(blank, kind: mouse);
    await drag.moveBy(const Offset(50, 0));
    await drag.up();
    await tester.pump(kDoubleTapMinTime);
    expect(windowActions, ['startDragging']);
  });

  testWidgets('取消的按下和右键双击不切换窗口状态', (tester) async {
    await tester.pumpWidget(buildApp());
    final blank = tester.getCenter(find.byType(Spacer));

    final canceled = await tester.startGesture(blank, kind: mouse);
    await canceled.cancel();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(blank, kind: mouse);
    await tester.pump(kDoubleTapTimeout);
    await doubleTap(tester, blank, buttons: kSecondaryMouseButton);
    expect(windowActions, isEmpty);
  });

  testWidgets('子窗标题旁的空白可双击，边缘可缩放，关闭按钮仍请求关闭', (tester) async {
    await tester.pumpWidget(buildApp(title: const Text('工具窗口')));

    await doubleTap(tester, const Offset(400, 8));
    expect(windowActions, ['maximize']);

    final edgeDrag = await tester.startGesture(const Offset(400, 1), kind: mouse);
    await edgeDrag.moveBy(const Offset(0, 30));
    await edgeDrag.up();
    await tester.tap(find.byType(WindowCaptionButton).last, kind: mouse);
    await tester.pump();
    expect(windowActions, ['maximize', 'startResizing', 'close']);
  });
}
