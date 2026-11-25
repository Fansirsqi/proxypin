import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/websocket.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/component/standalone_window_payload.dart';
import 'package:proxypin/ui/content/panel.dart';
import 'package:screen_retriever/screen_retriever.dart';

class _ToolProcess implements Process {
  final _input = StreamController<List<int>>();
  final _output = StreamController<List<int>>();
  final _exit = Completer<int>();
  late final lines = StreamIterator(_input.stream.transform(utf8.decoder).transform(const LineSplitter()));

  @override
  final int pid;

  _ToolProcess(this.pid);

  @override
  late final IOSink stdin = IOSink(_input.sink);

  @override
  Stream<List<int>> get stdout => _output.stream;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => throw StateError('Unexpected kill');

  void send(Map<String, dynamic> message) => _output.add(utf8.encode('proxypin:tool:${jsonEncode(message)}\n'));

  Future<String> next() async {
    expect(await lines.moveNext(), isTrue);
    return lines.current;
  }

  Future<void> exit() async {
    _exit.complete(0);
    await _output.close();
    await lines.cancel();
  }
}

class _WorkerOnlyBytes extends ListBase<int> {
  final String? origin = Isolate.current.debugName;

  @override
  int get length {
    if (Isolate.current.debugName == origin) throw StateError('Body encoded on the launching isolate');
    return 4;
  }

  @override
  set length(int value) => throw UnsupportedError('immutable');

  @override
  int operator [](int index) => [0, 127, 128, 255][index];

  @override
  void operator []=(int index, int value) => throw UnsupportedError('immutable');
}

Future<String?> _launch(_ToolProcess process,
    {String name = 'RequestDetailPage', StandaloneWindowPayload? payload, String? source, bool singleton = false}) =>
    DesktopMultiWindow.launchStandaloneWindow(
      'Capture',
      const Size(800, 680),
      {'name': name},
      payload: payload,
      payloadSource: source,
      singleton: singleton,
      startProcess: () async => process,
    );

Future<Map<String, dynamic>> _message(_ToolProcess process) async =>
    jsonDecode(await process.next()) as Map<String, dynamic>;

Future<Map<String, dynamic>> _payloadStatus(_ToolProcess process) async {
  final message = await _message(process);
  expect(message['event'], '__windowPayload');
  return message['arguments'] as Map<String, dynamic>;
}

