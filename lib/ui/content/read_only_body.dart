import 'dart:math';

import 'package:code_forge/code_forge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/http/content_type.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/ui/component/search/highlight_text_document.dart';
import 'package:proxypin/ui/component/search/search_controller.dart';
import 'package:proxypin/ui/component/theme_presets.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/utils/highlight_languages.dart';
import 'package:proxypin/utils/platform.dart';
import 'package:scrollable_positioned_list_nic/scrollable_positioned_list_nic.dart';

part 'virtualized_body_text.dart';

class ReadOnlyBody extends StatefulWidget {
  final String text;
  final String? language;
  final TextStyle style;
  final double height;
  final bool virtualized;
  final SearchTextController searchController;
  final ScrollController? scrollController;
  final Widget Function(TextStyle style) fallback;

  const ReadOnlyBody({
    super.key,
    required this.text,
    this.language,
    required this.style,
    required this.height,
    required this.virtualized,
    required this.searchController,
    this.scrollController,
    required this.fallback,
  });

  bool get useCodeForge => !virtualized;
  bool get prepareInBackground => virtualized && text.length >= 16384;

  @override
  State<ReadOnlyBody> createState() => ReadOnlyBodyState();
}

class ReadOnlyBodyState extends State<ReadOnlyBody> {
  CodeForgeController? _editor;
  FindController? _finder;
  Map<String, TextStyle>? _theme;
  _BodyPalette? _palette;
  String? _language;
  var _editorKey = GlobalKey<_CodeBodyEditorState>();
  double _initialScrollOffset = 0;
  bool _restoreFinderFocus = false;
  bool _restoreEditorFocus = false;

  @override
  void initState() {
    super.initState();
    _initializeEditor();
  }

  @override
  void didUpdateWidget(covariant ReadOnlyBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text || widget.useCodeForge != oldWidget.useCodeForge) {
      closeSearch();
      if (widget.useCodeForge) {
        if (_editor == null) {
          _initializeEditor();
        } else {
          _editor!
            ..text = widget.text
            ..setSelectionSilently(const TextSelection.collapsed(offset: 0));
        }
      }
    }
  }

  void _initializeEditor() {
    if (!widget.useCodeForge || _editor != null) return;
    try {
      _editor = _ReadOnlyController()
        ..readOnly = true
        ..text = widget.text
        ..setSelectionSilently(const TextSelection.collapsed(offset: 0));
    } on StateError catch (error, stackTrace) {
      logger.d('Code Forge unavailable for body preview', error: error, stackTrace: stackTrace);
      return;
    }
    _finder = FindController(_editor!);
  }

  bool toggleSearch() {
    final finder = _finder;
    if (!widget.useCodeForge || finder == null) return false;
    finder.toggleActive();
    if (finder.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final field = finder.findInputFocusNode.context;
        if (mounted && finder.isActive && field != null) {
          Scrollable.ensureVisible(field, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
        }
      });
    }
    return true;
  }

  void closeSearch() {
    _finder?.isActive = false;
  }

  @override
  void dispose() {
    final finder = _finder;
    finder?.dispose();
    finder?.findInputFocusNode.dispose();
    finder?.replaceInputFocusNode.dispose();
    _editor?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = widget.useCodeForge ? _editor : null;
    final syntax = codeEditorTheme(context);
    final preference = AppDisplaySettings.of(context)?.editorColorScheme ?? EditorColorScheme.followTheme;
    final colors = Theme.of(context).colorScheme;
    final surface = preference == EditorColorScheme.followTheme
        ? Color.lerp(colors.surface, colors.onSurface, .045)!
        : syntax['root']!.backgroundColor!;
    final paletteChanged = !mapEquals(_theme, syntax) || _palette?.surface != surface;
    if (paletteChanged) {
      _theme = Map.of(syntax);
      _palette = _BodyPalette.fromSyntax(syntax, surface);
    }
    final palette = _palette!;
    if (editor != null && (_language != widget.language || paletteChanged)) {
      final previous = _editorKey.currentState;
      _initialScrollOffset = previous?.scrollOffset ?? 0;
      _restoreFinderFocus = _finder!.findInputFocusNode.hasFocus;
      _restoreEditorFocus = previous?._focus.hasFocus == true && !_restoreFinderFocus;
      _language = widget.language;
      _editorKey = GlobalKey<_CodeBodyEditorState>();
    }

    if (widget.virtualized) {
      return _VirtualizedBodyText(
        text: widget.text,
        language: widget.language,
        style: widget.style,
        height: max(0, widget.height - 8),
        palette: palette,
        prepareInBackground: widget.prepareInBackground,
        searchController: widget.searchController,
        scrollController: widget.scrollController,
        frameBuilder: (context, palette, child) => _buildFrame(palette, _fallbackTheme(context, palette, child)),
      );
    }

    final content = editor == null
        ? _fallbackTheme(
            context,
            palette,
            SizedBox(
              width: double.infinity,
              child: widget.fallback(widget.style.copyWith(color: palette.foreground)),
            ),
          )
        : _CodeBodyEditor(
            key: _editorKey,
            editor: editor,
            finder: _finder!,
            palette: palette,
            language: widget.language,
            style: widget.style,
            height: max(1, widget.height - 8),
            initialScrollOffset: _initialScrollOffset,
            restoreFinderFocus: _restoreFinderFocus,
            restoreEditorFocus: _restoreEditorFocus,
          );
    return _buildFrame(palette, content);
  }

  Widget _fallbackTheme(BuildContext context, _BodyPalette palette, Widget child) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(
          primary: palette.currentMatch,
          onPrimary: palette.foreground,
          inversePrimary: palette.otherMatch,
        ),
        extensions: [
          ...theme.extensions.values.where((extension) => extension is! ActiveThemePreset),
          palette.fallbackPreset,
        ],
        textSelectionTheme: theme.textSelectionTheme.copyWith(selectionColor: palette.selection),
      ),
      child: child,
    );
  }

  Widget _buildFrame(_BodyPalette palette, Widget content) {
    return Material(
      color: palette.surface,
      animationDuration: Duration.zero,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: double.infinity, minHeight: widget.height),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 0, 4),
          child: content,
        ),
      ),
    );
  }
}

