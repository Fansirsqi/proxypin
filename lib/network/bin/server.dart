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
import 'dart:io';

import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/components/hosts.dart';
import 'package:proxypin/network/components/interceptor.dart';
import 'package:proxypin/network/components/network_condition.dart';
import 'package:proxypin/network/components/manager/client_cert_manager.dart';
import 'package:proxypin/network/components/report_server_interceptor.dart';
import 'package:proxypin/network/components/request_block.dart';
import 'package:proxypin/network/components/request_rewrite.dart';
import 'package:proxypin/network/components/script.dart';
import 'package:proxypin/network/handle/http_proxy_handle.dart';
import 'package:proxypin/network/util/crts.dart';
import 'package:proxypin/utils/platform.dart';

import '../components/request_map.dart';
import '../http/codec.dart';
import '../channel/network.dart';
import '../util/logger.dart';
import '../util/system_proxy.dart';
import 'listener.dart';
import 'package:proxypin/network/components/request_breakpoint.dart';

Future<void> main() async {
  var configuration = await Configuration.instance;
  ProxyServer(configuration).start();
}

/// 代理服务器
class ProxyServer {
  static ProxyServer? current;

  //socket服务
  Server? server;

  //请求事件监听
  List<EventListener> listeners = [];

  //配置
  final Configuration configuration;

  ProxyServer(this.configuration) {
    current = this;
  }

  //是否启动
  bool get isRunning => server?.isRunning ?? false;

  ///是否启用https抓包
  bool get enableSsl => configuration.enableSsl;

  int get port => configuration.port;

  Future<void> _pendingOperation = Future.value();

  Future<T> _runOperation<T>(Future<T> Function() operation) {
    final result = _pendingOperation.then((_) => operation());
    _pendingOperation = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> changePort(int newPort) async {
    Configuration.checkPort(newPort);
    await _runOperation(() => _changePort(newPort));
  }

  Future<void> _changePort(int newPort) async {
    final oldPort = port;
    if (newPort == oldPort) return;

    final active = server;
    if (active == null || !active.isRunning) {
      await configuration.savePort(newPort);
      return;
    }

    final replacement = await _bind(newPort);
    final updateSystemProxy = configuration.enableSystemProxy && Platforms.isDesktop();
    final sslSetting = enableSsl;
    final passDomains = configuration.proxyPassDomains;
    try {
      if (updateSystemProxy) await SystemProxy.updatePort(newPort, sslSetting, passDomains);
      await configuration.savePort(newPort);
    } catch (_) {
      try {
        if (updateSystemProxy) await SystemProxy.updatePort(oldPort, sslSetting, passDomains);
      } catch (error, stackTrace) {
        logger.e('Could not restore the system proxy to port $oldPort', error: error, stackTrace: stackTrace);
      }
      await _closeListener(replacement);
      rethrow;
    }
    server = replacement;
    await _closeListener(active);
  }

  Future<void> _closeListener(Server listener) async {
    try {
      await listener.stop();
    } catch (error, stackTrace) {
      logger.e('Could not close the proxy listener', error: error, stackTrace: stackTrace);
    }
  }

  set enableSsl(bool enableSsl) {
    configuration.enableSsl = enableSsl;
    if (server == null || server?.isRunning == false) {
      return;
    }

    if (configuration.enableSystemProxy) {
      SystemProxy.setSslProxyEnable(enableSsl, port);
    }
  }

  /// 启动代理服务
  Future<Server> start() => _runOperation(_start);

  Future<Server> _start() async {
    if (isRunning) return server!;
    final listener = await _bind(port);
    server = listener;
    try {
      if (configuration.enableSystemProxy) await _setSystemProxyEnable(true, port);
    } catch (error, stackTrace) {
      logger.e('Could not enable the system proxy on port $port', error: error, stackTrace: stackTrace);
    }
    CertificateManager.initCAConfig();
    ClientCertManager.preload();
    return listener;
  }

  Future<Server> _bind(int listenPort) async {
    Server server = Server(configuration, listener: CombinedEventListener(listeners));

    List<Interceptor> interceptors = [
      Hosts(),
      RequestMapInterceptor.instance,
      RequestRewriteInterceptor.instance,
      ScriptInterceptor(),
      RequestBlockInterceptor(),
      RequestBreakpointInterceptor.instance, // Register the interceptor
      NetworkConditionInterceptor.instance,
      ReportServerInterceptor()
    ];

    interceptors.sort((a, b) => a.priority.compareTo(b.priority));

    server.initChannel((channel) {
      channel.dispatcher.handle(
        HttpRequestCodec(),
        HttpResponseCodec(),
        HttpProxyChannelHandler(listener: CombinedEventListener(listeners), interceptors: interceptors),
      );
    });

    await server.bind(listenPort);
    logger.i("listen on $listenPort");
    return server;
  }

  /// 停止代理服务
  Future<Server?> stop() => _runOperation(_stop);

  Future<Server?> _stop() async {
    if (!isRunning) {
      return server;
    }

    if (configuration.enableSystemProxy) {
      await _setSystemProxyEnable(false, port);
    }
    logger.i("stop on $port");
    await server?.stop();
    return server;
  }

  /// 设置系统代理
  Future<void> setSystemProxyEnable(bool enable) => _runOperation(() => _setSystemProxyEnable(enable, port));

  Future<void> _setSystemProxyEnable(bool enable, int listenPort) async {
    if (!Platforms.isDesktop()) {
      return;
    }

    //关闭系统代理 恢复成外部代理地址
    if (!enable && configuration.externalProxy?.enabled == true) {
      await SystemProxy.setSystemProxy(configuration.externalProxy!.port!, enableSsl, configuration.proxyPassDomains);
      return;
    }

    await SystemProxy.setSystemProxyEnable(listenPort, enable, enableSsl, passDomains: configuration.proxyPassDomains);
  }

  /// 重启代理服务
  Future<void> restart() => _runOperation(() async {
        await _stop().whenComplete(_start);
      });

  ///检查是否监听端口 没有监听则启动
  Future<void> retryBind() async {
    try {
      await Socket.connect('127.0.0.1', port, timeout: const Duration(milliseconds: 350));
    } catch (e) {
      logger.d('端口未被占用，尝试重新绑定 $port');
      await restart();
    }
  }

  ///添加监听器
  void addListener(EventListener listener) {
    listeners.add(listener);
  }

  ///移除监听器
  void removeListener(EventListener listener) {
    listeners.remove(listener);
  }
}
