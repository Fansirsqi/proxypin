import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:highlight/highlight.dart' show Node, highlight;
import 'package:proxypin/ui/component/theme_presets.dart';

import 'search_controller.dart';

export 'preview_task.dart' show PreviewTask;

typedef HighlightDocumentInput = ({
  String text,
  String? language,
  TextStyle? style,
  Brightness brightness,
  ThemePreset preset,
  SearchSettings? search,
});

bool revealHighlightOffset(BuildContext context, int offset) {
  if (!context.mounted) return false;
  RenderParagraph? findParagraph(RenderObject? object) {
    if (object is RenderParagraph) return object;
    RenderParagraph? result;
    object?.visitChildren((child) => result ??= findParagraph(child));
    return result;
  }

  final paragraph = findParagraph(context.findRenderObject());
  if (paragraph == null || !paragraph.attached || !paragraph.hasSize) return false;
  final viewport = RenderAbstractViewport.maybeOf(paragraph);
  final scroll = Scrollable.maybeOf(context)?.position;
  if (viewport == null || scroll == null || !scroll.hasContentDimensions) return false;

  final position = TextPosition(offset: offset);
  final caret = paragraph.getOffsetForCaret(position, Rect.zero);
  final range = Rect.fromLTWH(caret.dx, caret.dy, 1, paragraph.getFullHeightForCaret(position));
  final visible = viewport.paintBounds;
  final laidOut = MatrixUtils.transformRect(paragraph.getTransformTo(viewport), range);
  if (laidOut.top < visible.top || laidOut.bottom > visible.bottom) {
    final target =
        (scroll.pixels + laidOut.center.dy - visible.center.dy).clamp(scroll.minScrollExtent, scroll.maxScrollExtent);
    if (target != scroll.pixels) scroll.jumpTo(target);
  }
  return true;
}

class HighlightTextDocument {
  final String text;
  final TextStyle? rootStyle;
  final List<HighlightStyledSegment> segments;
  final List<HighlightSearchMatch> matches;
  final List<HighlightDocumentLine> lines;
  final int currentMatchIndex;

  const HighlightTextDocument._({
    required this.text,
    required this.rootStyle,
    required this.segments,
    required this.matches,
    required this.lines,
    required this.currentMatchIndex,
  });

  factory HighlightTextDocument.create(
    BuildContext context, {
    required String text,
    String? language,
    TextStyle? style,
    required SearchTextController searchController,
  }) =>
      HighlightTextDocument.prepare((
        text: text,
        language: language,
        style: style,
        brightness: Theme.brightnessOf(context),
        preset: ActiveThemePreset.of(context),
        search: searchController.shouldSearch() ? searchController.value : null,
      ));

  factory HighlightTextDocument.prepare(HighlightDocumentInput input) {
    final theme = input.preset.syntax(input.brightness);
    final defaultStyle = theme['root'] ?? const TextStyle(fontFamily: 'monospace', fontSize: 14.5);
    final rootStyle = _stripBackground(defaultStyle.merge(input.style));
    final baseStyle = input.preset == ThemePreset.custom ? input.style : rootStyle;
    final segments = _buildHighlightBaseSegments(input.text, input.language, baseStyle, theme);
    final document = HighlightTextDocument._(
      text: input.text,
      rootStyle: rootStyle,
      segments: segments,
      matches: const [],
      lines: buildHighlightDocumentLines(segments),
      currentMatchIndex: -1,
    );
    final search = input.search;
    return search == null
        ? document
        : document.withMatches(findHighlightMatches((input.text, search)), search.currentMatchIndex);
  }

  HighlightTextDocument withMatches(List<HighlightSearchMatch> matches, [int currentMatch = 0]) =>
      HighlightTextDocument._(
        text: text,
        rootStyle: rootStyle,
        segments: segments,
        lines: lines,
        matches: matches,
        currentMatchIndex: matches.isEmpty ? -1 : currentMatch.clamp(0, matches.length - 1),
      );

  int get totalMatchCount => matches.length;

