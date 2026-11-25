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
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:get/get.dart';
import 'package:image_pickers/image_pickers.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/http/content_type.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/code_style.dart';
import 'package:proxypin/ui/component/json/json_viewer.dart';
import 'package:proxypin/ui/component/json/theme.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/component/svg_icon.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/desktop/common.dart';
import 'package:proxypin/ui/mobile/setting/request_rewrite.dart';
import 'package:proxypin/utils/crypto_body_decoder.dart';
import 'package:proxypin/utils/css_formatter.dart';
import 'package:proxypin/utils/html_formatter.dart';
import 'package:proxypin/utils/js_formatter.dart';
import 'package:proxypin/utils/num.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:proxypin/utils/xml_formatter.dart';

import '../component/search/highlight_text.dart';
import '../component/search/preview_task.dart';
import '../component/search/search_controller.dart';
import '../toolbox/encoder.dart';
import 'detail_fields.dart';
import 'read_only_body.dart';
import 'stream_body.dart';
import 'video_preview.dart';

/// body 选区菜单：整个文本即全部内容，复制全部用“全选”即可，故不提供“复制值”
Widget bodyContextMenu(BuildContext context, EditableTextState editableTextState) =>
    contextMenu(context, editableTextState, copyValue: false);

bool _showsStream(HttpMessage? message, CryptoDecodedResult? decoded) =>
    decoded == null &&
    (message?.isWebSocket == true || (message?.contentType == ContentType.sse && message?.messages.isNotEmpty == true));

bool _hasManyLines(String text) {
  var offset = -1;
  for (var line = 0; line < 80; line++) {
    offset = text.indexOf('\n', offset + 1);
    if (offset == -1) return false;
  }
  return true;
}

bool _usesVirtualText(String text) => text.length >= 2048 || _hasManyLines(text);

ContentType _previewContentType(HttpMessage message) {
  final type = message.contentType;
  if (type != ContentType.text && type != ContentType.http) return type;
  final path = Uri.tryParse(message.requestUrl ?? '')?.path.toLowerCase() ?? '';
  final name = path.split('/').last;
  final extension = name.lastIndexOf('.');
  if (extension == -1) return type;
  return switch (name.substring(extension)) {
    '.html' || '.htm' || '.xhtml' => ContentType.html,
    '.yaml' || '.yml' => ContentType.yaml,
    '.json' => ContentType.json,
    '.xml' => ContentType.xml,
    '.css' => ContentType.css,
    '.js' || '.mjs' => ContentType.js,
    _ => type,
  };
}

///请求响应的body部分
///@Author wanghongen
class HttpBodyWidget extends StatefulWidget {
  final HttpMessage? httpMessage;
  final bool inNewWindow; //是否在新窗口打开
  final WindowController? windowController;
  final ScrollController? scrollController;
  final bool hideRequestRewrite; //是否隐藏请求重写
  final bool active;
  final double? previewHeight;

  const HttpBodyWidget(
      {super.key,
      required this.httpMessage,
      this.inNewWindow = false,
      this.windowController,
      this.scrollController,
      this.hideRequestRewrite = false,
      this.active = true,
      this.previewHeight});

  @override
  State<StatefulWidget> createState() {
    return HttpBodyState();
  }
}

class HttpBodyState extends State<HttpBodyWidget> {
  var bodyKey = GlobalKey<_BodyState>();
  ViewType? _selectedView;
  (HttpMessage?, List<int>?, String?, String?)? _textInput;
  Future<String>? _bodyText;
  bool _looksLikeJson = false;
  final searchIconKey = GlobalKey();
  final SearchTextController searchController = SearchTextController();

  AppLocalizations get localizations => AppLocalizations.of(context)!;
  bool showDecoded = false;
  CryptoDecodedResult? decoded;

  //当前请求是否命中已启用的重写规则
  final RxBool rewriteEnabled = false.obs;

  @override
  void initState() {
    super.initState();
    if (widget.windowController != null) {
      HardwareKeyboard.instance.addHandler(onKeyEvent);
    }

    _loadBodyText();
    _loadDecoded();
    managerStateVersion.addListener(_loadRewriteEnabled);
    _loadRewriteEnabled();
  }

