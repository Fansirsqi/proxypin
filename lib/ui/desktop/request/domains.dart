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
  final MultiSelectController selectionController;
  final RequestSelectionHandlers selectionHandlers;

  const DomainList(
      {super.key,
      required this.proxyServer,
      required this.list,
      required this.panel,
      this.onRemove,
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
  LinkedHashMap<String, DomainRequests> searchView = LinkedHashMap<String, DomainRequests>();

  //搜索的内容
  SearchModel? searchModel;
  bool changing = false; //是否存在刷新任务
  //关键词高亮监听
  late VoidCallback highlightListener;
  late MultiSelectListener<String> selectionListener;

  bool sortDesc = true;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  MultiSelectController get selectionController => widget.selectionController;

  void changeState() {
    if (!changing) {
      changing = true;
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        setState(() {
          changing = false;
        });
      });
    }
  }

  @override
  void initState() {
    super.initState();
    var container = widget.list;
    for (var request in container.source) {
      DomainRequests domainRequests = getDomainRequests(request);
      domainRequests.addRequest(request.requestId, request, sortDesc);
    }
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
    selectionController.selectedIds.removeListener(selectionListener);
    KeywordHighlights.removeListener(highlightListener);
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // values 是惰性 Iterable，elementAt 每次 O(n)；转成 List 保证按下标取值 O(1)
    var list = containerMap.values.toList();

    //根究搜素文本过滤
    if (searchModel?.isNotEmpty == true) {
      searchView = searchFilter(searchModel!);
      list = searchView.values.toList();
      selectionController.prune(list.expand((e) => e.body).map((e) => e.request.requestId).toSet());
    } else {
      searchView.clear();
    }

    var count = 0;
    final sections = <({DomainRequests domain, int start, List<RequestWidget> rows})>[];
    for (final domain in list) {
      final rows = domain.currentSelected ? domain.visibleRows : const <RequestWidget>[];
      sections.add((domain: domain, start: count, rows: rows));
      count += 1 + rows.length;
    }
    final headers = {for (final section in sections) section.domain.key!: section.start};
    Map<Key, int>? rowIndices;
    return ListView.builder(
      itemCount: count,
      findChildIndexCallback: (key) =>
          headers[key] ??
          (rowIndices ??= {
            for (final section in sections)
              for (final (rowIndex, row) in section.rows.indexed) row.key!: section.start + rowIndex + 1,
          })[key],
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
        return offset == 0 ? section.domain : section.rows[offset - 1];
      },
    );
  }

  ///搜索
  void search(SearchModel? val) {
    setState(() {
      searchModel = val;
    });
  }

  ///搜索过滤
  LinkedHashMap<String, DomainRequests> searchFilter(SearchModel searchModel) {
    LinkedHashMap<String, DomainRequests> result = LinkedHashMap<String, DomainRequests>();

    containerMap.forEach((key, domainRequests) {
      var body = domainRequests.search(searchModel);
      if (body.isNotEmpty) {
        result[key] = domainRequests.copy(body: body);
      }
    });

    return result;
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
    String? host = request.remoteDomain();
    if (host == null) {
      return;
    }

    //按照域名分类
    DomainRequests domainRequests = getDomainRequests(request);
    var isNew = domainRequests.body.isEmpty;

    domainRequests.addRequest(request.requestId, request, sortDesc);
    //搜索视图
    if (searchModel?.isNotEmpty == true && searchModel?.filter(request, null) == true) {
      changeState();
    }

    if (isNew) {
      setState(() {
        containerMap[host] = domainRequests;
      });
    }
  }

  DomainRequests getDomainRequests(HttpRequest request) {
    var host = request.remoteDomain()!;
    DomainRequests? domainRequests = containerMap[host];
    if (domainRequests == null) {
      domainRequests = DomainRequests._(
        host,
        proxyServer: widget.proxyServer,
        trailing: appIcon(request),
        onDelete: deleteHost,
        onExportHar: exportDomainHar,
        onExpansionChanged: () => setState(() {}),
        onRowsChanged: changeState,
        onRequestRemove: (req) {
          widget.onRemove?.call([req]);
          changeState();
        },
        selectionController: selectionController,
        selectionHandlers: widget.selectionHandlers,
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
    setState(() {});

    widget.onRemove?.call(domainRequests.body.map((e) => e.request).toList());
  }

  ///添加响应
  void addResponse(ChannelContext channelContext, HttpResponse response) {
    String domain = response.request?.hostAndPort?.domain ?? channelContext.host!.domain;
    DomainRequests? domainRequests = containerMap[domain];
    var pathRow = domainRequests?.getRequest(response);
    pathRow?.setResponse(response);
    if (pathRow == null) {
      return;
    }

    //搜索视图
    if (searchModel case final model? when model.isNotEmpty) {
      final wasVisible = searchView[domain]?.getRequest(response) != null;
      if (wasVisible != model.filter(pathRow.request, response)) changeState();
    }
  }

  void remove(List<HttpRequest> list) {
    for (var request in list) {
      String? host = request.remoteDomain();
      containerMap[host]?._removeRequest(request);
    }
  }

  ///清理
  void clean() {
    setState(() {
      containerMap.clear();
      searchView.clear();

      var container = widget.list;
      for (var request in container.source) {
        DomainRequests domainRequests = getDomainRequests(request);
        domainRequests.addRequest(request.requestId, request, sortDesc);
      }
    });
  }

  List<HttpRequest> currentView() {
    var container = containerMap.values;
    if (searchModel?.isNotEmpty == true) {
      container = searchView.values;
    }
    return container.expand((list) => list.body.map((it) => it.request)).toList();
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
    sortDesc = desc;
    containerMap.forEach((key, request) {
      request.reverseRows();
    });
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
    var container = containerMap.values;
    if (searchModel?.isNotEmpty == true) {
      container = searchView.values;
    }
    for (var domain in container) {
      for (var requestWidget in domain.body) {
        if (selectedIds.contains(requestWidget.request.requestId)) {
          requestWidget.changeState();
        }
      }
    }
  }
}

///标题和内容布局 标题是域名 内容是域名下请求
class DomainRequests extends StatefulWidget {
  //请求ID和请求的映射
  final Map<String, RequestWidget> requestMap = HashMap<String, RequestWidget>();

  final String domain;
  final ProxyServer proxyServer;
  final Widget? trailing;

  //请求列表
  final _rows = _DomainRows();
  Queue<RequestWidget> get body => _rows.body;
  List<RequestWidget> get visibleRows => _rows.snapshot ??= body.toList(growable: false);

  final _DomainExpansion _expansion;
  final VoidCallback onExpansionChanged;
  final VoidCallback onRowsChanged;

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
      required this.onRowsChanged,
      this.onDelete,
      this.onExportHar,
      required this.proxyServer,
      this.onRequestRemove,
      required this.selectionHandlers,
      this.trailing,
      required this.selectionController})
      : _expansion = expansion ?? _DomainExpansion(),
        super(key: key ?? GlobalKey<_DomainRequestsState>());

  ///添加请求
  void addRequest(String? requestId, HttpRequest request, bool sortDesc) {
    if (requestMap.containsKey(requestId)) return;

    var requestWidget = RequestWidget(request,
        key: ValueKey(request.requestId),
        index: body.length,
        proxyServer: proxyServer,
        displayDomain: false,
        multiSelectController: selectionController,
        selectionHandlers: selectionHandlers,
        remove: (it) => _remove(it));
    sortDesc ? body.addFirst(requestWidget) : body.addLast(requestWidget);
    _rowsChanged();

    if (requestId == null) {
      return;
    }

    requestMap[requestId] = requestWidget;
    changeState();
  }

  RequestWidget? getRequest(HttpResponse response) {
    return requestMap[response.request?.requestId ?? response.requestId];
  }

  void setTrailing(Widget? trailing) {
    var state = key as GlobalKey<_DomainRequestsState>;
    state.currentState?.trailing = trailing;
  }

  void _remove(RequestWidget requestWidget) {
    if (body.remove(requestWidget)) {
      requestMap.remove(requestWidget.request.requestId);
      _rowsChanged();
      onRequestRemove?.call(requestWidget.request);
      changeState();
    }
  }

  void reverseRows() {
    final reversed = body.toList().reversed;
    body
      ..clear()
      ..addAll(reversed);
    _rowsChanged();
    changeState();
  }

  void _rowsChanged() {
    _rows.snapshot = null;
    if (currentSelected) onRowsChanged();
  }

  void _removeRequest(HttpRequest request) {
    var requestWidget = requestMap.remove(request.requestId);
    if (requestWidget != null) {
      _remove(requestWidget);
    }
  }

  ///根据文本过滤
  Iterable<RequestWidget> search(SearchModel searchModel) {
    return body
        .where((element) => searchModel.filter(element.request, element.response.get() ?? element.request.response));
  }

  ///复制
  DomainRequests copy({Iterable<RequestWidget>? body}) {
    var state = key as GlobalKey<_DomainRequestsState>;
    var headerBody = DomainRequests._(domain,
        key: state,
        trailing: trailing,
        expansion: _expansion,
        onExpansionChanged: onExpansionChanged,
        onRowsChanged: onRowsChanged,
        onDelete: onDelete,
        onExportHar: onExportHar,
        onRequestRemove: onRequestRemove,
        selectionController: selectionController,
        selectionHandlers: selectionHandlers,
        proxyServer: proxyServer);
    if (body != null) {
      headerBody.body.addAll(body);
      for (final row in headerBody.body) {
        headerBody.requestMap[row.request.requestId] = row;
      }
    }
    return headerBody;
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
  bool expanded = false;
}

class _DomainRows {
  final Queue<RequestWidget> body = Queue();
  List<RequestWidget>? snapshot;
}

class _DomainRequestsState extends State<DomainRequests> {
  final GlobalKey<ColorTransitionState> transitionState = GlobalKey<ColorTransitionState>();
  late Configuration configuration;
  Widget? trailing;
  bool changing = false;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    configuration = widget.proxyServer.configuration;
    trailing = widget.trailing;
  }

  void changeState() {
    //防止频繁刷新
    if (!changing) {
      changing = true;
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          setState(() {
            changing = false;
          });
          transitionState.currentState?.show();
        }
      });
    }
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
