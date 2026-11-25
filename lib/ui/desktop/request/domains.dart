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
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/ui/component/context_menu.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/channel.dart';
import 'package:proxypin/network/channel/channel_context.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_client.dart';
import 'package:proxypin/ui/component/multi_select_controller.dart';
import 'package:proxypin/ui/component/transition.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/content/panel.dart';
import 'package:proxypin/ui/desktop/request/request.dart';
import 'package:proxypin/utils/har.dart';
import 'package:proxypin/utils/keyword_highlight.dart';
import 'package:proxypin/utils/lang.dart';
import 'package:proxypin/utils/listenable_list.dart';
import 'package:proxypin/utils/platform.dart';

import '../../component/model/search_model.dart';

/// 左侧域名
/// @author wanghongen
/// 2023/10/8
class DomainList extends StatefulWidget {
  final ProxyServer proxyServer;
  final NetworkTabController panel;

  final ListenableList<HttpRequest> list;
  final Function(List<HttpRequest>)? onRemove;
  final ValueChanged<int>? onVisibleCountChanged;
  final MultiSelectController selectionController;
  final RequestSelectionHandlers selectionHandlers;

  const DomainList(
      {super.key,
      required this.proxyServer,
      required this.list,
      required this.panel,
      this.onRemove,
      this.onVisibleCountChanged,
      required this.selectionController,
      required this.selectionHandlers});

  @override
  State<StatefulWidget> createState() {
    return DomainWidgetState();
  }
}

class DomainWidgetState extends State<DomainList> with AutomaticKeepAliveClientMixin {
  //域名和对应请求列表的映射
  final LinkedHashMap<String, DomainRequests> containerMap = LinkedHashMap<String, DomainRequests>();

  //搜索视图
  final _searchView = <String, DomainRequests>{};
  final _requestDomains = <String, DomainRequests>{};
  Timer? _refreshTimer;
  int _matches = 0;
  bool get _searching => searchModel?.isNotEmpty == true;
  int get visibleCount => _searching ? _matches : _requestDomains.length;

  //搜索的内容
  SearchModel? searchModel;
  //关键词高亮监听
  late VoidCallback highlightListener;
  late MultiSelectListener<String> selectionListener;

  bool sortDesc = true;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  MultiSelectController get selectionController => widget.selectionController;

  void changeState() {
    _refreshTimer ??= Timer(const Duration(milliseconds: 500), () {
      _refreshTimer = null;
      setState(() {});
    });
  }

  void _publishCount() {
    widget.onVisibleCountChanged?.call(visibleCount);
  }

  Iterable<DomainRequests> get _visibleDomains =>
      _searching ? containerMap.keys.map((host) => _searchView[host]).whereType<DomainRequests>() : containerMap.values;

  bool _isVisible(String id) {
    final domain = _requestDomains[id];
    return domain != null && (!_searching || _searchView[domain.domain]?._indices.containsKey(id) == true);
  }