  int? lineIndexForMatch(int matchIndex) {
    if (matchIndex < 0 || matchIndex >= matches.length) {
      return null;
    }
    final start = matches[matchIndex].start;
    var lower = 0;
    var upper = lines.length - 1;
    while (lower < upper) {
      final mid = (lower + upper + 1) ~/ 2;
      if (lines[mid].start <= start) {
        lower = mid;
      } else {
        upper = mid - 1;
      }
    }
    return lower;
  }

  int _firstMatchAfter(int offset) {
    var lower = 0;
    var upper = matches.length;
    while (lower < upper) {
      final mid = (lower + upper) ~/ 2;
      if (matches[mid].end <= offset) {
        lower = mid + 1;
      } else {
        upper = mid;
      }
    }
    return lower;
  }

  List<InlineSpan> buildAllSpans(BuildContext context) {
    final spans = <InlineSpan>[];
    for (var i = 0; i < lines.length; i++) {
      spans.addAll(buildSpansForLine(context, i));
      if (i != lines.length - 1) {
        spans.add(TextSpan(text: '\n', style: rootStyle));
      }
    }
    return spans;
  }

  List<InlineSpan> buildSpansForLine(BuildContext context, int lineIndex, {int? currentMatchIndexOverride}) {
    final line = lines[lineIndex];
    var matchIndex = _firstMatchAfter(line.start);
    if (matchIndex == matches.length || matches[matchIndex].start >= line.end) {
      return _plainLineSpans(line);
    }

    final spans = <InlineSpan>[];
    final colorScheme = ColorScheme.of(context);
    final effectiveCurrentMatchIndex = currentMatchIndexOverride ?? currentMatchIndex;
    var consumed = 0;

    for (final segment in line.segments) {
      final segmentStart = line.start + consumed;
      final segmentEnd = segmentStart + segment.text.length;
      var localStart = 0;

      while (localStart < segment.text.length) {
        while (matchIndex < matches.length && matches[matchIndex].end <= segmentStart + localStart) {
          matchIndex++;
        }

        if (matchIndex >= matches.length || matches[matchIndex].start >= segmentEnd) {
          _appendTextSpan(spans, segment.text.substring(localStart), segment.style);
          break;
        }

        final match = matches[matchIndex];
        final absoluteStart = segmentStart + localStart;

        if (match.start > absoluteStart) {
          final plainEnd = match.start - segmentStart;
          _appendTextSpan(spans, segment.text.substring(localStart, plainEnd), segment.style);
          localStart = plainEnd;
          continue;
        }

        final isCurrentMatch = match.index == effectiveCurrentMatchIndex;
        var highlightEnd = match.end;
        while (!isCurrentMatch &&
            highlightEnd < segmentEnd &&
            matchIndex + 1 < matches.length &&
            matches[matchIndex + 1].index != effectiveCurrentMatchIndex &&
            matches[matchIndex + 1].start == highlightEnd) {
          highlightEnd = matches[++matchIndex].end;
        }
        final overlapEnd = highlightEnd < segmentEnd ? highlightEnd : segmentEnd;
        final matchText = segment.text.substring(localStart, overlapEnd - segmentStart);

        // 复用样式计算，减少对象创建
        final baseStyle = segment.style ?? const TextStyle();
        final highlightedStyle = baseStyle.copyWith(
          backgroundColor: isCurrentMatch ? colorScheme.primary : colorScheme.inversePrimary,
          color: isCurrentMatch ? colorScheme.onPrimary : baseStyle.color,
        );

        _appendTextSpan(spans, matchText, highlightedStyle);

        localStart = overlapEnd - segmentStart;
      }

      consumed += segment.text.length;
    }

    return spans;
  }

  List<InlineSpan> _plainLineSpans(HighlightDocumentLine line) {
    if (line.segments.isEmpty) {
      return [const TextSpan(text: '', style: TextStyle(color: Colors.transparent))];
    }

    return [for (final segment in line.segments) TextSpan(text: segment.text, style: segment.style)];
  }
}

