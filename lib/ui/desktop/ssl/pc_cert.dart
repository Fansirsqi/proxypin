import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:proxypin/ui/component/floating_dialog.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/util/cert/cert_data.dart';
import 'package:proxypin/network/util/crts.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/storage/local_storage.dart';
import 'package:proxypin/ui/component/app_dialog.dart';
import 'package:proxypin/ui/desktop/ssl/cert_installer.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../storage/shared_preference_keys.dart';

class PCCertChecker {
  static bool checked = false;

  static void check(BuildContext context) async {
    if (checked || !Platforms.isDesktop()) {
      return;
    }

    checked = true;

    if (ProxyServer.current?.enableSsl != true || ProxyServer.current?.configuration.enableSystemProxy != true) {
      return;
    }

    if (_AutomaticInstallState.isCertInstalled.value == true) {
      return;
    }
    if ((await LocalStorage.getBool(SharedPreferenceKeys.CERT_INSTALL_SKIP)) == true) {
      return;
    }

    final cert = await CertificateManager.getCertificateDetails();
    final caFile = await CertificateManager.certificateFile();
    final installed = await CertInstaller.isCertInstalled(caFile, cert);
    if (!installed && context.mounted) {
      showDialog(
          barrierDismissible: false,
          context: context,
          builder: (context) {
            final localizations = AppLocalizations.of(context)!;
            return FloatingAlertDialog(
              content: _AutomaticInstall(),
              actions: <Widget>[
                TextButton(
                  onPressed: () {
                    LocalStorage.setBool(SharedPreferenceKeys.CERT_INSTALL_SKIP, true);
                    Navigator.pop(context);
                  },
                  child: Text(localizations.appUpdateIgnoreBtnTxt),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(localizations.cancel),
                ),
              ],
            );
          });
    }
  }
}

class PCCert extends StatefulWidget {
  const PCCert({super.key});

  @override
  State<PCCert> createState() => _PCCertState();
}

class _PCCertState extends State<PCCert> with TickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

    return FloatingSimpleDialog(
      titlePadding: const EdgeInsets.symmetric(),
      contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 15),
      title: Row(children: [
        const Expanded(child: SizedBox()),
        Text(isCN ? "安装证书" : "Install Certificate", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        const Expanded(child: SizedBox()),
        Align(alignment: Alignment.topRight, child: CloseButton())
      ]),
      children: [
        TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: localizations.automatic),
            Tab(text: localizations.manual),
          ],
        ),
        SizedBox(
          width: 700,
          height: 470,
          child: TabBarView(
            controller: _tabController,
            children: [
              SingleChildScrollView(child: _AutomaticInstall()),
              _buildManualTab(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildManualTab(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
          padding: const EdgeInsets.only(top: 12.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _buildChildren(context),
          )),
    );
  }

  List<Widget> _buildChildren(BuildContext context) {
    if (Platform.isMacOS || Platform.isWindows) {
      return _buildWindowsAndMacContent(context);
    }
    return _buildLinuxContent(context);
  }

  List<Widget> _buildWindowsAndMacContent(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

    return [
      isCN
          ? Text(" 安装证书到本系统，${Platform.isMacOS ? "安装完双击选择“始终信任此证书”。 如安装打开失败，请导出证书拖拽到系统证书里" : "选择“受信任的根证书颁发机构”"}")
          : Text(
              " Install certificate to this system，${Platform.isMacOS ? "After installation, double-click to select “Always Trust”。\n If installation and opening fail，Please export the certificate and drag it to the system certificate" : "choice“Trusted Root Certificate Authority”"}"),
      const SizedBox(height: 10),
      SizedBox(
          width: double.maxFinite,
          child: FilledButton(
              onPressed: () => _manualInstallCert(),
              style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              child: Text(localizations.installRootCa))),
      const SizedBox(height: 10),
      Platform.isMacOS
          ? Image.network("https://foruda.gitee.com/images/1689323260158189316/c2d881a4_1073801.png",
              width: 800, height: 500)
          : Row(children: [
              Image.network("https://foruda.gitee.com/images/1689335589122168223/c904a543_1073801.png",
                  width: 370, height: 380),
              const SizedBox(width: 10),
              Image.network("https://foruda.gitee.com/images/1689335334688878324/f6aa3a3a_1073801.png",
                  width: 370, height: 380)
            ])
    ];
  }

  List<Widget> _buildLinuxContent(BuildContext context) {
    final isCN = Localizations.localeOf(context) == const Locale.fromSubtags(languageCode: 'zh');

    return [
      Text(isCN
          ? "安装证书到本系统，以Ubuntu为例 下载证书：\n"
              "先把证书复制到 /usr/local/share/ca-certificates/，然后执行 update-ca-certificates 即可。\n"
              "其他系统请网上搜索安装根证书"
          : "Install the certificate to this system), take Ubuntu as an example to download the certificate:\n"
              "First copy the certificate to /usr/local/share/ca-certificates/, and then execute update-ca-certificates.\n"
              "For other systems, please search online for installing root certificates."),
      const SizedBox(height: 5),
      Text(
          isCN
              ? "提示：FireFox有自己的信任证书库，所以要手动在设置中导入需要导入的证书。"
              : "Note: FireFox has its own trusted certificate library, so you need to manually import the required certificates in the settings.",
          style: TextStyle(fontSize: 12)),
      const SizedBox(height: 10),
      const SelectableText.rich(
          textAlign: TextAlign.justify,
          TextSpan(style: TextStyle(color: Color(0xff6a8759)), children: [
            TextSpan(text: "  sudo cp ProxyPinCA.crt /usr/local/share/ca-certificates/ \n"),
            TextSpan(text: "  sudo update-ca-certificates")
          ])),
      const SizedBox(height: 10)
    ];
  }

  void _manualInstallCert() async {
    var caFile = await CertificateManager.certificateFile();
    launchUrl(Uri.file(caFile.path)).then((_) {
      CertificateManager.cleanCache();
    });
  }
}

class _AutomaticInstall extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _AutomaticInstallState();
}