  @override
  void didUpdateWidget(covariant HttpBodyWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_loadBodyText()) {
      _selectedView = null;
      hideSearchOverlay();
      showDecoded = false;
      decoded = null;
      rewriteEnabled.value = false;
      _loadDecoded();
      _loadRewriteEnabled();
    }
  }

  bool _loadBodyText() {
    final message = widget.httpMessage;
    final bytes = message?.body;
    final encoding = message?.headers.contentEncoding;
    final input = (message, bytes, message?.headers.contentType, encoding);
    if (input == _textInput) return false;
    _textInput = input;
    _bodyText = null;
    _looksLikeJson = false;
    if (message == null || bytes == null || bytes.isEmpty || message.isWebSocket) return true;
    final contentType = _previewContentType(message);
    if (contentType == ContentType.image || contentType == ContentType.video) return true;

    final bodyText = message.decodeBodyString(offload: bytes.length >= 16384 || (encoding?.isNotEmpty ?? false));
    _bodyText = bodyText;
    if (contentType == ContentType.text || contentType == ContentType.http) {
      bodyText.then((text) {
        if (!mounted || _bodyText != bodyText || text.length < 2) return;
        final last = text.length - 1;
        if ((text[0] == '{' && text[last] == '}') || (text[0] == '[' && text[last] == ']')) {
          setState(() => _looksLikeJson = true);
        }
      }, onError: (Object _) {});
    }
    return true;
  }

  ///计算当前请求是否命中已启用的重写规则
  Future<void> _loadRewriteEnabled() async {
    final message = widget.httpMessage;
    if (message == null || widget.hideRequestRewrite) return;

    HttpRequest? request = message is HttpRequest ? message : (message as HttpResponse).request;
    if (request == null) return;

    var types = message is HttpRequest
        ? [RuleType.requestReplace, RuleType.requestUpdate, RuleType.redirect]
        : [RuleType.responseReplace, RuleType.responseUpdate];

    var requestRewrites = await RequestRewriteManager.instance;
    if (!mounted || widget.httpMessage != message) return;
    rewriteEnabled.value = requestRewrites.getRewriteRule(request.domainPath, types) != null;
  }

  /// 按键事件
  bool onKeyEvent(KeyEvent event) {
    if ((HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed) &&
        event.logicalKey == LogicalKeyboardKey.keyW) {
      HardwareKeyboard.instance.removeHandler(onKeyEvent);
      widget.windowController?.close();
      return true;
    }

    return false;
  }

  Future<void> _loadDecoded() async {
    final message = widget.httpMessage;
    if (message == null) return;
    final input = _textInput;
    final result = await CryptoBodyDecoder.maybeDecode(message);
    if (mounted && _textInput == input && result != null && result.hasText) {
      setState(() => decoded = result);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(onKeyEvent);
    managerStateVersion.removeListener(_loadRewriteEnabled);
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.httpMessage == null) {
      return const SizedBox();
    }

    if ((widget.httpMessage?.body == null || widget.httpMessage?.body?.isEmpty == true) &&
        widget.httpMessage?.messages.isNotEmpty == false) {
      return const SizedBox();
    }

    final contentType = _previewContentType(widget.httpMessage!);
    final tabs = Tabs.of(contentType, _looksLikeJson, isSvg: widget.httpMessage!.isSvg);

    List<Widget> bodyContent(double? previewHeight) => [
          widget.inNewWindow ? const SizedBox() : titleWidget(tabs: tabs),
          const SizedBox(height: 3),
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _Body(
                  key: bodyKey,
                  message: widget.httpMessage,
                  bodyText: _bodyText,
                  decoded: showDecoded ? decoded : null,
                  viewType: _viewFor(tabs),
                  active: widget.active,
                  previewHeight: previewHeight,
                  scrollController: widget.scrollController,
                  searchController: searchController)) //body
        ];

    var tabController = FocusableActionDetector(
        shortcuts: {
          LogicalKeySet(
                  Platform.isMacOS ? LogicalKeyboardKey.meta : LogicalKeyboardKey.control, LogicalKeyboardKey.keyF):
              ActivateIntent(),
          LogicalKeySet(LogicalKeyboardKey.escape): DismissIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (intent) {
              _toggleSearch();
              return null;
            },
          ),
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (intent) {
              hideSearchOverlay();
              return null;
            },
          ),
        },
        child: widget.inNewWindow
            ? LayoutBuilder(
                builder: (context, constraints) => ListView(children: bodyContent(constraints.maxHeight - 11)),
              )
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: bodyContent(widget.previewHeight)));

    //在新窗口打开
    if (widget.inNewWindow) {
      return Scaffold(
          appBar:
              AppBar(title: titleWidget(inNewWindow: true, tabs: tabs), toolbarHeight: Platform.isWindows ? 36 : null),
          // 与详情面板一致的 14px 水平内边距（panel.dart message() 内嵌时由外层给）
          body: Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: tabController));
    }
    return tabController;
  }

  void hideSearchOverlay() {
    searchController.removeSearchOverlay();
    bodyKey.currentState?.closeTextSearch();
  }

  void _toggleSearch() {
    final view = bodyKey.currentState?.viewType;
    if (view == ViewType.image || view == ViewType.video) return;
    if (searchController.isSearchOverlayVisible) {
      hideSearchOverlay();
      return;
    }
    if (bodyKey.currentState?.toggleTextSearch() == true) return;
    final box = searchIconKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final position = box.localToGlobal(Offset.zero);
    searchController.showSearchOverlay(context, top: max(position.dy + box.size.height + 50, 100), right: 10);
  }

  ViewType _viewFor(Tabs tabs) => tabs.list.contains(_selectedView) ? _selectedView! : tabs.list.first;

  /// 设计稿 .fmt 分段小胶囊：选中 primary-soft 底 + primary 字，未选中灰色
  List<Widget> _fmtChips(BuildContext context, Tabs? tabs) {
    if (tabs == null || tabs.list.length <= 1) {
      return [const SizedBox()];
    }
    var theme = Theme.of(context);
    var inactiveColor = theme.colorScheme.onSurfaceVariant;
    final currentView = _viewFor(tabs);
    return [
      for (final view in tabs.list)
        Padding(
            padding: const EdgeInsets.only(right: 4),
            // 选中底色由 Material 绘制，InkWell 的 hover/水波纹才能显示在底色之上
            child: Material(
                color: view == currentView ? primarySoftBg(theme, lightAlpha: 0.12) : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
                child: InkWell(
                    borderRadius: BorderRadius.circular(5),
                    hoverColor: theme.colorScheme.surfaceContainerHigh,
                    onTap: () {
                      hideSearchOverlay();
                      setState(() => _selectedView = view);
                    },
                    child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        child: Text(view.title,
                            style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: view == currentView ? FontWeight.w500 : FontWeight.w400,
                                color: view == currentView ? theme.colorScheme.primary : inactiveColor)))))),
    ];
  }

  /// 标题
  Widget titleWidget({bool inNewWindow = false, Tabs? tabs}) {
    final currentView = tabs == null ? null : _viewFor(tabs);
    final isImage = currentView == ViewType.image;
    final isVideo = currentView == ViewType.video;

    final isMobile = Platforms.isMobile();

    // 操作图标与工具栏同色：onSurfaceVariant 淡灰（设计稿 .mini text-3）
    final iconColor = Theme.of(context).colorScheme.onSurfaceVariant;

    final searchBtn = _toolbarAction(
      key: searchIconKey,
      icon: SvgIcon('search', size: 15, color: iconColor),
      tooltip: localizations.search,
      onPressed: isImage || isVideo ? null : _toggleSearch,
    );

    final copyBtn = isImage
        ? downloadImageButton()
        : _toolbarAction(
            icon: SvgIcon('copy', size: 15, color: iconColor),
            tooltip: localizations.copy,
            onPressed: isVideo
                ? null
                : () async {
                    var body = await bodyKey.currentState?.getBody();
                    if (body == null) return;
                    Clipboard.setData(ClipboardData(text: body)).then((_) {
                      if (mounted) FlutterToastr.show(localizations.copied, context);
                    });
                  },
          );

    final rewriteBtn = _toolbarAction(
      icon: Obx(() => SvgIcon('pencil', size: 15, color: rewriteEnabled.value ? Colors.deepOrangeAccent : iconColor)),
      tooltip: localizations.requestRewrite,
      onPressed: showRequestRewrite,
    );

    final encodeBtn = _toolbarAction(
        icon: SvgIcon('encode', size: 15, color: iconColor),
        tooltip: localizations.encode,
        onPressed: isImage || isVideo
            ? null
            : () async {
                var body = await bodyKey.currentState?.getBody();
                if (mounted) {
                  encodeWindow(EncoderType.base64, context, body);
                }
              });

    final openNewBtn = _toolbarAction(
        icon: SvgIcon('arrow_out', size: 15, color: iconColor),
        tooltip: localizations.newWindow,
        onPressed: () => openNew());

    Widget? cryptoToggle;
    if (decoded != null) {
      cryptoToggle = TextButton.icon(
        onPressed: () {
          setState(() {
            showDecoded = !showDecoded;
          });
        },
        icon: Icon(showDecoded ? Icons.lock_open : Icons.lock, size: 18),
        label: Text(showDecoded ? localizations.cryptoDecoded : localizations.cryptoDecodeToggle),
      );
    }

    // Mobile UX:
    // - If there is NO crypto result, keep the original (previous) horizontal-scroll title bar.
    // - Only when crypto is available, switch to the compact overflow-menu layout to keep
    //   the crypto toggle visible.
    if (isMobile && cryptoToggle != null) {
      final overflowItems = <PopupMenuEntry<String>>[];
      if (!widget.hideRequestRewrite) {
        overflowItems.add(PopupMenuItem(
            value: 'rewrite',
            child: Obx(() => Text(localizations.requestRewrite,
                style: rewriteEnabled.value ? TextStyle(color: Theme.of(context).colorScheme.primary) : null))));
      }
      overflowItems.add(PopupMenuItem(value: 'encode', child: Text(localizations.encode)));
      if (!inNewWindow) {
        overflowItems.add(PopupMenuItem(value: 'new_window', child: Text(localizations.newWindow)));
      }

      final row = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.httpMessage is HttpRequest ? localizations.requestBody : localizations.responseBody,
              style: detailSectionStyle(context)),
          const SizedBox(width: 8),
          searchBtn,
          const SizedBox(width: 4),
          copyBtn,
          const SizedBox(width: 4),
          Flexible(child: cryptoToggle),
          if (overflowItems.isNotEmpty)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) {
                if (v == 'rewrite') showRequestRewrite();
                if (v == 'encode') {
                  bodyKey.currentState?.getBody().then((body) {
                    if (mounted) encodeWindow(EncoderType.base64, context, body);
                  });
                }
                if (v == 'new_window') openNew();
              },
              itemBuilder: (_) => overflowItems,
            ),
        ],
      );
      // 格式分段第二行（改版把分段并入标题行后加密分支丢了切换入口，且一行放不下）
      if (tabs != null && tabs.list.length > 1) {
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          row,
          Row(children: _fmtChips(context, tabs)),
        ]);
      }
      return row;
    }

    // 设计稿 .d-sec + .fmt：11px 灰色分区标签（请求体/响应体）+ 格式分段胶囊 + 紧凑操作图标
    // 标签不再带「· JSON」类型后缀：格式分段已按类型默认选中
    var label = widget.httpMessage is HttpRequest ? localizations.requestBody : localizations.responseBody;

    final labelWidget = Text(label, style: detailSectionStyle(context));

    final actions = <Widget>[
      searchBtn,
      const SizedBox(width: 2),
      copyBtn,
    ];
    if (!widget.hideRequestRewrite) {
      actions.add(rewriteBtn);
    }
    actions.add(encodeBtn);
    if (!inNewWindow) {
      actions.add(openNewBtn);
    }
    if (cryptoToggle != null) {
      actions.add(cryptoToggle);
    }

    // 手机端两行布局（旧版行为）：第一行 标签+操作图标，第二行 格式分段——合并一行手机上放不下
    if (isMobile) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [labelWidget, const SizedBox(width: 8), ...actions]),
        if (tabs != null && tabs.list.length > 1) Row(children: _fmtChips(context, tabs)),
      ]);
    }

    final list = <Widget>[
      labelWidget,
      const SizedBox(width: 12),
      ..._fmtChips(context, tabs),
      const SizedBox(width: 8),
      ...actions,
    ];

    return SingleChildScrollView(
        scrollDirection: Axis.horizontal, child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: list));
  }

  Widget _toolbarAction({Key? key, required Widget icon, required String tooltip, required VoidCallback? onPressed}) {
    final size = Platforms.isDesktop() ? 28.0 : 36.0;
    return SizedBox.square(
      key: key,
      dimension: size,
      child: IconButton(
        tooltip: tooltip,
        icon: icon,
        style: IconButton.styleFrom(
          minimumSize: Size.zero,
          fixedSize: Size.square(size),
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
        padding: EdgeInsets.zero,
        splashRadius: size / 2,
        onPressed: onPressed,
      ),
    );
  }

  ///下载图片
  Widget downloadImageButton() {
    return _toolbarAction(
        icon: SvgIcon('download', size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
        tooltip: localizations.saveImage,
        onPressed: () async {
          final message = widget.httpMessage;
          if (message == null) return;
          final input = _textInput;
          final isSvg = message.isSvg;
          final body = isSvg ? await message.decodeBodyBytes() : message.body;
          if (!mounted || _textInput != input || body == null || body.isEmpty) return;
          final bytes = body is Uint8List ? body : Uint8List.fromList(body);
          final extension = isSvg ? 'svg' : _imageExtension(bytes, message.headers.contentType);
          final fileName = "image_${DateTime.now().millisecondsSinceEpoch}.$extension";
          if (Platform.isIOS && !isSvg) {
            String? path = await ImagePickers.saveByteDataImageToGallery(bytes);
            if (path != null && mounted) {
              FlutterToastr.show(localizations.saveSuccess, context, duration: 2, rootNavigator: true);
            }
            return;
          }

          final saved = await FilePicker.saveFile(
            fileName: fileName,
            bytes: bytes,
            mimeType: isSvg ? 'image/svg+xml' : 'application/octet-stream',
            type: FileType.image,
          );
          if (saved != null && mounted) {
            FlutterToastr.show(localizations.saveSuccess, context, duration: 2, rootNavigator: true);
          }
        });
  }

  String _imageExtension(Uint8List bytes, String? contentType) {
    var type = contentType?.toLowerCase() ?? '';
    if (type.contains('jpeg') || type.contains('jpg')) return 'jpg';
    if (type.contains('png')) return 'png';
    if (type.contains('webp')) return 'webp';
    if (type.contains('gif')) return 'gif';
    if (type.contains('bmp')) return 'bmp';
    if (type.contains('svg')) return 'svg';

    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'png';
    }
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return 'jpg';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      return 'gif';
    }
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return 'bmp';
    }

    return 'png';
  }

  ///展示请求重写
  Future<void> showRequestRewrite() async {
    final message = widget.httpMessage;
    final request = message is HttpRequest ? message : (message as HttpResponse?)?.request;
    if (request == null) return;
    final type = message is HttpRequest ? RuleType.requestReplace : RuleType.responseReplace;
    if (Platforms.isDesktop()) {
      await openCapturedRewrite(context, request, ruleType: type, response: message is HttpResponse ? message : null);
      return;
    }

    final manager = await RequestRewriteManager.instance;
    final rule = manager.getRequestRewriteRule(request, type);
    final items = await manager.getRewriteItems(rule);
    if (!mounted || widget.httpMessage != message) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => RewriteRule(rule: rule, items: items, request: request)));
  }

  ///打开新窗口
  void openNew() async {
    if (Platforms.isDesktop()) {
      var size = MediaQuery.of(context).size;
      await MultiWindow.openToolWindow(
        widget.httpMessage is HttpRequest ? localizations.requestBody : localizations.responseBody,
        'HttpBodyWidget',
        args: {'httpMessage': widget.httpMessage?.toJson(), 'inNewWindow': true},
        size: Size(800, size.height),
      );
      return;
    }

    Navigator.push(
        context, MaterialPageRoute(builder: (_) => HttpBodyWidget(httpMessage: widget.httpMessage, inNewWindow: true)));
  }
}

