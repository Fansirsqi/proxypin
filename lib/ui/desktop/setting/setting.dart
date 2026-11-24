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
import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/util/system_proxy.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/component/proxy_port_setting.dart';
import 'package:proxypin/ui/component/svg_icon.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/content/detail_settings.dart';
import 'package:proxypin/ui/desktop/preference.dart';
import 'package:proxypin/ui/desktop/setting/about.dart';
import 'package:proxypin/ui/desktop/setting/environment.dart';
import 'package:proxypin/ui/desktop/ssl/ssl.dart';
import 'package:proxypin/ui/desktop/toolbar/quick_tools.dart';
import 'package:url_launcher/url_launcher.dart';

class Setting extends StatelessWidget {
  final ProxyServer proxyServer;
  final AppConfiguration appConfiguration;

  const Setting({super.key, required this.proxyServer, required this.appConfiguration});

  @override
  Widget build(BuildContext context) {
    final labels = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final sections = [
      (
        title: labels.preference,
        content: Column(
          children: [
            Preference(appConfiguration, proxyServer.configuration),
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
            _ProxySettings(proxyServer: proxyServer),
            const Divider(height: 24),
            SslWidget(proxyServer: proxyServer, settingsTile: true),
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
              onTap: () => showEnvironmentDialog(context),
            ),
          ],
        ),
      ),
      (title: labels.customizeToolbar, content: ToolbarSettings(appConfiguration: appConfiguration)),
    ];

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 660,
        height: 620,
        child: DefaultTabController(
          length: sections.length,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 7, 8, 4),
                child: Row(
                  children: [
                    Expanded(child: Text(labels.setting, style: theme.textTheme.titleLarge)),
                    const CloseButton(),
                  ],
                ),
              ),
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
      ),
    );
  }

  Widget _toolLink(BuildContext context, AppLocalizations labels, QuickTool tool) {
    return _SettingsLink(
      label: tool.name(labels),
      icon: tool.icon,
      onTap: () async {
        await tool.launch(context, proxyServer);
        managerStateVersion.value++;
      },
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
  final ProxyServer proxyServer;

  const _ProxySettings({required this.proxyServer});

  @override
  State<_ProxySettings> createState() => _ProxySettingsState();
}

class _ProxySettingsState extends State<_ProxySettings> {
  late final configuration = widget.proxyServer.configuration;
  late final bypassController = TextEditingController(text: configuration.proxyPassDomains);

  @override
  void dispose() {
    if (configuration.proxyPassDomains != bypassController.text) {
      configuration.proxyPassDomains = bypassController.text;
      SystemProxy.setProxyPassDomains(configuration.proxyPassDomains);
      configuration.flushConfig();
    }
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
        PortWidget(proxyServer: widget.proxyServer, textStyle: style),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${labels.setAs}${labels.systemProxy}', style: style),
          value: configuration.enableSystemProxy,
          onChanged: (value) {
            widget.proxyServer.setSystemProxyEnable(value);
            setState(() => configuration.enableSystemProxy = value);
            configuration.flushConfig();
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('SOCKS5', style: style),
          value: configuration.enableSocks5,
          onChanged: (value) {
            setState(() => configuration.enableSocks5 = value);
            configuration.flushConfig();
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(labels.enabledHTTP2, style: style),
          value: configuration.enabledHttp2,
          onChanged: (value) {
            setState(() => configuration.enabledHttp2 = value);
            configuration.flushConfig();
          },
        ),
        Row(
          children: [
            Expanded(child: Text(labels.proxyIgnoreDomain, style: style)),
            TextButton(
              onPressed: () => bypassController.text = SystemProxy.proxyPassDomains,
              child: Text(labels.reset),
            ),
          ],
        ),
        TextField(
          controller: bypassController,
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
