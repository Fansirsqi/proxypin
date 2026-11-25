import 'dart:math' as math;

import 'package:code_forge/code_forge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:proxypin/ui/component/theme_presets.dart';
import 'package:re_highlight/re_highlight.dart';

enum EditorDiffSide {
  deletion(Colors.red),
  insertion(Colors.green);

  const EditorDiffSide(this.gutterColor);

  final Color gutterColor;

  Color get lineColor => gutterColor.withValues(alpha: .18);

  List<Color> _lineColors(bool lightText) => [
        lineColor,
        ...switch ((this, lightText)) {
          (deletion, true) => const [Color(0x59572735), Color(0x59AC426C), Color(0x59260C14)],
          (deletion, false) => const [Color(0x4DFFABC1), Color(0x52F6608C), Color(0x52FFE1EA)],
          (insertion, true) => const [Color(0x59133C2C), Color(0x59197452), Color(0x73092013), Color(0x75266335)],
          (insertion, false) => const [Color(0x4DB4EABB), Color(0x526FCA84), Color(0x52E4FCE2)],
        },
      ];

  List<Color> _characterColors(bool lightText) => switch ((this, lightText)) {
        (deletion, true) => const [Color(0xFF64313C), Color(0xFF822D53), Color(0xFF45202D)],
        (deletion, false) => const [Color(0xFFF7BEC5), Color(0xFFFF9AB8), Color(0xFFFFE0E8)],
        (insertion, true) => const [Color(0xFF244D37), Color(0xFF146345), Color(0xFF143D30), Color(0xFF3C6530)],
        (insertion, false) => const [Color(0xFFB6E3BA), Color(0xFF95D796), Color(0xFFD6F6D8)],
      };
}

class ThemedCodeEditor extends StatefulWidget {
  const ThemedCodeEditor({
    super.key,
    required this.controller,
    this.language,
    this.findController,
    this.finderBuilder,
    this.textStyle,
    this.diffSide,
    this.onDiffLineColorChanged,
    this.lineWrap = false,
    this.autoFocus = false,
    this.readOnly,
  });

  final CodeForgeController controller;
  final Mode? language;
  final FindController? findController;
  final PreferredSizeWidget Function(BuildContext, FindController)? finderBuilder;
  final TextStyle? textStyle;
  final EditorDiffSide? diffSide;
  final ValueChanged<Color>? onDiffLineColorChanged;
  final bool lineWrap;
  final bool autoFocus;
  final bool? readOnly;

  @override
  State<ThemedCodeEditor> createState() => _ThemedCodeEditorState();
}

class _ThemedCodeEditorState extends State<ThemedCodeEditor> {
  final _undoController = UndoRedoController();
  FindController? _ownedFinder;
  var _viewport = _EditorViewport();
  _EditorPalette? _palette;
  bool _remount = false;
  bool _themeChangePending = false;
  bool _waitingForUnmount = false;
  late bool _editorAutoFocus;

  FindController get _finder => widget.findController ?? (_ownedFinder ??= FindController(widget.controller));

  @override
  void initState() {
    super.initState();
    _editorAutoFocus = widget.autoFocus;
    if (widget.readOnly case final readOnly?) widget.controller.readOnly = readOnly;
  }

