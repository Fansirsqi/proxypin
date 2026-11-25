import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

export 'package:desktop_multi_window/desktop_multi_window.dart';

typedef DesktopMultiWindowMethodHandler = Future<dynamic> Function(MethodCall call, String fromWindowId);
typedef _CloseSaveState = ({Future<void> saves, Future<void> requests, Object? configWrites});

class DesktopMultiWindow {
  static const String _mainWindowIdKey = '__mainWindowId';
  static const String _mainWindowScreenKey = '__mainWindowScreen';
  static const String _windowTitleKey = '__windowTitle';
  static const String _windowSizeKey = '__windowSize';
  static const String _fromWindowIdKey = '__fromWindowId';
  static const String _argumentsKey = '__arguments';
  static const String _themeKey = '__theme';
  static const String _themeMethod = 'applyTheme';
  static const String _getThemeMethod = 'getThemeSettings';
  static const String _saveDetailPreferencesMethod = 'saveDetailPreferences';
  static const String _mainWindowChannelName = 'proxypin/main_window';
  static const String standaloneWindowArgument = 'standalone_window';
  static const String _standaloneRequestPrefix = 'proxypin:tool:';
  static const String _prepareClose = 'prepare_close';
  static const String _commitClose = 'commit_close';
  static const String _cancelClose = 'cancel_close';
  static const _standaloneMethods = {
    _saveDetailPreferencesMethod,
    ...desktopSettingsMethods,
    'getProxyInfo',
    'getReplayTasks',
    'updateReplayTask',
    'getCapturedRewrite',
    'refreshRequestRewrite',
    'refreshRequestMap',
    'refreshRequestBlock',
    'refreshRequestCrypto',
    'refreshRequestBreakpoint',
    'refreshScript',
    'openScriptConsole',
    'registerConsoleLog',
    'openToolWindow',
  };

  static const desktopSettingsMethods = {
    'getDesktopSettings',
    'saveDesktopSettings',
    'previewSettingsDensity',
    'resetSettingsPreview',
    'updateDesktopProxySetting',
    'openDesktopSettingTool',
    'changeDesktopCertificate',
  };

  static final WindowMethodChannel _mainWindowChannel = WindowMethodChannel(
    _mainWindowChannelName,
    mode: ChannelMode.unidirectional,
  );

  static String? _currentWindowId;
  static String? _mainWindowId;
  static Rect? _mainWindowScreen;
  static double? _mainWindowScreenScale;
  static String? _windowTitle;
  static Size? _windowSize;
  static DesktopMultiWindowMethodHandler? _handler;
  static final Map<String, _StandaloneProcess> _standaloneProcesses = {};
  static final Map<String, _StandaloneProcess> _standaloneSingletons = {};
  static final Set<Future<void>> _standaloneLaunches = {};
  static bool _closingStandaloneWindows = false;
  static int _closeAttempt = 0;
  static StreamIterator<String>? _standaloneInput;
  static Future<void> _standaloneQueue = Future.value();
  static Completer<dynamic>? _standaloneReply;
  static Future<void> _windowSaves = Future.value();
  static final Queue<Future<void> Function()> _pendingSaves = Queue();
  static AsyncError? _windowSaveFailure;
  static Future<void> Function()? _flushStandaloneConfig;
  static Object Function()? _standaloneConfigWriteToken;
  static IOSink? _closeOutput;
  static Future<void>? _standaloneClosing;
  static int? _closingAttempt;
  static bool _standaloneClosed = false;
  static Future<_CloseSaveState>? _standaloneCloseSaves;
  static int? _preparedClose;
  static bool _standaloneDisconnected = false;
  static Map<dynamic, dynamic>? _themeSettings;
  static void Function(Map<dynamic, dynamic>)? onThemeChanged;
  static Future<void> Function(Map<dynamic, dynamic>)? onSaveDetailPreferences;
  static void Function(String)? onStandaloneClosed;

  static String? get currentWindowId => _currentWindowId;
  static String? get windowTitle => _windowTitle;
  static bool get isStandalone => _standaloneInput != null;
  static Map<dynamic, dynamic>? get themeSettings => _themeSettings;

