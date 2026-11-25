import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:code_forge/code_forge.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/http/content_type.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/storage/favorites.dart';
import 'package:proxypin/ui/component/json/json_viewer.dart';
import 'package:proxypin/ui/component/search/search_field.dart';
import 'package:proxypin/ui/component/theme_presets.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/content/body.dart';
import 'package:proxypin/ui/content/panel.dart';
import 'package:proxypin/ui/content/read_only_body.dart';
import 'package:scrollable_positioned_list_nic/scrollable_positioned_list_nic.dart';

void main() {
  final nativeLibraryAvailable = Platform.environment.containsKey('FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR');

  setUpAll(() async {
    await AppLocalizations.delegate.load(const Locale('en'));
    if (nativeLibraryAvailable) await RustLib.init();
  });

  final code = find.byType(CodeForge);
  final finderField = find.byType(TextField);

  testWidgets('code previews default to the detected language', (tester) async {
    for (final (mime, path, text, expectedType, language) in [
      ('Text/HTML; charset=utf-8', 'index', '<main>Hello</main>', ContentType.html, 'html'),
      ('application/x-yaml', 'config', 'pipeline:\n  enabled: true\n', ContentType.yaml, 'yaml'),
      ('text/plain', 'workflow.yml?raw=1', 'pipeline:\n  enabled: true\n', ContentType.text, 'yaml'),
      ('application/problem+json', 'error', '{"error": true}', ContentType.json, 'json'),
    ]) {
      final response = HttpResponse(HttpStatus.ok)
        ..request = HttpRequest(HttpMethod.get, 'https://example.test/$path')
        ..body = utf8.encode(text);
      response.headers.contentType = mime;
      expect(response.contentType, expectedType);
      await tester.pumpWidget(_app(ThemeData(), HttpBodyWidget(httpMessage: response, hideRequestRewrite: true)));
      await _waitForEditor(tester, code);
      expect(tester.widget<ReadOnlyBody>(find.byType(ReadOnlyBody)).language, language);
      expect(tester.widget<CodeForge>(code).language, isNotNull);
      await tester.tap(find.text('Text'));
      await tester.pump();
      expect(tester.widget<ReadOnlyBody>(find.byType(ReadOnlyBody)).language, isNull);
    }
  }, skip: !nativeLibraryAvailable);

  testWidgets('virtualized YAML paints syntax tokens and preserves indentation', (tester) async {
    final text = 'pipeline:\n${List.filled(80, '  - "run"').join('\n')}\n';
    final response = HttpResponse(HttpStatus.ok)..body = utf8.encode(text);
    response.headers.contentType = 'application/vnd.config+yaml';
    await tester.pumpWidget(_app(ThemeData(), HttpBodyWidget(httpMessage: response)));
    await _waitForBody(tester, () => _bodyTokens(tester, '"run"').isNotEmpty);
    final preview = tester.widget<ReadOnlyBody>(find.byType(ReadOnlyBody));
    expect(preview.text, text);
    expect(preview.language, 'yaml');
    expect(preview.virtualized, isTrue);
    expect(
      _bodyTokens(tester, '"run"').first.color,
      codeEditorTheme(tester.element(find.byType(ReadOnlyBody)))['string']!.color,
    );
  });

  for (final darkCode in [true, false]) {
    testWidgets('large body uses fixed ${darkCode ? 'dark' : 'light'} syntax with opposite app brightness',
        (tester) async {
      final configuration = AppConfiguration.withConfigFile(File('unused'))
        ..editorColorScheme = darkCode ? EditorColorScheme.atomOneDark : EditorColorScheme.atomOneLight;
      addTearDown(configuration.globalChange.dispose);
      final text = jsonEncode([
        'needle',
        if (darkCode) 'x' * 16384 else ...List.filled(80, 'line'),
      ]);
      final response = HttpResponse(HttpStatus.ok)..body = utf8.encode(text);
      response.headers.contentType = 'application/json';
      final theme = ThemeData(brightness: darkCode ? Brightness.light : Brightness.dark);
      await tester.pumpWidget(
        _app(theme, AppDisplaySettings(configuration: configuration, child: HttpBodyWidget(httpMessage: response))),
      );
      final chunk = find.byKey(const ValueKey('virtualized-code-chunk-0'));
      for (var attempt = 0; attempt < 50 && chunk.evaluate().isEmpty; attempt++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(chunk, findsOneWidget);
      final preview = tester.widget<ReadOnlyBody>(find.byType(ReadOnlyBody));
      expect(preview.language, 'json');
      expect(preview.prepareInBackground, darkCode);

      final body = find.byType(ReadOnlyBody);
      final expected = codeEditorTheme(tester.element(body));
      final surface = tester.widget<Material>(find.descendant(of: body, matching: find.byType(Material)).first).color!;
      expect(surface, expected['root']!.backgroundColor);
      expect(surface.computeLuminance(), darkCode ? lessThan(.15) : greaterThan(.6));
      final richText = tester.widget<Text>(chunk);
      Color? token;
      richText.textSpan!.visitChildren((span) {
        if (span is TextSpan && span.text == '"needle"') token = span.style?.color;
        return true;
      });
      expect(token, expected['string']!.color);
      expect(_contrast(token!, surface), greaterThanOrEqualTo(4.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('long JSON keeps token and painted background paired on every frame, starting dark=$darkCode',
        (tester) async {
      final initialScheme = darkCode ? EditorColorScheme.atomOneDark : EditorColorScheme.atomOneLight;
      final nextScheme = darkCode ? EditorColorScheme.atomOneLight : EditorColorScheme.atomOneDark;
      final settings = AppConfiguration.withConfigFile(File('unused'))..editorColorScheme = initialScheme;
      addTearDown(settings.globalChange.dispose);
      final response = HttpResponse(HttpStatus.ok)..body = utf8.encode(jsonEncode(['needle', 'needle', 'x' * 20000]));
      response.headers.contentType = 'application/json';
      await tester.pumpWidget(_app(
        ThemeData(brightness: darkCode ? Brightness.light : Brightness.dark),
        AppDisplaySettings(configuration: settings, child: HttpBodyWidget(httpMessage: response, previewHeight: 250)),
      ));
      await _waitForBody(tester, () => _bodyTokens(tester, '"needle"').length == 2);

      final initial = _bodyColors(tester, '"needle"');
      _setScheme(settings, nextScheme);
      await tester.pump();
      expect(_bodyColors(tester, '"needle"'), initial);
      final expected = codeEditorTheme(tester.element(find.byType(ReadOnlyBody)))['string']!.color;
      await _waitForBody(tester, () => _bodyColors(tester, '"needle"').foreground == expected);
      final settled = _bodyColors(tester, '"needle"');
      expect(settled.background, isNot(initial.background));
      expect(settled.foreground, isNot(initial.foreground));
      expect(settled.background.computeLuminance(), darkCode ? greaterThan(.6) : lessThan(.15));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('obsolete long-body palette cannot displace the active search, selection and viewport', (tester) async {
    final settings = AppConfiguration.withConfigFile(File('unused'))..editorColorScheme = EditorColorScheme.atomOneDark;
    addTearDown(settings.globalChange.dispose);
    final response = HttpResponse(HttpStatus.ok)
      ..body = utf8
          .encode(jsonEncode(List.generate(420, (index) => index % 140 == 0 ? 'needle' : 'line $index ${'x' * 80}')));
    response.headers.contentType = 'application/json';
    await tester.pumpWidget(_app(
      ThemeData.light(),
      AppDisplaySettings(configuration: settings, child: HttpBodyWidget(httpMessage: response, previewHeight: 250)),
    ));
    await _waitForBody(tester, () => _bodyTokens(tester, '"needle"').isNotEmpty);
    final initialSurface = _paintedBodySurface(tester);

    await tester.tap(find.byTooltip('Search'), kind: PointerDeviceKind.mouse);
    await tester.pump();
    final finder = tester.widget<SearchField>(find.byType(SearchField)).searchController;
    addTearDown(() async {
      if (finder.isSearchOverlayVisible) {
        finder.closeSearch();
        await tester.pump();
      }
    });
    await tester.enterText(finderField, 'needle');
    await _waitForBody(tester, () => find.text('1 / 3').evaluate().isNotEmpty);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    final focus = tester.widget<TextField>(finderField).focusNode!;
    expect(focus.hasFocus, isTrue);

    final list = find.byKey(const ValueKey('virtualized-highlight-text'));
    final scrollable = find.descendant(of: list, matching: find.byType(Scrollable)).first;
    double currentOffset() => tester.state<ScrollableState>(scrollable).position.pixels;
    tester.binding.handlePointerEvent(PointerScrollEvent(
      position: tester.getTopLeft(list) + const Offset(70, 140),
      kind: PointerDeviceKind.mouse,
      scrollDelta: const Offset(0, 300),
    ));
    await tester.pumpAndSettle();
    final scrollOffset = currentOffset();
    expect(scrollOffset, greaterThan(0));
    expect(find.byKey(const ValueKey('virtualized-code-chunk-141')).hitTestable(), findsNothing);

    void expectSearchAndScroll() {
      expect(find.text('2 / 3'), findsOneWidget);
      expect(tester.widget<TextField>(finderField).controller!.text, 'needle');
      expect(tester.widget<TextField>(finderField).focusNode, same(focus));
      expect(focus.hasFocus, isTrue);
      expect(currentOffset(), closeTo(scrollOffset, .01));
    }

    _setScheme(settings, EditorColorScheme.atomOneLight);
    await tester.pump();
    expect(_paintedBodySurface(tester), initialSurface);
    _setScheme(settings, EditorColorScheme.atomOneDark);
    for (var frame = 0; frame < 15; frame++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_paintedBodySurface(tester), initialSurface);
      expectSearchAndScroll();
    }

    _setScheme(settings, EditorColorScheme.atomOneLight);
    await tester.pump();
    expectSearchAndScroll();
    await _waitForBody(tester, () {
      expectSearchAndScroll();
      return _paintedBodySurface(tester) != initialSurface;
    });
    await tester.tap(find.byIcon(Icons.south), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('virtualized-code-chunk-281')).hitTestable(), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(SearchField), matching: find.byIcon(Icons.close)));
    await tester.pumpAndSettle();
    expect(finderField, findsNothing);
    await _waitForBody(tester, () => tester.widget<ScrollablePositionedList>(list).itemCount < 24);

    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final chunk = find.byKey(const ValueKey('virtualized-code-chunk-0'));
    await tester.scrollUntilVisible(chunk, -330, scrollable: scrollable);
    await tester.pumpAndSettle();
    final start = tester.getTopLeft(chunk) + const Offset(4, 26);
    expect(tester.getRect(list).contains(start), isTrue);
    final mouse = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump();
    await mouse.moveBy(const Offset(21, 0));
    await tester.pump();
    await mouse.moveBy(const Offset(15, 0));
    await tester.pump();
    await mouse.up();
    await _control(tester, LogicalKeyboardKey.keyC);
    final selection = clipboard;
    expect(selection, isNotEmpty);
    final body = tester.widget<ReadOnlyBody>(find.byType(ReadOnlyBody)).text;
    expect(selection!.length, lessThan(body.length));
    expect(body, contains(selection));

    _setScheme(settings, EditorColorScheme.atomOneDark);
    await _waitForBody(tester, () => _paintedBodySurface(tester) == initialSurface);
    clipboard = null;
    await _control(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, selection);
    await _control(tester, LogicalKeyboardKey.keyX);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(find.byType(EditableText), findsNothing);
    expect(tester.widget<ReadOnlyBody>(find.byType(ReadOnlyBody)).text, body);
    expect(_bodyTokens(tester, '"needle"'), isNotEmpty);

    await tester.tap(find.byTooltip('Copy'), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(clipboard, body);
    final localizations = AppLocalizations.of(tester.element(find.byTooltip('Copy')))!;
    expect(find.text(localizations.copied), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets('body supports pointer selection, read-only shortcuts, zoom and full copy', (tester) async {
    const text = 'First line\nSecond line with 😀';
    final response = HttpResponse(HttpStatus.ok)..body = utf8.encode(text);
    response.headers.contentType = 'text/plain';
    await tester.pumpWidget(_app(ThemeData(), HttpBodyWidget(httpMessage: response)));
    await _waitForEditor(tester, code);
    final editor = tester.widget<CodeForge>(code);
    expect(editor.readOnly, isTrue);
    expect(editor.controller!.text, text);

    final copy = find.byTooltip('Copy');
    final surface = tester.getRect(find.byType(ReadOnlyBody));
    final copyBounds = tester.getRect(copy);
    expect(copyBounds.bottom, lessThanOrEqualTo(surface.top));
    expect(tester.getTopRight(code).dx, surface.right);

    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final points = tester.getTopLeft(code) + const Offset(2, 8);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: points);
    await mouse.down(points);
    await tester.pump();
    await mouse.moveBy(const Offset(62, 0));
    await tester.pump();
    await mouse.up();
    expect(editor.controller!.selection.isCollapsed, isFalse);
    final selection = editor.controller!.selection;
    await _control(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, text.substring(selection.start, selection.end));
    await _control(tester, LogicalKeyboardKey.keyA);
    await _control(tester, LogicalKeyboardKey.keyC);
    expect(clipboard, text);
    await _control(tester, LogicalKeyboardKey.keyX);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(editor.controller!.text, text);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    tester.binding.handlePointerEvent(PointerScrollEvent(
      position: points,
      kind: PointerDeviceKind.mouse,
      scrollDelta: const Offset(0, -100),
    ));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(tester.widget<CodeForge>(code).textStyle!.fontSize, editor.textStyle!.fontSize! + 1);

    clipboard = null;
    await mouse.down(copyBounds.center);
    await mouse.up();
    await tester.pump();
    expect(clipboard, text);
    final localizations = AppLocalizations.of(tester.element(copy))!;
    expect(find.text(localizations.copied), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  }, skip: !nativeLibraryAvailable);

  testWidgets('request, response and overview use the read-only editor and retain alternate formats', (tester) async {
    final favorites = FavoriteStorage.list;
    FavoriteStorage.list = ListQueue();
    addTearDown(() => FavoriteStorage.list = favorites);
    await tester.binding.setSurfaceSize(const Size(960, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final body = utf8.encode('{"message":"sample"}');
    final request = HttpRequest(HttpMethod.post, 'https://example.test/resource')..body = body;
    request.headers.contentType = 'application/json';
    final response = HttpResponse(HttpStatus.ok)..body = body;
    response.headers.contentType = 'application/json';
    final detail = NetworkTabController(httpRequest: request, httpResponse: response);
    final theme = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal));
    await tester.pumpWidget(_app(theme, detail));
    await _waitForEditor(tester, code);

    Future<void> tapLabel(String label) async {
      final target = find.text(label);
      await tester.ensureVisible(target);
      await tester.pump();
      await tester.tap(target);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    for (final tab in ['Request', 'Response', 'Overview']) {
      await tapLabel(tab);
      await _waitForEditor(tester, code);
      final editor = tester.widget<CodeForge>(code);
      expect(editor.readOnly, isTrue);
      expect(editor.controller!.text, contains('"message": "sample"'));
      final reader = find.byType(ReadOnlyBody);
      final frame = find.descendant(of: reader, matching: find.byType(Material)).first;
      final height = tester.widget<ReadOnlyBody>(reader).height;
      expect(tester.getSize(frame).height, height);
      expect(tester.getSize(frame).width, tester.getSize(reader).width);
      expect(tester.getSize(code).height, height - 8);
      final background = Color.lerp(theme.colorScheme.surface, theme.colorScheme.onSurface, .045);
      expect(tester.widget<Material>(frame).color, background);
      expect(editor.editorTheme!['root']!.backgroundColor, background);
    }

    await tapLabel('Response');
    await tapLabel('JSON');
    expect(find.byType(JsonViewer), findsOneWidget);
    expect(code, findsNothing);
    await tapLabel('Hex');
    expect(find.byType(HexViewer), findsOneWidget);
    await tapLabel('Text');
    await _waitForEditor(tester, code);
    expect(tester.widget<CodeForge>(code).controller!.text, utf8.decode(body));
  }, skip: !nativeLibraryAvailable);

  testWidgets('finder keeps the active match, scroll and focus across syntax changes', (tester) async {
    final text = List.generate(60, (index) => index % 20 == 0 ? 'needle' : 'line $index').join('\n');
    final response = HttpResponse(HttpStatus.ok)..body = utf8.encode(text);
    response.headers.contentType = 'text/plain';
    final view = HttpBodyWidget(httpMessage: response, previewHeight: 170);
    final configuration = AppConfiguration.withConfigFile(File('unused'));
    addTearDown(configuration.globalChange.dispose);
    final configured = AppDisplaySettings(configuration: configuration, child: view);
    final colors = ColorScheme.fromSeed(seedColor: Colors.indigo);
    ThemeData theme(ThemePreset preset) => ThemeData(
          colorScheme: colors,
          extensions: [ActiveThemePreset(preset)],
        );
    await tester.pumpWidget(_app(theme(ThemePreset.atomOne), configured));
    await _waitForEditor(tester, code);

    final initial = tester.widget<CodeForge>(code);
    final initialState = tester.state(code);
    await tester.tapAt(tester.getTopLeft(code) + const Offset(2, 8), kind: PointerDeviceKind.mouse);
    await tester.pump();
    await _control(tester, LogicalKeyboardKey.keyF);
    await tester.pump();
    await tester.enterText(finderField, 'needle');
    await tester.pump();
    final finder = initial.findController!;
    expect(finder.matchCount, 3);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump(const Duration(milliseconds: 400));
    expect(finder.currentMatchIndex, 1);
    final offset = initial.verticalScrollController!.offset;
    expect(offset, greaterThan(0));

    await tester.pumpWidget(_app(theme(ThemePreset.atomOne), configured));
    expect(tester.state(code), same(initialState));
    await tester.pumpWidget(_app(theme(ThemePreset.catppuccin), configured));
    await tester.pump();
    final updated = tester.widget<CodeForge>(code);
    expect(tester.state(code), isNot(same(initialState)));
    expect(updated.findController, same(finder));
    expect(finder.findInputController.text, 'needle');
    expect(finder.currentMatchIndex, 1);
    expect(finder.findInputFocusNode.hasFocus, isTrue);
    expect(updated.verticalScrollController!.offset, closeTo(offset, 1));

    final dark = ThemeData(
        colorScheme: ThemePreset.catppuccin.colorScheme(Brightness.dark),
        extensions: const [ActiveThemePreset(ThemePreset.catppuccin)]);
    await tester.pumpWidget(_app(dark, configured));
    await tester.pump();
    final restyled = tester.widget<CodeForge>(code);
    expect(finder.currentMatchIndex, 1);
    expect(finder.findInputFocusNode.hasFocus, isTrue);
    expect(restyled.verticalScrollController!.offset, closeTo(offset, 1));
    configuration.editorColorScheme = EditorColorScheme.atomOneLight;
    configuration.globalChange.value = !configuration.globalChange.value;
    await tester.pump();
    final fixed = tester.widget<CodeForge>(code);
    final fixedState = tester.state(code);
    final fixedRoot = codeEditorTheme(tester.element(find.byType(ReadOnlyBody)))['root']!;
    expect(fixed.editorTheme!['root']!.backgroundColor, fixedRoot.backgroundColor);
    expect(fixed.editorTheme!['root']!.backgroundColor!.computeLuminance(), greaterThan(.5));
    expect(finder.currentMatchIndex, 1);
    expect(finder.findInputFocusNode.hasFocus, isTrue);
    await tester.pumpWidget(_app(theme(ThemePreset.catppuccin), configured));
    expect(tester.state(code), same(fixedState));
    expect(tester.widget<CodeForge>(code).verticalScrollController!.offset, closeTo(offset, 1));

    for (final editor in [initial, updated, restyled, fixed]) {
      final root = editor.editorTheme!['root']!;
      final backgrounds = [
        root.backgroundColor!,
        editor.selectionStyle!.selectionColor,
        editor.matchHighlightStyle!.currentMatchStyle.backgroundColor!,
        editor.matchHighlightStyle!.otherMatchStyle.backgroundColor!,
      ];
      for (final style in editor.editorTheme!.values.where((style) => style.color != null)) {
        for (final background in backgrounds) {
          expect(_contrast(style.color!, background), greaterThanOrEqualTo(4.5));
        }
      }
    }

    await tester.tap(find.byTooltip('Next'), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(finder.currentMatchIndex, 2);
    await tester.tap(finderField, kind: PointerDeviceKind.mouse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(finderField, findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  }, skip: !nativeLibraryAvailable);
}

double _contrast(Color foreground, Color background) {
  final values = [foreground.computeLuminance(), background.computeLuminance()]..sort();
  return (values.last + .05) / (values.first + .05);
}

void _setScheme(AppConfiguration configuration, EditorColorScheme scheme) {
  configuration.editorColorScheme = scheme;
  configuration.globalChange.value = !configuration.globalChange.value;
}

Color _paintedBodySurface(WidgetTester tester) {
  final body = find.byType(ReadOnlyBody);
  final shape = find.descendant(of: body, matching: find.byType(PhysicalShape)).first;
  return tester.renderObject<RenderPhysicalShape>(shape).color;
}

Iterable<TextStyle> _bodyTokens(WidgetTester tester, String token) sync* {
  final rows = find.descendant(
    of: find.byKey(const ValueKey('virtualized-highlight-text')),
    matching: find.byType(Text),
  );
  for (final row in tester.widgetList<Text>(rows)) {
    final tokens = <TextStyle>[];
    row.textSpan?.visitChildren((span) {
      if (span is TextSpan && span.text == token && span.style != null) tokens.add(span.style!);
      return true;
    });
    yield* tokens;
  }
}

({Color foreground, Color background}) _bodyColors(WidgetTester tester, String token) {
  final foregrounds = _bodyTokens(tester, token).map((style) => style.color!).toSet();
  expect(foregrounds, hasLength(1));
  final foreground = foregrounds.single;
  final background = _paintedBodySurface(tester);
  expect(_contrast(foreground, background), greaterThanOrEqualTo(4.5));
  return (foreground: foreground, background: background);
}

Future<void> _waitForBody(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 60 && !condition(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(condition(), isTrue);
}

Widget _app(ThemeData theme, Widget body) => MaterialApp(
      theme: theme,
      themeAnimationDuration: Duration.zero,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Padding(padding: const EdgeInsets.all(12), child: body)),
    );

Future<void> _control(WidgetTester tester, LogicalKeyboardKey key) async {
  final modifier = Platform.isMacOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

Future<void> _waitForEditor(WidgetTester tester, Finder code) async {
  for (var frame = 0; frame < 30 && code.evaluate().isEmpty; frame++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(code, findsOneWidget);
}
