/*
 * Copyright 2023 Hongen Wang
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

import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/network/components/manager/request_crypto_manager.dart';
import 'package:proxypin/network/components/manager/request_breakpoint_manager.dart';
import 'package:proxypin/network/components/manager/request_map_manager.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/components/request_breakpoint.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/content/body.dart';
import 'package:proxypin/ui/content/panel.dart';
import 'package:proxypin/ui/desktop/debug/breakpoint_executor.dart';
import 'package:proxypin/ui/desktop/request/request_editor.dart';
import 'package:proxypin/ui/desktop/setting/request_rewrite.dart';
import 'package:proxypin/ui/desktop/setting/script.dart';
import 'package:proxypin/ui/toolbox/aes_page.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:proxypin/utils/replay_task.dart';

import '../desktop/left_menus/replay_tasks.dart';
import '../desktop/setting/request_breakpoint.dart';
import '../desktop/setting/request_block.dart';
import '../desktop/setting/request_crypto.dart';
import '../desktop/setting/request_map.dart';
import '../toolbox/cert_hash.dart';
import '../toolbox/encoder.dart';
import '../toolbox/js_run.dart';
import '../toolbox/json_viewer.dart';
import '../toolbox/qr_code_page.dart';
import '../toolbox/text_diff.dart';
import '../toolbox/text_editor.dart';
import '../toolbox/xml_viewer.dart';
import '../toolbox/regexp.dart';
import '../toolbox/timestamp.dart';
import '../toolbox/websocket_request.dart';

bool isMultiWindow = false;

///多窗口
Widget multiWindow(String windowId, Map<dynamic, dynamic> argument) {
  isMultiWindow = true;
  //请求编辑器
  if (argument['name'] == 'RequestEditor') {
    return RequestEditor(
        windowController: WindowController.fromWindowId(windowId),
        request: argument['request'] == null ? null : HttpRequest.fromJson(argument['request']));
  }

  //请求详情
  if (argument['name'] == 'RequestDetailPage') {
    return NetworkTabController(
      windowId: windowId,
      httpRequest: argument['request'] == null ? null : HttpRequest.fromJson(argument['request']),
      httpResponse: argument['response'] == null ? null : HttpResponse.fromJson(argument['response']),
    );
  }

  //请求体
  if (argument['name'] == 'HttpBodyWidget') {
    return HttpBodyWidget(
        windowController: WindowController.fromWindowId(windowId),
        httpMessage: HttpMessage.fromJson(argument['httpMessage']),
        inNewWindow: true,
        hideRequestRewrite: true);
  }
  //编码
  if (argument['name'] == 'EncoderWidget') {
    return EncoderWidget(
        type: EncoderType.nameOf(argument['type']),
        text: argument['text'],
        windowController: WindowController.fromWindowId(windowId));
  }
  //脚本
  if (argument['name'] == 'ScriptWidget') {
    return ScriptWidget(windowId: windowId);
  }
  //请求重写
  if (argument['name'] == 'RequestRewriteWidget') {
    return futureWidget(
        RequestRewriteManager.instance, (data) => RequestRewriteWidget(windowId: windowId, requestRewrites: data));
  }

  if (argument['name'] == 'RequestBlock') {
    return futureWidget(RequestBlockManager.instance, (manager) => RequestBlock(requestBlockManager: manager));
  }

  // 请求加密
  if (argument['name'] == 'RequestCryptoPage') {
    return futureWidget(RequestCryptoManager.instance, (data) => RequestCryptoPage(windowId: windowId, manager: data));
  }
  // 请求映射
  if (argument['name'] == 'RequestMapPage') {
    return RequestMapPage(windowId: windowId);
  }

  // 请求拦截
  if (argument['name'] == 'RequestBreakpointPage') {
    return futureWidget(
        RequestBreakpointManager.instance, (manager) => RequestBreakpointPage(windowId: windowId, manager: manager));
  }

  if (argument['name'] == 'QrCodePage') {
    return QrCodePage(windowId: windowId);
  }

  if (argument['name'] == 'JsonViewerPage') {
    return JsonViewerPage(windowId: windowId);
  }

  if (argument['name'] == 'XmlViewerPage') {
    return XmlViewerPage(windowId: windowId);
  }

  if (argument['name'] == 'TextDiffPage') {
    return TextDiffPage(windowId: windowId);
  }

  if (argument['name'] == 'TextEditorPage') {
    return TextEditorPage(windowId: windowId);
  }

  if (argument['name'] == 'CertHashPage') {
    return CertHashPage(windowId: windowId);
  }

  if (argument['name'] == 'JavaScript') {
    return JavaScript(windowId: windowId);
  }

  if (argument['name'] == 'RegExpPage') {
    return RegExpPage(windowId: windowId);
  }
  if (argument['name'] == 'TimestampPage') {
    return TimestampPage(windowId: windowId);
  }

  if (argument['name'] == 'AesPage') {
    return AesPage(text: argument['text'], windowId: windowId);
  }

  //脚本日志
  if (argument['name'] == 'ScriptConsoleWidget') {
    return ScriptConsoleWidget(windowId: windowId);
  }

  if (argument['name'] == 'WebSocketRequestPage') {
    return WebSocketRequestPage(windowId: windowId);
  }

  if (argument['name'] == 'ReplayTasksPage') {
    return ReplayTasksPage(windowId: windowId);
  }

  if (argument['name'] == 'BreakpointExecutor') {
    return BreakpointExecutor(
      windowId: windowId,
      request: HttpRequest.fromJson(argument['request']),
      response: argument['response'] == null ? null : HttpResponse.fromJson(argument['response']),
      isResponse: argument['type'] == 'response',
      requestId: argument['requestId'],
    );
  }

  return const SizedBox();
}

enum Operation {
  add,
  update,
  delete,
  enabled,
  refresh,
  reorder;

  static Operation of(String name) {
    return values.firstWhere((element) => element.name == name);
  }
}

class MultiWindow {
  static Function(String widgetName, Map<String, dynamic>? args)? onOpenWindow;

  /// 单例型子窗口（编辑共享配置的管理器页）：重复打开时前置已有窗口而不是再开一个，
  /// 避免多个窗口各自加载/保存同一配置互相覆盖，导致编辑静默丢失
  static const Set<String> _singletonWidgets = {
    'RequestBlock',
    'RequestRewriteWidget',
    'RequestMapPage',
    'RequestCryptoPage',
    'ScriptWidget',
    'RequestBreakpointPage',
    'ScriptConsoleWidget',
  };

  /// 正在创建中的单例窗口：createWindow 需启动新 engine 耗时数百毫秒，
  /// 期间连点在原生窗口注册表里还查不到，会重复开
  static final Set<String> _openingWidgets = {};

  /// 刷新请求重写
  static Future<void> invokeRefreshRewrite(Operation operation,
      {int? index, RequestRewriteRule? rule, List<RewriteItem>? items, bool? enabled, List<int>? order}) async {
    final arguments = {
      "enabled": enabled,
      "operation": operation.name,
      'index': index,
      'rule': rule?.toJson(),
      'items': items?.map((e) => e.toJson()).toList(),
      'order': order
    };
    Future<void> refresh() async {
      final path = await DesktopMultiWindow.invokeMainWindowMethod<String>("refreshRequestRewrite", arguments);
      if (DesktopMultiWindow.isStandalone && rule != null && path != null) rule.rewritePath = path;
    }

    await DesktopMultiWindow.saveStandaloneChanges(refresh);
  }

  static Future<WindowController> openWindow(String title, String widgetName,
      {Size size = const Size(800, 680), Map<String, dynamic>? args}) async {
    if (Platform.isAndroid || Platform.isIOS) {
      onOpenWindow?.call(widgetName, args);
      return WindowController.fromWindowId('0'); // Dummy controller
    }

    if (_singletonWidgets.contains(widgetName)) {
      var existing = await _focusSingletonWindow(widgetName);
      if (existing != null) return existing;
      if (!_openingWidgets.add(widgetName)) {
        return WindowController.fromWindowId('0'); // 正在创建中（连点），忽略本次点击
      }
    }

    try {
      registerMethodHandler();
      return DesktopMultiWindow.createWindow(
        jsonEncode({'name': widgetName, ...?args}),
        title: Platform.isMacOS ? null : title,
        size: size,
      );
    } finally {
      _openingWidgets.remove(widgetName);
    }
  }

  static Future<void> openToolWindow(String title, String widgetName,
      {Size size = const Size(800, 680), Map<String, dynamic>? args}) async {
    final standalone = Platform.isLinux;
    final singleton = _singletonWidgets.contains(widgetName);
    if (standalone && singleton && !_openingWidgets.add(widgetName)) return;
    try {
      if (standalone) {
        registerMethodHandler();
        await DesktopMultiWindow.launchStandaloneWindow(title, size, {'name': widgetName, ...?args},
            singleton: singleton);
      } else {
        await openWindow(title, widgetName, size: size, args: args);
      }
    } catch (error, stackTrace) {
      logger.e('Failed to open $widgetName', error: error, stackTrace: stackTrace);
    } finally {
      if (standalone && singleton) _openingWidgets.remove(widgetName);
    }
  }

  /// 查找已存在的单例子窗口并前置。窗口销毁后原生注册表可能短暂残留已注销 channel 的条目，
  /// 残留条目 focus 失败时跳过继续扫描；整体查询异常返回 null，调用方回落到新建窗口
  static Future<WindowController?> _focusSingletonWindow(String widgetName) async {
    try {
      for (var window in await WindowController.getAll()) {
        String? name;
        try {
          var decoded = jsonDecode(window.arguments);
          if (decoded is Map<String, dynamic>) {
            name = decoded['name'] as String?;
          }
        } catch (_) {
          continue; // 主窗口等无 JSON 参数的窗口
        }
        if (name != widgetName) continue;
        try {
          await window.focus();
          return window;
        } catch (e) {
          // focus 已等待启动中的 channel 就绪；仍失败说明窗口已关闭或启动失败，跳过继续扫描。
          logger.d('skip focusing unavailable window ${window.windowId}: $e');
          continue;
        }
      }
    } catch (e) {
      logger.w('focus singleton window $widgetName failed, fallback to create new: $e');
    }
    return null;
  }

  static bool _refreshRewrite = false;

  static Future<String?> _handleRefreshRewrite(Operation operation, Map<dynamic, dynamic> arguments,
      {required bool persist}) async {
    RequestRewriteManager requestRewrites = await RequestRewriteManager.instance;
    String? path;

    switch (operation) {
      case Operation.add:
      case Operation.update:
        var rule = RequestRewriteRule.formJson(arguments['rule']);
        List<dynamic>? list = arguments['items'] as List<dynamic>?;
        List<RewriteItem>? items = list?.map((e) => RewriteItem.fromJson(e)).toList();

        if (operation == Operation.add) {
          await requestRewrites.addRule(rule, items!);
        } else {
          await requestRewrites.updateRule(arguments['index'], rule, items);
        }
        path = rule.rewritePath;
        break;
      case Operation.delete:
        var rule = requestRewrites.rules.removeAt(arguments['index']);
        requestRewrites.rewriteItemsCache.remove(rule); //删除缓存
        break;
      case Operation.enabled:
        requestRewrites.enabled = arguments['enabled'];
        break;
      case Operation.reorder:
        //order 为新的顺序：每个元素是规则在原列表中的下标
        var newOrder = (arguments['order'] as List<dynamic>).map((e) => e as int).toList();
        var oldRules = requestRewrites.rules;
        var reordered = newOrder.map((i) => oldRules[i]).toList();
        requestRewrites.rules
          ..clear()
          ..addAll(reordered);
        break;
      default:
        break;
    }

    if (persist) {
      await requestRewrites.flushRequestRewriteConfig();
      return path;
    }
    if (_refreshRewrite) return path;
    _refreshRewrite = true;
    Future.delayed(const Duration(milliseconds: 1000), () async {
      _refreshRewrite = false;
      requestRewrites.flushRequestRewriteConfig();
    });
    return path;
  }
}

bool _registerHandler = false;

/// 主窗口管理器状态版本号：子窗口经 invokeMainWindowMethod 触发主窗口 reload 后递增，
/// 观察者（如工具栏快捷图标启用态高亮）据此刷新
final ValueNotifier<int> managerStateVersion = ValueNotifier<int>(0);

Map<String, dynamic>? _currentProxyInfo() {
  final server = ProxyServer.current;
  if (server == null || !server.isRunning) return null;
  return {'host': '127.0.0.1', 'port': server.port};
}

/// 桌面端多窗口 注册方法处理器
void registerMethodHandler() {
  if (_registerHandler) {
    return;
  }
  _registerHandler = true;
  DesktopMultiWindow.onStandaloneClosed = ScriptManager.removeLogHandler;
  DesktopMultiWindow.setMethodHandler((call, fromWindowId) async {
    if (call.method == 'getProxyInfo') {
      return _currentProxyInfo();
    }
    if (call.method == 'getReplayTasks' || call.method == 'updateReplayTask') {
      final manager = ReplayTaskManager.instance;
      if (call.method == 'updateReplayTask') {
        final action = call.arguments['action'];
        if (action == 'clearFinished') {
          manager.clearFinished();
        } else {
          final task = manager.tasks.where((task) => task.id == call.arguments['id']).firstOrNull;
          if (task != null) {
            switch (action) {
              case 'pause':
                manager.pause(task);
              case 'resume':
                manager.resume(task);
              case 'cancel':
                manager.cancel(task);
              case 'delete':
                if (!task.isActive) manager.remove(task);
            }
          }
        }
      }
      return manager.tasks
          .map((task) => {
                'id': task.id,
                'method': task.request.method.name,
                'url': task.request.requestUrl,
                'status': task.status.name,
                'executedCount': task.executedCount,
                'totalCount': task.totalCount,
                'nextRunAt': task.nextRunAt?.millisecondsSinceEpoch,
              })
          .toList(growable: false);
    }
    logger.d('${call.method} $fromWindowId');
    if (call.method == 'refreshRequestRewrite') {
      final path = await MultiWindow._handleRefreshRewrite(Operation.of(call.arguments['operation']), call.arguments,
          persist: fromWindowId.startsWith('tool:'));
      managerStateVersion.value++;
      return path;
    }

    if (call.method == 'refreshRequestBlock') {
      await (await RequestBlockManager.instance).reloadConfig();
      managerStateVersion.value++;
      return 'done';
    }

    if (call.method == 'refreshScript') {
      await ScriptManager.instance.then((value) {
        return value.reloadScript();
      });
      managerStateVersion.value++;
      return 'done';
    }

    if (call.method == 'refreshRequestMap') {
      await RequestMapManager.instance.then((value) {
        return value.reloadConfig();
      });
      managerStateVersion.value++;
      return 'done';
    }

    if (call.method == 'refreshRequestCrypto') {
      await RequestCryptoManager.instance.then((value) {
        return value.reloadConfig();
      });
      managerStateVersion.value++;
      return 'done';
    }

    if (call.method == 'refreshRequestBreakpoint') {
      await RequestBreakpointManager.instance.then((value) {
        return value.load();
      });
      managerStateVersion.value++;
      return 'done';
    }

    if (call.method == 'registerConsoleLog') {
      ScriptManager.registerConsoleLog(fromWindowId);
      return "done";
    }

    if (call.method == 'openScriptConsole') {
      await openScriptConsoleWindow(call.arguments as String);
      return 'done';
    }

    if (call.method == 'resumeRequest') {
      var request = call.arguments['request'] == null
          ? null
          : HttpRequest.fromJson(jsonDecode(jsonEncode(call.arguments['request'])));
      RequestBreakpointInterceptor.instance.resumeRequest(call.arguments['requestId'], request);
      return 'done';
    }

    if (call.method == 'resumeResponse') {
      var response = call.arguments['response'] == null
          ? null
          : HttpResponse.fromJson(jsonDecode(jsonEncode(call.arguments['response'])));
      if (response != null) {
        response.requestId = call.arguments['requestId'];
      }
      RequestBreakpointInterceptor.instance.resumeResponse(call.arguments['requestId'], response);
      return 'done';
    }

    return 'done';
  });
}

///打开编码窗口
Future<void> encodeWindow(EncoderType type, BuildContext context, [String? text]) async {
  if (Platforms.isMobile()) {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => EncoderWidget(type: type, text: text)));
    return;
  }

  if (!context.mounted) return;
  final title = AppLocalizations.of(context)!.encode;
  await MultiWindow.openToolWindow(
    title,
    'EncoderWidget',
    args: {'type': type.name, 'text': text},
    size: const Size(900, 600),
  );
}

///打开 AES 窗口
Future<void> openAesWindow(BuildContext context, String text) async {
  if (Platforms.isMobile()) {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => AesPage(text: text)));
    return;
  }

  await MultiWindow.openToolWindow(
    'AES',
    'AesPage',
    args: {'text': text},
    size: const Size(700, 672),
  );
}

Future<void> openScriptConsoleWindow(String title) async {
  if (DesktopMultiWindow.isStandalone) {
    await DesktopMultiWindow.invokeMainWindowMethod('openScriptConsole', title);
    return;
  }
  await MultiWindow.openToolWindow(title, 'ScriptConsoleWidget', size: const Size(900, 650));
}