  static Future<WindowController> ensureInitialized({String? mainWindowId}) async {
    await windowManager.ensureInitialized();
    final controller = await WindowController.fromCurrentEngine();
    _currentWindowId = controller.windowId;
    _mainWindowId = mainWindowId ?? _mainWindowId ?? controller.windowId;
    await _setWindowMethodHandler(controller);
    return controller;
  }

  static void initializeFromArguments(Map<dynamic, dynamic> arguments) {
    final mainWindowId = arguments.remove(_mainWindowIdKey) as String?;
    if (mainWindowId != null && mainWindowId.isNotEmpty) {
      _mainWindowId = mainWindowId;
    }
    final screen = arguments.remove(_mainWindowScreenKey);
    _mainWindowScreen = _rectFromJson(screen);
    final scale = screen is Map ? screen['scale'] : null;
    _mainWindowScreenScale = scale is num && _validScale(scale.toDouble()) ? scale.toDouble() : null;
    _windowTitle = arguments.remove(_windowTitleKey) as String?;
    _windowSize = _sizeFromJson(arguments.remove(_windowSizeKey));
    final launchTheme = arguments.remove(_themeKey) as Map?;
    _themeSettings ??= launchTheme;
  }

  /// [size] 使用 Flutter 逻辑尺寸，由子窗口按目标显示器的 DPI 换算。
  static Future<WindowController> createWindow(String arguments, {String? title, Size? size}) async {
    final configurationArguments = await _withWindowContext(arguments, title: title, size: size);
    return WindowController.create(WindowConfiguration(
      arguments: configurationArguments,
      hiddenAtLaunch: true,
    ));
  }

  static Future<void> launchStandaloneWindow(
    String title,
    Size size,
    Map<String, dynamic> pageArguments, {
    bool singleton = false,
    @visibleForTesting Future<Process> Function()? startProcess,
  }) async {
    if (_closingStandaloneWindows) throw StateError('The main window is closing');
    final launch = _launchStandaloneWindow(title, size, pageArguments, singleton, startProcess);
    _standaloneLaunches.add(launch);
    try {
      await launch;
    } finally {
      _standaloneLaunches.remove(launch);
    }
  }