  @override
  void didUpdateWidget(covariant ThemedCodeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller || oldWidget.findController != widget.findController) {
      _remount = true;
      final oldFinder = _ownedFinder;
      _ownedFinder = null;
      if (oldFinder != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _disposeFinder(oldFinder));
      }
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.setUndoController(null);
      _undoController.clear();
    }
    if (oldWidget.controller != widget.controller || oldWidget.readOnly != widget.readOnly) {
      if (widget.readOnly case final readOnly?) widget.controller.readOnly = readOnly;
    }
    if (oldWidget.language != widget.language ||
        oldWidget.readOnly != widget.readOnly ||
        oldWidget.diffSide != widget.diffSide) {
      _remount = true;
    }
  }

  void _remountEditor(FindController finder) {
    _waitingForUnmount = true;
    final previous = _viewport;
    _editorAutoFocus = previous.focus.hasFocus;
    final findFocused = finder.findInputFocusNode.hasFocus;
    final replaceFocused = finder.replaceInputFocusNode.hasFocus;
    _viewport = _EditorViewport(
      horizontalOffset: previous.horizontal.hasClients ? previous.horizontal.offset : 0,
      verticalOffset: previous.vertical.hasClients ? previous.vertical.offset : 0,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      previous.dispose();
      if (!mounted) return;
      setState(() => _waitingForUnmount = false);
      if (findFocused || replaceFocused) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !identical(finder, _finder)) return;
          (findFocused ? finder.findInputFocusNode : finder.replaceInputFocusNode).requestFocus();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final syntax = codeEditorTheme(context);
    if (_waitingForUnmount) return const SizedBox.expand();

    final finder = _finder;
    _themeChangePending = _palette != null && !mapEquals(_palette!.sourceSyntax, syntax);
    if (_remount || (_themeChangePending && !_viewport.isScrolling)) {
      _remount = false;
      _themeChangePending = false;
      _palette = null;
      _remountEditor(finder);
      return const SizedBox.expand();
    }
    final palette = _palette ??= _createPalette(syntax);
    final foreground = palette.syntax['root']!.color!;
    return NotificationListener<ScrollEndNotification>(
      onNotification: (_) {
        if (_themeChangePending) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }
        return false;
      },
      child: CodeForge(
        controller: widget.controller,
        undoController: _undoController,
        findController: finder,
        focusNode: _viewport.focus,
        horizontalScrollController: _viewport.horizontal,
        verticalScrollController: _viewport.vertical,
        editorTheme: palette.syntax,
        language: widget.language,
        finderBuilder: widget.finderBuilder,
        textStyle: palette.readableTextStyle(widget.textStyle),
        selectionStyle: CodeSelectionStyle(
          cursorColor: foreground,
          cursorBubbleColor: foreground,
          selectionColor: palette.selection,
        ),
        matchHighlightStyle: palette.matches,
        lineWrap: widget.lineWrap,
        autoFocus: _editorAutoFocus,
        readOnly: widget.readOnly ?? widget.controller.readOnly,
        enableGuideLines: false,
      ),
    );
  }

  _EditorPalette _createPalette(Map<String, TextStyle> syntax) {
    final palette = _EditorPalette(syntax, widget.diffSide);
    if (palette.overlays.line case final line?) widget.onDiffLineColorChanged?.call(line);
    return palette;
  }

  void _disposeFinder(FindController finder) {
    finder.dispose();
    finder.findInputFocusNode.dispose();
    finder.replaceInputFocusNode.dispose();
  }

  @override
  void dispose() {
    widget.controller.setUndoController(null);
    _undoController.dispose();
    if (_ownedFinder case final finder?) _disposeFinder(finder);
    _viewport.dispose();
    super.dispose();
  }
}

class _EditorPalette {
  _EditorPalette(this.sourceSyntax, EditorDiffSide? diffSide) {
    final surface = sourceSyntax['root']!.backgroundColor!;
    _lightText = _prefersLightText(surface.computeLuminance());
    overlays = _resolveOverlays(surface, diffSide, _lightText);
    matches = MatchHighlightStyle(
      currentMatchStyle: TextStyle(backgroundColor: overlays.current),
      otherMatchStyle: TextStyle(backgroundColor: overlays.other),
    );

    final line = overlays.line;
    final beforeSelection = [
      for (final background in [surface, overlays.current, overlays.other]) ...[
        background,
        if (line != null) Color.alphaBlend(line, background),
      ],
    ];
    _limitingLuminance = beforeSelection
        .expand((background) => [background, Color.alphaBlend(selection, background)])
        .map((background) => background.computeLuminance())
        .reduce(_lightText ? math.max : math.min);

    syntax = {
      for (final entry in sourceSyntax.entries)
        entry.key: readableTextStyle(entry.value, paintsBackground: entry.key != 'root')!,
    };
  }

  final Map<String, TextStyle> sourceSyntax;
  late final Map<String, TextStyle> syntax;
  late final _EditorOverlays overlays;
  Color get selection => overlays.selection;
  late final MatchHighlightStyle matches;
  late final bool _lightText;
  late final double _limitingLuminance;

  static const _contrastTarget = 4.55;

  static bool _prefersLightText(double luminance) => luminance + .05 < math.sqrt(1.05 * .05);