List<HighlightStyledSegment> _buildHighlightBaseSegments(
  String text,
  String? language,
  TextStyle? style,
  Map<String, TextStyle> theme,
) {
  if (!(language?.isNotEmpty ?? false)) {
    return [HighlightStyledSegment(text: text, style: _stripBackground(style))];
  }

  try {
    final parsed = highlight.parse(text, language: language).nodes ?? const <Node>[];
    List<HighlightStyledSegment> convert(List<Node> nodes, [TextStyle? inheritedStyle]) {
      final spans = <HighlightStyledSegment>[];
      for (final node in nodes) {
        final nodeStyle = node.className == null ? null : _stripBackground(theme[node.className!]);
        final mergedStyle = _stripBackground(inheritedStyle?.merge(nodeStyle) ?? nodeStyle);

        if (node.value != null) {
          spans.add(HighlightStyledSegment(text: node.value!, style: mergedStyle));
          continue;
        }

        if (node.children != null && node.children!.isNotEmpty) {
          spans.addAll(convert(node.children!, mergedStyle));
        }
      }
      return spans;
    }

    final result = convert(parsed, style);
    if (result.isNotEmpty) {
      return result;
    }
  } catch (_) {}

  return [HighlightStyledSegment(text: text, style: _stripBackground(style))];
}

List<HighlightSearchMatch> findHighlightMatches((String, SearchSettings) input) {
  final (text, search) = input;
  if (search.pattern.isEmpty) return const [];

  try {
    final regex =
        RegExp(search.isRegExp ? search.pattern : RegExp.escape(search.pattern), caseSensitive: search.isCaseSensitive);

    final matches = <HighlightSearchMatch>[];
    var index = 0;
    for (final match in regex.allMatches(text)) {
      if (match.start == match.end) {
        continue;
      }
      matches.add(HighlightSearchMatch(index: index, start: match.start, end: match.end));
      index++;
    }
    return matches;
  } catch (_) {
    return const [];
  }
}

List<HighlightDocumentLine> buildHighlightDocumentLines(List<HighlightStyledSegment> segments) {
  final lines = <HighlightDocumentLine>[];
  final currentSegments = <HighlightStyledSegment>[];
  var lineStart = 0;
  var offset = 0;
  var lineNumber = 0;

  void pushLine() {
    lines.add(HighlightDocumentLine(
      index: lineNumber++,
      start: lineStart,
      end: offset,
      segments: List<HighlightStyledSegment>.from(currentSegments),
    ));
    currentSegments.clear();
  }

  for (final segment in segments) {
    final parts = segment.text.split('\n');
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.isNotEmpty) {
        currentSegments.add(HighlightStyledSegment(text: part, style: segment.style));
      }
      offset += part.length;

      if (i != parts.length - 1) {
        pushLine();
        offset += 1;
        lineStart = offset;
      }
    }
  }

  if (lines.isEmpty || lineStart <= offset) {
    pushLine();
  }

  return lines;
}

void _appendTextSpan(List<InlineSpan> spans, String value, TextStyle? textStyle) {
  if (value.isEmpty) {
    return;
  }
  spans.add(TextSpan(text: value, style: textStyle));
}

class HighlightStyledSegment {
  final String text;
  final TextStyle? style;

  const HighlightStyledSegment({required this.text, this.style});
}

class HighlightSearchMatch {
  final int index;
  final int start;
  final int end;

  const HighlightSearchMatch({required this.index, required this.start, required this.end});
}

class HighlightDocumentLine {
  final int index;
  final int start;
  final int end;
  final List<HighlightStyledSegment> segments;

  const HighlightDocumentLine({
    required this.index,
    required this.start,
    required this.end,
    required this.segments,
  });

  String get text => segments.map((segment) => segment.text).join();
}

TextStyle? _stripBackground(TextStyle? style) {
  if (style == null) {
    return null;
  }
  return style.copyWith(backgroundColor: null, background: null);
}
