import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_dispatcher.dart';
import 'package:proxypin/network/channel/network.dart';
import 'package:proxypin/network/util/file_read.dart';
import 'package:proxypin/ui/component/proxy_port_setting.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory appSupport;
  late Directory home;
  late String? previousHome;

  setUpAll(() async {
    appSupport = await Directory.systemTemp.createTemp('proxypin-app-support-test-');
  });

  tearDownAll(() => appSupport.delete(recursive: true));

  setUp(() async {
    home = await Directory.systemTemp.createTemp('proxypin-config-test-');
    previousHome = FileRead.userHome;
    FileRead.userHome = home.path;
    messenger.setMockMethodCallHandler(pathProvider, (_) async => appSupport.path);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathProvider, null);
    FileRead.userHome = previousHome;
    await home.delete(recursive: true);
  });

  test('invalid saved ports recover without losing other settings', () async {
    for (final invalid in [null, 0, -1, 65536, 9099.0, '9099', true]) {
      final config = Configuration.fromJson({'port': invalid, 'enableSystemProxy': false, 'startup': true});
      expect(config.port, Configuration.defaultPort);
      expect(config.startup, isTrue);
      expect(config.enableSystemProxy, isFalse);
      await config.flushConfig();
      expect(await _savedPort(), Configuration.defaultPort);
    }
    for (final valid in [1, 65535]) {
      expect(Configuration.fromJson({'port': valid}).port, valid);
    }
  });

  test('server and configuration reject invalid port assignments and saves', () async {
    final config = Configuration.fromJson({'enableSystemProxy': false});
    final proxy = ProxyServer(config);
    for (final invalid in [0, -1, 65536]) {
      expect(() => config.port = invalid, throwsRangeError);
      await expectLater(config.savePort(invalid), throwsRangeError);
      await expectLater(proxy.changePort(invalid), throwsRangeError);
    }
    expect(proxy.port, Configuration.defaultPort);
    expect(await (await Configuration.configFile()).exists(), isFalse);

    for (final valid in [65535, 1]) {
      await proxy.changePort(valid);
      expect(proxy.isRunning, isFalse);
      expect(proxy.port, valid);
      expect(await _savedPort(), valid);
    }
  });

  testWidgets('port dialog rejects zero, signed values and out-of-range paste', (tester) async {
    final config = Configuration.fromJson({'enableSystemProxy': false});
    final proxy = ProxyServer(config);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(builder: (context) {
          return TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ProxyPortDialog(proxyServer: proxy),
            ),
            child: const Text('Open port settings'),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open port settings'));
    await tester.pumpAndSettle();

    for (final invalid in ['0', '-1', '65536', '100000']) {
      final field = find.byType(TextField);
      await tester.enterText(field, invalid);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).decoration!.errorText, '1–65535');
      expect(proxy.port, Configuration.defaultPort);
    }
  });

  test('occupied destination preserves the same listener and saved port', () async {
    final (proxy, active) = await _runningProxy();
    final occupied = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(occupied.close);
    final oldPort = proxy.port;

    await expectLater(proxy.changePort(occupied.port), throwsA(isA<SocketException>()));
    expect(proxy.server, same(active));
    expect(proxy.isRunning, isTrue);
    expect(proxy.port, oldPort);
    expect(await _savedPort(), oldPort);
    await _connect(oldPort);
  });

  test('failed replacement preserves the original file and listener during an overlapping save', () async {
    final (proxy, active) = await _runningProxy();
    final oldPort = proxy.port;
    final configFile = await Configuration.configFile();
    final original = await configFile.readAsBytes();
    final nextPort = await _unusedPort();
    final renameStarted = Completer<void>();
    final releaseRename = Completer<void>();
    var renames = 0;

    await _withStagedRename(() async {
      final failure = expectLater(proxy.changePort(nextPort), throwsA(isA<FileSystemException>()));
      await renameStarted.future;
      expect(proxy.port, oldPort);
      expect(proxy.server, same(active));
      expect(await configFile.readAsBytes(), original);
      expect(await _savedPort(), oldPort);
      await _connect(oldPort);
      await _connect(nextPort);

      proxy.configuration.enableSocks5 = false;
      final backgroundSave = proxy.configuration.flushConfig();
      expect(renames, 1);
      releaseRename.complete();
      await failure;
      await backgroundSave;
    }, (staged, target) async {
      renames++;
      if (renames == 1) {
        renameStarted.complete();
        await releaseRename.future;
        expect(await configFile.readAsBytes(), original);
        throw FileSystemException('Injected config replacement failure', target);
      }
      return staged.rename(target);
    });

    expect(renames, 2);
    expect(proxy.server, same(active));
    expect(proxy.port, oldPort);
    expect(await _savedPort(), oldPort);
    expect(jsonDecode(await configFile.readAsString())['enableSocks5'], isFalse);
    expect(await configFile.parent.list().map((entry) => entry.path).toList(), [configFile.path]);
    await _connect(oldPort);
    await (await ServerSocket.bind(InternetAddress.anyIPv4, nextPort)).close();

    await proxy.changePort(nextPort);
    expect(proxy.port, nextPort);
    expect(await _savedPort(), nextPort);
    expect(active.isRunning, isFalse);
    await _connect(nextPort);
  });

  test('Linux system proxy is restored after an unsuccessful port commit', () async {
    final fakeLog = File(Platform.environment['PROXYPIN_TEST_SYSTEM_PROXY_LOG']!);
    final (proxy, active) = await _runningProxy();
    final oldPort = proxy.port;
    final configFile = await Configuration.configFile();
    final original = await configFile.readAsBytes();
    final nextPort = await _unusedPort();
    proxy.configuration.enableSystemProxy = true;

    await _withStagedRename(() async {
      await expectLater(proxy.changePort(nextPort), throwsA(isA<FileSystemException>()));
    }, (_, target) async {
      throw FileSystemException('Injected config replacement failure', target);
    });
    expect(proxy.server, same(active));
    expect(await configFile.readAsBytes(), original);
    final portChanges = (await fakeLog.readAsLines()).where((line) => line.contains('proxy.http port '));
    expect(portChanges, [
      'set org.gnome.system.proxy.http port $nextPort',
      'set org.gnome.system.proxy.http port $oldPort',
    ]);
  }, skip: !Platform.isLinux || Platform.environment['PROXYPIN_TEST_SYSTEM_PROXY_LOG'] == null);
}

