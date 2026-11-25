import 'dart:convert';
import 'dart:io';
import 'package:proxypin/network/util/cert/cert_data.dart';
import 'package:proxypin/network/util/cert/x509.dart';
import 'package:proxypin/network/util/crypto.dart';
import 'package:proxypin/network/util/logger.dart';

enum CertificateUninstallResult { removed, cancelled, failed }

class CertInstaller {
  static final _pemCertificate = RegExp(r'-----BEGIN CERTIFICATE-----\s+([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----');
  static final _whitespace = RegExp(r'\s+');
  static const _installLinuxAnchor = r'''
set -eu
target=$1
certificate=$2
shift 2
exec 9>/run/proxypin-ca-install.lock
/usr/bin/flock -x 9
staged=$(/usr/bin/mktemp "$target.XXXXXX")
trap '/usr/bin/rm -f -- "$staged"' EXIT
printf '%s\n' "$certificate" > "$staged"
/usr/bin/chmod 0644 "$staged"
added=0
if [ -e "$target" ] || [ -L "$target" ]; then
  [ ! -L "$target" ] && /usr/bin/cmp -s -- "$staged" "$target" || exit 1
else
  /usr/bin/ln -T -- "$staged" "$target"
  added=1
fi
/usr/bin/rm -f -- "$staged"
if "$@"; then
  exit 0
fi
if [ "$added" = 1 ]; then
  /usr/bin/rm -f -- "$target"
  "$@" || :
fi
exit 1
''';

  static const _uninstallLinuxAnchors = r'''
set -eu
directory=$1
refresh=$2
refresh_argument=$3
shift 3
exec 9>/run/proxypin-ca-install.lock
/usr/bin/flock -x 9
for anchor do
  path=${anchor#*:}
  case "$path" in
    "$directory/"*) ;;
    *) exit 1 ;;
  esac
  [ -f "$path" ] && [ ! -L "$path" ] || exit 1
  [ "$(/usr/bin/realpath -e -- "$path")" = "$path" ] || exit 1
  checksum=$(/usr/bin/sha256sum < "$path")
  [ "${checksum%% *}" = "${anchor%%:*}" ] || exit 1
done

parent=${directory%/*}
backup=$(/usr/bin/mktemp -d "${parent%/*}/.proxypin-ca-uninstall.XXXXXXXX")
rollback() {
  index=0
  for anchor do
    index=$((index + 1))
    if [ -f "$backup/$index" ]; then
      /usr/bin/mv -n -- "$backup/$index" "${anchor#*:}" || :
    fi
  done
  /usr/bin/rmdir -- "$backup" || printf 'Certificate backup retained at %s\n' "$backup" >&2
  "$refresh" "$refresh_argument" || :
}
trap 'rollback "$@"' EXIT
trap 'exit 1' HUP INT TERM
index=0
for anchor do
  index=$((index + 1))
  /usr/bin/mv -- "${anchor#*:}" "$backup/$index"
done
"$refresh" "$refresh_argument"
trap - EXIT HUP INT TERM
/usr/bin/rm -f -- "$backup/"*
/usr/bin/rmdir -- "$backup"
''';

  static ({String anchors, String bundle, List<String> refresh, String uninstallRefreshArgument})? _linuxTrustStore() {
    const fedoraAnchors = '/etc/pki/ca-trust/source/anchors';
    const fedoraRefresh = '/usr/bin/update-ca-trust';
    if (Directory(fedoraAnchors).existsSync() && File(fedoraRefresh).existsSync()) {
      return (
        anchors: fedoraAnchors,
        bundle: '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem',
        refresh: [fedoraRefresh, 'extract'],
        uninstallRefreshArgument: 'extract',
      );
    }

    const debianAnchors = '/usr/local/share/ca-certificates';
    const debianRefresh = '/usr/sbin/update-ca-certificates';
    if (Directory(debianAnchors).existsSync() && File(debianRefresh).existsSync()) {
      return (
        anchors: debianAnchors,
        bundle: '/etc/ssl/certs/ca-certificates.crt',
        refresh: [debianRefresh],
        uninstallRefreshArgument: '--fresh',
      );
    }
    return null;
  }

  static String? _singlePemBody(String certificate) {
    final trimmed = certificate.trim();
    final match = _pemCertificate.firstMatch(trimmed);
    if (match == null || match.start != 0 || match.end != trimmed.length) return null;
    return match.group(1)!.replaceAll(_whitespace, '');
  }

  static Future<bool> _linuxBundleContains(String bundle, String certificate) async {
    final file = File(bundle);
    if (!await file.exists()) return false;

    final pemBody = _singlePemBody(certificate);
    if (pemBody == null) return false;

    final trustedCertificates = await file.readAsString();
    return _pemCertificate
        .allMatches(trustedCertificates)
        .any((match) => match.group(1)!.replaceAll(_whitespace, '') == pemBody);
  }

