import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

class WindowsToolbar extends StatefulWidget {
  final Widget? title;
  final double iconSize;

  const WindowsToolbar({
    super.key,
    this.title,
    this.iconSize = 32,
  });

  @override
  State<WindowsToolbar> createState() => _WindowsToolbarState();
}

class _WindowsToolbarState extends State<WindowsToolbar> with WindowListener {
  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 7),
        Padding(
            padding: EdgeInsets.only(top: 2),
            child: Center(
                child: Image.asset(
              'assets/icon_foreground.png',
              width: widget.iconSize,
            ))),
        Expanded(child: _ToolbarDragArea(child: widget.title ?? const SizedBox())),
        WindowCaptionButton.minimize(
            brightness: Theme.brightnessOf(context),
            onPressed: () async {
              bool isMinimized = await windowManager.isMinimized();
              if (isMinimized) {
                windowManager.restore();
              } else {
                windowManager.minimize();
              }
            }),
        FutureBuilder<bool>(
            future: windowManager.isMaximized(),
            builder: (BuildContext context, AsyncSnapshot<bool> snapshot) {
              if (snapshot.data == true) {
                return WindowCaptionButton.unmaximize(
                  brightness: Theme.brightnessOf(context),
                  onPressed: () {
                    windowManager.unmaximize();
                  },
                );
              }
              return WindowCaptionButton.maximize(
                brightness: Theme.brightnessOf(context),
                onPressed: () {
                  windowManager.maximize();
                },
              );
            }),
        WindowCaptionButton.close(
            brightness: Theme.brightnessOf(context),
            onPressed: () {
              windowManager.close();
            }),
      ],
    );
  }

  @override
  void onWindowMaximize() {
    setState(() {});
  }

  @override
  void onWindowUnmaximize() {
    setState(() {});
  }
}

class _ToolbarDragArea extends StatefulWidget {
  final Widget child;

  const _ToolbarDragArea({required this.child});

  @override
  State<_ToolbarDragArea> createState() => _ToolbarDragAreaState();
}

class _ToolbarDragAreaState extends State<_ToolbarDragArea> {
  DoubleTapGestureRecognizer? _blankDoubleTap;
  int? _blankPointer;

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_observePointerDown);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_observePointerDown);
    _blankDoubleTap?.dispose();
    super.dispose();
  }

  void _observePointerDown(PointerEvent event) {
    if (event is! PointerDownEvent) {
      return;
    }
    if (event.pointer != _blankPointer) {
      _blankDoubleTap?.dispose();
      _blankDoubleTap = null;
    }
    _blankPointer = null;
  }

  void _trackBlankPointer(PointerDownEvent event) {
    _blankPointer = event.pointer;
    final recognizer = _blankDoubleTap ??= DoubleTapGestureRecognizer(debugOwner: this);
    recognizer
      ..onDoubleTap = _toggleMaximize
      ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
      ..addPointer(event);
  }

  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      gestures: {
        _WindowDragRecognizer: GestureRecognizerFactoryWithHandlers<_WindowDragRecognizer>(
          _WindowDragRecognizer.new,
          (recognizer) {
            recognizer
              ..onlyAcceptDragOnThreshold = true
              ..onStart = (_) => windowManager.startDragging();
          },
        ),
      },
      child: Stack(children: [
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _trackBlankPointer,
          ),
        ),
        Align(alignment: AlignmentDirectional.centerStart, child: widget.child),
      ]),
    );
  }
}

class _WindowDragRecognizer extends PanGestureRecognizer {
  static const double _mouseDragThreshold = 8;

  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) {
    if (pointerDeviceKind == PointerDeviceKind.mouse) {
      return globalDistanceMoved.abs() > _mouseDragThreshold;
    }
    return super.hasSufficientGlobalDistanceToAccept(pointerDeviceKind, deviceTouchSlop);
  }
}
