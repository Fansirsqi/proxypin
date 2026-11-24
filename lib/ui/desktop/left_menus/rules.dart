import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/network/components/manager/request_breakpoint_manager.dart';
import 'package:proxypin/network/components/manager/request_crypto_manager.dart';
import 'package:proxypin/network/components/manager/request_map_manager.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/desktop/toolbar/quick_tools.dart';

class RulesPage extends StatefulWidget {
  final ProxyServer proxyServer;
  final ValueNotifier<int> selectIndex;
  final int index;

  const RulesPage({super.key, required this.proxyServer, required this.selectIndex, required this.index});

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  AppLocalizations get localizations => AppLocalizations.of(context)!;

  RequestBlockManager? _blockManager;
  RequestRewriteManager? _rewriteManager;
  RequestMapManager? _mapManager;
  RequestCryptoManager? _cryptoManager;
  ScriptManager? _scriptManager;
  RequestBreakpointManager? _breakpointManager;

  @override
  void initState() {
    super.initState();
    _reload();
    widget.selectIndex.addListener(_onIndexChanged);
    managerStateVersion.addListener(_reload);
  }

  @override
  void dispose() {
    widget.selectIndex.removeListener(_onIndexChanged);
    managerStateVersion.removeListener(_reload);
    super.dispose();
  }

  void _onIndexChanged() {
    if (widget.selectIndex.value == widget.index) {
      _reload();
    }
  }

  Future<void> _reload() async {
    var block = await RequestBlockManager.instance;
    var rewrite = await RequestRewriteManager.instance;
    var map = await RequestMapManager.instance;
    var crypto = await RequestCryptoManager.instance;
    var script = await ScriptManager.instance;
    var breakpoint = await RequestBreakpointManager.instance;
    if (!mounted) return;
    setState(() {
      _blockManager = block;
      _rewriteManager = rewrite;
      _mapManager = map;
      _cryptoManager = crypto;
      _scriptManager = script;
      _breakpointManager = breakpoint;
    });
  }

  @override
  Widget build(BuildContext context) {
    var theme = Theme.of(context);
    var rows = <Widget>[
      _ruleRow(
          icon: Icons.block,
          title: localizations.requestBlock,
          desc: localizations.requestBlockDesc,
          status: _ruleStatus(_blockManager?.enabled, _blockManager?.list.length, isScript: false),
          onTap: () => _openRule('requestBlock')),
      _ruleRow(
          icon: Icons.edit_outlined,
          title: localizations.requestRewrite,
          desc: localizations.requestRewriteDesc,
          status: _ruleStatus(_rewriteManager?.enabled, _rewriteManager?.rules.length, isScript: false),
          onTap: () => _openRule('requestRewrite')),
      _ruleRow(
          icon: Icons.compare_arrows_outlined,
          title: localizations.requestMap,
          desc: localizations.requestMapDesc,
          status: _ruleStatus(_mapManager?.enabled, _mapManager?.rules.length, isScript: false),
          onTap: () => _openRule('requestMap')),
      _ruleRow(
          icon: Icons.lock_outline,
          title: localizations.requestCrypto,
          desc: localizations.requestCryptoDesc,
          status: _ruleStatus(_cryptoManager?.enabled, _cryptoManager?.rules.length, isScript: false),
          onTap: () => _openRule('requestCrypto')),
      _ruleRow(
          icon: Icons.code,
          title: localizations.script,
          desc: localizations.scriptDesc,
          status: _ruleStatus(_scriptManager?.enabled, _scriptManager?.list.length, isScript: true),
          onTap: () => _openRule('script')),
      _ruleRow(
          icon: Icons.pause_circle_outline,
          title: localizations.breakpoint,
          desc: localizations.breakpointDesc,
          status: _ruleStatus(_breakpointManager?.enabled, _breakpointManager?.list.length, isScript: false),
          onTap: () => _openRule('breakpoint')),
    ];

    var children = <Widget>[
      Container(
          padding: const EdgeInsets.only(left: 16, right: 14, top: 13, bottom: 13),
          decoration:
              BoxDecoration(border: Border(bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)))),
          child: Row(children: [
            Text(localizations.trafficControl, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(localizations.rulesPageHint,
                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
          ])),
    ];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(Container(
            height: 1, color: theme.dividerColor.withValues(alpha: 0.3), margin: const EdgeInsets.only(left: 58)));
      }
      children.add(rows[i]);
    }

    return Align(
        alignment: Alignment.topLeft,
        child: Container(
            margin: const EdgeInsets.all(10),
            constraints: const BoxConstraints(maxWidth: 580),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.dividerColor.withValues(alpha: 0.5)),
                color: theme.colorScheme.surface),
            child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Column(mainAxisSize: MainAxisSize.min, children: children))));
  }

  String _ruleStatus(bool? enabled, int? count, {required bool isScript}) {
    if (enabled != true) {
      return localizations.notEnabled;
    }
    return isScript ? localizations.statusEnabledScripts(count ?? 0) : localizations.statusEnabledRules(count ?? 0);
  }

  Widget _ruleRow(
      {required IconData icon,
      required String title,
      required String desc,
      required String status,
      required VoidCallback onTap}) {
    var theme = Theme.of(context);
    var on = status != localizations.notEnabled;
    return InkWell(
        onTap: onTap,
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Row(children: [
              Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8), color: theme.colorScheme.primary.withValues(alpha: 0.08)),
                  child: Icon(icon, size: 16, color: theme.colorScheme.primary)),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500)),
                const SizedBox(height: 1),
                Text(desc, style: TextStyle(fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant)),
              ])),
              const SizedBox(width: 12),
              Text(status,
                  style: TextStyle(fontSize: 11.5, color: on ? okColor(theme) : theme.colorScheme.onSurfaceVariant)),
              Icon(Icons.chevron_right, size: 18, color: theme.colorScheme.onSurfaceVariant),
            ])));
  }

  void _openRule(String id) => quickToolOf(id)?.launch(context, widget.proxyServer);
}
