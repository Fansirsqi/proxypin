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

import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_client.dart';
import 'package:proxypin/storage/favorites.dart';
import 'package:proxypin/ui/component/state_component.dart';
import 'package:proxypin/ui/component/svg_icon.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/content/web_socket.dart';
import 'package:proxypin/ui/content/mqtt.dart';
import 'package:proxypin/utils/lang.dart';
import 'package:proxypin/utils/platform.dart';

import 'body.dart';
import 'detail_fields.dart';
import 'detail_settings.dart';
import 'headers.dart';
import 'menu.dart';

///网络请求详情页
///@Author: wanghongen
class NetworkTabController extends StatefulWidget {
  static GlobalKey<NetworkTabState>? currentKey;
  final String? windowId;
  final ProxyServer? proxyServer;
  final ValueWrap<HttpRequest> request = ValueWrap();
  final ValueWrap<HttpResponse> response = ValueWrap();
  final Widget? title;
  final TextStyle? tabStyle;
  final bool showLayoutSettings;

  /// 初始选中的 tab 下标（默认 0 = 概览）
  final int initialTab;

  NetworkTabController(
      {HttpRequest? httpRequest,
      HttpResponse? httpResponse,
      this.title,
      this.tabStyle,
      this.proxyServer,
      this.windowId,
      this.showLayoutSettings = true,
      this.initialTab = 0})
      : super(key: GlobalKey<NetworkTabState>()) {
    currentKey = key as GlobalKey<NetworkTabState>;
    request.set(httpRequest);
    response.set(httpResponse);
  }

  void change(HttpRequest? request, HttpResponse? response) {
    this.request.set(request);
    this.response.set(response);
    var state = key as GlobalKey<NetworkTabState>;
    state.currentState?.changeState();
  }

  void changeState() {
    var state = key as GlobalKey<NetworkTabState>;
    state.currentState?.changeState();
  }

  ///更新当前详情请求的响应，请求在详情页打开期间完成时刷新响应内容
  void updateResponse(HttpResponse? response) {
    var currentRequest = request.get();
    if (response?.request == null || currentRequest == null) {
      return;
    }
    if (currentRequest.requestId != response!.request!.requestId) {
      return;
    }
    this.response.set(response);
    changeState();
  }

  @override
  State<StatefulWidget> createState() {
    return NetworkTabState();
  }

  static NetworkTabController? get current => currentKey?.currentWidget as NetworkTabController?;
}

class NetworkTabState extends State<NetworkTabController> with TickerProviderStateMixin {
  late List<String> tabs;
  late bool _mqttTabs;

  static const double _detailTitleHeight = 40;
  late TabController _tabController;
  late int _activeTab;
  final _requestScrollController = ScrollController();
  final _responseScrollController = ScrollController();

  final GlobalKey<HttpBodyState> requestHttpBodyKey = GlobalKey<HttpBodyState>();
  final GlobalKey<HttpBodyState> responseHttpBodyKey = GlobalKey<HttpBodyState>();
  final GlobalKey<HttpBodyState> overviewHttpBodyKey = GlobalKey<HttpBodyState>();

  /// 当前请求的手动收藏状态，按 requestId 缓存避免每次 build 查存储
  String? _favoritedId;
  bool _favorited = false;

  void _checkFavorited(HttpRequest request) {
    if (_favoritedId == request.requestId) return;
    var id = request.requestId;
    FavoriteStorage.favorites.then((favorites) {
      if (!mounted) return;
      setState(() {
        _favoritedId = id;
        _favorited = favorites.any((f) => f.request.requestId == id);
      });
    });
  }

  Future<void> _toggleFavorite(HttpRequest request) async {
    var localizations = AppLocalizations.of(context)!;
    if (_favorited) {
      var favorites = await FavoriteStorage.favorites;
      Favorite? target;
      for (final f in favorites) {
        if (f.request.requestId == request.requestId) {
          target = f;
          break;
        }
      }
      if (target != null) {
        await FavoriteStorage.removeFavorite(target);
      }
      if (!mounted) return;
      setState(() => _favorited = false);
      FlutterToastr.show(localizations.deleteSuccess, context);
    } else {
      await FavoriteStorage.addFavorite(request);
      if (!mounted) return;
      setState(() => _favorited = true);
      FlutterToastr.show(localizations.addSuccess, context);
    }
  }