Future<int> _savedPort() async => jsonDecode(await (await Configuration.configFile()).readAsString())['port'] as int;

Future<int> _unusedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _connect(int port) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 2));
  socket.destroy();
}

Future<(ProxyServer, Server)> _runningProxy() async {
  final config = Configuration.fromJson({'enableSystemProxy': false});
  final active = Server(config)
    ..initChannel((channel) => channel.dispatcher.channelHandle(RawCodec(), _PassiveHandler()));
  final socket = await active.bind(0);
  config.port = socket.port;
  final proxy = ProxyServer(config)..server = active;
  addTearDown(() async {
    await proxy.server?.stop();
    await active.stop();
  });
  await config.flushConfig();
  return (proxy, active);
}

class _PassiveHandler extends ChannelHandler<Object> {}

Future<void> _withStagedRename(
  Future<void> Function() body,
  Future<File> Function(File, String) rename,
) {
  final realIo = _RealIo();
  return IOOverrides.runZoned(body, createFile: (path) {
    final file = realIo.createFile(path);
    return file.parent.path.split(Platform.pathSeparator).last.startsWith('.config.cnf-')
        ? _StagedFile(file, rename)
        : file;
  });
}

final class _RealIo extends IOOverrides {}

class _StagedFile extends Fake implements File {
  final File file;
  final Future<File> Function(File, String) replace;

  _StagedFile(this.file, this.replace);

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) =>
      file.writeAsString(contents, mode: mode, encoding: encoding, flush: flush);

  @override
  Future<File> rename(String newPath) => replace(file, newPath);
}
