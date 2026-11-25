/*
 * Copyright 2023 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/system_proxy.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/component/proxy_port_setting.dart';
import 'package:proxypin/ui/component/svg_icon.dart';
import 'package:proxypin/ui/content/detail_settings.dart';
import 'package:proxypin/ui/desktop/preference.dart';
import 'package:proxypin/ui/desktop/setting/about.dart';
import 'package:proxypin/ui/desktop/setting/settings_session.dart';
import 'package:proxypin/ui/desktop/ssl/ssl.dart';
import 'package:proxypin/ui/desktop/toolbar/quick_tools.dart';
import 'package:proxypin/ui/toolbox/viewer_app_bar.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

class Setting extends StatefulWidget {
  static const windowName = 'DesktopSettings';
  final String windowId;
  final DesktopSettingsSession session;

  const Setting({super.key, required this.windowId, required this.session});

  @override
  State<Setting> createState() => _SettingState();
}

class _SettingState extends State<Setting> with WindowListener {
  Map<String, dynamic> get proxy => widget.session.proxySettings;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_closeShortcut);
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_closeShortcut);
    windowManager.removeListener(this);
    super.dispose();
  }

  bool _closeShortcut(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (event.logicalKey != LogicalKeyboardKey.keyW || !(keyboard.isControlPressed || keyboard.isMetaPressed)) {
      return false;
    }
    if (event is KeyDownEvent) unawaited(WindowController.fromWindowId(widget.windowId).close());
    return true;
  }

  @override
  void onWindowFocus() async {
    try {
      await widget.session.refreshProxySettings();
      if (mounted) setState(() {});
    } catch (error, stackTrace) {
      logger.w('Could not refresh proxy settings', error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _applyProxy(String key, Object value) async {
    await widget.session.updateProxySetting(key, value);
    if (mounted) setState(() {});
  }

  Future<void> _saveProxy(String key, Object value) async {
    try {
      await _applyProxy(key, value);
    } catch (error, stackTrace) {
      logger.e('Could not save proxy setting $key', error: error, stackTrace: stackTrace);
      if (mounted) FlutterToastr.show(AppLocalizations.of(context)!.fail, context);
    }
  }

  Future<void> _openTool(String id) => DesktopMultiWindow.invokeMainWindowMethod('openDesktopSettingTool', id);

  Future<void> _certificateAction(String action, [Map<String, dynamic>? arguments]) async {
    if (action == 'client') return _openTool('clientCertificate');
    await DesktopMultiWindow.invokeMainWindowMethod('changeDesktopCertificate', {'action': action, ...?arguments});
  }

  @override
  Widget build(BuildContext context) {
    final labels = AppLocalizations.of(context)!;
    final appConfiguration = widget.session.configuration;
    final sections = [
      (
        title: labels.preference,
        content: Column(
          children: [
            Preference.remote(appConfiguration,
                startup: proxy['startup'] as bool, onStartupChanged: (value) => _saveProxy('startup', value)),
            const Divider(height: 24),
            _SettingsLink(
              label: labels.about,
              icon: 'info',
              onTap: () => showDialog<void>(context: context, builder: (_) => const DesktopAbout()),
            ),
            _SettingsLink(
              label: labels.feedback,
              icon: 'chat',
              onTap: () => launchUrl(Uri.parse('https://github.com/wanghongenpin/proxypin/issues')),
            ),
          ],
        ),
      ),
      (title: labels.detailLayoutSettings, content: DetailLayoutSettings(configuration: appConfiguration)),
      (
        title: labels.proxy,
        content: Column(
          children: [
            _ProxySettings(
              proxy: proxy,
              save: _saveProxy,
              changePort: (value) => _applyProxy('port', value),
            ),
            const Divider(height: 24),
            SslWidget.remote(
              enableSsl: proxy['enableSsl'] as bool,
              port: proxy['port'] as int,
              setSslEnabled: (value) => _applyProxy('enableSsl', value),
              certificateAction: _certificateAction,
            ),
            for (final tool in settingQuickTools) _toolLink(context, labels, tool),
          ],
        ),
      ),
      (
        title: labels.trafficControl,
        content: Column(
          children: [
            for (final tool in trafficQuickTools) _toolLink(context, labels, tool),
            _SettingsLink(
              label: labels.environmentVariables,
              icon: 'sliders',
              onTap: () => _openTool('environment'),
            ),
          ],
        ),
      ),
      (title: labels.customizeToolbar, content: ToolbarSettings(appConfiguration: appConfiguration)),
    ];

    return Scaffold(
      appBar: viewerAppBar(context, labels.setting, windowId: widget.windowId),
      body: DefaultTabController(
        length: sections.length,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              labelPadding: const EdgeInsets.symmetric(horizontal: 12),
              onTap: (_) => FocusManager.instance.primaryFocus?.unfocus(),
              tabs: [for (final section in sections) Tab(height: 40, text: section.title)],
            ),
            Expanded(
              child: TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (var sectionIndex = 0; sectionIndex < sections.length; sectionIndex++)
                    SingleChildScrollView(
                      key: PageStorageKey(sectionIndex),
                      primary: false,
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                      child: sections[sectionIndex].content,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolLink(BuildContext context, AppLocalizations labels, QuickTool tool) {
    return _SettingsLink(
      label: tool.name(labels),
      icon: tool.icon,
      onTap: () => _openTool(tool.id),
    );
  }
}

class _SettingsLink extends StatelessWidget {
  final String label;
  final String icon;
  final VoidCallback onTap;

  const _SettingsLink({required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      leading: SvgIcon(icon, color: colors.onSurfaceVariant),
      title: Text(label, style: Theme.of(context).textTheme.titleSmall),
      trailing: Icon(Icons.chevron_right, size: 18, color: colors.onSurfaceVariant),
      onTap: onTap,
    );
  }
}

class _ProxySettings extends StatefulWidget {
  final Map<String, dynamic> proxy;
  final Future<void> Function(String, Object) save;
  final Future<void> Function(int) changePort;

  const _ProxySettings({required this.proxy, required this.save, required this.changePort});

  @override
  State<_ProxySettings> createState() => _ProxySettingsState();
}

class _ProxySettingsState extends State<_ProxySettings> {
  late final bypassController = TextEditingController(text: widget.proxy['proxyPassDomains'] as String);
  final bypassFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    bypassFocus.addListener(() {
      if (!bypassFocus.hasFocus) _saveBypass();
    });
  }

  @override
  void didUpdateWidget(_ProxySettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!bypassFocus.hasFocus && widget.proxy['proxyPassDomains'] != oldWidget.proxy['proxyPassDomains']) {
      bypassController.text = widget.proxy['proxyPassDomains'] as String;
    }
  }

  void _saveBypass() {
    if (widget.proxy['proxyPassDomains'] != bypassController.text) {
      unawaited(widget.save('proxyPassDomains', bypassController.text));
    }
  }

  @override
  void dispose() {
    bypassFocus.dispose();
    bypassController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = AppLocalizations.of(context)!;
    final style = Theme.of(context).textTheme.titleSmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PortWidget.remote(port: widget.proxy['port'] as int, changePort: widget.changePort, textStyle: style),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${labels.setAs}${labels.systemProxy}', style: style),
          value: widget.proxy['enableSystemProxy'] as bool,
          onChanged: (value) => widget.save('enableSystemProxy', value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('SOCKS5', style: style),
          value: widget.proxy['enableSocks5'] as bool,
          onChanged: (value) => widget.save('enableSocks5', value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(labels.enabledHTTP2, style: style),
          value: widget.proxy['enabledHttp2'] as bool,
          onChanged: (value) => widget.save('enabledHttp2', value),
        ),
        Row(
          children: [
            Expanded(child: Text(labels.proxyIgnoreDomain, style: style)),
            TextButton(
              onPressed: () {
                bypassController.text = SystemProxy.proxyPassDomains;
                _saveBypass();
              },
              child: Text(labels.reset),
            ),
          ],
        ),
        TextField(
          controller: bypassController,
          focusNode: bypassFocus,
          onTapOutside: (_) => bypassFocus.unfocus(),
          textInputAction: TextInputAction.done,
          minLines: 1,
          maxLines: 5,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            helperText: labels.proxyBypassSeparatorHint,
            helperMaxLines: 2,
            contentPadding: const EdgeInsets.all(12),
          ),
        ),
      ],
    );
  }
}