  static Future<bool> _installLinuxCertificate(File certFile) async {
    final store = _linuxTrustStore();
    if (store == null) {
      logger.w('No supported Linux CA trust store found');
      return false;
    }

    final certificate = (await certFile.readAsString()).trim();
    if (_singlePemBody(certificate) == null) return false;
    if (await _linuxBundleContains(store.bundle, certificate)) return true;

    final fingerprint = X509Utils.x509CertificateFromPem(certificate).sha256Thumbprint!.toLowerCase();
    final result = await Process.run('/usr/bin/pkexec', [
      '--disable-internal-agent',
      '/bin/sh',
      '-c',
      _installLinuxAnchor,
      'proxypin-install-ca',
      '${store.anchors}/proxypin-ca-$fingerprint.crt',
      certificate,
      ...store.refresh,
    ]);
    if (result.exitCode != 0) {
      logger.w('Linux CA installation exited ${result.exitCode}: ${result.stderr}');
      return false;
    }
    return _linuxBundleContains(store.bundle, certificate);
  }

  static Future<CertificateUninstallResult> uninstallLinuxCertificate(File certFile) async {
    try {
      final store = _linuxTrustStore();
      if (!Platform.isLinux || store == null) return CertificateUninstallResult.failed;

      final certificate = await certFile.readAsString();
      final pemBody = _singlePemBody(certificate);
      if (pemBody == null) return CertificateUninstallResult.failed;
      if (!await _linuxBundleContains(store.bundle, certificate)) return CertificateUninstallResult.removed;

      final fingerprint = CryptoUtils.getHash(base64Decode(pemBody));
      final anchors = <String>[];
      await for (final entry in Directory(store.anchors).list(recursive: true, followLinks: false)) {
        if (entry is! File) continue;
        final bytes = await entry.readAsBytes();
        final checksum = CryptoUtils.getHash(bytes);
        if (checksum == fingerprint || _singlePemBody(utf8.decode(bytes, allowMalformed: true)) == pemBody) {
          anchors.add('${checksum.toLowerCase()}:${entry.path}');
        }
      }
      if (anchors.isEmpty) return CertificateUninstallResult.failed;

      final result = await Process.run('/usr/bin/pkexec', [
        '--disable-internal-agent',
        '/bin/sh',
        '-c',
        _uninstallLinuxAnchors,
        'proxypin-uninstall-ca',
        store.anchors,
        store.refresh.first,
        store.uninstallRefreshArgument,
        ...anchors,
      ]);
      if (result.exitCode == 126) return CertificateUninstallResult.cancelled;
      if (result.exitCode != 0) {
        logger.w('Linux CA uninstall exited ${result.exitCode}: ${result.stderr}');
        return CertificateUninstallResult.failed;
      }
      return await _linuxBundleContains(store.bundle, certificate)
          ? CertificateUninstallResult.failed
          : CertificateUninstallResult.removed;
    } catch (error) {
      logger.e('Failed to uninstall Linux CA: $error');
      return CertificateUninstallResult.failed;
    }
  }

  static Future<bool> installCertificate(File certFile) async {
    try {
      if (Platform.isMacOS) {
        // 使用 security add-trusted-cert 安装证书到登录钥匙串并设为信任根
        final result = await Process.run('security', [
          'add-trusted-cert',
          '-r',
          'trustRoot',
          '-k',
          '${Platform.environment['HOME']}/Library/Keychains/login.keychain-db',
          certFile.path,
        ]);
        logger.d('security add-trusted-cert result: \\${result.stdout} \\${result.stderr}');
        return result.exitCode == 0;
      }

      if (Platform.isWindows) {
        // Windows: 使用 certutil 命令行安装证书到根证书存储区
        final result = await Process.run('certutil', [
          '-addstore',
          '-user',
          'Root',
          certFile.path,
        ]);
        logger.d('certutil addstore result: \\${result.stdout} \\${result.stderr}');
        return result.exitCode == 0;
      }

      if (Platform.isLinux) {
        return await _installLinuxCertificate(certFile);
      }

      // 其他平台暂不支持
      return false;
    } catch (e) {
      logger.e('Failed to install certificate: $e');
      return false;
    }
  }

  /// 检查证书是否已安装
  static Future<bool> isCertInstalled(File filePath, X509CertificateData caCert) async {
    String commonName = caCert.subject['2.5.4.3'] ?? 'ProxyPin CA';
    String? sha1 = caCert.sha1Thumbprint;
    logger.d('Checking if certificate is installed: CN=$commonName, SHA1=$sha1');
    try {
      if (Platform.isWindows) {
        List<String> args = ['-user', '-store', 'root'];
        if (sha1 != null) {
          args.add(sha1);
        }
        var res = await Process.run('certutil', args);
        return res.stdout.toString().toLowerCase().contains(commonName.toLowerCase());
      } else if (Platform.isMacOS) {
        var res = await Process.run('security', ['find-certificate', '-c', commonName]);

        if ((res.stdout as String).isNotEmpty) {
          // check if trusted
          var trustRes = await Process.run('security', ['verify-cert', '-c', filePath.path]);

          logger.d('security verify-cert $commonName result: ${trustRes.stdout} ${trustRes.stderr}');
          return (trustRes.stdout as String).contains('certificate verification successful');
        }
        return false;
      } else if (Platform.isLinux) {
        final store = _linuxTrustStore();
        return store != null && await _linuxBundleContains(store.bundle, await filePath.readAsString());
      }
    } catch (_) {}
    return false;
  }
}
