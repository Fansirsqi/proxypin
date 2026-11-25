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
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/ui/component/floating_dialog.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/native/vpn.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/component/svg_icon.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/ui/desktop/ssl/pc_cert.dart';
import 'package:proxypin/utils/desktop_tray.dart';
import 'package:proxypin/utils/lang.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:window_manager/window_manager.dart';

import '../mobile/setting/ssl.dart';

///启动按钮
///@author wanghongen
///2023/10/8
class SocketLaunch extends StatefulWidget {
  static ValueNotifier<ValueWrap<bool>> startStatus = ValueNotifier(ValueWrap());

  final ProxyServer proxyServer;
  final int size;
  final bool startup; //默认是否启动
  final Function? onStart;
  final Function? onStop;

  final bool serverLaunch; //是否启动代理服务器

  const SocketLaunch(
      {super.key,
      required this.proxyServer,
      this.size = 25,
      this.onStart,
      this.onStop,
      this.startup = true,
      this.serverLaunch = true});

  @override
  State<StatefulWidget> createState() => _SocketLaunchState();
}

class _SocketLaunchState extends State<SocketLaunch> with WindowListener, WidgetsBindingObserver {
  AppLocalizations get localizations => AppLocalizations.of(context)!;
  bool started = false;
  bool _closing = false;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    if (Platforms.isDesktop()) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
      DesktopTrayManager.instance.setQuitHandler(appExit);
    }

    WidgetsBinding.instance.addObserver(this);
    //启动代理服务器
    if (widget.startup) {
      start();
    }

    SocketLaunch.startStatus.addListener(() {
      if (SocketLaunch.startStatus.value.get() == started) {
        return;
      }
      setState(() {
        started = SocketLaunch.startStatus.value.get() ?? started;
      });
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    if (Platforms.isDesktop()) {
      DesktopTrayManager.instance.setQuitHandler(null);
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (_closing || _exiting) return;
    _closing = true;
    try {
      await _handleWindowClose();
    } finally {
      _closing = false;
    }
  }

  Future<void> _handleWindowClose() async {
    final appConfiguration = AppConfiguration.current;
    var action = appConfiguration?.windowCloseAction ?? WindowCloseAction.ask;
    var remember = false;
    if (action == WindowCloseAction.ask) {
      final decision = await _showClosePrompt();
      if (!mounted || decision == null) return;
      (action, remember) = decision;
    }

    if (action == WindowCloseAction.minimize) {
      await windowManager.minimize();
    } else if (action == WindowCloseAction.tray) {
      try {
        await DesktopTrayManager.instance.showToTray();
      } catch (e) {
        logger.e('Could not minimize to the system tray', error: e);
        if (mounted) FlutterToastr.show(localizations.fail, context, duration: 3);
        return;
      }
    }

    if (remember && appConfiguration != null) {
      appConfiguration.windowCloseAction = action;
      try {
        await appConfiguration.flushConfig();
      } catch (error) {
        logger.e('Could not save the window close preference', error: error);
        if (mounted) FlutterToastr.show(localizations.fail, context, duration: 3);
        return;
      }
    }
    if (action == WindowCloseAction.quit) await appExit();
  }

  Future<(WindowCloseAction, bool)?> _showClosePrompt() {
    final strings = localizations;
    var remember = false;
    return showDialog<(WindowCloseAction, bool)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => FloatingAlertDialog(
          title: Text(strings.trayCloseTitle),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(strings.trayClosePromptContent),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(strings.trayCloseRemember),
                value: remember,
                onChanged: (value) => setState(() => remember = value ?? false),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(strings.cancel)),
            TextButton(
              onPressed: () => Navigator.of(context).pop((WindowCloseAction.quit, remember)),
              child: Text(strings.trayCloseExitAnyway),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop((WindowCloseAction.tray, remember)),
              child: Text(strings.trayCloseMinimizeToTray),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> appExit() async {
    if (_exiting) return;
    _exiting = true;
    logger.d("appExit");
    try {
      if (Platform.isLinux) {
        await AppConfiguration.current?.flushConfigForClose();
        await DesktopMultiWindow.closeStandaloneWindows();
      }
      await widget.proxyServer.stop();
      started = false;
      if (Platforms.isDesktop()) {
        await DesktopTrayManager.instance.exitApp();
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
      }
    } catch (error, stackTrace) {
      DesktopMultiWindow.resumeStandaloneWindows();
      _exiting = false;
      logger.e('Could not exit the application', error: error, stackTrace: stackTrace);
      if (Platform.isLinux) {
        try {
          if (!await windowManager.isVisible()) await DesktopTrayManager.instance.restoreWindow();
        } catch (restoreError) {
          logger.e('Could not restore the main window after a failed exit', error: restoreError);
        }
      }
      if (mounted) FlutterToastr.show(localizations.fail, context, duration: 3);
      return;
    }

    if (!Platform.isWindows && !Platform.isLinux) {
      try {
        await SystemNavigator.pop(animated: true).timeout(const Duration(milliseconds: 150));
      } catch (_) {
        //
      }
    }

    exit(0);
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (Platform.isLinux) {
      await appExit();
      return AppExitResponse.cancel;
    }
    bool isPreventClose = await windowManager.isPreventClose();
    if (!isPreventClose || Platform.isMacOS) {
      await appExit();
    }
    return super.didRequestAppExit();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (widget.proxyServer.isRunning && started) {
        widget.proxyServer.retryBind().catchError((e) {
          logger.e('retryBind failed on resumed', error: e);
        });
      }

      if (Platforms.isMobile() && started == false) {
        Vpn.isRunning().then((value) {
          Vpn.isVpnStarted = value;
          SocketLaunch.startStatus.value = ValueWrap.of(value);
        });
      }
    }

    if (state == AppLifecycleState.detached) {
      logger.d('AppLifecycleState.detached');
      widget.onStop?.call();
      widget.proxyServer.stop();
      started = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (Platforms.isDesktop()) {
      return Tooltip(
          // 设计稿 title：状态 · 端口 · 操作提示（端口不进胶囊文案，避免启停时宽度变化推动右侧图标）
          message:
              '${started ? localizations.statusRunning : localizations.statusStopped} · :${widget.proxyServer.port} · ${started ? localizations.stop : localizations.start}',
          child: InkWell(borderRadius: BorderRadius.circular(8), onTap: onToggle, child: capsule()));
    }
    // 移动端嵌在 FAB 里：图标恒白，状态色由 FAB 底色表达（运行绿 / 停止灰）
    return IconButton(
        tooltip: started ? localizations.stop : localizations.start,
        icon: Icon(started ? Icons.stop : Icons.play_arrow_sharp,
            color: Colors.white, size: widget.size.toDouble()),
        onPressed: onToggle);
  }

  /// 更新启动状态并广播（FAB 底色、桌面状态栏等监听 startStatus）
  void _updateStarted(bool value) {
    setState(() {
      started = value;
    });
    SocketLaunch.startStatus.value = ValueWrap.of(value);
  }

  Future<void> onToggle() async {
    if (started) {
      if (!widget.serverLaunch) {
        widget.onStop?.call();
        _updateStarted(false);
        return;
      }

      widget.proxyServer.stop().then((value) {
        widget.onStop?.call();
        if (mounted) {
          _updateStarted(false);
        }
      }).catchError((e) {
        logger.e("stop proxy server failed", error: e);
        if (mounted) {
          FlutterToastr.show(localizations.fail, context, duration: 3);
          _updateStarted(false);
        }
      });
    } else {
      start();
    }
  }

  /// 桌面端浅色胶囊（设计稿 .proxy-state）：电源图标 + 状态点 +「运行中 · :9099」
  Widget capsule() {
    var theme = Theme.of(context);
    final green = okColor(theme);
    var color = started ? green : theme.colorScheme.onSurfaceVariant;
    return Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            // 运行中底色：浅色 #F0F8F2，暗黑 --proxy-bg（绿 13%）
            color: started
                ? (theme.brightness == Brightness.light
                    ? const Color(0xFFF0F8F2)
                    : DarkPalette.ok.withValues(alpha: 0.13))
                : theme.colorScheme.surface,
            border: Border.all(
                color: started ? green.withValues(alpha: 0.4) : theme.dividerColor.withValues(alpha: 0.8))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SvgIcon('power', size: 14, color: color),
          const SizedBox(width: 6),
          Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 6),
          // 不带端口：两种状态等宽（端口见 tooltip 与底部状态栏），胶囊宽度稳定，右侧图标不随启停移位
          Text(started ? localizations.statusRunning : localizations.statusStopped,
              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface)),
        ]));
  }

  ///启动代理服务器
  Future<void> start() async {
    try {
      if (!widget.serverLaunch) {
        await widget.onStart?.call();
        _updateStarted(true);
        return;
      }

      widget.proxyServer.start().then((value) {
        if (mounted) {
          _updateStarted(true);
        }
        widget.onStart?.call();
      }).catchError((e) {
        logger.e("启动代理服务器失败", error: e);
        String message = localizations.proxyPortRepeat(widget.proxyServer.port);
        FlutterToastr.show(message, context, duration: 3);
      });
    } finally {
      Future.delayed(const Duration(seconds: 5)).then((value) {
        if (!mounted) {
          return;
        }
        if (Platforms.isDesktop()) {
          PCCertChecker.check(context);
        } else if (Platform.isIOS) {
          IOSCertChecker.check(context);
        }
      });
    }
  }
}