  void changeState() {
    final mqtt = widget.request.get()?.protocolVersion == 'MQTT';
    if (mqtt != _mqttTabs) {
      _tabController.dispose();
      _configureTabs(mqtt);
    }
    setState(() {});
  }

  void _configureTabs(bool mqtt) {
    _mqttTabs = mqtt;
    tabs = mqtt ? ['General', 'MQTT'] : ['General', 'Request', 'Response', 'Cookies'];
    _tabController =
        TabController(length: tabs.length, vsync: this, initialIndex: widget.initialTab.clamp(0, tabs.length - 1));
    _activeTab = _tabController.index;
    _tabController.addListener(() {
      if (_activeTab == _tabController.index) return;
      setState(() => _activeTab = _tabController.index);
      if (_activeTab != 0) {
        overviewHttpBodyKey.currentState?.hideSearchOverlay();
      }
      if (_tabController.index != 1) {
        requestHttpBodyKey.currentState?.hideSearchOverlay();
      }
      if (_tabController.index != 2) {
        responseHttpBodyKey.currentState?.hideSearchOverlay();
      }
    });
  }

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    _configureTabs(widget.request.get()?.protocolVersion == 'MQTT');

    if (widget.windowId != null) {
      HardwareKeyboard.instance.addHandler(onKeyEvent);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _requestScrollController.dispose();
    _responseScrollController.dispose();
    HardwareKeyboard.instance.removeHandler(onKeyEvent);
    super.dispose();
  }

