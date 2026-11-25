import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/network.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/launch/launch.dart';

const _prefix = 'proxypin:tool:';
const _windowChannel = MethodChannel('window_manager');

StreamIterator<String> _lines(Stream<List<int>> bytes) =>
    StreamIterator(bytes.transform(utf8.decoder).transform(const LineSplitter()));

Future<Map<String, dynamic>> _read(StreamIterator<String> stream, {String prefix = ''}) async {
  expect(await stream.moveNext(), isTrue);
  expect(stream.current, startsWith(prefix));
  return jsonDecode(stream.current.substring(prefix.length)) as Map<String, dynamic>;
}

class _ToolProcess implements Process {
  final _input = StreamController<List<int>>();
  final _output = StreamController<List<int>>();
  final _exit = Completer<int>();
  late final commands = _lines(_input.stream);
  int killCalls = 0;

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
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalls++;
    return false;
  }

  void send(Map<String, dynamic> message) => _output.add(utf8.encode('$_prefix${jsonEncode(message)}\n'));

  void exit(int code) => _exit.complete(code);

  Future<void> finishOutput() => _output.close();
}

class _CloseOutput extends Fake implements IOSink {
  final lines = StreamController<List<int>>();
  Completer<void> allowReceiptFlush = Completer<void>();
  bool _sendingReceipt = false;

  @override
  void writeln([Object? object = '']) {
    final line = object.toString();
    _sendingReceipt = (jsonDecode(line.substring(_prefix.length)) as Map)['closeSaved'] == true;
    lines.add(utf8.encode('$line\n'));
  }

  @override
  Future<void> flush() => _sendingReceipt ? allowReceiptFlush.future : Future.value();
}

class _ExitTestProxy extends ProxyServer {
  int stopCalls = 0;

  _ExitTestProxy() : super(Configuration.fromJson({'startup': false, 'enableSystemProxy': false}));

  @override
  Future<Server?> stop() async {
    stopCalls++;
    throw StateError('Test stopped before native exit');
  }
}

Future<void> _launch(_ToolProcess tool) async {
  await DesktopMultiWindow.launchStandaloneWindow(
    'Test tool',
    const Size(800, 600),
    {'name': 'Test ${tool.pid}'},
    startProcess: () async => tool,
  );
  expect((await _read(tool.commands))['name'], 'Test ${tool.pid}');
}