class _Body extends StatefulWidget {
  final HttpMessage? message;
  final Future<String>? bodyText;
  final CryptoDecodedResult? decoded;
  final ViewType viewType;
  final bool active;
  final double? previewHeight;
  final ScrollController? scrollController;
  final SearchTextController searchController; // 添加搜索设置控制器

  const _Body({
    super.key,
    this.message,
    this.bodyText,
    this.decoded,
    required this.viewType,
    required this.active,
    this.previewHeight,
    this.scrollController,
    required this.searchController, // 添加必需参数
  });

  @override
  State<StatefulWidget> createState() {
    return _BodyState();
  }
}

// Top-level isolate function for compute()
// Accepts a Map<String, String> with keys: 'type' and 'body'.
String _formatTextBodyIsolate(Map<String, String> args) {
  final typeName = args['type'] ?? 'text';
  final body = args['body'] ?? '';
  final type = ViewType.values.firstWhere((v) => v.name == typeName, orElse: () => ViewType.text);

  try {
    if (type == ViewType.formUrl) return Uri.decodeFull(body);
    if (type == ViewType.html) return HTML.pretty(body);
    if (type == ViewType.xml) return XML.pretty(body);
    if (type == ViewType.css) return CSS.pretty(body);
    if (type == ViewType.js) return JS.pretty(body);
    if (type == ViewType.jsonText || type == ViewType.json) {
      final jsonObject = json.decode(body);
      return JsonEncoder.withIndent(args['indent'] ?? '  ').convert(jsonObject);
    }
  } catch (_) {}

  return body;
}

