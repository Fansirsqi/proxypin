import 'package:flutter/material.dart';
import 'package:proxypin/ui/component/search/highlight_text_document.dart';
import 'package:proxypin/ui/component/search/search_controller.dart';
import 'package:proxypin/ui/component/theme_presets.dart';

class HighlightTextWidget extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final String? language;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final SearchTextController searchController;

  const HighlightTextWidget({
    super.key,
    required this.text,
    this.style,
    this.language,
    this.contextMenuBuilder,
    required this.searchController,
  });

  @override
  State<HighlightTextWidget> createState() => _HighlightTextWidgetState();
}

class _HighlightTextWidgetState extends State<HighlightTextWidget> {
  HighlightDocumentInput? _input;
  HighlightTextDocument? _base;
  SearchSettings? _query;
  List<HighlightSearchMatch> _matches = const [];

  @override
  Widget build(BuildContext context) {
    final searchController = widget.searchController;
    return AnimatedBuilder(
      animation: searchController,
      builder: (context, child) {
        final query = _searchQuery(searchController);
        final input = (
          text: widget.text,
          style: widget.style,
          language: widget.language,
          brightness: Theme.brightnessOf(context),
          preset: ActiveThemePreset.of(context),
          search: null,
        );
        if (_input?.text != input.text || _query != query) {
          _query = query;
          _matches = query == null ? const [] : findHighlightMatches((input.text, query));
        }
        if (_input != input) {
          _input = input;
          _base = HighlightTextDocument.prepare(input);
        }
        final document = _base!.withMatches(_matches, searchController.currentMatchIndex.value);
        final spans = document.buildAllSpans(context);

        if (searchController.totalMatchCount.value != document.totalMatchCount) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted ||
                widget.searchController != searchController ||
                widget.text != input.text ||
                _searchQuery(searchController) != query) {
              return;
            }
            searchController.updateMatchCount(document.totalMatchCount);
          });
        }

        return SelectableText.rich(
          TextSpan(children: spans),
          style: widget.style,
          showCursor: true,
          // selectionColor: highlightSelectionColor(context),
          contextMenuBuilder: widget.contextMenuBuilder,
        );
      },
    );
  }

  SearchSettings? _searchQuery(SearchTextController controller) =>
      controller.shouldSearch() ? controller.value.copyWith(currentMatchIndex: 0) : null;
}
