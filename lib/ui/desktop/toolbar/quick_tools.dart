import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/mcp/mcp_service.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/components/manager/hosts_manager.dart';
import 'package:proxypin/network/components/manager/network_condition_manager.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/network/components/manager/request_breakpoint_manager.dart';
import 'package:proxypin/network/components/manager/request_crypto_manager.dart';
import 'package:proxypin/network/components/manager/request_map_manager.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/component/svg_icon.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/desktop/setting/external_proxy.dart';
import 'package:proxypin/ui/desktop/setting/filter.dart';
import 'package:proxypin/ui/desktop/setting/hosts.dart';
import 'package:proxypin/ui/desktop/setting/weak_network.dart';
import 'package:proxypin/ui/desktop/toolbar/mcp_panel.dart';

typedef QuickToolName = String Function(AppLocalizations localizations);
typedef QuickToolLaunch = Future<void> Function(BuildContext context, ProxyServer proxyServer);

/// 功能是否处于启用/生效状态（用于工具栏图标高亮）
typedef QuickToolActive = Future<bool> Function(ProxyServer proxyServer);

class QuickTool {
  final String id;

  /// assets/icons/ 下的设计稿线条图标名
  final String icon;
  final QuickToolName name;
  final QuickToolLaunch launch;

  /// 启用状态检查；为 null 时恒视为启用（保持高亮）
  final QuickToolActive? isActive;

  const QuickTool({required this.id, required this.icon, required this.name, required this.launch, this.isActive});
}

final trafficQuickTools = <QuickTool>[
  QuickTool(
      id: 'requestBlock',
      icon: 'block',
      name: (l) => l.requestBlock,
      isActive: (_) async {
        var m = await RequestBlockManager.instance;
        return m.enabled && m.list.isNotEmpty;
      },
      launch: (context, proxyServer) async {
        await MultiWindow.openToolWindow(AppLocalizations.of(context)!.requestBlock, 'RequestBlock',
            size: const Size(650, 570));
      }),
  QuickTool(
      id: 'requestRewrite',
      icon: 'pencil',
      name: (l) => l.requestRewrite,
      isActive: (_) async {
        var m = await RequestRewriteManager.instance;
        return m.enabled && m.rules.isNotEmpty;
      },
      launch: (context, proxyServer) async {
        await MultiWindow.openToolWindow(AppLocalizations.of(context)!.requestRewrite, 'RequestRewriteWidget',
            size: const Size(800, 750));
      }),
  QuickTool(
      id: 'requestMap',
      icon: 'swap',
      name: (l) => l.requestMap,
      isActive: (_) async {
        var m = await RequestMapManager.instance;
        return m.enabled && m.rules.isNotEmpty;
      },
      launch: (context, proxyServer) async {
        await MultiWindow.openToolWindow(AppLocalizations.of(context)!.requestMap, 'RequestMapPage',
            size: const Size(800, 720));
      }),
  QuickTool(
      id: 'requestCrypto',
      icon: 'key',
      name: (l) => l.requestCrypto,
      isActive: (_) async {
        var m = await RequestCryptoManager.instance;
        return m.enabled && m.rules.isNotEmpty;
      },
      launch: (context, proxyServer) async {
        await MultiWindow.openToolWindow(AppLocalizations.of(context)!.requestCrypto, 'RequestCryptoPage',
            size: const Size(820, 750));
      }),
  QuickTool(
      id: 'script',
      icon: 'code',
      name: (l) => l.script,
      isActive: (_) async {
        var m = await ScriptManager.instance;
        return m.enabled && m.list.isNotEmpty;
      },
      launch: (context, proxyServer) async {
        await MultiWindow.openToolWindow(AppLocalizations.of(context)!.script, 'ScriptWidget',
            size: const Size(800, 780));
      }),
  QuickTool(
      id: 'breakpoint',
      icon: 'breakpoint',
      name: (l) => l.breakpoint,
      isActive: (_) async {
        var m = await RequestBreakpointManager.instance;
        return m.enabled && m.list.isNotEmpty;
      },
      launch: (context, proxyServer) async {
        await MultiWindow.openToolWindow(AppLocalizations.of(context)!.breakpoint, 'RequestBreakpointPage',
            size: const Size(800, 750));
      }),
];