  bool onKeyEvent(KeyEvent event) {
    if ((HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed) &&
        event.logicalKey == LogicalKeyboardKey.keyW) {
      if (DesktopMultiWindow.isStandalone) {
        if (event is! KeyDownEvent) return true;
      } else {
        HardwareKeyboard.instance.removeHandler(onKeyEvent);
      }
      WindowController.fromWindowId(widget.windowId!).close();
      return true;
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    final configuration = AppConfiguration.current;
    if (configuration == null) {
      return _buildDetail(context, AppConfiguration.defaultDetailLayout);
    }
    return ValueListenableBuilder(
      valueListenable: configuration.detailLayout,
      builder: (context, layout, _) => _buildDetail(context, layout, configuration: configuration),
    );
  }

  Widget _buildDetail(BuildContext context, DetailLayout layout, {AppConfiguration? configuration}) {
    bool isMqtt = widget.request.get()?.protocolVersion == 'MQTT';
    bool isWebSocket = widget.request.get()?.isWebSocket == true;
    bool isSse = widget.response.get()?.headers.contentType.toLowerCase().startsWith('text/event-stream') == true;
    bool isStreamMessages = isWebSocket || isSse;
    if (isMqtt) {
      tabs[tabs.length - 1] = 'MQTT';
    } else if (isSse) {
      tabs[tabs.length - 1] = "SSE";
    } else if (isWebSocket) {
      tabs[tabs.length - 1] = "WebSocket";
    } else {
      tabs[tabs.length - 1] = 'Cookies';
    }

    final isDesktop = Platforms.isDesktop();
    final theme = Theme.of(context);
    final tabStyle = theme.textTheme.labelLarge?.merge(widget.tabStyle);
    final tabHeight = isDesktop ? MediaQuery.textScalerOf(context).scale(tabStyle?.fontSize ?? 14) + 20 : null;
    final labelAlignment = switch (layout.labels) {
      DetailTabLabelAlignment.top => Alignment.topCenter,
      DetailTabLabelAlignment.center => Alignment.center,
      DetailTabLabelAlignment.bottom => Alignment.bottomCenter,
    };
    final tabBar = TabBar(
      controller: _tabController,
      isScrollable: isDesktop,
      tabAlignment: isDesktop ? TabAlignment.start : null,
      dividerHeight: isDesktop ? 0 : null,
      labelPadding: EdgeInsets.symmetric(horizontal: isDesktop ? 13 : 10),
      labelStyle: isDesktop ? tabStyle?.copyWith(fontWeight: FontWeight.w600) : widget.tabStyle,
      unselectedLabelStyle: isDesktop ? tabStyle?.copyWith(fontWeight: FontWeight.w400) : widget.tabStyle,
      unselectedLabelColor: isDesktop ? theme.colorScheme.onSurfaceVariant : null,
      tabs: [
        for (final title in tabs)
          Tab(
            height: tabHeight,
            child: isDesktop
                ? Align(
                    alignment: labelAlignment,
                    widthFactor: 1,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(tabLabel(title), maxLines: 1),
                    ),
                  )
                : Text(tabLabel(title), maxLines: 1),
          ),
      ],
    );
    final tabPosition = switch (layout.tabs) {
      DetailTabAlignment.left => Alignment.centerLeft,
      DetailTabAlignment.center => Alignment.center,
      DetailTabAlignment.right => Alignment.centerRight,
    };
    final scrollBehavior = ScrollConfiguration.of(context);
    final PreferredSizeWidget tabStrip = isDesktop
        ? PreferredSize(
            preferredSize: tabBar.preferredSize,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: theme.dividerColor)),
              ),
              child: Align(
                alignment: tabPosition,
                child: ScrollConfiguration(
                  behavior: scrollBehavior.copyWith(
                    dragDevices: {...scrollBehavior.dragDevices, PointerDeviceKind.mouse},
                  ),
                  child: tabBar,
                ),
              ),
            ),
          )
        : tabBar;
    final layoutButton = isDesktop && widget.showLayoutSettings && configuration != null
        ? DetailLayoutSettings.menu(configuration: configuration)
        : null;

    PreferredSizeWidget appBar;
    if (widget.title != null) {
      appBar = AppBar(
        title: widget.title,
        bottom: tabStrip,
        centerTitle: true,
        actions: [
          ShareWidget(proxyServer: widget.proxyServer, request: widget.request.get(), response: widget.response.get()),
          const SizedBox(width: 3),
          DetailMenuWidget(request: widget.request.get()),
          if (layoutButton != null) layoutButton,
          const SizedBox(width: 10),
        ],
      );
    } else if (isDesktop) {
      // 桌面子窗口：同主窗口详情，URL 标题栏 + tab 条；
      // URL 栏同时把 tab 条压到 macOS 红绿灯（隐藏式标题栏，悬浮在左上约 72px）之下，
      // 标题栏自身内容也要右移避开红绿灯
      var request = widget.request.get();
      if (request == null) {
        appBar = widget.windowId == null ? const PreferredSize(preferredSize: Size.zero, child: SizedBox()) : tabStrip;
      } else {
        appBar = PreferredSize(
            preferredSize: Size.fromHeight(tabStrip.preferredSize.height + _detailTitleHeight),
            child: Material(
                color: theme.colorScheme.surface,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Padding(
                      padding: EdgeInsets.only(left: widget.windowId != null && Platform.isMacOS ? 72 : 0),
                      child: detailTitleBar(request, layoutButton)),
                  tabStrip,
                ])));
      }
    } else {
      appBar = tabStrip;
    }

    return Scaffold(
      endDrawerEnableOpenDragGesture: false,
      // 桌面端详情区用纯白底（用户反馈 #F5F6F8 发灰）；手机端保持主题默认
      backgroundColor: isDesktop ? Theme.of(context).colorScheme.surface : null,
      appBar: appBar,
      body: Padding(
          padding: isDesktop ? EdgeInsets.zero : const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: isDesktop && widget.request.get() == null
              ? const SizedBox() // 未选中请求：空白，不渲染 tab 内容
              : TabBarView(
                  physics: isDesktop ? const NeverScrollableScrollPhysics() : null,
                  controller: _tabController,
                  children: isMqtt
                      ? [
                          Overview(widget.request, widget.response, density: layout.headers),
                          SelectionArea(child: MqttMessages(widget.request)),
                        ]
                      : [
                          Overview(widget.request, widget.response,
                              density: layout.headers, bodyKey: overviewHttpBodyKey, active: _activeTab == 0),
                          KeepAliveWrapper(child: request(layout.headers)),
                          KeepAliveWrapper(child: response(layout.headers)),
                          if (isStreamMessages)
                            SelectionArea(child: Websocket(widget.request, widget.response))
                          else
                            Cookies(widget.request, widget.response, density: layout.headers),
                        ],
                )),
    );
  }

  Widget request(HeaderDensity density) {
    if (widget.request.get() == null) {
      return const SizedBox();
    }

    // 路径带查询参数（pathAndQuery），下方「查询参数」分区仍提供逐项解析
    var path = widget.request.get()?.pathAndQuery ?? '';
    try {
      path = Uri.decodeFull(path);
    } catch (_) {}

    return _DetailScrollView(controller: _requestScrollController, slivers: [
      SliverToBoxAdapter(child: DetailField(name: localizations.path, value: path, density: density)),
      SliverToBoxAdapter(child: RequestParams(widget.request, density: density)),
      ...message(widget.request.get(), "Request", _requestScrollController, density),
    ]);
  }

  Widget response(HeaderDensity density) {
    final response = widget.response.get();
    if (response == null) {
      return const SizedBox();
    }

    return _DetailScrollView(controller: _responseScrollController, slivers: [
      SliverToBoxAdapter(
        child: DetailField(
          name: localizations.statusCode,
          value: response.status.toString(),
          density: density,
          valueColor: statusColor(response.status.code, Theme.of(context)),
        ),
      ),
      ...message(response, "Response", _responseScrollController, density),
    ]);
  }

  String tabLabel(String title) {
    switch (title) {
      case 'General':
        return localizations.overview;
      case 'Request':
        return localizations.request;
      case 'Response':
        return localizations.response;
      default:
        return title; // Cookies / WebSocket / SSE / MQTT 保持原文
    }
  }

  Widget detailTitleBar(HttpRequest request, Widget? layoutButton) {
    var url = request.requestUrl;
    try {
      url = Uri.decodeFull(url);
    } catch (_) {}

    var theme = Theme.of(context);
    return Container(
        height: _detailTitleHeight,
        padding: const EdgeInsets.only(left: 12, right: 8),
        child: Row(children: [
          Text(request.method.name.toUpperCase(),
              style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: request.isWebSocket == true
                      // 设计稿 --ws：浅色 #6E3FC1，暗黑 #9B72E0
                      ? (theme.brightness == Brightness.light ? const Color(0xFF6E3FC1) : DarkPalette.ws)
                      : methodColor(request.method, theme))),
          const SizedBox(width: 10),
          Expanded(
              child: SelectableText(url,
                  maxLines: 1,
                  contextMenuBuilder: contextMenu,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface))),
          const SizedBox(width: 4),
          miniAction(
              tooltip: localizations.copyUrl,
              icon: 'copy',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: request.requestUrl)).then((_) {
                  if (mounted) FlutterToastr.show(localizations.copied, context);
                });
              }),
          miniAction(tooltip: localizations.repeat, icon: 'refresh', onPressed: () => resendRequest(request)),
          Builder(builder: (context) {
            _checkFavorited(request);
            var favorited = _favoritedId == request.requestId && _favorited;
            // 已收藏：琥珀色实心星（Material filled）；未收藏：中性灰线条星（设计 SVG）
            var amber = Theme.of(context).brightness == Brightness.light ? const Color(0xFFB76E00) : DarkPalette.warn;
            return miniAction(
                tooltip: localizations.favorite,
                icon: 'star',
                iconWidget: favorited ? Icon(Icons.star, size: 16, color: amber) : null,
                onPressed: () => _toggleFavorite(request));
          }),
          if (layoutButton != null) layoutButton,
        ]));
  }

  /// 设计稿 .mini：26x26 灰色小图标按钮（iconWidget 优先于 icon，用于实心/自定义图标）
  Widget miniAction(
      {required String tooltip,
      required String icon,
      required VoidCallback onPressed,
      Color? color,
      Widget? iconWidget}) {
    return Tooltip(
        message: tooltip,
        child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onPressed,
            child: SizedBox(
                width: 26,
                height: 26,
                child: Center(
                    child: iconWidget ??
                        SvgIcon(icon, size: 15, color: color ?? Theme.of(context).colorScheme.onSurfaceVariant)))));
  }

  void resendRequest(HttpRequest httpRequest) {
    var proxyServer = widget.proxyServer;
    var proxyInfo = proxyServer != null && proxyServer.isRunning ? ProxyInfo.of("127.0.0.1", proxyServer.port) : null;
    HttpClients.proxyRequest(httpRequest.copy(uri: httpRequest.requestUrl), proxyInfo: proxyInfo);
    FlutterToastr.show(localizations.reSendRequest, context, rootNavigator: true);
  }

  List<Widget> message(HttpMessage? message, String type, ScrollController scrollController, HeaderDensity density) {
    return [
      SliverToBoxAdapter(child: HeadersWidget(title: type, message: message, density: density)),
      SliverToBoxAdapter(child: detailDivider(context)),
      _detailBody(
        bodyKey: type == "Request" ? requestHttpBodyKey : responseHttpBodyKey,
        hideRequestRewrite: widget.windowId != null,
        message: message,
        active: _activeTab == (type == "Request" ? 1 : 2),
        scrollController: scrollController,
      ),
    ];
  }
}