class _AutomaticInstallState extends State<_AutomaticInstall> {
  static final RxnBool isCertInstalled = RxnBool(null);
  static final _isUpdating = false.obs;
  X509CertificateData? certDetails;

  @override
  void initState() {
    super.initState();
    certDetails = CertificateManager.caCert;
    if (!_isUpdating.value) {
      isCertInstalled.value = null;
      _checkCertStatus();
    }

    if (certDetails == null) {
      CertificateManager.getCertificateDetails().then((value) {
        if (mounted) {
          setState(() => certDetails = value);
        }
      });
    }
  }

  void _checkCertStatus() async {
    final details = certDetails ?? await CertificateManager.getCertificateDetails();
    final caFile = await CertificateManager.certificateFile();
    isCertInstalled.value = await CertInstaller.isCertInstalled(caFile, details);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 16.0),
      child: Obx(() => Column(mainAxisSize: MainAxisSize.min, children: buildAutomaticChildren())),
    );
  }

  List<Widget> buildAutomaticChildren() {
    final localizations = AppLocalizations.of(context)!;
    final isCN = Localizations.localeOf(context).languageCode == 'zh';

    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final subtitleStyle = theme.textTheme.bodyMedium;
    final infoLabelStyle = theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant);
    final infoValueStyle = subtitleStyle?.copyWith(color: colors.onSurface, fontWeight: FontWeight.w500);
    List<Widget> children = [
      const SizedBox(height: 8),
      Text(isCN ? "通过安装并信任 ProxyPin CA" : "Install and Trust ProxyPin CA Certificate",
          style: subtitleStyle, textAlign: TextAlign.center),
      const SizedBox(height: 3),
      Text(
          isCN
              ? "ProxyPin 可以动态解密 HTTPS 流量以展示原始请求/响应。"
              : "ProxyPin can decrypt encrypted traffic on the fly and enable to see raw HTTPS requests and responses.",
          style: subtitleStyle,
          textAlign: TextAlign.center),
      const SizedBox(height: 45),
    ];

    if (isCertInstalled.value == false) {
      children.add(const SizedBox(height: 20));
      children.add(Icon(Icons.error_outline, color: Colors.red, size: 56));
      children.add(const SizedBox(height: 12));
      children.add(Text(localizations.certNotInstalled,
          textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)));
      children.add(const SizedBox(height: 20));
      children.add(
        FilledButton(
            onPressed: _isUpdating.value ? null : () => _updateCertificate(install: true),
            style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 19)),
            child: Text(localizations.install)),
      );
    } else if (isCertInstalled.value == true) {
      children.add(Card(
        elevation: 2,
        color: theme.cardTheme.color ?? colors.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 18.0),
          child: Column(children: [
            Icon(Icons.verified_rounded, color: Colors.green, size: 56),
            const SizedBox(height: 12),
            Text(isCN ? "证书已安装" : "Certificate Installed", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (certDetails != null) ...[
              const Divider(),
              const SizedBox(height: 8),
              // certificate details
              Row(children: [
                Text('Name', style: infoLabelStyle),
                Expanded(
                    child: SelectableText(certDetails!.subject['2.5.4.3'] ?? 'ProxyPin CA',
                        style: infoValueStyle, textAlign: TextAlign.right)),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                Text('Expires', style: infoLabelStyle),
                Expanded(
                    child: SelectableText(certDetails!.validity.notAfter.toLocal().toString().split(' ').first,
                        style: infoValueStyle, textAlign: TextAlign.right)),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                Text('Fingerprint', style: infoLabelStyle),
                Expanded(
                  child: SelectableText(certDetails!.sha1Thumbprint ?? '-',
                      style: infoValueStyle, textAlign: TextAlign.right),
                ),
              ])
            ]
          ]),
        ),
      ));
      if (Platform.isLinux) {
        children.add(const SizedBox(height: 16));
        children.add(OutlinedButton(
          onPressed: _isUpdating.value ? null : () => _updateCertificate(install: false),
          child: Text(isCN ? '卸载证书' : 'Uninstall Certificate'),
        ));
      }
    }

    return children;
  }

  Future<void> _updateCertificate({required bool install}) async {
    if (_isUpdating.value) return;

    final isCN = Localizations.localeOf(context).languageCode == 'zh';
    _isUpdating.value = true;
    try {
      if (!install && !await _confirmUninstall(isCN)) return;
      if (!mounted) return;

      final caFile = await CertificateManager.certificateFile();
      final details = await CertificateManager.getCertificateDetails();
      final uninstallResult = install ? null : await CertInstaller.uninstallLinuxCertificate(caFile);
      final success = install
          ? await CertInstaller.installCertificate(caFile)
          : uninstallResult == CertificateUninstallResult.removed;
      isCertInstalled.value = await CertInstaller.isCertInstalled(caFile, details);
      CertificateManager.cleanCache();

      if (!mounted || uninstallResult == CertificateUninstallResult.cancelled) return;
      if (success) {
        final message = install
            ? (isCN ? '证书安装成功' : 'Certificate installed successfully')
            : (isCN ? '证书已卸载' : 'Certificate uninstalled successfully');
        CustomToast.success(message).show(context);
      } else {
        _showUpdateFailure(isCN, install);
      }
    } catch (error) {
      logger.e('Could not update the root certificate: $error');
      if (mounted) _showUpdateFailure(isCN, install);
    } finally {
      _isUpdating.value = false;
    }
  }

  Future<bool> _confirmUninstall(bool isCN) async {
    final localizations = AppLocalizations.of(context)!;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => FloatingAlertDialog(
            title: Text(isCN ? '卸载 ProxyPin CA' : 'Uninstall ProxyPin CA'),
            content: Text(isCN
                ? '这会从系统信任库移除当前证书。使用同一张证书的其他 ProxyPin 版本也会失去系统信任。'
                : 'This removes the current certificate from system trust. Other ProxyPin versions using the same certificate will also lose system trust.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(localizations.cancel)),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(isCN ? '卸载' : 'Uninstall'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showUpdateFailure(bool isCN, bool install) {
    final message = install
        ? (isCN ? '证书安装失败，请尝试手动安装' : 'Certificate installation failed. Please try manual installation.')
        : (isCN ? '证书卸载未完成，请检查系统证书库' : 'Certificate uninstall did not complete. Check the system trust store.');
    CustomToast.error(message).show(context);
  }
}