final settingQuickTools = <QuickTool>[
  QuickTool(
      id: 'domainFilter',
      icon: 'funnel',
      name: (l) => l.domainFilter,
      isActive: (_) async => HostFilter.whitelist.enabled || HostFilter.blacklist.enabled,
      launch: (context, proxyServer) async {
        await showDialog(
            barrierDismissible: false,
            context: context,
            builder: (context) => FilterDialog(configuration: proxyServer.configuration));
      }),
  QuickTool(
      id: 'hosts',
      icon: 'lines',
      name: (l) => l.hosts,
      isActive: (_) async {
        var m = await HostsManager.instance;
        return m.enabled && m.list.isNotEmpty;
      },
      launch: (context, proxyServer) async {
        var hosts = await HostsManager.instance;
        if (!context.mounted) return;
        await showDialog(
            barrierDismissible: false, context: context, builder: (context) => HostsDialog(hostsManager: hosts));
      }),
  QuickTool(
      id: 'externalProxy',
      icon: 'arrow_out',
      name: (l) => l.externalProxy,
      isActive: (proxyServer) async => proxyServer.configuration.externalProxy?.enabled == true,
      launch: (context, proxyServer) async {
        await showDialog(
            barrierDismissible: false,
            context: context,
            builder: (context) => ExternalProxyDialog(configuration: proxyServer.configuration));
      }),
  QuickTool(
      id: 'weakNetwork',
      icon: 'zap',
      name: (l) => l.weakNetwork,
      isActive: (_) async {
        var m = await NetworkConditionManager.instance;
        return m.enabled && m.rules.any((r) => r.enabled);
      },
      launch: (context, proxyServer) async {
        var manager = await NetworkConditionManager.instance;
        if (!context.mounted) return;
        await showDialog(
            barrierDismissible: false, context: context, builder: (context) => WeakNetworkDialog(manager: manager));
      }),
  QuickTool(
      id: 'mcpService',
      icon: 'mcp',
      name: (l) => l.mcpService,
      isActive: (_) async => McpService.instance.isRunning,
      launch: (context, proxyServer) async {
        await McpServiceDialog.show(context, proxyServer);
      }),
];

final quickTools = <QuickTool>[...trafficQuickTools, ...settingQuickTools];

QuickTool? quickToolOf(String id) {
  for (var tool in quickTools) {
    if (tool.id == id) {
      return tool;
    }
  }
  return null;
}

void toggleToolbarPin(AppConfiguration appConfiguration, String id) {
  var pins = List<String>.of(appConfiguration.toolbarPins.value);
  if (!pins.remove(id)) {
    pins.add(id);
  }
  appConfiguration.toolbarPins.value = pins;
  appConfiguration.flushConfig();
}

class QuickToolbar extends StatefulWidget {
  final ProxyServer proxyServer;

  const QuickToolbar({super.key, required this.proxyServer});

  @override
  State<QuickToolbar> createState() => _QuickToolbarState();
}

class _QuickToolbarState extends State<QuickToolbar> {
  /// 各工具的启用状态缓存：启用主色高亮，未启用灰色（管理器均为缓存单例，读取近零成本）
  final Map<String, bool> _active = {};
  String _lastPinsKey = '';

  @override
  void initState() {
    super.initState();
    _refresh();
    // 子窗口（重写/映射/加密/脚本/断点）开关变化 → 主窗口 reload 后版本号递增 → 刷新高亮
    managerStateVersion.addListener(_onManagerStateChanged);
  }

  @override
  void dispose() {
    managerStateVersion.removeListener(_onManagerStateChanged);
    super.dispose();
  }

  void _onManagerStateChanged() => _refresh();

