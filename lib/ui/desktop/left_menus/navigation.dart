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
import 'package:proxypin/ui/component/svg_icon.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/desktop/setting/setting.dart';

class LeftNavigationBar extends StatefulWidget {
  final AppConfiguration appConfiguration;
  final ProxyServer proxyServer;
  final ValueNotifier<int> selectIndex;

  const LeftNavigationBar(
      {super.key, required this.appConfiguration, required this.proxyServer, required this.selectIndex});

  @override
  State<StatefulWidget> createState() => _LeftNavigationBarState();
}

class _LeftNavigationBarState extends State<LeftNavigationBar> {
  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final expanded = widget.appConfiguration.desktopNavigationExpanded;
    final width = expanded ? (MediaQuery.sizeOf(context).width / 4).clamp(48.0, 160.0) : 48.0;
    final items = [
      (icon: 'list', label: localizations.navRequests),
      (icon: 'star', label: localizations.favorites),
      (icon: 'clock', label: localizations.history),
      (icon: 'wrench', label: localizations.toolbox),
    ];

    return ValueListenableBuilder(
        valueListenable: widget.selectIndex,
        builder: (_, index, __) {
          if (index == -1) {
            return const SizedBox.shrink();
          }

          return SizedBox(
            width: width.toDouble(),
            child: Material(
              color: desktopChromeColor(theme),
              child: DecoratedBox(
                decoration: BoxDecoration(border: Border(right: BorderSide(color: chromeBorderColor(theme)))),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(5, 6, 6, 6),
                  child: CustomScrollView(
                    primary: false,
                    slivers: [
                      SliverList.list(children: [
                        _RailItem(
                          icon: (color) => Icon(Icons.view_sidebar_outlined, size: 18, color: color),
                          label: expanded ? localizations.collapseNavigation : localizations.expandNavigation,
                          expanded: expanded,
                          trailing: expanded ? const Icon(Icons.chevron_left, size: 16) : null,
                          onTap: () {
                            setState(() => widget.appConfiguration.desktopNavigationExpanded = !expanded);
                            widget.appConfiguration.flushConfig();
                          },
                        ),
                        const Divider(height: 12, indent: 5, endIndent: 5),
                        for (var indexOfItem = 0; indexOfItem < items.length; indexOfItem++)
                          _RailItem(
                            icon: (color) => SvgIcon(items[indexOfItem].icon, color: color),
                            label: items[indexOfItem].label,
                            expanded: expanded,
                            active: index == indexOfItem,
                            onTap: () => widget.selectIndex.value = indexOfItem,
                          ),
                      ]),
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: SizedBox(
                            width: 37,
                            child: _RailItem(
                              icon: (color) => SvgIcon('gear', color: color),
                              label: localizations.setting,
                              expanded: false,
                              onTap: () => showDialog<void>(
                                context: context,
                                builder: (_) => Setting(
                                  proxyServer: widget.proxyServer,
                                  appConfiguration: widget.appConfiguration,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        });
  }
}

class _RailItem extends StatelessWidget {
  final Widget Function(Color) icon;
  final String label;
  final bool expanded;
  final bool active;
  final Widget? trailing;
  final VoidCallback onTap;

  const _RailItem({
    required this.icon,
    required this.label,
    required this.expanded,
    required this.onTap,
    this.active = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = active ? theme.colorScheme.onSecondaryContainer : theme.colorScheme.onSurfaceVariant;
    final radius = BorderRadius.circular(7);
    final rowHeight = 36 + theme.visualDensity.vertical * 2;
    return Semantics(
      button: true,
      selected: active ? true : null,
      label: label,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Ink(
            decoration:
                BoxDecoration(borderRadius: radius, color: active ? theme.colorScheme.secondaryContainer : null),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: rowHeight),
              child: ExcludeSemantics(
                child: IconTheme.merge(
                  data: IconThemeData(color: color),
                  child: expanded
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                          child: Row(children: [
                            icon(color),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelLarge?.copyWith(color: color)),
                            ),
                            if (trailing != null) trailing!,
                          ]),
                        )
                      : Center(heightFactor: 1, child: icon(color)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
