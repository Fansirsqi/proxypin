import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/ui/component/floating_dialog.dart';

final _caption = find.byKey(const ValueKey('floating-dialog-caption'));

Finder _surface(Finder caption) =>
    find.ancestor(of: caption, matching: find.byWidgetPredicate((widget) => widget is Material)).first;

Future<void> _open<T>(
  WidgetTester tester,
  WidgetBuilder builder, {
  TargetPlatform platform = TargetPlatform.linux,
  ValueChanged<T?>? onResult,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(platform: platform),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final result = await showDialog<T>(context: context, builder: builder);
            onResult?.call(result);
          },
          child: const Text('Open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> _drag(WidgetTester tester, Offset from, Offset delta) async {
  await tester.dragFrom(from, delta, kind: PointerDeviceKind.mouse);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('caption moves the dialog and viewport bounds keep it reachable', (tester) async {
    await _open<void>(
      tester,
      (_) => const FloatingDialog(child: SizedBox(width: 360, height: 260)),
    );
    final surface = _surface(_caption);
    final initial = tester.getRect(surface);
    await _drag(tester, tester.getCenter(_caption), const Offset(80, 60));
    final moved = tester.getRect(surface);
    expect(moved.left, greaterThan(initial.left));
    expect(moved.top, greaterThan(initial.top));
    expect(moved.size, initial.size);

    await _drag(tester, tester.getCenter(_caption), const Offset(900, 800));
    expect(tester.getRect(surface).right, 760);
    expect(tester.getRect(surface).bottom, 576);

    await tester.binding.setSurfaceSize(const Size(540, 440));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
    expect(tester.getRect(surface).right, 500);
    expect(tester.getRect(surface).bottom, 416);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edges and opposite corners resize while retaining focus and input', (tester) async {
    String? result;
    await _open<String>(
      tester,
      (context) => FloatingAlertDialog(
        title: const Text('Edit'),
        content: const SizedBox(width: 300, child: TextField(autofocus: true)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'saved'),
            child: const Text('Save'),
          ),
        ],
      ),
      onResult: (value) => result = value,
    );
    final input = find.byType(TextField);
    await tester.enterText(input, 'draft');
    final editor = tester.widget<EditableText>(find.byType(EditableText));
    final surface = _surface(_caption);
    final initial = tester.getRect(surface);
    await _drag(tester, Offset(initial.right - 2, initial.center.dy), const Offset(55, 20));
    final wider = tester.getRect(surface);
    expect(wider.width, greaterThan(initial.width));
    expect(wider.height, initial.height);
    expect(wider.topLeft, initial.topLeft);

    await _drag(tester, wider.bottomRight - const Offset(5, 5), const Offset(65, 72));
    final larger = tester.getRect(surface);
    expect(larger.width, greaterThan(wider.width));
    expect(larger.height, greaterThan(wider.height));
    expect(larger.topLeft, wider.topLeft);

    await _drag(tester, larger.topLeft + const Offset(5, 5), const Offset(150, 105));
    final smaller = tester.getRect(surface);
    expect(smaller.width, lessThan(initial.width));
    expect(smaller.height, lessThan(initial.height));
    expect(smaller.bottomRight, larger.bottomRight);
    final current = tester.widget<EditableText>(find.byType(EditableText));
    expect(current.controller, same(editor.controller));
    expect(current.focusNode, same(editor.focusNode));
    expect(current.focusNode.hasFocus, isTrue);
    expect(current.controller.text, 'draft');

    await tester.ensureVisible(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, 'saved');
    expect(tester.takeException(), isNull);
  });

  testWidgets('nested dialogs retain their own geometry and deliver a typed result', (tester) async {
    int? result;
    await _open<void>(
      tester,
      (context) => FloatingDialog(
        child: SizedBox(
          width: 400,
          height: 300,
          child: Center(
            child: TextButton(
              onPressed: () async {
                result = await showDialog<int>(
                  context: context,
                  builder: (context) => FloatingSimpleDialog(
                    title: const Text('Choose'),
                    children: [
                      SimpleDialogOption(onPressed: () => Navigator.pop(context, 42), child: const Text('Choice')),
                    ],
                  ),
                );
              },
              child: const Text('Nested'),
            ),
          ),
        ),
      ),
    );
    final surface = _surface(_caption);
    await _drag(tester, tester.getCenter(_caption), const Offset(40, 45));
    final outer = tester.getRect(surface);
    await tester.tap(find.text('Nested'));
    await tester.pumpAndSettle();
    expect(_caption, findsNWidgets(2));
    await _drag(tester, tester.getCenter(_caption.last), const Offset(-50, -40));
    await tester.tap(find.text('Choice'));
    await tester.pumpAndSettle();
    expect(result, 42);
    expect(tester.getRect(surface), outer);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(_caption, findsNothing);
  });

  testWidgets('mobile keeps the Material dialog interaction', (tester) async {
    await _open<void>(
      tester,
      (_) => const FloatingAlertDialog(title: Text('Mobile')),
      platform: TargetPlatform.android,
    );
    expect(find.text('Mobile'), findsOneWidget);
    expect(_caption, findsNothing);
  });
}