(bool, Object?) _parseJsonTree(String body) {
  try {
    return (true, json.decode(body));
  } on FormatException {
    return (false, null);
  }
}

class _BodyState extends State<_Body> {
  static const int _backgroundThreshold = 10000;
  final _textReaderKey = GlobalKey<ReadOnlyBodyState>();
  (ViewType, String)? _formatInput;
  Future<String>? _formattedBody;
  (ViewType, String)? _longInput;
  PreviewTask<String>? _longFormat;
  String? _longFormattedBody;
  bool _longHighlight = false;
  String? _jsonInput;
  Future<(bool, Object?)>? _jsonTree;
  double _zoom = 1;

  ViewType get viewType => widget.viewType;

  bool toggleTextSearch() => _textReaderKey.currentState?.toggleSearch() ?? false;

  void closeTextSearch() => _textReaderKey.currentState?.closeSearch();

  TextStyle get _textStyle => codeTextStyle(
        context,
        base: (Theme.of(context).textTheme.bodyMedium ?? DefaultTextStyle.of(context).style).copyWith(height: 1.4),
      );

  @override
  void didUpdateWidget(covariant _Body oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged = oldWidget.bodyText != widget.bodyText || oldWidget.decoded != widget.decoded;
    if (sourceChanged || oldWidget.viewType != widget.viewType) {
      _longFormat?.cancel();
      _longFormat = null;
    }
    if (sourceChanged) {
      _formatInput = null;
      _formattedBody = null;
      _longInput = null;
      _longFormattedBody = null;
      _longHighlight = false;
      _jsonInput = null;
      _jsonTree = null;
    }
  }