class _BodyPalette {
  final Color surface;
  final Color selection;
  final Color currentMatch;
  final Color otherMatch;
  final Map<String, TextStyle> syntax;
  final ActiveThemePreset fallbackPreset;

  _BodyPalette(this.surface, this.selection, this.currentMatch, this.otherMatch, this.syntax)
      : fallbackPreset =
            ActiveThemePreset(_BodySyntaxPreset({...syntax, 'root': TextStyle(color: syntax['root']!.color)}));

  Color get foreground => syntax['root']!.color!;

  factory _BodyPalette.fromSyntax(Map<String, TextStyle> source, Color surface) {
    final root = source['root']!;
    final dark = surface.computeLuminance() < .179;
    final selection = Color.lerp(surface, dark ? const Color(0xff2e4e76) : const Color(0xffe3efff), .82)!;
    final currentMatch = Color.lerp(surface, dark ? const Color(0xff69491d) : const Color(0xffffedaa), .68)!;
    final otherMatch = Color.lerp(surface, currentMatch, .55)!;
    final backgrounds = [surface, selection, currentMatch, otherMatch];

    bool readable(Color color, Color? background) {
      final text = color.computeLuminance();
      return (background == null ? backgrounds : [background]).every((color) {
        final luminance = color.computeLuminance();
        return (max(text, luminance) + .05) / (min(text, luminance) + .05) >= 4.5;
      });
    }

    final foreground = readable(root.color!, null) ? root.color! : (dark ? Colors.white : Colors.black);
    final syntax = <String, TextStyle>{};
    for (final entry in source.entries) {
      final style = entry.value;
      if (entry.key == 'root') {
        syntax[entry.key] = style.copyWith(backgroundColor: surface, color: foreground);
      } else if (style.color == null || readable(style.color!, style.backgroundColor)) {
        syntax[entry.key] = style;
      } else {
        final background = style.backgroundColor;
        syntax[entry.key] = style.copyWith(
          color: readable(foreground, background) || background == null
              ? foreground
              : (background.computeLuminance() < .179 ? Colors.white : Colors.black),
        );
      }
    }
    return _BodyPalette(surface, selection, currentMatch, otherMatch, syntax);
  }
}

