import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/desktop/widgets/windows_toolbar.dart';
import 'package:window_manager/window_manager.dart';

class IndependentWindowFrame extends StatefulWidget {
  final String? toolTitle;
  final Widget child;

  const IndependentWindowFrame({super.key, this.toolTitle, required this.child});

  @override
  State<IndependentWindowFrame> createState() => _IndependentWindowFrameState();
}

class _IndependentWindowFrameState extends State<IndependentWindowFrame> {
  Brightness? _brightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.brightnessOf(context);
    if (_brightness == brightness) return;
    _brightness = brightness;
    if (!Platform.isLinux || widget.toolTitle != null) {
      unawaited(_updateNativeBrightness(brightness));
    }
  }

  Future<void> _updateNativeBrightness(Brightness brightness) async {
    try {
      await windowManager.setBrightness(brightness);
    } catch (error, stackTrace) {
      logger.w('Could not update the native child window brightness', error: error, stackTrace: stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget content = widget.child;
    if (widget.toolTitle case final title?) {
      content = Column(children: [
        Material(
          color: desktopChromeColor(theme),
          child: SizedBox(
            height: 38,
            child: WindowsToolbar(
              iconSize: 24,
              title: Padding(
                padding: const EdgeInsets.only(left: 5),
                child: Text(title, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
        ),
        Divider(height: 1, color: chromeBorderColor(theme)),
        Expanded(child: content),
      ]);
    }

    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(color: Color.lerp(chromeBorderColor(theme), theme.colorScheme.outline, 0.45)!),
      ),
      child: content,
    );
  }
}