  @override
  void dispose() {
    _longFormat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = _getBody(viewType);
    if (!Platforms.isDesktop() || viewType == ViewType.image || viewType == ViewType.video) return body;

    final media = MediaQuery.of(context);
    final size = _textStyle.fontSize ?? 14;
    final scaler = _zoom == 1 ? media.textScaler : TextScaler.linear(media.textScaler.scale(size) / size * _zoom);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        MediaQuery(data: media.copyWith(textScaler: scaler), child: body),
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: _handleZoom,
          ),
        ),
      ],
    );
  }

  void _handleZoom(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || event.scrollDelta.dy == 0 || !HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final size = _textStyle.fontSize ?? 14;
      final nextSize = (size * _zoom + (event.scrollDelta.dy < 0 ? 1 : -1)).clamp(8.0, 40.0);
      final zoom = nextSize / size;
      if (zoom != _zoom) setState(() => _zoom = zoom);
    });
  }

  Future<String> _formatTextBody(ViewType type, String text) {
    if (type == ViewType.text || type == ViewType.yaml) return SynchronousFuture(text);
    final input = (type, text);
    if (_formatInput != input) {
      _formatInput = input;
      final args = {'type': type.name, 'body': text, 'indent': Platforms.isDesktop() ? '    ' : '  '};
      _formattedBody = text.length < _backgroundThreshold
          ? SynchronousFuture(_formatTextBodyIsolate(args))
          : compute(_formatTextBodyIsolate, args);
    }
    return _formattedBody!;
  }

  Future<String?> getBody() async {
    final type = viewType;
    final streamText = widget.decoded == null ? widget.message?.messagesText : null;
    if (streamText != null) return streamText;

    final bytes = widget.decoded?.bytes ?? widget.message?.body;
    if (bytes == null) return null;
    if (type == ViewType.hex) return bytes.map(intToHex).join(' ');
    final body = widget.decoded?.text ?? await widget.bodyText;
    if (body == null) return null;
    if (_formatsOnDemand(type, body)) return _longInput == (type, body) ? _longFormattedBody ?? body : body;
    return _formatTextBody(type, body);
  }

  Widget _getBody(ViewType type) {
    final message = widget.message;

    if (_showsStream(message, widget.decoded)) {
      return StreamBody(
        key: ObjectKey(message),
        message: message!,
        height: _previewHeight(context),
        virtualized: Platforms.isDesktop(),
      );
    }

    final bytes = widget.decoded?.bytes ?? message?.body;
    if (message == null || bytes == null) {
      return const SizedBox();
    }

    if (type == ViewType.image) {
      final label = AppLocalizations.of(context)!.detailMediaUnavailable;
      final placeholder = Center(child: Text(label));
      final Widget image;
      if (message.isSvg) {
        final source = widget.bodyText;
        image = source == null
            ? placeholder
            : KeyedSubtree(
                key: ObjectKey(source),
                child: futureWidget(
                  source,
                  (text) => SvgPicture.string(
                    text,
                    fit: BoxFit.scaleDown,
                    errorBuilder: (context, error, stack) => placeholder,
                  ),
                ),
              );
      } else {
        final imageBytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
        image = Image.memory(imageBytes, fit: BoxFit.scaleDown, errorBuilder: (context, error, stack) => placeholder);
      }
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: _previewHeight(context)),
        child: Center(heightFactor: 1, child: image),
      );
    }
    if (type == ViewType.video) {
      return SizedBox(
        height: _previewHeight(context),
        width: double.infinity,
        child: CapturedVideoPreview(key: ObjectKey(bytes), bytes: bytes, active: widget.active),
      );
    }
    if (type == ViewType.hex) {
      return HexViewer(
        data: bytes,
        style: _textStyle,
        height: _previewHeight(context),
        searchController: widget.searchController,
      );
    }

    final decodedText = widget.decoded?.text;
    if (decodedText != null) return _renderText(type, decodedText);
    final bodyText = widget.bodyText;
    if (bodyText == null) return const SizedBox();
    return KeyedSubtree(
      key: ObjectKey(bodyText),
      child: futureWidget(bodyText, (text) => _renderText(type, text)),
    );
  }

  Widget _renderText(ViewType type, String text) {
    if (type == ViewType.text) return _textViewer(text);
    if (_formatsOnDemand(type, text)) return _renderLongCode(type, text);
    if (type == ViewType.json) {
      if (_jsonInput != text) {
        _jsonInput = text;
        _jsonTree = text.length < _backgroundThreshold
            ? SynchronousFuture(_parseJsonTree(text))
            : compute(_parseJsonTree, text);
      }
      return KeyedSubtree(
        key: ObjectKey(_jsonTree),
        child: futureWidget(_jsonTree!, (result) {
          final (valid, value) = result;
          if (!valid) return _textViewer(text, language: 'json');
          return JsonViewer(value,
              colorTheme: ColorTheme.of(context), searchController: widget.searchController, textStyle: _textStyle);
        }),
      );
    }

    final formattedBody = _formatTextBody(type, text);
    return KeyedSubtree(
      key: ObjectKey(formattedBody),
      child: futureWidget(formattedBody, (text) => _textViewer(text, language: _languageForViewType(type))),
    );
  }

  bool _formatsOnDemand(ViewType type, String text) =>
      (type == ViewType.html || type == ViewType.xml || type == ViewType.js || type == ViewType.css) &&
      (text.length >= _backgroundThreshold || _hasManyLines(text));

  Widget _renderLongCode(ViewType type, String source) {
    final input = (type, source);
    final formatted = _longInput == input ? _longFormattedBody : null;
    final highlight = _longInput == input && _longHighlight;
    final strings = AppLocalizations.of(context)!;
    const controlsHeight = 40.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: controlsHeight,
          child: Row(
            children: [
              if (formatted == null)
                TextButton(
                  onPressed: _longFormat == null ? () => _formatLongCode(type, source) : null,
                  child: _longFormat == null
                      ? Text(strings.format)
                      : const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              FilterChip(
                label: Text(strings.highlight),
                selected: highlight,
                onSelected: (selected) => setState(() {
                  _longInput = input;
                  _longHighlight = selected;
                }),
              ),
            ],
          ),
        ),
        _textViewer(
          formatted ?? source,
          language: highlight ? _languageForViewType(type) : null,
          height: max(0, _previewHeight(context) - controlsHeight),
          forceVirtualized: true,
        ),
      ],
    );
  }

  void _formatLongCode(ViewType type, String source) {
    if (_longFormat != null) return;
    final input = (type, source);
    final task = PreviewTask.start(
      _formatTextBodyIsolate,
      {'type': type.name, 'body': source},
      timeout: const Duration(seconds: 10),
    );
    setState(() {
      _longInput = input;
      _longFormat = task;
    });
    task.result.then((formatted) {
      if (!mounted || _longFormat != task) return;
      setState(() {
        _longFormat = null;
        _longFormattedBody = formatted;
      });
    });
  }

  double _previewHeight(BuildContext context) =>
      max(0, widget.previewHeight ?? MediaQuery.sizeOf(context).height - 180);

  String? _languageForViewType(ViewType type) {
    switch (type) {
      case ViewType.html:
        return 'html';
      case ViewType.xml:
        return 'xml';
      case ViewType.css:
        return 'css';
      case ViewType.yaml:
        return 'yaml';
      case ViewType.js:
        return 'javascript';
      case ViewType.json:
      case ViewType.jsonText:
        return 'json';
      default:
        return null;
    }
  }

  Widget _textViewer(String text, {String? language, double? height, bool forceVirtualized = false}) {
    final style = _textStyle;
    return ReadOnlyBody(
      key: _textReaderKey,
      text: text,
      language: language,
      style: style,
      height: height ?? _previewHeight(context),
      virtualized: forceVirtualized || _usesVirtualText(text),
      searchController: widget.searchController,
      scrollController: widget.scrollController,
      fallback: (style) => HighlightTextWidget(
        text: text,
        language: language,
        style: style,
        searchController: widget.searchController,
        contextMenuBuilder: bodyContextMenu,
      ),
    );
  }
}