Future<List<String>> _receiveChunks(_ToolProcess process) async {
  final chunks = <String>[];
  while (true) {
    final frame = await _payloadStatus(process);
    if (frame['chunk'] case final String chunk) {
      chunks.add(chunk);
    } else {
      expect(frame, {'done': true});
      return chunks;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('new windows start with a bounded launch line and preserve captured bytes and frames', () async {
    final small = _ToolProcess(101);
    final large = _ToolProcess(102);
    final request = HttpRequest(HttpMethod.post, 'https://example.invalid/upload')
      ..body = _WorkerOnlyBytes()
      ..headers.set('X-Probe', 'capture');
    request.attributes['nonTransportState'] = ReceivePort();
    addTearDown((request.attributes['nonTransportState'] as ReceivePort).close);
    final body = Uint8List.fromList(List.generate(2 * 1024 * 1024, (index) => index & 255));
    final frame = WebSocketFrame(
      fin: true,
      opcode: 2,
      mask: true,
      payloadLength: 3,
      maskingKey: 5,
      payloadData: Uint8List.fromList([0, 128, 255]),
    )..isFromClient = true;
    final response = HttpResponse(HttpStatus.ok)
      ..body = body
      ..request = request
      ..messages.add(frame);

    await Future.wait([
      _launch(small, payload: StandaloneWindowPayload(request, null)),
      _launch(large, payload: StandaloneWindowPayload(request, response)),
    ]);
    final smallLine = await small.next();
    final largeLine = await large.next();
    expect(largeLine, smallLine);
    expect(jsonDecode(largeLine), containsPair('__windowPayload', true));
    expect(jsonDecode(largeLine), isNot(contains('request')));
    small.send({'__windowPayloadReady': true});
    large.send({'__windowPayloadReady': true});
    final transfers = await Future.wait([_receiveChunks(small), _receiveChunks(large)]);
    final restored = await StandaloneWindowPayload.decode(transfers.last);
    final receivedRequest = restored['request'] as HttpRequest;
    final receivedResponse = restored['response'] as HttpResponse;
    expect(receivedRequest.requestId, request.requestId);
    expect(receivedRequest.headers.get('X-Probe'), 'capture');
    expect(receivedRequest.body, [0, 127, 128, 255]);
    expect(receivedResponse.requestUrl, request.requestUrl);
    expect(Uint8List.fromList(receivedResponse.body!).buffer.asUint8List(), body);
    expect(receivedResponse.messages.single.toJson(), frame.toJson());
    final detail = multiWindow('captured-detail', {'name': 'RequestDetailPage', ...restored}) as NetworkTabController;
    expect(detail.request.get()!.response, same(receivedResponse));
    expect(detail.response.get()!.request, same(receivedRequest));
    final smallRestored = await StandaloneWindowPayload.decode(transfers.first);
    expect((smallRestored['request'] as HttpRequest).body, [0, 127, 128, 255]);
    expect(smallRestored['response'], isNull);
    await small.exit();
    await large.exit();
    print('capture raw_response_bytes=${body.length} small_launch_bytes=${smallLine.length + 1} '
        'large_launch_bytes=${largeLine.length + 1} pipe_chunks=${transfers.last.length}');
  });

  test('forwarding scopes payloads to their source and releases early target or source exits', () async {
    final source = _ToolProcess(201);
    final target = _ToolProcess(202);
    final other = _ToolProcess(203);
    await _launch(source, name: 'Source');
    await _message(source);
    await _launch(other, name: 'Other');
    await _message(other);
    final targetId = (await _launch(target, source: 'tool:${source.pid}'))!;
    expect(await _message(target), containsPair('__windowPayload', true));
    target.send({'__windowPayloadReady': true});

    Future<bool> forward(_ToolProcess sender, String receiver, Map<String, dynamic> frame) async {
      sender.send({'__windowPayload': receiver, 'frame': frame});
      final reply = await _message(sender);
      expect(reply['event'], '__windowPayloadAck');
      expect(reply['arguments']['id'], receiver);
      return reply['arguments']['accepted'] as bool;
    }

    expect(await forward(other, targetId, {'error': 'wrong sender'}), isFalse);
    final chunks = await StandaloneWindowPayload(null, HttpResponse(HttpStatus.ok)..body = [1, 2, 255]).encode();
    final transfer = _receiveChunks(target);
    for (final chunk in chunks) {
      expect(await forward(source, targetId, {'chunk': chunk}), isTrue);
    }
    expect(await forward(source, targetId, {'done': true}), isTrue);
    final response = (await StandaloneWindowPayload.decode(await transfer))['response'] as HttpResponse;
    expect(response.body, [1, 2, 255]);
    await target.exit();

    final earlyClose = _ToolProcess(204);
    final earlyId = (await _launch(earlyClose, source: 'tool:${source.pid}'))!;
    await _message(earlyClose);
    final earlyResult = forward(source, earlyId, {'chunk': chunks.first});
    await earlyClose.exit();
    expect(await earlyResult, isFalse);
    final lostSource = _ToolProcess(205);
    final lostId = (await _launch(lostSource, source: 'tool:${source.pid}'))!;
    await _message(lostSource);
    lostSource.send({'__windowPayloadReady': true});
    final accepted = forward(source, lostId, {'chunk': chunks.first});
    expect(await _payloadStatus(lostSource), {'chunk': chunks.first});
    expect(await accepted, isTrue);
    final notReady = _ToolProcess(206);
    final notReadyId = (await _launch(notReady, source: 'tool:${source.pid}'))!;
    await _message(notReady);
    source.send({'__windowPayload': notReadyId, 'frame': {'chunk': chunks.first}});
    await source.exit();
    expect(await _payloadStatus(lostSource), {'error': 'The source window closed during transfer'});
    expect(await _payloadStatus(notReady), {'error': 'The source window closed during transfer'});
    await lostSource.exit();
    await notReady.exit();
    await other.exit();
  });

  test('a real Linux pipe releases a child that exits during a large transfer', () async {
    const script = r'''
IFS= read -r launch || exit 2
printf '%s\n' 'proxypin:tool:{"__windowPayloadReady":true}'
IFS= read -r frame || exit 3
case "$frame" in
  *'"chunk":'*) exit 17 ;;
  *) exit 4 ;;
esac
''';
    final closed = Completer<String>();
    DesktopMultiWindow.onStandaloneClosed = (id) {
      if (!closed.isCompleted) closed.complete(id);
    };
    addTearDown(() => DesktopMultiWindow.onStandaloneClosed = null);
    final process = await Process.start('/bin/sh', ['-c', script]);
    final response = HttpResponse(HttpStatus.ok)..body = Uint8List(2 * 1024 * 1024);
    await DesktopMultiWindow.launchStandaloneWindow(
      'Capture',
      const Size(800, 680),
      {'name': 'PipeReceiver'},
      payload: StandaloneWindowPayload(null, response),
      startProcess: () async => process,
    );
    expect(await process.exitCode.timeout(const Duration(seconds: 10)), 17);
    expect(await closed.future.timeout(const Duration(seconds: 10)), 'tool:${process.pid}');
    expect(Directory.systemTemp.listSync().where((entry) => entry.path.contains('proxypin-window-')), isEmpty);
  }, skip: !Platform.isLinux);

  test('an encoding failure is terminal for that payload and a new window can retry', () async {
    final failed = _ToolProcess(251);
    final retried = _ToolProcess(252);
    final badResponse = HttpResponse(HttpStatus.ok)..body = [0x110000];
    await _launch(failed, payload: StandaloneWindowPayload(null, badResponse));
    await _message(failed);
    failed.send({'__windowPayloadReady': true});
    expect(await _payloadStatus(failed), {'error': 'Could not encode the window payload'});
    await failed.exit();

    final response = HttpResponse(HttpStatus.ok)..body = [0, 255];
    await _launch(retried, payload: StandaloneWindowPayload(null, response));
    await _message(retried);
    retried.send({'__windowPayloadReady': true});
    final restored = await StandaloneWindowPayload.decode(await _receiveChunks(retried));
    expect((restored['response'] as HttpResponse).body, [0, 255]);
    await retried.exit();
    expect(Directory.systemTemp.listSync().where((entry) => entry.path.contains('proxypin-window-')), isEmpty);
  });

  test('shutdown control and theme events pass during a payload transfer', () async {
    final child = _ToolProcess(291);
    final response = HttpResponse(HttpStatus.ok)..body = Uint8List(256 * 1024);
    await _launch(child, payload: StandaloneWindowPayload(null, response));
    await _message(child);
    child.send({'__windowPayloadReady': true});
    expect(await _payloadStatus(child), contains('chunk'));
    final theme = DesktopMultiWindow.invokeMethod('tool:${child.pid}', 'applyTheme', {'themeMode': 'dark'});
    final closing = DesktopMultiWindow.closeStandaloneWindows();
    final events = <String>[];
    while (true) {
      final frame = await _message(child);
      final event = frame['event'] as String;
      if (event == '__windowPayload') continue;
      events.add(event);
      if (event == 'prepare_close') child.send({'closeAttempt': frame['arguments'], 'ready': true});
      if (event == 'commit_close') {
        child.send({'closeSaved': true});
        await child.exit();
        break;
      }
    }
    await theme;
    await closing;
    DesktopMultiWindow.resumeStandaloneWindows();
    expect(events, ['applyTheme', 'prepare_close', 'commit_close']);
  });

  test('a singleton repeat starts only one process and sends focus', () async {
    final first = _ToolProcess(301);
    final second = _ToolProcess(302);
    await _launch(first, name: 'Empty window', singleton: true);
    await _message(first);
    await _launch(second, name: 'Empty window', singleton: true);
    expect(await _message(first), {'event': 'window_focus', 'arguments': null});
    await first.exit();
  });

  testWidgets('standalone startup keeps cursor-monitor geometry and reaches show in six calls', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    const window = MethodChannel('window_manager');
    const screen = MethodChannel('dev.leanflutter.plugins/screen_retriever');
    const display = Display(
      id: 'secondary',
      size: Size(1920, 1080),
      visiblePosition: Offset(-1920, 33),
      visibleSize: Size(1920, 1040),
    );
    final events = <String>[];
    Map? bounds;
    messenger.setMockMethodCallHandler(window, (call) async {
      events.add(call.method);
      if (call.method == 'setBounds') bounds = call.arguments as Map;
      return call.method == 'isMinimized' ? false : null;
    });
    messenger.setMockMethodCallHandler(screen, (call) async {
      events.add(call.method);
      return switch (call.method) {
        'getAllDisplays' => {'displays': [display.toJson()]},
        'getCursorScreenPoint' => {'dx': -200.0, 'dy': 100.0},
        _ => throw MissingPluginException(call.method),
      };
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(window, null);
      messenger.setMockMethodCallHandler(screen, null);
    });

    final launch = await DesktopMultiWindow.readStandaloneWindowArguments(
      Stream.value(utf8.encode('{"__windowTitle":"Capture","__windowSize":{"width":800,"height":680}}\n')),
    );
    DesktopMultiWindow.initializeFromArguments(jsonDecode(launch) as Map);
    final shown = DesktopMultiWindow.prepareWindow();
    expect(events, isEmpty);
    await tester.pumpWidget(const SizedBox());
    expect(events, isNot(contains('show')));
    await tester.pumpAndSettle();
    expect(await shown, isTrue);
    expect(events, ['setTitle', 'getAllDisplays', 'getCursorScreenPoint', 'setBounds', 'isMinimized', 'show']);
    expect(bounds, containsPair('x', -1360.0));
    expect(bounds, containsPair('y', 213.0));
    expect(bounds, containsPair('width', 800.0));
    expect(bounds, containsPair('height', 680.0));
    print('empty show_channel_calls=${events.length} sequence=${events.join(",")} bounds=$bounds');
  }, skip: !Platform.isLinux);

  test('the child decodes payload events and discards a partial payload at parent EOF', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const window = MethodChannel('window_manager');
    var destroyed = 0;
    messenger.setMockMethodCallHandler(window, (call) async {
      if (call.method == 'destroy') destroyed++;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(window, null));
    const script = r'''
while IFS= read -r line; do
  if [ "$line" = abort ]; then exit 19; fi
  printf '%s\n' "$line"
done
''';
    final parent = await Process.start('/bin/sh', ['-c', script]);
    parent.stderr.drain<void>().ignore();
    parent.stdin.done.ignore();
    void send(Map<String, dynamic> line) => parent.stdin.writeln(jsonEncode(line));
    void frame(Map<String, dynamic> args) => send({'event': '__windowPayload', 'arguments': args});

    send({'__windowPayload': true});
    final arguments = await DesktopMultiWindow.readStandaloneWindowArguments(parent.stdout);
    DesktopMultiWindow.initializeFromArguments(jsonDecode(arguments) as Map);
    final listener = DesktopMultiWindow.listenForStandaloneEvents();
    final first = DesktopMultiWindow.loadStandalonePayload();
    final chunks = await StandaloneWindowPayload(
      HttpRequest(HttpMethod.get, 'https://example.invalid/日本語')..body = [0, 128, 255],
      null,
    ).encode();
    for (final chunk in chunks) {
      frame({'chunk': chunk});
    }
    frame({'done': true});
    expect(((await first)['request'] as HttpRequest).body, [0, 128, 255]);

    DesktopMultiWindow.initializeFromArguments({'__windowPayload': true});
    final corrupt = DesktopMultiWindow.loadStandalonePayload();
    frame({'chunk': 'invalid base64!'});
    frame({'done': true});
    await expectLater(corrupt, throwsFormatException);

    DesktopMultiWindow.initializeFromArguments({'__windowPayload': true});
    final interrupted = DesktopMultiWindow.loadStandalonePayload();
    final checked = expectLater(interrupted, throwsStateError);
    frame({'chunk': chunks.first});
    parent.stdin.writeln('abort');
    expect(await parent.exitCode.timeout(const Duration(seconds: 10)), 19);
    await parent.stdin.close();
    await checked;
    await listener;
    expect(destroyed, 1);
    expect(DesktopMultiWindow.hasStandalonePayload, isFalse);
  }, skip: !Platform.isLinux);
}
