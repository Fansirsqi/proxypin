import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/ui/desktop/ssl/cert_installer.dart';

void main() {
  late Directory fixture;
  late Directory anchors;
  late File bundle;
  late File certificate;
  late File refresh;
  late String pem;
  late int authorizationCalls;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('proxypin-ca-test-');
    anchors = await Directory('${fixture.path}/trust/anchors').create(recursive: true);
    pem = await File('assets/certs/ca.crt').readAsString();
    bundle = await File('${fixture.path}/bundle.pem').writeAsString(pem);
    certificate = await File('${fixture.path}/app-ca.pem').writeAsString(pem);
    refresh = File('${fixture.path}/fake-refresh');
    authorizationCalls = 0;
  });

  tearDown(() => fixture.delete(recursive: true));

  Future<CertificateUninstallResult> uninstall({
    int? authorizationExit,
    Future<void> Function()? onAuthorized,
    Set<String>? expectedAnchors,
  }) {
    return CertInstaller.uninstallLinuxCertificateFromStore(
      certificate,
      anchors: anchors,
      bundle: bundle,
      refresh: [refresh.path, 'extract'],
      runProcess: (executable, arguments) async {
        authorizationCalls++;
        expect(executable, '/usr/bin/pkexec');
        expect(arguments.take(3), ['--disable-internal-agent', '/bin/sh', '-c']);
        expect(arguments.sublist(4, 8), ['proxypin-uninstall-ca', anchors.path, refresh.path, 'extract']);
        final targets = arguments.skip(8).map((anchor) => anchor.substring(65)).toSet();
        if (expectedAnchors != null) expect(targets, expectedAnchors);
        if (authorizationExit != null) return ProcessResult(0, authorizationExit, '', 'fake authorization');
        await onAuthorized?.call();

        const lock = '/run/proxypin-ca-install.lock';
        final script = arguments[3];
        expect(lock.allMatches(script), hasLength(1));
        return Process.run('/bin/sh', [
          '-c',
          script.replaceFirst(lock, '${fixture.path}/test.lock'),
          ...arguments.skip(4),
        ], environment: {
          'PROXYPIN_TEST_CA_ROOT': fixture.path
        });
      },
    );
  }

  Future<void> writeFakeRefresh({bool failFirst = false}) async {
    final source = failFirst
        ? r'''
if [ ! -f "$PROXYPIN_TEST_CA_ROOT/refresh-failed" ]; then
  : > "$PROXYPIN_TEST_CA_ROOT/refresh-failed"
  exit 1
fi
'''
        : '';
    await refresh.writeAsString('''#!/bin/sh
set -eu
$source
${r'''
[ "$1" = extract ]
root=$PROXYPIN_TEST_CA_ROOT
if [ -f "$root/trust/anchors/ProxyPinCA.crt" ]; then
  /usr/bin/cp -- "$root/app-ca.pem" "$root/bundle.pem"
else
  : > "$root/bundle.pem"
fi
'''}''');
    expect((await Process.run('/usr/bin/chmod', ['0700', refresh.path])).exitCode, 0);
  }

  test('unreadable neighbors do not block authorization for exact PEM and DER anchors', () async {
    final inaccessible = await File('${anchors.path}/unrelated.crt').writeAsString('unrelated');
    final inaccessibleDirectory = await Directory('${anchors.path}/private').create();
    expect((await Process.run('/usr/bin/chmod', ['0000', inaccessible.path, inaccessibleDirectory.path])).exitCode, 0);
    addTearDown(() => Process.run('/usr/bin/chmod', ['0700', inaccessible.path, inaccessibleDirectory.path]));
    final actualRead = await inaccessible.readAsBytes().then<bool>((_) => true, onError: (_) => false);
    if (actualRead) {
      markTestSkipped('The test requires a user without permission to read a mode-000 file.');
      return;
    }

    final target = await File('${anchors.path}/ProxyPinCA.crt').writeAsString(pem.replaceAll('\n', '\r\n'));
    final nested = await Directory('${anchors.path}/custom').create();
    final der = await File('${nested.path}/copied-ca.crt').writeAsBytes(base64Decode(
      pem.replaceAll(RegExp(r'-----.*?-----|\s+'), ''),
    ));
    final misleading = await File('${anchors.path}/proxypin-ca-unrelated.crt').writeAsString('unrelated');
    final chain = await File('${anchors.path}/chain.crt').writeAsString('$pem\n$pem');
    final link = await Link('${anchors.path}/linked-ca.crt').create(certificate.path);
    await writeFakeRefresh();

    final result = await uninstall(expectedAnchors: {target.path, der.path});
    expect(result, CertificateUninstallResult.removed);
    expect(authorizationCalls, 1);
    expect(await target.exists(), isFalse);
    expect(await der.exists(), isFalse);
    expect(await misleading.readAsString(), 'unrelated');
    expect(await chain.readAsString(), '$pem\n$pem');
    expect(await link.exists(), isTrue);
    expect(await certificate.readAsString(), pem);
  }, skip: !Platform.isLinux);

  test('does not request authorization without a confirmed anchor', () async {
    await File('${anchors.path}/ProxyPinCA.crt').writeAsString('unrelated');
    await Link('${anchors.path}/copied-ca.crt').create(certificate.path);

    expect(await uninstall(), CertificateUninstallResult.failed);
    expect(authorizationCalls, 0);
    await bundle.writeAsString('');
    expect(await uninstall(), CertificateUninstallResult.removed);
    expect(authorizationCalls, 0);
  }, skip: !Platform.isLinux);

  test('reports authorization cancellation and rejects a changed anchor before moving it', () async {
    final target = await File('${anchors.path}/ProxyPinCA.crt').writeAsString(pem);
    await writeFakeRefresh();

    expect(await uninstall(authorizationExit: 126), CertificateUninstallResult.cancelled);
    expect(await target.readAsString(), pem);
    expect(await uninstall(onAuthorized: () => target.writeAsString('changed')), CertificateUninstallResult.failed);
    expect(await target.readAsString(), 'changed');
    expect(await bundle.readAsString(), pem);
    expect(authorizationCalls, 2);
  }, skip: !Platform.isLinux);

  test('restores the exact anchor and trust bundle if the refresh command fails', () async {
    final target = await File('${anchors.path}/ProxyPinCA.crt').writeAsString(pem);
    await writeFakeRefresh(failFirst: true);

    expect(await uninstall(), CertificateUninstallResult.failed);
    expect(authorizationCalls, 1);
    expect(await target.readAsString(), pem);
    expect(await bundle.readAsString(), pem);
    expect(await File('${fixture.path}/refresh-failed').exists(), isTrue);
  }, skip: !Platform.isLinux);
}
