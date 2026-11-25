import 'dart:math' as math;

import 'package:flutter/material.dart';

class FloatingDialog extends Dialog {
  const FloatingDialog({
    super.key,
    super.backgroundColor,
    super.insetPadding,
    super.clipBehavior,
    super.shape,
    super.child,
    this.contentMinSize,
  });

  final Size? contentMinSize;

  @override
  Widget build(BuildContext context) {
    return _usesFloatingFrame(context)
        ? _FloatingFrame(dialog: this, contentMinSize: contentMinSize)
        : super.build(context);
  }
}

class FloatingAlertDialog extends AlertDialog {
  const FloatingAlertDialog({
    super.key,
    super.icon,
    super.title,
    super.titlePadding,
    super.content,
    super.contentPadding,
    super.actions,
    super.actionsPadding,
    super.actionsAlignment,
    super.backgroundColor,
    super.elevation,
    super.insetPadding,
    super.clipBehavior,
    super.shape,
    super.alignment,
    super.constraints,
    super.scrollable,
  });

  @override
  Widget build(BuildContext context) {
    final built = super.build(context);
    return _usesFloatingFrame(context) && built is Dialog ? _FloatingFrame(dialog: built) : built;
  }
}

class FloatingSimpleDialog extends SimpleDialog {
  const FloatingSimpleDialog({
    super.key,
    super.title,
    super.titlePadding,
    super.children,
    super.contentPadding,
    super.backgroundColor,
    super.shape,
    super.alignment,
  });

  @override
  Widget build(BuildContext context) {
    final built = super.build(context);
    return _usesFloatingFrame(context) && built is Dialog ? _FloatingFrame(dialog: built) : built;
  }
}

bool _usesFloatingFrame(BuildContext context) => switch (Theme.of(context).platform) {
      TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows => true,
      _ => false,
    };

class _FloatingFrame extends StatefulWidget {
  const _FloatingFrame({required this.dialog, this.contentMinSize});

  final Dialog dialog;
  final Size? contentMinSize;

  @override
  State<_FloatingFrame> createState() => _FloatingFrameState();
}

class _FloatingFrameState extends State<_FloatingFrame> {
  static const _edge = 6.0;
  static const _captionHeight = 24.0;

  final _viewportKey = GlobalKey();
  final _surfaceKey = GlobalKey();
  final _contentKey = GlobalKey();
  Offset? _position;
  Size? _requestedSize;
  Size? _contentFloor;
  Rect? _dragStart;
  Offset? _pointerStart;

  RenderBox get _viewport => _viewportKey.currentContext!.findRenderObject()! as RenderBox;

  void _startDrag(DragStartDetails details, {required bool resizing}) {
    final surface = _surfaceKey.currentContext!.findRenderObject()! as RenderBox;
    _dragStart = surface.localToGlobal(Offset.zero, ancestor: _viewport) & surface.size;
    _pointerStart = _viewport.globalToLocal(details.globalPosition);
    if (resizing) {
      _contentFloor ??= widget.contentMinSize ?? _contentKey.currentContext!.size!;
    }
  }

  void _updateDrag(DragUpdateDetails details, int horizontal, int vertical) {
    final start = _dragStart!;
    final delta = _viewport.globalToLocal(details.globalPosition) - _pointerStart!;
    final viewport = _viewport.size;
    if (horizontal == 0 && vertical == 0) {
      setState(() => _position = start.topLeft + delta);
      return;
    }

    final width = horizontal == 0
        ? start.width
        : _resizeExtent(
            start.width, delta.dx * horizontal, 220, horizontal < 0 ? start.right : viewport.width - start.left);
    final height = vertical == 0
        ? start.height
        : _resizeExtent(
            start.height, delta.dy * vertical, 120, vertical < 0 ? start.bottom : viewport.height - start.top);
    setState(() {
      _position =
          Offset(horizontal < 0 ? start.right - width : start.left, vertical < 0 ? start.bottom - height : start.top);
      _requestedSize = Size(width, height);
    });
  }

  double _resizeExtent(double start, double delta, double minimum, double available) {
    final maxExtent = math.max(0.0, available);
    return (start + delta).clamp(math.min(math.min(minimum, start), maxExtent), maxExtent);
  }

