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

import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/util/file_read.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/network/util/system_proxy.dart';
import 'package:proxypin/utils/platform.dart';

class Configuration {
  static const minPort = 1;
  static const maxPort = 65535;
  static const defaultPort = 9099;

  ///代理相关配置
  int _port = defaultPort;
  int get port => _port;
  set port(int value) => _port = checkPort(value);

  static bool isValidPort(Object? value) => value is int && value >= minPort && value <= maxPort;

  static int checkPort(int value) => RangeError.checkValueInInterval(value, minPort, maxPort, 'port');

  //是否启用https抓包
  bool enableSsl = Platforms.isMobile();

  //是否设置系统代理
  bool enableSystemProxy = true;

  //代理忽略域名
  String proxyPassDomains = SystemProxy.proxyPassDomains;

  //enabled socks5 proxy
  bool enableSocks5 = true;

  //外部代理
  ProxyInfo? externalProxy;

  //白名单应用
  List<String> appWhitelist = [];

  //白名单应用是否启用
  bool appWhitelistEnabled = true;

  //应用黑名单
  List<String>? appBlacklist;

  //远程连接 不持久化保存
  String? remoteHost;

  bool enabledHttp2 = false; // 是否启用http2

  //历史记录缓存时间
  int historyCacheTime = 0;

  //默认是否启动
  bool startup = false;

  Configuration._();

  /// 单例
  static Future<Configuration>? _instance;

  static Future<Configuration> get instance => _instance ??= _initialize();

  static Future<Configuration> _initialize() async {
    try {
      return Configuration.fromJson(await _loadConfig());
    } catch (error, stackTrace) {
      logger.e('初始化配置失败', error: error, stackTrace: stackTrace);
      return Configuration._();
    }
  }

  /// 加载配置
  Configuration.fromJson(Map<String, dynamic> config) {
    final savedPort = config['port'];
    if (savedPort is int && isValidPort(savedPort)) _port = savedPort;
    enableSsl = config['enableSsl'] == true;
    startup = config['startup'] ?? Platforms.isDesktop();
    enableSystemProxy = config['enableSystemProxy'] ?? (config['enableDesktop'] ?? true);
    enableSocks5 = config['enableSocks5'] ?? true;
    enabledHttp2 = config['enabledHttp2'] ?? false;

    proxyPassDomains = config['proxyPassDomains'] ?? SystemProxy.proxyPassDomains;
    historyCacheTime = config['historyCacheTime'] ?? 0;
    if (config['externalProxy'] != null) {
      externalProxy = ProxyInfo.fromJson(config['externalProxy']);
    }
    appWhitelist = List<String>.from(config['appWhitelist'] ?? []);
    appWhitelistEnabled = config['appWhitelistEnabled'] ?? true;
    appBlacklist = config['appBlacklist'] == null ? null : List<String>.from(config['appBlacklist']);
    HostFilter.whitelist.load(config['whitelist']);
    HostFilter.blacklist.load(config['blacklist']);
  }

  /// 配置文件
  static Future<File> configFile() async {
    var separator = Platform.pathSeparator;
    var home = await FileRead.homeDir();
    return File("${home.path}${separator}config.cnf");
  }

  static Future<void> _pendingSave = Future.value();

  /// 刷新配置文件
  Future<void> flushConfig() => _enqueueSave(_writeConfig);

  Future<void> savePort(int newPort) async {
    checkPort(newPort);
    await _enqueueSave(() async {
      await _writeConfig(newPort);
      _port = newPort;
    });
  }

  static Future<void> _enqueueSave(Future<void> Function() save) {
    final result = _pendingSave.then((_) => save());
    _pendingSave = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _writeConfig([int? newPort]) async {
    final settings = toJson();
    if (newPort != null) settings['port'] = newPort;
    final json = jsonEncode(settings);
    var file = await configFile();
    if (await FileSystemEntity.isLink(file.path)) {
      file = File(await file.resolveSymbolicLinks());
    }
    final parent = await file.parent.create(recursive: true);
    final staging = await parent.createTemp('.config.cnf-');
    try {
      final stagedFile = File('${staging.path}${Platform.pathSeparator}config.cnf');
      await stagedFile.writeAsString(json, flush: true);
      await stagedFile.rename(file.path);
      logger.d('Refreshed configuration file $file');
    } finally {
      try {
        await staging.delete(recursive: true);
      } on FileSystemException catch (error) {
        logger.w('Could not remove configuration staging directory', error: error);
      }
    }
  }

  /// 加载配置文件
  static Future<Map<String, dynamic>> _loadConfig() async {
    var file = await configFile();
    var exits = await file.exists();
    if (!exits) {
      return {};
    }

    Map<String, dynamic> config = jsonDecode(await file.readAsString());
    logger.i('加载配置文件 [$file]');
    return config;
  }

  Map<String, dynamic> toJson() {
    return {
      'port': port,
      'enableSsl': enableSsl,
      'startup': startup,
      'enableSystemProxy': enableSystemProxy,
      'enableSocks5': enableSocks5,
      'proxyPassDomains': proxyPassDomains,
      'externalProxy': externalProxy?.toJson(),
      'appWhitelist': appWhitelist,
      'appWhitelistEnabled': appWhitelistEnabled,
      'appBlacklist': appBlacklist,
      'historyCacheTime': historyCacheTime,
      'enabledHttp2': enabledHttp2,
      'whitelist': HostFilter.whitelist.toJson(),
      'blacklist': HostFilter.blacklist.toJson(),
    };
  }
}