  @override
  void initState() {
    super.initState();
    for (final request in widget.list.source) {
      _add(request, refresh: false);
    }
    _publishCount();
    highlightListener = () {
      //回调时机在高亮设置页面dispose之后。所以需要在下一帧刷新，否则会报错
      WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
        highlightHandler();
      });
    };
    KeywordHighlights.addListener(highlightListener);

    selectionListener = MultiSelectListener((items) {
      if (!mounted) {
        return;
      }
      _refreshRequestSelection(items);
    });
    selectionController.selectedIds.addListener(selectionListener);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    selectionController.selectedIds.removeListener(selectionListener);
    KeywordHighlights.removeListener(highlightListener);
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    var count = 0;
    final sections = <({DomainRequests domain, int start, int rows, bool descending})>[];
    for (final domain in _visibleDomains) {
      final rows = domain.currentSelected ? domain._rows.length : 0;
      sections.add((domain: domain, start: count, rows: rows, descending: domain.sortDesc));
      count += 1 + rows;
    }
    final headers = {for (final section in sections) section.domain.key!: section};
    return ListView.builder(
      itemCount: count,
      findChildIndexCallback: (key) {
        if (key is! ValueKey<String>) return headers[key]?.start;
        final section = headers[_requestDomains[key.value]?.key];
        if (section == null || section.rows == 0) return null;
        final index = section.domain._indices[key.value];
        if (index == null || index >= section.rows) return null;
        final offset = section.descending ? section.rows - 1 - index : index;
        return section.start + offset + 1;
      },
      itemBuilder: (_, index) {
        var lower = 0;
        var upper = sections.length;
        while (lower + 1 < upper) {
          final middle = (lower + upper) ~/ 2;
          if (sections[middle].start <= index) {
            lower = middle;
          } else {
            upper = middle;
          }
        }
        final section = sections[lower];
        final offset = index - section.start;
        if (offset == 0) return section.domain;
        final row = section.descending ? section.rows - offset : offset - 1;
        return row < section.domain._rows.length ? section.domain._rows[row] : null;
      },
    );
  }

  ///搜索
  void search(SearchModel? val) {
    setState(() {
      searchModel = val;
      _searchView.clear();
      _matches = 0;
      if (_searching) {
        for (final domain in containerMap.values) {
          final filtered = domain.copy();
          for (final row in domain._rows) {
            if (val!.filter(row.request, row.response.get() ?? row.request.response)) {
              filtered._appendRow(row);
            }
          }
          if (filtered._rows.isNotEmpty) {
            _searchView[domain.domain] = filtered;
            _matches += filtered._rows.length;
          }
        }
        selectionController.pruneWhere(_isVisible);
      }
      _publishCount();
    });
  }

  ///高亮处理
  void highlightHandler() {
    //获取所有请求Widget
    List<RequestWidget> requests = containerMap.values.map((e) => e.body).expand((element) => element).toList();
    for (RequestWidget request in requests) {
      request.changeState();
    }
  }

  ///添加请求
  void add(Channel channel, HttpRequest request) {
    if (_add(request)) _publishCount();
  }

  bool _add(HttpRequest request, {bool refresh = true}) {
    final host = request.remoteDomain();
    final id = request.requestId;
    if (host == null || _requestDomains.containsKey(id)) return false;
    final domain = _getDomainRequests(host, request);
    final first = domain._rows.isEmpty;
    final row = domain.addRequest(request);
    _requestDomains[id] = domain;
    var visible = !_searching;
    if (_searching) {
      if (searchModel!.filter(request, request.response)) {
        final filtered = _searchView.putIfAbsent(host, domain.copy);
        visible = true;
        filtered._appendRow(row);
        _matches++;
      }
    }
    if (refresh && visible) {
      if (first) {
        setState(() {});
      } else if (_searching || domain.currentSelected) {
        changeState();
      }
    }
    return true;
  }

  DomainRequests _getDomainRequests(String host, HttpRequest request) {
    DomainRequests? domainRequests = containerMap[host];
    if (domainRequests == null) {
      domainRequests = DomainRequests._(
        host,
        proxyServer: widget.proxyServer,
        trailing: appIcon(request),
        onDelete: deleteHost,
        onExportHar: exportDomainHar,
        onExpansionChanged: () => setState(() {}),
        onRequestRemove: (req) {
          _removeFromView(req, domainRequests!);
          widget.onRemove?.call([req]);
        },
        selectionController: selectionController,
        selectionHandlers: widget.selectionHandlers,
        sortDesc: sortDesc,
      );
      containerMap[host] = domainRequests;
    }

    return domainRequests;
  }

  Widget? appIcon(HttpRequest request) {
    var processInfo = request.processInfo;
    if (processInfo == null) {
      return null;
    }

    return futureWidget(
        processInfo.getIcon(),
        (data) =>
            data.isEmpty ? const SizedBox() : Image.memory(data, width: 23, height: Platform.isWindows ? 16 : null));
  }

  ///移除域名
  void deleteHost(String host) {
    DomainRequests? domainRequests = containerMap.remove(host);
    if (domainRequests == null) {
      return;
    }
    final requests = domainRequests.body.map((e) => e.request).toList();
    for (final request in requests) {
      _requestDomains.remove(request.requestId);
    }
    _matches -= _searchView.remove(host)?._rows.length ?? 0;
    _publishCount();
    setState(() {});
    widget.onRemove?.call(requests);
  }

  ///添加响应
  void addResponse(ChannelContext channelContext, HttpResponse response) {
    final id = response.request?.requestId ?? response.requestId;
    final domain = _requestDomains[id];
    final row = domain?._rowFor(id);
    if (domain == null || row == null) return;
    row.setResponse(response);
    if (!_searching) return;

    final filtered = _searchView[domain.domain];
    final wasVisible = filtered?._indices.containsKey(id) == true;
    final matches = searchModel!.filter(row.request, response);
    if (matches == wasVisible) return;
    if (matches) {
      final target = filtered ?? (_searchView[domain.domain] = domain.copy());
      target._insertInOrder(row, domain);
      _matches++;
    } else {
      _removeMatch(domain, id);
      selectionController.pruneWhere(_isVisible);
    }
    _publishCount();
    setState(() {});
  }

  void remove(List<HttpRequest> list) {
    var changed = false;
    for (final request in list) {
      final domain = _requestDomains[request.requestId];
      if (domain == null || !domain._removeRow(request.requestId)) continue;
      _requestDomains.remove(request.requestId);
      _removeMatch(domain, request.requestId);
      changed = true;
    }
    if (!changed) return;
    selectionController.pruneWhere((id) => _requestDomains.containsKey(id));
    _publishCount();
    setState(() {});
  }

  void _removeFromView(HttpRequest request, DomainRequests domain) {
    _requestDomains.remove(request.requestId);
    _removeMatch(domain, request.requestId);
    _publishCount();
    setState(() {});
  }

  void _removeMatch(DomainRequests domain, String id) {
    final filtered = _searchView[domain.domain];
    if (filtered == null || !filtered._removeRow(id)) return;
    _matches--;
    if (filtered._rows.isEmpty) _searchView.remove(domain.domain);
  }

  ///清理
  void clean() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    setState(() {
      containerMap.clear();
      _requestDomains.clear();
      _searchView.clear();
      _matches = 0;
      for (final request in widget.list.source) {
        _add(request, refresh: false);
      }
      _publishCount();
    });
  }

  List<HttpRequest> currentView() {
    return _visibleDomains.expand((list) => list.body.map((it) => it.request)).toList();
  }

  Future<void> exportDomainHar(String domain) async {
    var requests = containerMap[domain]?.body.map((it) => it.request).toList() ?? [];
    if (requests.isEmpty) {
      if (mounted) FlutterToastr.show(localizations.emptyData, context);
      return;
    }

    var fileName = _domainHarFileName(domain);
    try {
      var path = await Platforms.saveFileAdaptive(fileName: fileName);
      if (path == null) {
        return;
      }
      var file = await File(path).create(recursive: true);
      await Har.writeFile(requests, file, title: fileName);
      if (mounted) FlutterToastr.show(localizations.exportSuccess, context);
    } catch (e) {
      if (mounted) FlutterToastr.show('${localizations.exportFailed} $e', context);
    }
  }

  String _domainHarFileName(String domain) {
    var uri = Uri.tryParse(domain);
    var host = (uri?.host.isNotEmpty == true) ? uri!.host : domain;
    var suffix = uri?.hasPort == true ? '_${uri!.port}' : '';
    var safeDomain = '$host$suffix'.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safeDomain.isEmpty) {
      safeDomain = 'domain';
    }
    return 'ProxyPin_${safeDomain}_${DateTime.now().dateFormat()}.har';
  }

  ///排序
  void sort(bool desc) {
    if (sortDesc == desc) return;
    sortDesc = desc;
    for (final request in containerMap.values) {
      request.sortDesc = desc;
    }
    setState(() {});
  }

  List<HttpRequest> selectedRequests() {
    final selectedIds = selectionController.selectedIds;
    if (selectedIds.isEmpty) {
      return [];
    }
    return currentView().where((request) => selectedIds.contains(request.requestId)).toList();
  }

  void selectRange(HttpRequest request) {
    final currentIds = currentView().map((item) => item.requestId).toList();
    if (currentIds.isEmpty) {
      return;
    }

    selectionController.selectRange(currentIds, request.requestId);
  }

  void _refreshRequestSelection(List<String> selectedIds) {
    for (final id in selectedIds) {
      _requestDomains[id]?._rowFor(id)?.changeState();
    }
  }
}