  Widget _dragTarget(Widget child, MouseCursor cursor, {int horizontal = 0, int vertical = 0}) {
    return TextFieldTapRegion(
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) => _startDrag(details, resizing: horizontal != 0 || vertical != 0),
          onPanUpdate: (details) => _updateDrag(details, horizontal, vertical),
          child: child,
        ),
      ),
    );
  }

  Widget _resizeTarget(int horizontal, int vertical, MouseCursor cursor) {
    const corner = _edge * 2;
    final isCorner = horizontal != 0 && vertical != 0;
    final inset = isCorner ? 0.0 : corner;
    return Positioned(
      left: horizontal <= 0 ? (horizontal < 0 ? 0 : inset) : null,
      right: horizontal >= 0 ? (horizontal > 0 ? 0 : inset) : null,
      top: vertical <= 0 ? (vertical < 0 ? 0 : inset) : null,
      bottom: vertical >= 0 ? (vertical > 0 ? 0 : inset) : null,
      width: horizontal == 0 ? null : (isCorner ? corner : _edge),
      height: vertical == 0 ? null : (isCorner ? corner : _edge),
      child: _dragTarget(const SizedBox.expand(), cursor, horizontal: horizontal, vertical: vertical),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dialog = widget.dialog;
    final theme = Theme.of(context);
    final dialogTheme = DialogTheme.of(context);
    final colors = theme.colorScheme;
    final insets =
        dialog.insetPadding ?? dialogTheme.insetPadding ?? const EdgeInsets.symmetric(horizontal: 40, vertical: 24);
    final content = dialog.child ?? const SizedBox.shrink();

    return Padding(
      padding: insets + MediaQuery.viewInsetsOf(context),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeTop: true,
        removeRight: true,
        removeBottom: true,
        removeLeft: true,
        child: CustomSingleChildLayout(
          key: _viewportKey,
          delegate: _FloatingLayout(
            position: _position,
            requestedSize: _requestedSize,
            alignment:
                (dialog.alignment ?? dialogTheme.alignment ?? Alignment.center).resolve(Directionality.of(context)),
          ),
          child: Semantics(
            role: dialog.semanticsRole,
            child: Material(
              key: _surfaceKey,
              type: MaterialType.card,
              color: dialog.backgroundColor ?? dialogTheme.backgroundColor ?? colors.surfaceContainerHigh,
              elevation: dialog.elevation ?? dialogTheme.elevation ?? 6.0,
              shadowColor: dialog.shadowColor ?? dialogTheme.shadowColor ?? theme.shadowColor,
              surfaceTintColor: dialog.surfaceTintColor ?? dialogTheme.surfaceTintColor,
              shape: dialog.shape ??
                  dialogTheme.shape ??
                  const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
              clipBehavior: dialog.clipBehavior ?? dialogTheme.clipBehavior ?? Clip.antiAlias,
              child: Stack(
                fit: StackFit.passthrough,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(_edge, _edge + _captionHeight, _edge, _edge),
                    child: LayoutBuilder(
                      builder: (context, bounds) {
                        final floor = _contentFloor;
                        final constraints = _requestedSize == null
                            ? (dialog.constraints ?? dialogTheme.constraints ?? const BoxConstraints(minWidth: 280))
                                .enforce(bounds)
                            : BoxConstraints.tight(Size(
                                math.max(bounds.maxWidth, floor!.width),
                                math.max(bounds.maxHeight, floor.height),
                              ));
                        return SingleChildScrollView(
                          primary: false,
                          child: SingleChildScrollView(
                            primary: false,
                            scrollDirection: Axis.horizontal,
                            child: ConstrainedBox(key: _contentKey, constraints: constraints, child: content),
                          ),
                        );
                      },
                    ),
                  ),
                  Positioned(
                    top: _edge,
                    left: _edge,
                    right: _edge,
                    child: _dragTarget(
                      SizedBox(
                        key: const ValueKey('floating-dialog-caption'),
                        height: _captionHeight,
                        child: Icon(Icons.drag_handle, size: 20, color: colors.onSurfaceVariant),
                      ),
                      SystemMouseCursors.move,
                    ),
                  ),
                  _resizeTarget(0, -1, SystemMouseCursors.resizeUpDown),
                  _resizeTarget(0, 1, SystemMouseCursors.resizeUpDown),
                  _resizeTarget(-1, 0, SystemMouseCursors.resizeLeftRight),
                  _resizeTarget(1, 0, SystemMouseCursors.resizeLeftRight),
                  _resizeTarget(-1, -1, SystemMouseCursors.resizeUpLeftDownRight),
                  _resizeTarget(1, -1, SystemMouseCursors.resizeUpRightDownLeft),
                  _resizeTarget(-1, 1, SystemMouseCursors.resizeUpRightDownLeft),
                  _resizeTarget(1, 1, SystemMouseCursors.resizeUpLeftDownRight),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingLayout extends SingleChildLayoutDelegate {
  const _FloatingLayout({required this.position, required this.requestedSize, required this.alignment});

  final Offset? position;
  final Size? requestedSize;
  final Alignment alignment;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final requested = requestedSize;
    return requested == null ? constraints.loosen() : BoxConstraints.tight(constraints.loosen().constrain(requested));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final remaining = Offset(size.width - childSize.width, size.height - childSize.height);
    final target = position ?? alignment.alongOffset(remaining);
    return Offset(target.dx.clamp(0, remaining.dx), target.dy.clamp(0, remaining.dy));
  }

  @override
  bool shouldRelayout(_FloatingLayout oldDelegate) =>
      position != oldDelegate.position ||
      requestedSize != oldDelegate.requestedSize ||
      alignment != oldDelegate.alignment;
}
