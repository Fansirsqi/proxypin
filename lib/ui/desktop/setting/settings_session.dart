import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/util/crts.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/system_proxy.dart';
import 'package:proxypin/ui/component/multi_window.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/desktop/setting/environment.dart';
import 'package:proxypin/ui/desktop/ssl/client_cert.dart';
import 'package:proxypin/ui/desktop/toolbar/quick_tools.dart';
import 'package:proxypin/utils/navigator.dart';
import 'package:window_manager/window_manager.dart';

class DesktopSettingsSession {
  final AppConfiguration configuration;
  Map<String, dynamic> proxySettings;
  Future<void> _proxyWrites = Future.value();
  final _pendingPreviews = <DisplayDensitySetting, double>{};
  Future<void>? _previewWrite;
  bool _hasPreviews = false;

  DesktopSettingsSession._(this.configuration, this.proxySettings);

  Object get closeWriteToken => (configuration.configWriteToken, _proxyWrites, _previewWrite);

  static Future<Map> read() async {
    final settings = await DesktopMultiWindow.invokeMainWindowMethod<Map>('getDesktopSettings');
    if (settings == null) throw StateError('Main window did not return desktop settings');
    return settings;
  }

  static Future<DesktopSettingsSession> connect(AppConfiguration configuration) async {
    final settings = await read();
    final session = DesktopSettingsSession._(configuration, Map<String, dynamic>.from(settings['proxy'] as Map));
    configuration.forwardDesktopSettings(
      Map<String, dynamic>.from(settings['ui'] as Map),
      session._save,
      session._preview,
    );
    return session;
  }

  Future<void> _save(Map<String, dynamic> changes) async {
    await _previewWrite;
    final saved = await DesktopMultiWindow.invokeMainWindowMethod<bool>('saveDesktopSettings', changes);
    if (saved != true) throw StateError('Main window did not save desktop settings');
  }

  void _preview(DisplayDensitySetting setting, double value) {
    _hasPreviews = true;
    _pendingPreviews[setting] = value;
    _previewWrite ??= _sendPreviews().whenComplete(() => _previewWrite = null);
  }

  Future<void> _sendPreviews() async {
    while (_pendingPreviews.isNotEmpty) {
      final previews = {for (final entry in _pendingPreviews.entries) entry.key.name: entry.value};
      _pendingPreviews.clear();
      try {
        await DesktopMultiWindow.invokeMainWindowMethod('previewSettingsDensity', previews);
      } catch (error, stackTrace) {
        logger.w('Could not preview desktop settings', error: error, stackTrace: stackTrace);
      }
    }
  }

  Future<void> flushForClose() async {
    final focus = FocusManager.instance;
    focus.primaryFocus?.unfocus();
    focus.applyFocusChangesIfNeeded();
    final flush = configuration.flushConfigForClose();
    await _proxyWrites;
    await flush;
    await _previewWrite;
    if (_hasPreviews) {
      await DesktopMultiWindow.invokeMainWindowMethod('resetSettingsPreview');
      _hasPreviews = false;
    }
  }

  Future<void> updateProxySetting(String key, Object value) {
    final write = _proxyWrites.then((_) async {
      final result = await DesktopMultiWindow.invokeMainWindowMethod<Map>(
        'updateDesktopProxySetting',
        {'key': key, 'value': value},
      );
      proxySettings = Map<String, dynamic>.from(result!);
    });
    _proxyWrites = write.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return write;
  }

  Future<void> refreshProxySettings() async {
    final previous = _proxyWrites;
    await previous;
    final settings = await read();
    if (identical(previous, _proxyWrites)) proxySettings = Map<String, dynamic>.from(settings['proxy'] as Map);
  }
}

String? _previewOwner;

void resetSettingsPreview(String windowId) {
  if (_previewOwner != windowId) return;
  _previewOwner = null;
  AppConfiguration.current?.clearSettingsDensityPreviews();
}