  void _refresh() {
    var pins = AppConfiguration.current?.toolbarPins.value ?? const <String>[];
    for (var id in pins) {
      var checker = quickToolOf(id)?.isActive;
      if (checker == null) {
        _active[id] = true; // 无状态检查的工具恒高亮（当前没有此类工具）
        continue;
      }
      checker(widget.proxyServer).then((active) {
        if (mounted && _active[id] != active) {
          setState(() => _active[id] = active);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    var appConfiguration = AppConfiguration.current;
    if (appConfiguration == null) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<List<String>>(
        valueListenable: appConfiguration.toolbarPins,
        builder: (context, pins, _) {
          // 固定项变化时调度一次状态刷新（microtask 避开 build 期 setState）
          var pinsKey = pins.join(',');
          if (pinsKey != _lastPinsKey) {
            _lastPinsKey = pinsKey;
            Future.microtask(_refresh);
          }
          var theme = Theme.of(context);
          var tools = pins.map(quickToolOf).whereType<QuickTool>().toList();
          return Row(children: [
            for (var tool in tools) ...[
              IconButton(
                  tooltip: tool.name(AppLocalizations.of(context)!),
                  // 设计稿 .tbtn：32x32 点击盒
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  padding: EdgeInsets.zero,
                  // 未启用灰色，启用才主色高亮
                  icon: SvgIcon(tool.icon,
                      size: 17,
                      color:
                          _active[tool.id] == true ? theme.colorScheme.tertiary : theme.colorScheme.onSurfaceVariant),
                  onPressed: () async {
                    await tool.launch(context, widget.proxyServer);
                    // 弹窗类工具关闭后刷新状态；独立窗口类在下次固定项变化/启动时刷新
                    _refresh();
                  }),
              const SizedBox(width: 6),
            ],
            _menuButton(context, appConfiguration),
          ]);
        });
  }

  Widget _menuButton(BuildContext context, AppConfiguration appConfiguration) {
    var localizations = AppLocalizations.of(context)!;
    var theme = Theme.of(context);
    return PopupMenuButton<String>(
        tooltip: localizations.allFunctions,
        icon: SvgIcon('dots', size: 17, color: Theme.of(context).colorScheme.onSurfaceVariant),
        position: PopupMenuPosition.under,
        itemBuilder: (menuContext) => [
              PopupMenuItem<String>(
                  enabled: false,
                  height: 26,
                  padding: const EdgeInsets.only(left: 14),
                  child: Text(localizations.trafficControl,
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurfaceVariant))),
              for (var tool in trafficQuickTools) _menuRow(context, tool, appConfiguration),
            ]);
  }

  PopupMenuItem<String> _menuRow(BuildContext context, QuickTool tool, AppConfiguration appConfiguration) {
    var localizations = AppLocalizations.of(context)!;
    var theme = Theme.of(context);
    return PopupMenuItem<String>(
        value: tool.id,
        height: 40,
        padding: EdgeInsets.zero,
        onTap: () {
          tool.launch(context, widget.proxyServer);
        },
        child: SizedBox(
            height: 40,
            child: Row(children: [
              const SizedBox(width: 14),
              SvgIcon(tool.icon, size: 15, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(child: Text(tool.name(localizations), style: const TextStyle(fontSize: 13))),
              ValueListenableBuilder<List<String>>(
                  valueListenable: appConfiguration.toolbarPins,
                  builder: (context, pins, _) {
                    var pinned = pins.contains(tool.id);
                    return InkWell(
                        onTap: () => toggleToolbarPin(appConfiguration, tool.id),
                        child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                            child: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined,
                                size: 16,
                                color: pinned ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant)));
                  }),
            ])));
  }
}

class ToolbarSettings extends StatelessWidget {
  final AppConfiguration appConfiguration;

  const ToolbarSettings({super.key, required this.appConfiguration});

  @override
  Widget build(BuildContext context) {
    var localizations = AppLocalizations.of(context)!;
    return ValueListenableBuilder<List<String>>(
      valueListenable: appConfiguration.toolbarPins,
      builder: (context, pins, _) {
        final theme = Theme.of(context);
        final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        final pinnedTools = pins.map(quickToolOf).whereType<QuickTool>();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () {
                  appConfiguration.toolbarPins.value = List<String>.of(AppConfiguration.defaultToolbarPins);
                  appConfiguration.flushConfig();
                },
                child: Text(localizations.restoreDefaults),
              ),
            ),
            Text(localizations.pinnedDragSort, style: hint),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final tool in pinnedTools) _pinnedChip(context, tool),
            ]),
            const SizedBox(height: 20),
            Text(localizations.pinToolsHint, style: hint),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final tool in quickTools) _toolChip(context, tool, pins.contains(tool.id)),
            ]),
          ],
        );
      },
    );
  }

  /// 已固定 chip：整体按住即拖（桌面端鼠标直接拖，无需长按），拖到另一个 chip 上落到其位置
  Widget _pinnedChip(BuildContext context, QuickTool tool) {
    return DragTarget<String>(onAcceptWithDetails: (details) {
      if (details.data != tool.id) {
        _reorderPin(details.data, tool.id);
      }
    }, builder: (context, candidateData, rejectedData) {
      // 拖拽物悬停（非自身）时加粗高亮描边，提示落点
      var dropHighlight = candidateData.isNotEmpty && candidateData.first != tool.id;
      return Draggable<String>(
          data: tool.id,
          feedback: Material(color: Colors.transparent, child: _chip(context, tool, dragging: true)),
          childWhenDragging: Opacity(opacity: 0.35, child: _chip(context, tool)),
          child:
              MouseRegion(cursor: SystemMouseCursors.grab, child: _chip(context, tool, dropHighlight: dropHighlight)));
    });
  }

  /// 把 draggedId 移动到 targetId 的位置（其余顺延）
  void _reorderPin(String draggedId, String targetId) {
    var list = List<String>.of(appConfiguration.toolbarPins.value);
    var oldIndex = list.indexOf(draggedId);
    var targetIndex = list.indexOf(targetId);
    if (oldIndex < 0 || targetIndex < 0) return;
    list.removeAt(oldIndex);
    list.insert(targetIndex, draggedId);
    appConfiguration.toolbarPins.value = list;
    appConfiguration.flushConfig();
  }

  Widget _chip(BuildContext context, QuickTool tool, {bool dropHighlight = false, bool dragging = false}) {
    final colors = Theme.of(context).colorScheme;
    return InputChip(
      backgroundColor: dragging ? colors.primaryContainer : null,
      side: dropHighlight ? BorderSide(color: colors.primary) : null,
      avatar: const Icon(Icons.drag_indicator, size: 16),
      label: Text(tool.name(AppLocalizations.of(context)!)),
      onDeleted: () => toggleToolbarPin(appConfiguration, tool.id),
    );
  }

  Widget _toolChip(BuildContext context, QuickTool tool, bool pinned) {
    return FilterChip(
      avatar: SvgIcon(tool.icon, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
      label: Text(tool.name(AppLocalizations.of(context)!)),
      selected: pinned,
      onSelected: (_) => toggleToolbarPin(appConfiguration, tool.id),
    );
  }
}