  TextStyle? readableTextStyle(TextStyle? style, {bool paintsBackground = false}) {
    final color = style?.color;
    if (color == null) return style;
    final tokenLuminance = paintsBackground ? style!.backgroundColor?.computeLuminance() : null;
    final luminance = tokenLuminance ?? _limitingLuminance;
    final lightText = tokenLuminance == null ? _lightText : _prefersLightText(tokenLuminance);
    final requiredLuminance =
        lightText ? (luminance + .05) * _contrastTarget - .05 : (luminance + .05) / _contrastTarget - .05;
    bool readable(Color candidate) {
      final value = candidate.computeLuminance();
      return lightText ? value >= requiredLuminance : value <= requiredLuminance;
    }

    if (readable(color)) return style;
    final target = lightText ? Colors.white : Colors.black;
    var lower = 0.0;
    var upper = 1.0;
    for (var step = 0; step < 10; step++) {
      final weight = (lower + upper) / 2;
      if (readable(Color.lerp(color, target, weight)!)) {
        upper = weight;
      } else {
        lower = weight;
      }
    }
    return style!.copyWith(color: Color.lerp(color, target, upper));
  }

  static _EditorOverlays _resolveOverlays(Color surface, EditorDiffSide? side, bool lightText) {
    final lines = side?._lineColors(lightText) ?? const <Color?>[null];
    final selections = lightText
        ? const [Color(0x8036539B), Color(0x731B2475), Color(0x665056A3), Color(0x7011173F)]
        : const [Color(0x705993EF), Color(0x70B9CEFF), Color(0x66ABDFFF), Color(0x6B7186DB)];
    final currentMatches = lightText
        ? const [Color(0xFF5B431E), Color(0xFF775012), Color(0xFF3C2811), Color(0xFF856634)]
        : const [Color(0xFFFFD487), Color(0xFFFFBC56), Color(0xFFFFF18A)];
    final otherMatches = side?._characterColors(lightText) ??
        (lightText
            ? const [Color(0xFF41341F), Color(0xFF605132), Color(0xFF2D230B)]
            : const [Color(0xFFFFEBC1), Color(0xFFF5DE9A), Color(0xFFFBF2D8)]);

    bool readable(Color color) {
      final luminance = color.computeLuminance() + .05;
      return (lightText ? 1.05 / luminance : luminance / .05) >= _contrastTarget;
    }

    for (final line in lines) {
      final baseWithLine = line == null ? surface : Color.alphaBlend(line, surface);
      if (line != null && (!_distinct(surface, baseWithLine) || !readable(baseWithLine))) continue;

      for (final selection in selections) {
        List<Color> backgrounds(Color color) {
          final withLine = line == null ? color : Color.alphaBlend(line, color);
          return [
            color,
            Color.alphaBlend(selection, color),
            if (line != null) ...[withLine, Color.alphaBlend(selection, withLine)],
          ];
        }

        bool usable(List<Color> layers) =>
            layers.every(readable) &&
            _distinct(layers[0], layers[1]) &&
            (line == null || _distinct(layers[2], layers[3]));

        final base = backgrounds(surface);
        if (!usable(base)) continue;

        for (final other in otherMatches) {
          final inactive = backgrounds(other);
          if (!usable(inactive) || !_distinctLayers(inactive, base)) continue;

          for (final current in currentMatches) {
            final active = backgrounds(current);
            if (usable(active) && _distinctLayers(active, base) && _distinctLayers(active, inactive)) {
              return (line: line, selection: selection, current: current, other: other);
            }
          }
        }
      }
    }

    return (
      line: lines.last,
      selection: selections[1],
      current: currentMatches.last,
      other: otherMatches.last,
    );
  }

  static bool _distinctLayers(List<Color> first, List<Color> second) {
    for (var index = 0; index < first.length; index++) {
      if (!_distinct(first[index], second[index])) return false;
    }
    return true;
  }

  static bool _distinct(Color first, Color second) {
    final red = first.r - second.r;
    final green = first.g - second.g;
    final blue = first.b - second.b;
    return red * red + green * green + blue * blue >= .05 * .05;
  }
}

typedef _EditorOverlays = ({Color? line, Color selection, Color current, Color other});

class _EditorViewport {
  _EditorViewport({double horizontalOffset = 0, double verticalOffset = 0})
      : horizontal = ScrollController(initialScrollOffset: horizontalOffset, keepScrollOffset: false),
        vertical = ScrollController(initialScrollOffset: verticalOffset, keepScrollOffset: false);

  final focus = FocusNode();
  final ScrollController horizontal;
  final ScrollController vertical;

  bool get isScrolling => vertical.positions.any((position) => position.isScrollingNotifier.value);

  void dispose() {
    focus.dispose();
    horizontal.dispose();
    vertical.dispose();
  }
}