///标题和内容布局 标题是域名 内容是域名下请求
class DomainRequests extends StatefulWidget {
  final String domain;
  final ProxyServer proxyServer;
  final Widget? trailing;

  //请求列表
  final _rows = <RequestWidget>[];
  final _indices = <String, int>{};
  bool get sortDesc => _expansion.sortDesc;
  set sortDesc(bool desc) => _expansion.sortDesc = desc;
  Iterable<RequestWidget> get body => sortDesc ? _rows.reversed : _rows;

  RequestWidget? _rowFor(String id) {
    final index = _indices[id];
    return index == null ? null : _rows[index];
  }

  final _DomainExpansion _expansion;
  final VoidCallback onExpansionChanged;

  //移除回调
  final Function(String host)? onDelete;
  final Function(String host)? onExportHar;
  final Function(HttpRequest request)? onRequestRemove;
  final RequestSelectionHandlers selectionHandlers;
  final MultiSelectController selectionController;

  DomainRequests._(this.domain,
      {GlobalKey? key,
      _DomainExpansion? expansion,
      required this.onExpansionChanged,
      required bool sortDesc,
      this.onDelete,
      this.onExportHar,
      required this.proxyServer,
      this.onRequestRemove,
      required this.selectionHandlers,
      this.trailing,
      required this.selectionController})
      : _expansion = expansion ?? _DomainExpansion(sortDesc),
        super(key: key ?? GlobalKey<_DomainRequestsState>());