  static Future<void> _launchStandaloneWindow(
    String title,
    Size size,
    Map<String, dynamic> pageArguments,
    bool singleton,
    Future<Process> Function()? startProcess,
  ) async {
    final name = pageArguments['name'] as String;
    final existing = _standaloneSingletons[name];
    if (singleton && existing != null) {
      _sendStandaloneEvent(existing, 'window_focus', null);
      return;
    }
    final arguments = jsonEncode({
      ...pageArguments,
      _windowTitleKey: title,
      _windowSizeKey: {'width': size.width, 'height': size.height},
      _themeKey: _themeSettings,
    });
    final process =
        await (startProcess?.call() ?? Process.start(Platform.resolvedExecutable, [standaloneWindowArgument]));
    final id = 'tool:${process.pid}';
    final tool = _StandaloneProcess(process);
    _standaloneProcesses[id] = tool;
    if (singleton) _standaloneSingletons[name] = tool;
    process.stdin.done.ignore();
    process.stdin.writeln(arguments);
    if (_themeSettings case final settings?) {
      _sendStandaloneEvent(tool, _themeMethod, settings);
    }
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) async {
      if (!line.startsWith(_standaloneRequestPrefix)) {
        print(line);
        return;
      }
      try {
        final request = jsonDecode(line.substring(_standaloneRequestPrefix.length)) as Map<String, dynamic>;
        if (tool.handleCloseMessage(request)) return;
        final method = request['method'] as String;
        if (!_standaloneMethods.contains(method) || (_handler == null && method != _saveDetailPreferencesMethod)) {
          throw UnsupportedError(method);
        }
        final result = await _dispatchMethodCall(MethodCall(method, request['arguments']), id);
        process.stdin.writeln(jsonEncode({'result': result}));
      } catch (error) {
        process.stdin.writeln(jsonEncode({'error': error.toString()}));
      }
    }, onError: (Object error, StackTrace stackTrace) {
      logger.e('Tool output failed', error: error, stackTrace: stackTrace);
    }, onDone: tool.outputClosed.complete);
    process.stderr.listen(stderr.add, onError: (Object error, StackTrace stackTrace) {
      logger.e('Tool error output failed', error: error, stackTrace: stackTrace);
    });
    unawaited(tool.exited.then((code) {
      process.stdin.close().ignore();
      if (_standaloneProcesses[id] == tool) _standaloneProcesses.remove(id);
      if (_standaloneSingletons[name] == tool) _standaloneSingletons.remove(name);
      onStandaloneClosed?.call(id);
      if (code != 0) {
        logger.e('Tool window ${pageArguments['name']} exited with code $code');
      }
    }));
  }

  static Future<void> closeStandaloneWindows({Duration timeout = const Duration(seconds: 5)}) async {
    _closingStandaloneWindows = true;
    final attempt = ++_closeAttempt;
    var tools = <_StandaloneProcess>[];
    try {
      await Future.wait(_standaloneLaunches.toList().map((launch) => launch.then<void>((_) {}, onError: (_) {})))
          .timeout(timeout);
      tools = _standaloneProcesses.values.toList();
      await Future.wait(tools.map((tool) => tool.prepare(attempt, timeout)), eagerError: true);
      await Future.wait(tools.map((tool) => tool.commit(attempt, timeout)), eagerError: true);
    } catch (_) {
      for (final tool in tools) {
        tool.cancel(attempt);
      }
      resumeStandaloneWindows();
      rethrow;
    } finally {
      for (final tool in tools) {
        tool.finish(attempt);
      }
    }
  }

  static void resumeStandaloneWindows() => _closingStandaloneWindows = false;

  static Future<String> readStandaloneWindowArguments(Stream<List<int>> bytes) async {
    final input = StreamIterator(bytes.transform(utf8.decoder).transform(const LineSplitter()));
    _standaloneInput = input;
    return await input.moveNext() ? input.current : '';
  }

  static Future<void> listenForStandaloneEvents() async {
    final input = _standaloneInput!;
    try {
      while (await input.moveNext()) {
        final message = jsonDecode(input.current) as Map<String, dynamic>;
        if (message['event'] case final String event) {
          final arguments = message['arguments'];
          final handling = switch (event) {
            _prepareClose || _commitClose || _cancelClose => _handleStandaloneClose(event, arguments as int),
            _ => _handleWindowEvent(MethodCall(event, arguments)),
          };
          unawaited(handling.then<void>((_) {}, onError: (Object error, StackTrace stackTrace) {
            logger.e('Tool window event failed', error: error, stackTrace: stackTrace);
          }));
        } else {
          final reply = _standaloneReply;
          _standaloneReply = null;
          if (message['error'] case final String error) {
            reply?.completeError(PlatformException(code: 'standalone_window', message: error));
          } else {
            reply?.complete(message['result']);
          }
        }
      }
    } finally {
      _standaloneDisconnected = true;
      final reply = _standaloneReply;
      _standaloneReply = null;
      reply?.completeError(StateError('Main window disconnected'));
      await closeStandaloneWindow();
    }
  }

  static Future<T?> _invokeStandalone<T>(String method, dynamic arguments) {
    final reply = _standaloneQueue.then((_) async {
      if (_standaloneDisconnected) throw StateError('Main window disconnected');
      final pending = Completer<dynamic>();
      _standaloneReply = pending;
      stdout.writeln('$_standaloneRequestPrefix${jsonEncode({'method': method, 'arguments': arguments})}');
      return await pending.future as T?;
    });
    _standaloneQueue = reply.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return reply;
  }

  static void _sendStandaloneEvent(_StandaloneProcess tool, String event, dynamic arguments) {
    if (!tool.processExited) tool.process.stdin.writeln(jsonEncode({'event': event, 'arguments': arguments}));
  }

  static Future<void> updateTheme(Map<String, dynamic> settings) async {
    _themeSettings = settings;
    for (final process in _standaloneProcesses.values) {
      _sendStandaloneEvent(process, _themeMethod, settings);
    }
    try {
      final windows = await WindowController.getAll();
      if (!identical(_themeSettings, settings)) return;
      await Future.wait(windows.where((window) => window.windowId != _currentWindowId).map((window) async {
        try {
          await window.invokeMethod(_themeMethod, settings);
        } on WindowChannelException catch (error, stackTrace) {
          if (error.code != 'CHANNEL_UNREGISTERED' && error.code != 'CHANNEL_NOT_FOUND') {
            logger.w('Could not update child window theme', error: error, stackTrace: stackTrace);
          }
        }
      }));
    } catch (error, stackTrace) {
      logger.w('Could not broadcast child window theme', error: error, stackTrace: stackTrace);
    }
  }

  static Future<void> _refreshNativeChildTheme() async {
    if (isStandalone || _mainWindowId == _currentWindowId) return;

    final previous = _themeSettings;
    try {
      final settings = await invokeMainWindowMethod<Map>(_getThemeMethod).timeout(const Duration(seconds: 1));
      if (settings != null && identical(_themeSettings, previous)) {
        _applyWindowTheme(settings);
      }
    } catch (error, stackTrace) {
      logger.w('Could not load the latest child window theme', error: error, stackTrace: stackTrace);
    }
  }

  static Future<void> saveStandaloneChanges(Future<void> Function() save, {bool retryOnClose = false}) {
    if (!isStandalone) return _queueWindowSave(save);
    if (retryOnClose) {
      _pendingSaves.add(save);
      return _queueWindowSave(_retryPendingSaves);
    }
    return _queueWindowSave(() async {
      try {
        await save();
        _windowSaveFailure = null;
      } catch (error, stackTrace) {
        _windowSaveFailure = AsyncError(error, stackTrace);
        rethrow;
      }
    });
  }

  static Future<void> _queueWindowSave(Future<void> Function() save) {
    final operation = _windowSaves.then((_) => save());
    _windowSaves = operation.then<void>((_) {}, onError: (Object error, StackTrace stackTrace) {
      logger.e('Saving tool changes failed', error: error, stackTrace: stackTrace);
    });
    return operation;
  }

  static Future<void> _retryPendingSaves() async {
    while (_pendingSaves.isNotEmpty) {
      await _pendingSaves.first();
      _pendingSaves.removeFirst();
    }
  }

  static Future<void> prepareStandaloneClose(
    Future<void> Function() flushConfig, {
    Object Function()? configWriteToken,
    @visibleForTesting IOSink? closeOutput,
  }) async {
    _flushStandaloneConfig = flushConfig;
    _standaloneConfigWriteToken = configWriteToken;
    _closeOutput = closeOutput;
    await windowManager.setPreventClose(true);
    windowManager.addListener(_StandaloneCloseListener());
  }

  static _CloseSaveState get _closeSaveState =>
      (saves: _windowSaves, requests: _standaloneQueue, configWrites: _standaloneConfigWriteToken?.call());

  static Future<_CloseSaveState> _saveBeforeClosing() {
    return _standaloneCloseSaves ??= _drainCloseSaves().whenComplete(() => _standaloneCloseSaves = null);
  }

  static Future<_CloseSaveState> _drainCloseSaves() async {
    while (true) {
      final drain = _queueWindowSave(_retryPendingSaves);
      final saves = _windowSaves;
      await drain;
      final requests = _standaloneQueue;
      await requests;
      final configFlush = _flushStandaloneConfig?.call();
      final configWrites = _standaloneConfigWriteToken?.call();
      await configFlush;
      final state = _closeSaveState;
      if (state != (saves: saves, requests: requests, configWrites: configWrites)) continue;
      if (_windowSaveFailure case final failure?) Error.throwWithStackTrace(failure.error, failure.stackTrace);
      return state;
    }
  }

  static Future<void> closeStandaloneWindow() async {
    try {
      await _finishStandaloneClose();
    } catch (error, stackTrace) {
      logger.e('Could not close the tool window', error: error, stackTrace: stackTrace);
    }
  }

  static Future<void> _finishStandaloneClose({int? attempt}) async {
    for (var closing = _standaloneClosing; closing != null; closing = _standaloneClosing) {
      if (attempt == _closingAttempt || (_closingAttempt == null && attempt != null)) return closing;
      try {
        await closing;
      } catch (_) {}
    }
    if (_standaloneClosed) return;
    if (attempt != null && _preparedClose != attempt) return;
    _closingAttempt = attempt;
    await (_standaloneClosing = _destroySavedWindow(attempt).whenComplete(() => _standaloneClosing = null));
  }

  static Future<void> _destroySavedWindow(int? attempt) async {
    bool cancelled() => attempt != null && _preparedClose != attempt;
    var saved = await _saveBeforeClosing();
    if (cancelled()) return;
    final sendReceipt = isStandalone && !_standaloneDisconnected;
    try {
      if (sendReceipt) await _sendCloseMessage({'closeSaved': true});
      while (!cancelled() && saved != _closeSaveState) {
        saved = await _saveBeforeClosing();
      }
      if (cancelled()) {
        if (sendReceipt && !_standaloneDisconnected) await _sendCloseMessage({'closeSaved': false});
        return;
      }
      await windowManager.destroy();
      _standaloneClosed = true;
    } catch (_) {
      if (sendReceipt && !_standaloneDisconnected) await _sendCloseMessage({'closeSaved': false});
      rethrow;
    }
  }

  static Future<void> _sendCloseMessage(Map<String, dynamic> message) {
    final output = _closeOutput ?? stdout;
    output.writeln('$_standaloneRequestPrefix${jsonEncode(message)}');
    return output.flush();
  }

  static Future<void> _handleStandaloneClose(String event, int attempt) async {
    try {
      if (event == _prepareClose) {
        _preparedClose = attempt;
        await _saveBeforeClosing();
        if (_preparedClose == attempt) {
          await _sendCloseMessage({'closeAttempt': attempt, 'ready': true});
        }
      } else if (event == _cancelClose) {
        if (_preparedClose == attempt) _preparedClose = null;
      } else if (_preparedClose == attempt) {
        await _finishStandaloneClose(attempt: attempt);
      }
    } catch (error) {
      await _sendCloseMessage({'closeAttempt': attempt, 'closeError': error.toString()});
    }
  }

  /// 首帧初始化 Flutter surface 后调整隐藏窗口，并等待 resize 后的帧完成再显示。
  static void prepareWindow() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _refreshNativeChildTheme();
      if (Platform.isMacOS || Platform.isWindows) {
        try {
          await windowManager.setHasShadow(true);
        } catch (error, stackTrace) {
          logger.w('Could not enable the native child window shadow', error: error, stackTrace: stackTrace);
        }
      }
      try {
        final title = _windowTitle;
        if (title != null) {
          await windowManager.setTitle(title);
        }
        final size = _windowSize;
        final screen = _mainWindowScreen;
        final screenScale = _mainWindowScreenScale;
        if (Platform.isWindows && screen != null && screenScale != null) {
          await _resizeAndCenterOnMainScreen(screen, screenScale, size);
        } else {
          if (size != null) {
            await windowManager.setSize(size);
          }
          await windowManager.center();
        }
        await WidgetsBinding.instance.endOfFrame;
      } catch (error, stackTrace) {
        logger.e('Prepare child window failed, showing fallback window', error: error, stackTrace: stackTrace);
      } finally {
        try {
          await windowManager.show();
        } catch (error, stackTrace) {
          logger.e('Show child window failed, closing hidden window', error: error, stackTrace: stackTrace);
          try {
            await _closeCurrentWindow();
          } catch (closeError, closeStackTrace) {
            logger.e('Close hidden child window failed', error: closeError, stackTrace: closeStackTrace);
          }
        }
      }
    });
  }

  /// 同 DPI 直接设置最终尺寸；跨 DPI 先移动隐藏窗口，避免 WM_DPICHANGED 二次缩放目标尺寸。
  static Future<void> _resizeAndCenterOnMainScreen(Rect screen, double screenScale, Size? size) async {
    var scale = _windowPixelRatio();
    if (scale != screenScale) {
      final initialSize = await windowManager.getSize();
      final initialPosition = centeredWindowPosition(screen, initialSize * scale);
      await windowManager.setPosition(initialPosition / scale);
      await WidgetsBinding.instance.endOfFrame;
      scale = _windowPixelRatio();
    }

    if (size != null) {
      // setSize 内部会乘以当前窗口 DPI；跨 DPI 时换算成目标屏幕的物理尺寸。
      await windowManager.setSize(scale == screenScale ? size : size * screenScale / scale);
    }
    final windowSize = await windowManager.getSize();
    final position = centeredWindowPosition(screen, windowSize * scale);
    await windowManager.setPosition(position / scale);
  }

  static Future<T?> invokeMainWindowMethod<T>(String method, [dynamic arguments]) async {
    if (isStandalone && _standaloneMethods.contains(method)) {
      return _invokeStandalone<T>(method, arguments);
    }
    return _mainWindowChannel.invokeMethod<T>(method, {
      _fromWindowIdKey: _currentWindowId,
      _argumentsKey: arguments,
    });
  }

  static Future<void> saveDetailPreferences(Map<String, String> changes) {
    Future<void> save() async {
      final saved = await invokeMainWindowMethod<bool>(_saveDetailPreferencesMethod, changes);
      if (saved != true) throw StateError('Main window did not save detail preferences');
    }

    return isStandalone ? _queueWindowSave(save) : save();
  }

  static Future<T?> invokeMethod<T>(Object windowId, String method, [dynamic arguments]) async {
    if (windowId.toString() == '0') {
      return invokeMainWindowMethod<T>(method, arguments);
    }

    if (_standaloneProcesses[windowId] case final process?) {
      _sendStandaloneEvent(process, method, arguments);
      return null;
    }

    final targetWindowId = _resolveWindowId(windowId);
    return WindowController.fromWindowId(targetWindowId).invokeMethod<T>(method, arguments);
  }

  static Future<void> setMethodHandler(DesktopMultiWindowMethodHandler handler) async {
    _handler = handler;
    final controller = await ensureInitialized(mainWindowId: _mainWindowId);
    if (_currentWindowId == _mainWindowId) {
      await _mainWindowChannel.setMethodCallHandler(_handleMethodCall);
    } else {
      await _setWindowMethodHandler(controller);
    }
  }

  static String _resolveWindowId(Object windowId) {
    final id = windowId.toString();
    if (id == '0') {
      return _mainWindowId ?? id;
    }
    return id;
  }

  static Future<dynamic> _handleMethodCall(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is Map && arguments.containsKey(_argumentsKey)) {
      return _dispatchMethodCall(
        MethodCall(call.method, arguments[_argumentsKey]),
        arguments[_fromWindowIdKey]?.toString() ?? '',
      );
    }
    return _dispatchMethodCall(call, '');
  }

  static Future<dynamic> _dispatchMethodCall(MethodCall call, String fromWindowId) async {
    if (call.method == _getThemeMethod) return _themeSettings;
    if (call.method == _saveDetailPreferencesMethod) {
      final save = onSaveDetailPreferences;
      if (save == null) throw StateError('Main window cannot save detail preferences');
      await save(call.arguments as Map);
      return true;
    }
    return _handler?.call(call, fromWindowId);
  }

  static Future<String> _withWindowContext(String arguments, {String? title, Size? size}) async {
    try {
      final decoded = jsonDecode(arguments);
      if (decoded is Map<String, dynamic>) {
        final context = Map<String, dynamic>.from(decoded);
        final mainWindowId = _mainWindowId ?? _currentWindowId;
        if (mainWindowId != null && mainWindowId.isNotEmpty) {
          context[_mainWindowIdKey] = mainWindowId;
        }
        if (Platform.isWindows) {
          final screen = await _currentWindowScreen();
          if (screen != null) {
            context[_mainWindowScreenKey] = {
              ..._rectToJson(screen),
              'scale': _windowPixelRatio(),
            };
          }
        }
        if (title != null) {
          context[_windowTitleKey] = title;
        }
        if (size != null) {
          context[_windowSizeKey] = {'width': size.width, 'height': size.height};
        }
        if (_themeSettings case final settings?) {
          context[_themeKey] = settings;
        }
        return jsonEncode(context);
      }
    } catch (_) {
      // Keep non-JSON arguments unchanged.
    }
    return arguments;
  }

  static Future<Rect?> _currentWindowScreen() async {
    try {
      // window_manager 和 screen_retriever 在 Windows 上使用不同 DPI 换算，
      // 统一还原成物理坐标后再判断父窗口属于哪个显示器。
      final scale = _windowPixelRatio();
      final bounds = await windowManager.getBounds();
      final windowBounds = Rect.fromLTWH(
        bounds.left * scale,
        bounds.top * scale,
        bounds.width * scale,
        bounds.height * scale,
      );
      return displayRectForWindow(
        windowBounds: windowBounds,
        displays: await screenRetriever.getAllDisplays(),
      );
    } catch (_) {
      // 获取显示器失败时回退到 window_manager 的默认居中行为。
      return null;
    }
  }

  @visibleForTesting
  static Rect? displayRectForWindow({
    required Rect windowBounds,
    required List<Display> displays,
  }) {
    if (!_validRect(windowBounds)) return null;

    Rect? bestRect;
    var bestOverlap = 0.0;
    for (final display in displays) {
      final scale = display.scaleFactor?.toDouble();
      if (!_validScale(scale)) continue;

      final origin = display.visiblePosition ?? Offset.zero;
      final size = display.visibleSize ?? display.size;
      final rect = Rect.fromLTWH(
        origin.dx * scale!,
        origin.dy * scale,
        size.width * scale,
        size.height * scale,
      );
      if (!_validRect(rect)) continue;
      if (rect.contains(windowBounds.center)) return rect;

      final overlapWidth = _min(windowBounds.right, rect.right) - _max(windowBounds.left, rect.left);
      final overlapHeight = _min(windowBounds.bottom, rect.bottom) - _max(windowBounds.top, rect.top);
      if (overlapWidth <= 0 || overlapHeight <= 0) continue;
      final overlap = overlapWidth * overlapHeight;
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        bestRect = rect;
      }
    }
    return bestRect;
  }

  @visibleForTesting
  static Offset centeredWindowPosition(Rect screen, Size windowSize) {
    final position = Offset(
      screen.left + (screen.width - windowSize.width) / 2,
      screen.top + (screen.height - windowSize.height) / 2,
    );
    return Offset(
      windowSize.width < screen.width
          ? position.dx.clamp(screen.left, screen.right - windowSize.width).toDouble()
          : position.dx,
      windowSize.height < screen.height
          ? position.dy.clamp(screen.top, screen.bottom - windowSize.height).toDouble()
          : position.dy,
    );
  }

  static double _windowPixelRatio() {
    if (!Platform.isWindows) return 1;
    final scale = windowManager.getDevicePixelRatio();
    return _validScale(scale) ? scale : 1;
  }

  static bool _validScale(double? scale) => scale != null && scale.isFinite && scale > 0;

  static bool _validRect(Rect rect) {
    return rect.left.isFinite &&
        rect.top.isFinite &&
        rect.width.isFinite &&
        rect.height.isFinite &&
        rect.width > 0 &&
        rect.height > 0;
  }

  static double _min(double a, double b) => a < b ? a : b;

  static double _max(double a, double b) => a > b ? a : b;

  static Map<String, double> _rectToJson(Rect rect) {
    return {'left': rect.left, 'top': rect.top, 'width': rect.width, 'height': rect.height};
  }

  static Rect? _rectFromJson(dynamic value) {
    if (value is! Map) return null;
    final left = value['left'];
    final top = value['top'];
    final width = value['width'];
    final height = value['height'];
    if (left is! num || top is! num || width is! num || height is! num) return null;
    final rect = Rect.fromLTWH(left.toDouble(), top.toDouble(), width.toDouble(), height.toDouble());
    return _validRect(rect) ? rect : null;
  }

  static Size? _sizeFromJson(dynamic value) {
    if (value is! Map) return null;
    final width = value['width'];
    final height = value['height'];
    if (width is! num || height is! num) return null;
    final size = Size(width.toDouble(), height.toDouble());
    return size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 ? size : null;
  }

  static Future<void> _setWindowMethodHandler(WindowController controller) {
    return controller.setWindowMethodHandler(_handleWindowEvent);
  }

  static Future<void> _closeCurrentWindow() => isStandalone ? closeStandaloneWindow() : windowManager.close();

  static void _applyWindowTheme(Map<dynamic, dynamic> settings) {
    _themeSettings = settings;
    onThemeChanged?.call(settings);
  }

  static Future<dynamic> _handleWindowEvent(MethodCall call) async {
    switch (call.method) {
      case 'window_close':
        return _closeCurrentWindow();
      case 'window_focus':
        if (await windowManager.isMinimized()) {
          await windowManager.restore();
        }
        return windowManager.focus();
      case _themeMethod:
        _applyWindowTheme(call.arguments as Map);
        return null;
      default:
        return _handleMethodCall(call);
    }
  }
}