class _DetailScrollView extends StatelessWidget {
  final ScrollController? controller;
  final List<Widget> slivers;

  const _DetailScrollView({this.controller, required this.slivers});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: CustomScrollView(controller: controller, slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 2)),
        ...slivers,
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ]),
    );
  }
}

Widget _detailBody({
  GlobalKey<HttpBodyState>? bodyKey,
  required HttpMessage? message,
  required bool hideRequestRewrite,
  required bool active,
  ScrollController? scrollController,
}) {
  double? previousHeight;
  Widget? body;
  return SliverLayoutBuilder(builder: (context, constraints) {
    final toolbarSpace = Platforms.isDesktop() ? 46.0 : 76.0;
    final availableHeight = max(0.0, constraints.viewportMainAxisExtent - toolbarSpace);
    final previewHeight = max(min(availableHeight, 240.0), availableHeight - constraints.precedingScrollExtent);
    if (previousHeight == previewHeight && body != null) return body!;
    previousHeight = previewHeight;
    return body = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: HttpBodyWidget(
          key: bodyKey,
          httpMessage: message,
          hideRequestRewrite: hideRequestRewrite,
          active: active,
          scrollController: scrollController,
          previewHeight: previewHeight,
        ),
      ),
    );
  });
}

/// 设计稿 --text-3：浅色 #8F959E，暗黑 #6F747D
Color text3Color(ThemeData theme) => theme.brightness == Brightness.light ? const Color(0xFF8F959E) : DarkPalette.text3;