Future<dynamic> handleDesktopSettingsMethod(String method, dynamic arguments, String windowId) async {
  final app = AppConfiguration.current!;
  final server = ProxyServer.current!;
  switch (method) {
    case 'getDesktopSettings':
      return {'ui': app.desktopSettings, 'proxy': _proxySettings(server)};
    case 'saveDesktopSettings':
      await app.saveDesktopSettings(Map<String, dynamic>.from(arguments as Map));
      return true;
    case 'previewSettingsDensity':
      _previewOwner = windowId;
      for (final entry in (arguments as Map).entries) {
        app.previewSettingsDensity(
          DisplayDensitySetting.values.byName(entry.key as String),
          (entry.value as num).toDouble(),
        );
      }
      return null;
    case 'resetSettingsPreview':
      resetSettingsPreview(windowId);
      return null;
    case 'updateDesktopProxySetting':
      await _updateProxySetting(server, arguments['key'] as String, arguments['value']);
      app.globalChange.value = !app.globalChange.value;
      return _proxySettings(server);
    case 'openDesktopSettingTool':
      unawaited(_openTool(server, arguments as String).catchError((Object error, StackTrace stackTrace) {
        logger.e('Could not open settings tool', error: error, stackTrace: stackTrace);
      }));
      return null;
    case 'changeDesktopCertificate':
      switch (arguments['action']) {
        case 'generate':
          await CertificateManager.generateNewRootCA();
        case 'reset':
          await CertificateManager.resetDefaultRootCA();
        case 'import':
          await CertificateManager.importPkcs12(
            Uint8List.fromList((arguments['bytes'] as List).cast<int>()),
            arguments['password'] as String?,
          );
        default:
          throw const FormatException('Invalid certificate action');
      }
      return null;
  }
  throw UnsupportedError(method);
}

Map<String, dynamic> _proxySettings(ProxyServer server) => {
      'port': server.port,
      'startup': server.configuration.startup,
      'enableSystemProxy': server.configuration.enableSystemProxy,
      'enableSocks5': server.configuration.enableSocks5,
      'enabledHttp2': server.configuration.enabledHttp2,
      'enableSsl': server.enableSsl,
      'proxyPassDomains': server.configuration.proxyPassDomains,
    };

Future<void> _updateProxySetting(ProxyServer server, String key, dynamic value) async {
  final config = server.configuration;
  switch (key) {
    case 'port':
      await server.changePort(value as int);
      return;
    case 'startup':
      config.startup = value as bool;
    case 'enableSystemProxy':
      final enabled = value as bool;
      if (server.isRunning) await server.setSystemProxyEnable(enabled);
      config.enableSystemProxy = enabled;
    case 'enableSocks5':
      config.enableSocks5 = value as bool;
    case 'enabledHttp2':
      config.enabledHttp2 = value as bool;
    case 'proxyPassDomains':
      final domains = value as String;
      if (server.isRunning && config.enableSystemProxy) await SystemProxy.setProxyPassDomains(domains);
      config.proxyPassDomains = domains;
    case 'enableSsl':
      server.enableSsl = value as bool;
      CertificateManager.cleanCache();
    default:
      throw const FormatException('Invalid proxy setting');
  }
  await config.flushConfig();
}

Future<void> _openTool(ProxyServer server, String id) async {
  final context = navigatorHelper.navigatorKey.currentContext;
  if (context == null) return;
  final tool = quickToolOf(id);
  if (tool == null || settingQuickTools.contains(tool)) {
    if (!await windowManager.isVisible()) await windowManager.show();
    await windowManager.focus();
  }
  if (!context.mounted) return;
  if (tool != null) {
    await tool.launch(context, server);
    managerStateVersion.value++;
  } else if (id == 'environment') {
    await showEnvironmentDialog(context);
  } else if (id == 'clientCertificate') {
    await showClientCertDialog(context);
  }
}