class _StandaloneProcess {
  final Process process;
  final outputClosed = Completer<void>();
  bool processExited = false;
  late final Future<int> exited = process.exitCode.then((code) async {
    processExited = true;
    await outputClosed.future;
    return code;
  });
  int? _attempt;
  Completer<void>? _reply;
  bool _preparing = false;
  bool _saved = false;
  bool _exited = false;

  _StandaloneProcess(this.process);

  bool handleCloseMessage(Map<String, dynamic> message) {
    if (message['closeSaved'] case final bool saved) {
      _saved = saved;
      return true;
    }
    if (message['closeAttempt'] case final int attempt) {
      final reply = _reply;
      if (_attempt == attempt && reply != null && !reply.isCompleted) {
        if (message['closeError'] case final String error) {
          reply.completeError(StateError(error));
        } else if (_preparing && message['ready'] == true) {
          reply.complete();
        }
      }
      return true;
    }
    return false;
  }

  Future<void> prepare(int attempt, Duration timeout) => _sendClose(attempt, DesktopMultiWindow._prepareClose, timeout);

  Future<void> commit(int attempt, Duration timeout) => _sendClose(attempt, DesktopMultiWindow._commitClose, timeout);

  Future<void> _sendClose(int attempt, String event, Duration timeout) async {
    if (_exited) return;
    final reply = Completer<void>();
    _attempt = attempt;
    _reply = reply;
    _preparing = event == DesktopMultiWindow._prepareClose;
    final result = Future.any<void>([
      reply.future,
      exited.then((code) {
        if (code != 0 || !_saved) throw StateError('Tool ${process.pid} exited without confirming its save ($code)');
        _exited = true;
      }),
    ]).timeout(timeout);
    try {
      DesktopMultiWindow._sendStandaloneEvent(this, event, attempt);
    } catch (error, stackTrace) {
      reply.completeError(error, stackTrace);
    }
    await result;
  }