class Tabs {
  final List<ViewType> list = [];

  static Tabs of(ContentType? contentType, bool isJsonText, {bool isSvg = false}) {
    var tabs = Tabs();
    if (contentType == null) {
      return tabs;
    }

    if (contentType == ContentType.video) {
      tabs.list.add(ViewType.video);
      tabs.list.add(ViewType.hex);
      return tabs;
    }

    if (isSvg) tabs.list.add(ViewType.image);
    if (contentType == ContentType.json) {
      tabs.list.add(ViewType.jsonText);
    }

    tabs.list.add(ViewType.of(contentType) ?? ViewType.text);

    //为json时，增加json格式化
    if (isJsonText && !tabs.list.contains(ViewType.jsonText)) {
      tabs.list.add(ViewType.jsonText);
      tabs.list.add(ViewType.json);
    }

    if (contentType == ContentType.formUrl ||
        contentType == ContentType.json ||
        contentType == ContentType.html ||
        contentType == ContentType.xml ||
        contentType == ContentType.js ||
        contentType == ContentType.css ||
        contentType == ContentType.yaml) {
      tabs.list.add(ViewType.text);
    }

    tabs.list.add(ViewType.hex);
    return tabs;
  }

  List<Tab> tabList() {
    return list.map((e) => Tab(text: e.title)).toList();
  }
}