/// 设计稿 行 hover（.row:hover / .rl-row:hover）：浅色 #F7F8FA，暗黑 --hover-weak #2A2D33
Color rowHoverColor(ThemeData theme) =>
    theme.brightness == Brightness.light ? const Color(0xFFF7F8FA) : DarkPalette.hoverWeak;

class RequestParams extends StatefulWidget {
  /// 展开状态跨请求保持（旧版行为）：默认折叠，点开一个详情的折叠/展开对后续详情生效
  static bool initiallyExpanded = false;

  final ValueWrap<HttpRequest> request;
  final HeaderDensity density;

  const RequestParams(this.request, {super.key, required this.density});

  @override
  State<RequestParams> createState() => _RequestParamsState();
}

class _RequestParamsState extends State<RequestParams> {
  @override
  Widget build(BuildContext context) {
    var request = widget.request.get();
    if (request == null) {
      return const SizedBox();
    }
    var params = request.requestUri?.queryParametersAll;
    if (params == null || params.isEmpty) {
      return const SizedBox();
    }
    final entries = [
      for (final param in params.entries)
        for (final value in param.value) MapEntry(param.key, value),
    ];
    final expanded = RequestParams.initiallyExpanded;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DetailSectionHeader(
        label: AppLocalizations.of(context)!.queryParams,
        count: entries.length,
        expanded: expanded,
        onTap: () => setState(() => RequestParams.initiallyExpanded = !expanded),
      ),
      if (expanded) DetailTable(entries: entries, density: widget.density),
    ]);
  }
}

class Overview extends StatelessWidget {
  final ValueWrap<HttpRequest> request;
  final ValueWrap<HttpResponse> response;
  final HeaderDensity density;
  final GlobalKey<HttpBodyState>? bodyKey;
  final bool active;

  const Overview(this.request, this.response, {super.key, required this.density, this.bodyKey, this.active = true});