  void finish(int attempt) {
    if (_attempt != attempt) return;
    _attempt = null;
    _reply = null;
  }

  void cancel(int attempt) {
    if (_attempt != attempt || _exited) return;
    try {
      DesktopMultiWindow._sendStandaloneEvent(this, DesktopMultiWindow._cancelClose, attempt);
    } catch (error) {
      logger.w('Could not cancel tool shutdown', error: error);
    }
  }
}

class _StandaloneCloseListener with WindowListener {
  @override
  void onWindowClose() => unawaited(DesktopMultiWindow.closeStandaloneWindow());
}

extension WindowControllerCompat on WindowController {
  Future<void> close() {
    if (windowId == DesktopMultiWindow.currentWindowId) {
      return DesktopMultiWindow._closeCurrentWindow();
    }
    return _invokeWindowMethod('window_close');
  }

  Future<void> focus() {
    return _invokeWindowMethod('window_focus');
  }

  Future<void> _invokeWindowMethod(String method, [dynamic arguments]) async {
    // 新窗口创建后，其 Dart engine 需要时间启动并注册对应的 window channel
    // （mixin.one/window_controller/<windowId>）。若立刻调用会在启动竞态期间
    // 收到 CHANNEL_UNREGISTERED，因此轮询等待窗口 engine 就绪。
    for (var i = 0; i < 20; i++) {
      try {
        await invokeMethod(method, arguments);
        return;
      } on WindowChannelException catch (e) {
        if (e.code != 'CHANNEL_UNREGISTERED' || i == 19) {
          rethrow;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }
}
