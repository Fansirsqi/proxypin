import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' show Node, highlight;
import 'package:proxypin/ui/component/theme_presets.dart';

import 'search_controller.dart';

typedef HighlightDocumentInput = ({
  String text,
  String? language,
  TextStyle? style,
  Brightness brightness,
  ThemePreset preset,
  SearchSettings? search,
});

class HighlightTextDocument {
  final String text;
  final TextStyle? rootStyle;
  final List<HighlightStyledSegment> segments;
  final List<HighlightSearchMatch> matches;
  final List<HighlightDocumentLine> lines;
  final List<List<HighlightSearchMatch>> lineMatches;
  final List<int> matchLineIndexes;
  final int currentMatchIndex;

  const HighlightTextDocument._({
    required this.text,
    required this.rootStyle,
    required this.segments,
    required this.matches,
    required this.lines,
    required this.lineMatches,
    required this.matchLineIndexes,
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
    final matches = _buildSearchMatches(input.text, input.search);
    final lines = buildHighlightDocumentLines(segments);
    final groupedMatches = _groupMatchesByLine(lines, matches);
    final currentMatchIndex = matches.isEmpty ? -1 : input.search!.currentMatchIndex.clamp(0, matches.length - 1);
    final matchLineIndexes = _buildMatchLineIndexes(groupedMatches, matches.length);

    return HighlightTextDocument._(
      text: input.text,
      rootStyle: rootStyle,
      segments: segments,
      matches: matches,
      lines: lines,
      lineMatches: groupedMatches,
      matchLineIndexes: matchLineIndexes,
      currentMatchIndex: currentMatchIndex,
    );
  }

  int get totalMatchCount => matches.length;

  int? lineIndexForMatch(int matchIndex) {
    if (matchIndex < 0 || matchIndex >= matchLineIndexes.length) {
      return null;
    }
    return matchLineIndexes[matchIndex];
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
    final matchesForLine = lineMatches[lineIndex];
    if (matchesForLine.isEmpty) {
      return _plainLineSpans(line);
    }

    final spans = <InlineSpan>[];
    final colorScheme = ColorScheme.of(context);
    final effectiveCurrentMatchIndex = currentMatchIndexOverride ?? currentMatchIndex;
    var matchIndex = 0;
    var consumed = 0;

    for (final segment in line.segments) {
      final segmentStart = line.start + consumed;
      final segmentEnd = segmentStart + segment.text.length;
      var localStart = 0;

      while (localStart < segment.text.length) {
        while (matchIndex < matchesForLine.length && matchesForLine[matchIndex].end <= segmentStart + localStart) {
          matchIndex++;
        }

        if (matchIndex >= matchesForLine.length || matchesForLine[matchIndex].start >= segmentEnd) {
          _appendTextSpan(spans, segment.text.substring(localStart), segment.style);
          break;
        }

        final match = matchesForLine[matchIndex];
        final absoluteStart = segmentStart + localStart;

        if (match.start > absoluteStart) {
          final plainEnd = match.start - segmentStart;
          _appendTextSpan(spans, segment.text.substring(localStart, plainEnd), segment.style);
          localStart = plainEnd;
          continue;
        }

        final overlapEnd = match.end < segmentEnd ? match.end : segmentEnd;
        final matchText = segment.text.substring(localStart, overlapEnd - segmentStart);
        final isCurrentMatch = match.index == effectiveCurrentMatchIndex;

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

List<HighlightSearchMatch> _buildSearchMatches(String text, SearchSettings? search) {
  if (search == null || search.pattern.isEmpty) return const [];

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

List<List<HighlightSearchMatch>> _groupMatchesByLine(
  List<HighlightDocumentLine> lines,
  List<HighlightSearchMatch> matches,
) {
  if (matches.isEmpty || lines.isEmpty) {
    return List.filled(lines.length, const <HighlightSearchMatch>[]);
  }

  final grouped = List.generate(lines.length, (_) => <HighlightSearchMatch>[]);
  var lineIndex = 0;
  for (final match in matches) {
    while (lineIndex < lines.length && lines[lineIndex].end <= match.start) {
      lineIndex++;
    }

    for (var i = lineIndex; i < lines.length; i++) {
      final line = lines[i];
      if (line.start >= match.end) {
        break;
      }
      if (line.end > match.start) {
        grouped[i].add(match);
      }
    }
  }

  return grouped;
}

List<int> _buildMatchLineIndexes(List<List<HighlightSearchMatch>> groupedMatches, int matchCount) {
  final indexes = List.filled(matchCount, 0);
  for (var lineIndex = 0; lineIndex < groupedMatches.length; lineIndex++) {
    for (final match in groupedMatches[lineIndex]) {
      if (match.index < indexes.length && indexes[match.index] == 0) {
        indexes[match.index] = lineIndex;
      }
    }
  }
  return indexes;
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