enum ViewType {
  text("Text"),
  formUrl("URL Decode"),
  json("JSON"),
  jsonText("JSON Text"),
  html("HTML"),
  xml("XML"),
  image("Image"),
  video("Video"),
  css("CSS"),
  yaml("YAML"),
  js("JavaScript"),
  hex("Hex"),
  ;

  final String title;

  const ViewType(this.title);

  static ViewType? of(ContentType contentType) {
    for (var value in values) {
      if (value.name == contentType.name) {
        return value;
      }
    }
    return null;
  }
}

class HexViewer extends StatefulWidget {
  final List<int> data;
  final int bytesPerRow;
  final TextStyle? style;
  final double? height;
  final SearchTextController searchController;

  const HexViewer(
      {super.key, required this.data, this.bytesPerRow = 16, this.style, this.height, required this.searchController});

  @override
  State<HexViewer> createState() => _HexViewerState();
}

class _HexViewerState extends State<HexViewer> {
  late String _text = _formatHex(widget.data, widget.bytesPerRow);

  @override
  void didUpdateWidget(covariant HexViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data || oldWidget.bytesPerRow != widget.bytesPerRow) {
      _text = _formatHex(widget.data, widget.bytesPerRow);
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style ?? const TextStyle(fontFamily: 'Courier', fontSize: 14);
    Widget fallback(TextStyle style) => HighlightTextWidget(
          style: style,
          text: _text,
          searchController: widget.searchController,
          contextMenuBuilder: bodyContextMenu,
        );
    if (_text.length > 100000) {
      return ReadOnlyBody(
        text: _text,
        style: style,
        height: widget.height ?? max(240, MediaQuery.sizeOf(context).height - 210),
        virtualized: true,
        searchController: widget.searchController,
        fallback: fallback,
      );
    }
    return fallback(style);
  }

  String _formatHex(List<int> data, int bytesPerRow) {
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < data.length; i += bytesPerRow) {
      // Address
      // buffer.write(i.toRadixString(16).padLeft(8, '0'));
      // buffer.write('  ');

      // Hex values
      for (int j = 0; j < bytesPerRow; j++) {
        if (i + j < data.length) {
          buffer.write(data[i + j].toRadixString(16).padLeft(2, '0'));
        } else {
          buffer.write('  ');
        }
        buffer.write(' ');
      }

      buffer.write('    ');

      // ASCII representation
      for (int j = 0; j < bytesPerRow; j++) {
        if (i + j < data.length) {
          final byte = data[i + j];
          if (byte >= 32 && byte <= 126) {
            buffer.write(String.fromCharCode(byte));
          } else {
            buffer.write('.');
          }
        }
      }

      buffer.writeln();
    }
    return buffer.toString();
  }
}