class _BodySyntaxPreset extends ThemePreset {
  final Map<String, TextStyle> styles;

  const _BodySyntaxPreset(this.styles);

  @override
  String get name => 'body';

  @override
  String label(Brightness brightness) => name;

  @override
  ColorScheme? colorScheme(Brightness brightness) => null;

  @override
  Color stringColor(Brightness brightness) => styles['string']?.color ?? styles['root']!.color!;

  @override
  Map<String, TextStyle> syntax(Brightness brightness, {ColorScheme? scheme}) => styles;
}

class _ReadOnlyController extends CodeForgeController {
  @override
  void copy() {
    if (selection.isCollapsed) return;
    final content = text;
    final start = CodeForgeController.scalarToUtf16Offset(content, selection.start);
    final end = CodeForgeController.scalarToUtf16Offset(content, selection.end);
    Clipboard.setData(ClipboardData(text: content.substring(start, end)));
  }
}

class _ImmediateScrollController extends ScrollController {
  _ImmediateScrollController({required super.initialScrollOffset});

  @override
  Future<void> animateTo(double offset, {required Duration duration, required Curve curve}) {
    jumpTo(offset.clamp(position.minScrollExtent, position.maxScrollExtent));
    return SynchronousFuture<void>(null);
  }
}

class _CodeBodyEditor extends StatefulWidget {
  final CodeForgeController editor;
  final FindController finder;
  final _BodyPalette palette;
  final String? language;
  final TextStyle style;
  final double height;
  final double initialScrollOffset;
  final bool restoreFinderFocus;
  final bool restoreEditorFocus;

  const _CodeBodyEditor({
    super.key,
    required this.editor,
    required this.finder,
    required this.palette,
    required this.language,
    required this.style,
    required this.height,
    required this.initialScrollOffset,
    required this.restoreFinderFocus,
    required this.restoreEditorFocus,
  });

  @override
  State<_CodeBodyEditor> createState() => _CodeBodyEditorState();
}

class _CodeBodyEditorState extends State<_CodeBodyEditor> {
  final _focus = FocusNode();
  final _editorFocus = FocusNode(canRequestFocus: false);
  late final _vertical = _ImmediateScrollController(initialScrollOffset: widget.initialScrollOffset);
  final _horizontal = ScrollController();

  double get scrollOffset => _vertical.hasClients ? _vertical.offset : 0;

  @override
  void initState() {
    super.initState();
    if (widget.restoreFinderFocus || widget.restoreEditorFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.restoreFinderFocus && widget.finder.isActive) {
          widget.finder.findInputFocusNode.requestFocus();
        } else {
          _focus.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _editorFocus.dispose();
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fontSize = MediaQuery.textScalerOf(context).scale(widget.style.fontSize ?? 14);
    final palette = widget.palette;
    final foreground = palette.foreground;
    final style = widget.style.copyWith(fontSize: fontSize, color: foreground);
    final language = switch (widget.language) {
      'json' => ContentType.json,
      'html' || 'xml' => ContentType.xml,
      'javascript' => ContentType.js,
      'css' => ContentType.css,
      'yaml' => ContentType.yaml,
      _ => null,
    };

    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      return ListenableBuilder(
        listenable: widget.finder,
        child: Focus(
          focusNode: _focus,
          onKeyEvent: (_, event) {
            if (!_focus.hasPrimaryFocus) return KeyEventResult.ignored;
            final keyboard = HardwareKeyboard.instance;
            if ((keyboard.isControlPressed || keyboard.isMetaPressed) &&
                (event.logicalKey == LogicalKeyboardKey.keyF || event.logicalKey == LogicalKeyboardKey.keyH)) {
              return KeyEventResult.ignored;
            }
            return _editorFocus.onKeyEvent?.call(_editorFocus, event) ?? KeyEventResult.ignored;
          },
          child: Listener(
            onPointerDown: (_) => _focus.requestFocus(),
            child: CodeForge(
              controller: widget.editor,
              findController: widget.finder,
              finderBuilder: (context, finder) => _ReadOnlyFinder(
                controller: finder,
                width: width,
                onClose: () {
                  finder.isActive = false;
                  _focus.requestFocus();
                },
              ),
              readOnly: true,
              autoFocus: true,
              focusNode: _editorFocus,
              verticalScrollController: _vertical,
              horizontalScrollController: _horizontal,
              lineWrap: true,
              innerPadding: EdgeInsets.zero,
              enableFolding: false,
              enableGutter: false,
              enableGuideLines: false,
              language: language == null ? null : HighlightLanguages.getLanguage(language),
              editorTheme: palette.syntax,
              textStyle: style,
              selectionStyle: CodeSelectionStyle(
                cursorColor: foreground,
                selectionColor: palette.selection,
                cursorBubbleColor: foreground,
              ),
              matchHighlightStyle: MatchHighlightStyle(
                currentMatchStyle: TextStyle(backgroundColor: palette.currentMatch),
                otherMatchStyle: TextStyle(backgroundColor: palette.otherMatch),
              ),
              scrollbarDecoration: ScrollbarDecoration(thickness: 6, thumbColor: foreground.withValues(alpha: .45)),
            ),
          ),
        ),
        builder: (context, child) => SizedBox(
          height: widget.height + (widget.finder.isActive ? _ReadOnlyFinder.height(width) : 0),
          width: width,
          child: child,
        ),
      );
    });
  }
}