  @override
  Widget build(BuildContext context) {
    var request = this.request.get();
    if (request == null) {
      return const SizedBox();
    }
    var localizations = AppLocalizations.of(context)!;
    var response = this.response.get();
    String requestUrl = request.requestUrl;
    try {
      requestUrl = Uri.decodeFull(request.requestUrl);
    } catch (_) {}

    DetailField row(String name, String? value, {Color? valueColor}) =>
        DetailField(name: name, value: value ?? '', density: density, valueColor: valueColor);

    if (request.protocolVersion == 'MQTT') {
      return _DetailScrollView(slivers: [
        SliverToBoxAdapter(
          child: SelectionArea(
            child: DetailRows(rows: [
              row('Connection', requestUrl),
              row('Protocol', 'MQTT over TLS'),
              row('Packets', request.messages.length.toString()),
              row('Start Time', request.requestTime.formatMillisecond()),
              if (request.processInfo != null) row('App', request.processInfo!.name),
            ]),
          ),
        ),
      ]);
    }

    // 设计稿 Overview 卡：状态码/协议/耗时/大小/远程地址/请求时间/App 七行（桌面端严格对齐）；
    // URL/方法/双 Content-Type 仅手机端 General 保留（桌面端 URL+方法已在顶部标题栏，类型见 Body 分区标签）
    var isDesktop = Platforms.isDesktop();
    return _DetailScrollView(slivers: [
      SliverToBoxAdapter(
        child: SelectionArea(
          child: DetailRows(rows: [
            row(localizations.statusCode, response?.status.toString(),
                valueColor: statusColor(response?.status.code, Theme.of(context))),
            row(localizations.protocol, request.protocolVersion),
            row(localizations.duration, _durationText(response)),
            row(localizations.size, _sizeText(context, request, response)),
            row(localizations.remoteAddress,
                '${response?.remoteHost ?? ''}${response?.remotePort == null ? '' : ':${response?.remotePort}'}'),
            row(localizations.requestTime, request.requestTime.formatMillisecond()),
            if (request.processInfo != null) row(localizations.app, request.processInfo!.name),
            if (!isDesktop) ...[
              row(localizations.requestUrl, requestUrl),
              row(localizations.requestMethod, request.method.name),
              row(localizations.requestType, request.headers.contentType),
              row(localizations.responseType, response?.headers.contentType),
            ],
          ]),
        ),
      ),
      if (response != null && (response.body?.isNotEmpty ?? false)) ...[
        SliverToBoxAdapter(child: detailDivider(context)),
        _detailBody(bodyKey: bodyKey, message: response, hideRequestRewrite: true, active: active),
      ],
    ]);
  }
}

/// 设计稿 Overview 耗时长："342 ms"（数值与单位间空格；costTime 原始格式 "84ms"/"1.23s"）
String? _durationText(HttpResponse? response) {
  var cost = response?.costTime();
  if (cost == null || cost.isEmpty) {
    return cost;
  }
  return cost.replaceAllMapped(RegExp(r'(\d)(ms|s)$'), (m) => '${m[1]} ${m[2]}');
}

/// 设计稿 Overview 大小行：请求 1.2 KB · 响应 8.6 KB (gzip)
String _sizeText(BuildContext context, HttpRequest request, HttpResponse? response) {
  var localizations = AppLocalizations.of(context)!;
  var reqSize = _kbText(request.packageSize);
  var respSize = _kbText(response?.packageSize);
  if (respSize.isEmpty) {
    return '${localizations.request} $reqSize';
  }
  var text = '${localizations.request} $reqSize · ${localizations.response} $respSize';
  if (response?.headers.isGzip == true) {
    text += ' (gzip)';
  }
  return text;
}

/// 1.2 KB / 8.6 KB 风格（去除多余的 0）
String _kbText(int? size) {
  if (size == null) {
    return '';
  }
  if (size < 1025) {
    return '$size B';
  }
  if (size > 1024 * 1024) {
    var mb = size / 1024 / 1024;
    return '${mb.toStringAsFixed(mb == mb.roundToDouble() ? 0 : 1)} MB';
  }
  var kb = size / 1024;
  return '${kb.toStringAsFixed(kb == kb.roundToDouble() ? 0 : 1)} KB';
}

/// 手机端详情 AppBar 标题（设计稿 .p-ptitle）：METHOD（语义色加粗）+ host/path，单行省略
Widget mobileDetailTitle(BuildContext context, HttpRequest request) {
  var theme = Theme.of(context);
  // 收藏/历史从 JSON 恢复时 hostAndPort 不持久化（为 null），退回 remoteDomain() 解析 uri
  var host = request.hostAndPort?.toString() ?? request.remoteDomain() ?? '';
  return Text.rich(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      TextSpan(children: [
        TextSpan(
            text: '${request.method.name} ',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: methodColor(request.method, theme))),
        TextSpan(text: '$host${request.pathAndQuery}', style: const TextStyle(fontSize: 15)),
      ]));
}