  ///添加请求
  RequestWidget addRequest(HttpRequest request) {
    final row = RequestWidget(request,
        key: ValueKey(request.requestId),
        index: _rows.length,
        proxyServer: proxyServer,
        displayDomain: false,
        multiSelectController: selectionController,
        selectionHandlers: selectionHandlers,
        remove: (it) => _remove(it));
    _appendRow(row);
    changeState();
    return row;
  }

  void _appendRow(RequestWidget row) {
    final id = row.request.requestId;
    _indices[id] = _rows.length;
    _rows.add(row);
  }

  void _insertInOrder(RequestWidget row, DomainRequests original) {
    final id = row.request.requestId;
    final originalIndex = original._indices[id]!;
    if (_rows.isEmpty || original._indices[_rows.last.request.requestId]! < originalIndex) {
      _appendRow(row);
      return;
    }
    var lower = 0;
    var upper = _rows.length;
    while (lower < upper) {
      final middle = (lower + upper) ~/ 2;
      if (original._indices[_rows[middle].request.requestId]! < originalIndex) {
        lower = middle + 1;
      } else {
        upper = middle;
      }
    }
    _rows.insert(lower, row);
    _reindexFrom(lower);
  }

  void _reindexFrom(int start) {
    for (var index = start; index < _rows.length; index++) {
      _indices[_rows[index].request.requestId] = index;
    }
  }

  void setTrailing(Widget? trailing) {
    var state = key as GlobalKey<_DomainRequestsState>;
    state.currentState?.trailing = trailing;
  }

  void _remove(RequestWidget requestWidget) {
    if (_removeRow(requestWidget.request.requestId)) {
      onRequestRemove?.call(requestWidget.request);
    }
  }

  bool _removeRow(String id) {
    final index = _indices.remove(id);
    if (index == null) return false;
    _rows.removeAt(index);
    _reindexFrom(index);
    changeState();
    return true;
  }

  ///复制
  DomainRequests copy() {
    return DomainRequests._(domain,
        key: key as GlobalKey<_DomainRequestsState>,
        trailing: trailing,
        expansion: _expansion,
        onExpansionChanged: onExpansionChanged,
        sortDesc: sortDesc,
        onDelete: onDelete,
        onExportHar: onExportHar,
        onRequestRemove: onRequestRemove,
        selectionController: selectionController,
        selectionHandlers: selectionHandlers,
        proxyServer: proxyServer);
  }

  bool get currentSelected => _expansion.expanded;

  void toggleExpanded() {
    _expansion.expanded = !currentSelected;
    onExpansionChanged();
  }

  void changeState() {
    var state = key as GlobalKey<_DomainRequestsState>;
    state.currentState?.changeState();
  }

  @override
  State<StatefulWidget> createState() {
    return _DomainRequestsState();
  }
}

class _DomainExpansion {
  _DomainExpansion(this.sortDesc);

  bool sortDesc;
  bool expanded = false;
}

