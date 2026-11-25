import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_dispatcher.dart';
import 'package:proxypin/network/channel/network.dart';
import 'package:proxypin/network/util/file_read.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixturePath = Platform.environment['PROXYPIN_LINUX_PROXY_FIXTURE'];

  test('Linux command failures roll back a port change and leave it retryable', () async {
    final fixture = Directory(fixturePath!);
    final fakeBin = '${fixture.path}/fakebin';
    final kde = Platform.environment['XDG_CURRENT_DESKTOP']!.split(':').contains('KDE');
    final kdeCommand = Platform.environment['PROXYPIN_TEST_KDE_COMMAND'] ?? 'kwriteconfig5';
    final gnomeSchema = Platform.environment['PROXYPIN_TEST_NO_GSETTINGS_SCHEMA'] != '1';
    expect(Platform.environment['PATH']!.split(':').first, fakeBin);
    final fakeCommand = await File('test/fixtures/linux_system_proxy_command.sh').readAsString();
    for (final command in ['gsettings', if (kde) kdeCommand]) {
      expect(await File('$fakeBin/$command').readAsString(), fakeCommand);
    }
    expect(Platform.environment['XDG_CONFIG_HOME'], '${fixture.path}/xdg-config');

    final support = await fixture.createTemp('config-');
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previousHome = FileRead.userHome;
    FileRead.userHome = support.path;
    messenger.setMockMethodCallHandler(pathProvider, (_) async => support.path);
    addTearDown(() {
      FileRead.userHome = previousHome;
      messenger.setMockMethodCallHandler(pathProvider, null);
    });

    final config = Configuration.fromJson({'enableSystemProxy': true});
    final active = Server(config)
      ..initChannel((channel) => channel.dispatcher.channelHandle(RawCodec(), _PassiveHandler()));
    final oldPort = (await active.bind(0)).port;
    final proxy = ProxyServer(config)..server = active;
    addTearDown(() async {
      await proxy.server?.stop();
      await active.stop();
    });
    config.port = oldPort;
    await config.flushConfig();
    final configFile = await Configuration.configFile();
    final original = await configFile.readAsBytes();
    final reservation = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final newPort = reservation.port;
    await reservation.close();
    final failures = File('${fixture.path}/failures');
    final log = File('${fixture.path}/commands.log');
    final failingKey = kde ? 'kde-httpProxy' : 'gnome-http-port';
    String failingValue(int port) => kde ? 'http://127.0.0.1:$port' : '$port';
    Future<String> readSetting(String key) async => (await File('${fixture.path}/$key').readAsString()).trim();

    Future<void> expectSettings(int port) async {
      if (gnomeSchema) {
        expect(await readSetting('gnome-mode'), 'manual');
        for (final protocol in ['http', 'https']) {
          expect(await readSetting('gnome-$protocol-host'), '127.0.0.1');
          expect(await readSetting('gnome-$protocol-port'), '$port');
        }
      }
      if (kde) {
        expect(await readSetting('kde-ProxyType'), '1');
        for (final protocol in ['http', 'https']) {
          expect(await readSetting('kde-${protocol}Proxy'), '$protocol://127.0.0.1:$port');
        }
      }
    }

    proxy.enableSsl = true;
    await proxy.setSystemProxyEnable(true);
    await expectSettings(oldPort);
    await log.writeAsString('');
    await failures.writeAsString('$failingKey=${failingValue(newPort)}\n$failingKey=${failingValue(oldPort)}\n');

    await expectLater(
      proxy.changePort(newPort),
      throwsA(isA<ProcessException>()
          .having((error) => error.executable, 'command', kde ? kdeCommand : 'gsettings')
          .having((error) => error.errorCode, 'exit code', 42)
          .having((error) => error.arguments.last, 'requested value', failingValue(newPort))),
    );
    expect(proxy.server, same(active));
    expect(proxy.isRunning, isTrue);
    expect(proxy.port, oldPort);
    expect(await configFile.readAsBytes(), original);
    (await Socket.connect(InternetAddress.loopbackIPv4, oldPort)).destroy();
    await (await ServerSocket.bind(InternetAddress.anyIPv4, newPort)).close();
    await expectSettings(oldPort);

    final attempt = await log.readAsLines();
    expect(attempt, contains(endsWith('$failingKey=${failingValue(newPort)} exit=42')));
    expect(attempt, contains(endsWith('$failingKey=${failingValue(oldPort)} exit=42')));
    final updatedKey = kde ? 'kde-httpsProxy=https://127.0.0.1:' : 'gnome-https-port=';
    expect(
        attempt, containsAllInOrder([endsWith('$updatedKey$newPort exit=0'), endsWith('$updatedKey$oldPort exit=0')]));

    await proxy.setSystemProxyEnable(true);
    await expectSettings(oldPort);
    await failures.delete();
    await proxy.changePort(newPort);
    expect(active.isRunning, isFalse);
    expect(proxy.isRunning, isTrue);
    expect(proxy.port, newPort);
    expect(jsonDecode(await configFile.readAsString())['port'], newPort);
    await expectSettings(newPort);
    await (await ServerSocket.bind(InternetAddress.anyIPv4, oldPort)).close();
    (await Socket.connect(InternetAddress.loopbackIPv4, newPort)).destroy();

    await proxy.stop();
    expect(proxy.isRunning, isFalse);
    if (gnomeSchema) expect(await readSetting('gnome-mode'), 'none');
    if (kde) expect(await readSetting('kde-ProxyType'), '0');
  }, skip: !Platform.isLinux || fixturePath == null);
}

class _PassiveHandler extends ChannelHandler<Object> {}