/// 方法颜色按设计稿：浅色 --get #1F8B4C / --post #B76E00 / --put #0E6BB8 / --delete #C4321F；
/// 暗黑对应 --get #3FB96A / --post #E8A33D / --put #4C9BE8 / --delete #E35B48
Color methodColor(HttpMethod method, ThemeData theme) {
  bool dark = theme.brightness == Brightness.dark;
  switch (method) {
    case HttpMethod.get:
      return dark ? DarkPalette.ok : const Color(0xFF1F8B4C);
    case HttpMethod.post:
      return dark ? DarkPalette.warn : const Color(0xFFB76E00);
    case HttpMethod.put:
      return dark ? DarkPalette.put : const Color(0xFF0E6BB8);
    case HttpMethod.delete:
      return dark ? DarkPalette.err : const Color(0xFFC4321F);
    default:
      return theme.colorScheme.onSurfaceVariant;
  }
}

/// 状态码颜色同方法色：2xx 绿 / 3xx 橙 / 其余红，暗黑用设计稿高亮版
Color? statusColor(int? status, ThemeData theme) {
  if (status == null) {
    return null;
  }
  bool dark = theme.brightness == Brightness.dark;
  if (status >= 200 && status < 300) {
    return dark ? DarkPalette.ok : const Color(0xFF1F8B4C);
  }
  if (status >= 300 && status < 400) {
    return dark ? DarkPalette.warn : const Color(0xFFB76E00);
  }
  return dark ? DarkPalette.err : const Color(0xFFC4321F);
}

class Cookies extends StatefulWidget {
  final ValueWrap<HttpRequest> request;
  final ValueWrap<HttpResponse> response;
  final HeaderDensity density;

  const Cookies(this.request, this.response, {super.key, required this.density});

  @override
  State<Cookies> createState() => _CookiesState();
}

class _CookiesState extends State<Cookies> {
  /// 请求/响应 Cookies 分区默认展开，点击小标题折叠；
  /// 展开状态跨请求保持（同 RequestParams.initiallyExpanded / HeadersWidget._lastExpanded 手法）
  static bool _requestExpanded = true;
  static bool _responseExpanded = true;

  @override
  Widget build(BuildContext context) {
    final requestCookies = widget.request.get()?.cookies ?? const <String>[];
    final responseCookies = widget.response.get()?.headers.getList("Set-Cookie") ?? const <String>[];
    final requestEntries = requestCookies.expand(_cookieEntries).toList();
    final localizations = AppLocalizations.of(context)!;
    if (requestEntries.isEmpty && responseCookies.isEmpty) {
      return Center(child: Text(localizations.emptyData, style: detailFieldStyle(context)));
    }
    return _DetailScrollView(slivers: [
      SliverList.list(children: [
        if (requestEntries.isNotEmpty) ...[
          DetailSectionHeader(
            label: localizations.requestCookies,
            count: requestEntries.length,
            expanded: _requestExpanded,
            onTap: () => setState(() => _requestExpanded = !_requestExpanded),
          ),
          if (_requestExpanded) DetailTable(entries: requestEntries, density: widget.density),
        ],
        if (responseCookies.isNotEmpty) ...[
          DetailSectionHeader(
            label: localizations.responseCookies,
            count: responseCookies.length,
            expanded: _responseExpanded,
            onTap: () => setState(() => _responseExpanded = !_responseExpanded),
          ),
          if (_responseExpanded)
            for (final cookie in responseCookies)
              DetailTable(entries: _cookieEntries(cookie, includeFlags: true), density: widget.density),
        ],
      ])
    ]);
  }

  Iterable<MapEntry<String, String>> _cookieEntries(String cookie, {bool includeFlags = false}) sync* {
    final segments = cookie.split(';');
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index].trimLeft();
      final entry = Strings.splitFirst(segment, '=');
      if (entry != null) {
        yield MapEntry(entry.key.trimRight(), entry.value);
      } else if (includeFlags && index > 0 && segment.isNotEmpty && !segment.startsWith('=')) {
        yield MapEntry(segment.trimRight(), '');
      }
    }
  }
}