class _DomainRequestsState extends State<DomainRequests> {
  final GlobalKey<ColorTransitionState> transitionState = GlobalKey<ColorTransitionState>();
  late Configuration configuration;
  Widget? trailing;
  Timer? _highlightTimer;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    configuration = widget.proxyServer.configuration;
    trailing = widget.trailing;
  }

  void changeState() {
    _highlightTimer ??= Timer(const Duration(milliseconds: 500), () {
      _highlightTimer = null;
      transitionState.currentState?.show();
    });
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _hostWidget(widget.domain);
  }

  //domain title（结构沿用旧版：Material 箭头 + 域名 + 右侧 app 图标；无底色无分割线。
  //Material+InkWell：hover/水波纹由组件自身处理，不再 setState 重建子树）
  Widget _hostWidget(String title) {
    final theme = Theme.of(context);
    final display = AppDisplaySettings.captureOf(context);
    final scale = display?.captureRowScale ?? 1;
    final contentScale = scale.clamp(0.0, 1.0);
    final height = 40 * scale;
    final arrowSize = 18 * contentScale;
    final appIconSize = 23 * contentScale;
    var host = Material(
        color: Colors.transparent,
        child: InkWell(
            onSecondaryTapDown: (details) => menu(details),
            onTap: () => setState(widget.toggleExpanded),
            hoverColor: rowHoverColor(theme),
            child: Container(
                constraints: BoxConstraints(minHeight: height),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(children: [
                  SizedBox(
                      width: 25,
                      child: Icon(widget.currentSelected ? Icons.arrow_drop_down : Icons.arrow_right,
                          size: arrowSize, color: theme.colorScheme.onSurfaceVariant)),
                  Expanded(
                      child: Text(title,
                          textAlign: TextAlign.left,
                          style: TextStyle(
                              fontSize: display?.captureRowMetrics.titleSize ?? 13,
                              height: 1.25,
                              color: theme.colorScheme.onSurface),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    ConstrainedBox(constraints: BoxConstraints.loose(Size.square(appIconSize)), child: trailing!),
                  ],
                ]))));

    return ColorTransition(
        key: transitionState,
        duration: const Duration(milliseconds: 1800),
        begin: Theme.of(context).focusColor,
        startAnimation: false,
        child: host);
  }

  //域名右键菜单
  void menu(TapDownDetails details) {
    showCustomContextMenu(context, details.globalPosition, [
      ContextMenuItem.normal(
          label: localizations.copyHost,
          onClick: () {
            Clipboard.setData(ClipboardData(text: Uri.parse(widget.domain).host));
            FlutterToastr.show(localizations.copied, context);
          }),
      ContextMenuItem.separator(),
      ContextMenuItem.submenu(label: localizations.domainFilter, submenu: hostFilterMenu()),
      ContextMenuItem.separator(),
      ContextMenuItem.normal(label: localizations.exportDomainHar, onClick: () => exportDomainHar()),
      ContextMenuItem.separator(),
      ContextMenuItem.normal(label: localizations.repeatDomainRequests, onClick: () => repeatDomainRequests()),
      ContextMenuItem.separator(),
      ContextMenuItem.normal(label: localizations.delete, onClick: () => _delete()),
    ]);
  }

  //重复域名下请求
  void repeatDomainRequests() async {
    var list = widget.body.toList().reversed;
    for (var requestWidget in list) {
      var request = requestWidget.request.copy(uri: requestWidget.request.requestUrl);
      var proxyInfo = widget.proxyServer.isRunning ? ProxyInfo.of("127.0.0.1", widget.proxyServer.port) : null;
      try {
        await HttpClients.proxyRequest(request, proxyInfo: proxyInfo, timeout: const Duration(seconds: 3));
        if (mounted) FlutterToastr.show(localizations.reSendRequest, rootNavigator: true, context);
      } catch (e) {
        if (mounted) FlutterToastr.show('${localizations.fail}$e', rootNavigator: true, context);
      }
    }
  }

  void exportDomainHar() {
    widget.onExportHar?.call(widget.domain);
  }

  List<ContextMenuItem> hostFilterMenu() {
    return [
      ContextMenuItem.normal(
          label: localizations.domainBlacklist,
          onClick: () {
            HostFilter.blacklist.add(Uri.parse(widget.domain).host);
            configuration.flushConfig();
            FlutterToastr.show(localizations.addSuccess, context);
          }),
      ContextMenuItem.normal(
          label: localizations.domainWhitelist,
          onClick: () {
            HostFilter.whitelist.add(Uri.parse(widget.domain).host);
            configuration.flushConfig();
            FlutterToastr.show(localizations.addSuccess, context);
          }),
      ContextMenuItem.normal(
          label: localizations.deleteWhitelist,
          onClick: () {
            HostFilter.whitelist.remove(Uri.parse(widget.domain).host);
            configuration.flushConfig();
            FlutterToastr.show(localizations.deleteSuccess, context);
          }),
    ];
  }

  void _delete() {
    widget.onDelete?.call(widget.domain);
    FlutterToastr.show(localizations.deleteSuccess, context);
  }
}

class HostWidget extends StatelessWidget {
  final String host;
  final Function()? onMenu;

  const HostWidget(this.host, {super.key, this.onMenu});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
        onSecondaryTap: onMenu,
        child: ListTile(
            minLeadingWidth: 25,
            leading: const Icon(Icons.arrow_right, size: 18),
            dense: true,
            horizontalTitleGap: 0,
            contentPadding: const EdgeInsets.only(left: 3, right: 8),
            visualDensity: const VisualDensity(vertical: -3.6),
            title: Text(host,
                textAlign: TextAlign.left,
                style: const TextStyle(fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis)));
  }
}