Future<int> _event(_ToolProcess tool, String name) async {
  final message = await _read(tool.commands);
  expect(message['event'], name);
  return message['arguments'] as int;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    DesktopMultiWindow.resumeStandaloneWindows();
    DesktopMultiWindow.onSaveDetailPreferences = null;
  });

  test('the primary keeps IPC available until child writes succeed and confirmed children exit', () async {
    final directory = await Directory.systemTemp.createTemp('proxypin-shutdown-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/ui_config.json');
    final configuration = AppConfiguration.withConfigFile(file);
    final saveStarted = Completer<void>();
    final allowSave = Completer<void>();
    DesktopMultiWindow.onSaveDetailPreferences = (changes) async {
      saveStarted.complete();
      await allowSave.future;
      await configuration.saveWindowDetailPreferences(changes);
    };

    final tool = _ToolProcess(101);
    await _launch(tool);
    var finished = false;
    final close = DesktopMultiWindow.closeStandaloneWindows().then((_) => finished = true);
    final attempt = await _event(tool, 'prepare_close');
    tool.send({
      'method': 'saveDetailPreferences',
      'arguments': {'headerViewMode': 'text'}
    });
    await saveStarted.future;
    expect(await file.exists(), isFalse);
    expect(finished, isFalse);
    allowSave.complete();
    expect(await _read(tool.commands), {'result': true});
    expect(jsonDecode(await file.readAsString())['headerViewMode'], 'text');

    tool.send({'closeAttempt': attempt, 'ready': true});
    expect(await _event(tool, 'commit_close'), attempt);
    tool.exit(0);
    await pumpEventQueue();
    expect(finished, isFalse);
    tool.send({'closeSaved': true});
    await tool.finishOutput();
    await close;
    expect(finished, isTrue);
    expect(tool.killCalls, 0);
    await tool.commands.cancel();
  });

  test('save errors and timeout cancel the attempt, and a fresh attempt closes the same children', () async {
    final healthy = _ToolProcess(102);
    final stalled = _ToolProcess(103);
    await _launch(healthy);
    await _launch(stalled);

    final failed = expectLater(DesktopMultiWindow.closeStandaloneWindows(), throwsA(isA<StateError>()));
    final firstAttempt = await _event(healthy, 'prepare_close');
    expect(await _event(stalled, 'prepare_close'), firstAttempt);
    healthy.send({'closeAttempt': firstAttempt, 'ready': true});
    stalled.send({'closeAttempt': firstAttempt, 'closeError': 'disk write failed'});
    await failed;
    expect(await _event(healthy, 'cancel_close'), firstAttempt);
    expect(await _event(stalled, 'cancel_close'), firstAttempt);

    final timedOut = expectLater(
      DesktopMultiWindow.closeStandaloneWindows(timeout: const Duration(milliseconds: 100)),
      throwsA(isA<TimeoutException>()),
    );
    final secondAttempt = await _event(healthy, 'prepare_close');
    expect(await _event(stalled, 'prepare_close'), secondAttempt);
    healthy.send({'closeAttempt': secondAttempt, 'ready': true});
    stalled.send({'closeAttempt': firstAttempt, 'ready': true});
    await timedOut;
    expect(await _event(healthy, 'cancel_close'), secondAttempt);
    expect(await _event(stalled, 'cancel_close'), secondAttempt);

    final retry = DesktopMultiWindow.closeStandaloneWindows();
    final thirdAttempt = await _event(healthy, 'prepare_close');
    expect(thirdAttempt, greaterThan(secondAttempt));
    expect(await _event(stalled, 'prepare_close'), thirdAttempt);
    for (final tool in [healthy, stalled]) {
      tool.send({'closeAttempt': thirdAttempt, 'ready': true});
    }
    for (final tool in [healthy, stalled]) {
      expect(await _event(tool, 'commit_close'), thirdAttempt);
      tool.send({'closeSaved': true});
      await tool.finishOutput();
      tool.exit(0);
    }
    await retry;
    for (final tool in [healthy, stalled]) {
      expect(tool.killCalls, 0);
      await tool.commands.cancel();
    }
  });

  test('a zero process exit without a save receipt does not confirm shutdown', () async {
    final tool = _ToolProcess(104);
    await _launch(tool);
    final close = expectLater(DesktopMultiWindow.closeStandaloneWindows(), throwsA(isA<StateError>()));
    await _event(tool, 'prepare_close');
    tool.exit(0);
    await tool.finishOutput();
    await close;
    expect(tool.killCalls, 0);
    await tool.commands.cancel();
  });

  testWidgets('Linux framework exit runs the save path while the native close guard is active', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    var preventClose = false;
    var destroyCalls = 0;
    messenger.setMockMethodCallHandler(_windowChannel, (call) async {
      if (call.method == 'setPreventClose') preventClose = call.arguments['isPreventClose'] as bool;
      if (call.method == 'isPreventClose') return preventClose;
      if (call.method == 'isVisible') return true;
      if (call.method == 'destroy') destroyCalls++;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_windowChannel, null));
    final proxy = _ExitTestProxy();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SocketLaunch(proxyServer: proxy, startup: false)),
    ));
    await tester.pumpAndSettle();
    expect(preventClose, isTrue);

    final observer = tester.state(find.byType(SocketLaunch)) as WidgetsBindingObserver;
    expect(await observer.didRequestAppExit(), AppExitResponse.cancel);
    expect(proxy.stopCalls, 1);
    expect(preventClose, isTrue);
    expect(destroyCalls, 0);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  }, skip: !Platform.isLinux);

  test('the child cancels a delayed commit, drains writes during receipt flush and retries failures', () async {
    final input = StreamController<List<int>>();
    final output = _CloseOutput();
    final replies = _lines(output.lines.stream);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final directory = await Directory.systemTemp.createTemp('proxypin-close-receipt-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/ui_config.json');
    final config = AppConfiguration.withConfigFile(file);
    final destroyed = Completer<void>();
    var destroyCount = 0;
    String? headerModeAtDestroy;
    messenger.setMockMethodCallHandler(_windowChannel, (call) async {
      if (call.method == 'destroy') {
        destroyCount++;
        if (await file.exists()) {
          headerModeAtDestroy = jsonDecode(await file.readAsString())['headerViewMode'] as String;
        }
        if (!destroyed.isCompleted) destroyed.complete();
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_windowChannel, null));

    void send(String event, int attempt) =>
        input.add(utf8.encode('${jsonEncode({'event': event, 'arguments': attempt})}\n'));
    input.add(utf8.encode('{}\n'));
    await DesktopMultiWindow.readStandaloneWindowArguments(input.stream);
    final delayedCommit = Completer<void>();
    final allowCommit = Completer<void>();
    var configWrites = Future<void>.value();
    var flushes = 0;
    await DesktopMultiWindow.prepareStandaloneClose(() async {
      flushes++;
      if (flushes == 2) {
        delayedCommit.complete();
        await allowCommit.future;
      }
      await configWrites;
    }, configWriteToken: () => configWrites, closeOutput: output);
    final events = DesktopMultiWindow.listenForStandaloneEvents();

    var editAttempts = 0;
    await expectLater(
      DesktopMultiWindow.saveStandaloneChanges(() async {
        editAttempts++;
        if (editAttempts < 3) throw StateError('disk unavailable');
      }, retryOnClose: true),
      throwsA(isA<StateError>()),
    );
    send('prepare_close', 1);
    expect(await _read(replies, prefix: _prefix), containsPair('closeAttempt', 1));
    expect(flushes, 0);

    send('prepare_close', 2);
    expect(await _read(replies, prefix: _prefix), {'closeAttempt': 2, 'ready': true});
    send('commit_close', 2);
    await delayedCommit.future;
    send('cancel_close', 2);
    await pumpEventQueue();
    allowCommit.complete();
    await pumpEventQueue();
    expect(destroyCount, 0);

    var importAttempts = 0;
    await expectLater(DesktopMultiWindow.saveStandaloneChanges(() async {
      importAttempts++;
      throw StateError('import write failed');
    }), throwsA(isA<StateError>()));
    send('prepare_close', 3);
    expect(await _read(replies, prefix: _prefix), {'closeAttempt': 3, 'closeError': 'Bad state: import write failed'});
    expect(importAttempts, 1);
    expect(destroyCount, 0);

    await DesktopMultiWindow.saveStandaloneChanges(() async {
      importAttempts++;
    });
    send('prepare_close', 4);
    expect(await _read(replies, prefix: _prefix), {'closeAttempt': 4, 'ready': true});
    send('commit_close', 4);
    expect(await _read(replies, prefix: _prefix), {'closeSaved': true});

    var retryEnabled = false;
    var lateSaveAttempts = 0;
    await expectLater(
      DesktopMultiWindow.saveStandaloneChanges(() async {
        lateSaveAttempts++;
        if (!retryEnabled) throw StateError('late write failed');
        await config.saveWindowDetailPreferences({'headerViewMode': 'table'});
      }, retryOnClose: true),
      throwsA(isA<StateError>()),
    );
    output.allowReceiptFlush.complete();
    expect(await _read(replies, prefix: _prefix), {'closeSaved': false});
    expect(await _read(replies, prefix: _prefix), {'closeAttempt': 4, 'closeError': 'Bad state: late write failed'});
    expect(destroyCount, 0);
    expect(await file.exists(), isFalse);
    send('cancel_close', 4);

    retryEnabled = true;
    output.allowReceiptFlush = Completer<void>();
    send('prepare_close', 5);
    expect(await _read(replies, prefix: _prefix), {'closeAttempt': 5, 'ready': true});
    expect(jsonDecode(await file.readAsString())['headerViewMode'], 'table');
    send('commit_close', 5);
    expect(await _read(replies, prefix: _prefix), {'closeSaved': true});

    final allowConfigWrite = Completer<void>();
    configWrites = allowConfigWrite.future;
    output.allowReceiptFlush.complete();
    await pumpEventQueue();
    expect(destroyCount, 0);
    send('cancel_close', 5);
    await pumpEventQueue();
    allowConfigWrite.complete();
    expect(await _read(replies, prefix: _prefix), {'closeSaved': false});
    expect(destroyCount, 0);

    output.allowReceiptFlush = Completer<void>();
    send('prepare_close', 6);
    expect(await _read(replies, prefix: _prefix), {'closeAttempt': 6, 'ready': true});
    send('commit_close', 6);
    expect(await _read(replies, prefix: _prefix), {'closeSaved': true});

    final saving = Completer<void>();
    final allowSave = Completer<void>();
    final save = DesktopMultiWindow.saveStandaloneChanges(() async {
      saving.complete();
      await allowSave.future;
      await config.saveWindowDetailPreferences({'headerViewMode': 'text'});
    }, retryOnClose: true);
    await saving.future;
    output.allowReceiptFlush.complete();
    await pumpEventQueue();
    final destroyedWhileSaving = destroyCount != 0;
    allowSave.complete();
    await save;
    await destroyed.future;
    expect(destroyedWhileSaving, isFalse);
    expect(headerModeAtDestroy, 'text');
    expect(destroyCount, 1);
    expect(editAttempts, 3);
    expect(importAttempts, 2);
    expect(lateSaveAttempts, 3);
    await input.close();
    await events;
    await replies.cancel();
    await output.lines.close();
  });
}