class _ReadOnlyFinder extends StatelessWidget implements PreferredSizeWidget {
  final FindController controller;
  final double width;
  final VoidCallback onClose;

  const _ReadOnlyFinder({required this.controller, required this.width, required this.onClose});

  static const _actionSize = 28.0;
  static const _actionCount = 6;
  static const _inlineWidth = 285.0;
  static double height(double width) {
    if (width >= _inlineWidth) return 36;
    final perRow = max(1, width ~/ _actionSize);
    return 36 + (_actionCount / perRow).ceil() * _actionSize;
  }

  @override
  Size get preferredSize => Size.fromHeight(height(width));

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final field = SizedBox(
      height: 32,
      child: TextField(
        controller: controller.findInputController,
        focusNode: controller.findInputFocusNode,
        textInputAction: TextInputAction.search,
        onEditingComplete: controller.next,
        decoration: InputDecoration(
          hintText: localizations.search,
          isDense: true,
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        ),
      ),
    );
    final actions = Wrap(
      children: [
        _action(
          tooltip: 'Match case',
          label: Text('Aa', style: TextStyle(fontWeight: controller.caseSensitive ? FontWeight.bold : null)),
          onPressed: controller.toggleCaseSensitive,
        ),
        _action(
          tooltip: 'Regular expression',
          label: Text('.*', style: TextStyle(fontWeight: controller.isRegex ? FontWeight.bold : null)),
          onPressed: controller.toggleRegex,
        ),
        SizedBox.square(
          dimension: _actionSize,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('${controller.currentMatchIndex + 1}/${controller.matchCount}'),
            ),
          ),
        ),
        _action(
          tooltip: 'Previous',
          label: const Icon(Icons.arrow_upward, size: 16),
          onPressed: controller.matchCount == 0 ? null : controller.previous,
        ),
        _action(
          tooltip: 'Next',
          label: const Icon(Icons.arrow_downward, size: 16),
          onPressed: controller.matchCount == 0 ? null : controller.next,
        ),
        _action(tooltip: localizations.close, label: const Icon(Icons.close, size: 16), onPressed: onClose),
      ],
    );

    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
        onClose();
        return KeyEventResult.handled;
      },
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: preferredSize.height,
          child: width < _inlineWidth
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [field, actions],
                )
              : Row(children: [Expanded(child: field), const SizedBox(width: 4), actions]),
        ),
      ),
    );
  }

  Widget _action({required String tooltip, required Widget label, required VoidCallback? onPressed}) {
    return SizedBox.square(
      dimension: _actionSize,
      child: IconButton(
        tooltip: tooltip,
        icon: label,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
      ),
    );
  }
}
