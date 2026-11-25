part of 'read_only_body.dart';

typedef _BodyDocumentRequest = ({_BodyPalette palette, HighlightDocumentInput input});
typedef _PreparedBodyDocument = ({_BodyDocumentRequest request, HighlightTextDocument document});
typedef _BodySearchPosition = ({String text, SearchSettings? search, int match});

class _VirtualizedBodyText extends StatefulWidget {
  final String text;
  final String? language;
  final TextStyle style;
  final double height;
  final _BodyPalette palette;
  final bool prepareInBackground;
  final SearchTextController searchController;
  final ScrollController? scrollController;
  final Widget Function(BuildContext context, _BodyPalette palette, Widget child) frameBuilder;

  const _VirtualizedBodyText({
    required this.text,
    required this.language,
    required this.style,
    required this.height,
    required this.palette,
    required this.prepareInBackground,
    required this.searchController,
    required this.scrollController,
    required this.frameBuilder,
  });

  @override
  State<_VirtualizedBodyText> createState() => _VirtualizedBodyTextState();
}

class _VirtualizedBodyTextState extends State<_VirtualizedBodyText> {
  final _items = ItemScrollController();
  ScrollController? _trackingScroll;
  _BodyDocumentRequest? _requested;
  _PreparedBodyDocument? _ready;
  _PreparedBodyDocument? _completed;
  Future<HighlightTextDocument>? _pending;
  _BodySearchPosition? _reportedPosition;
  bool _searchUpdateScheduled = false;
  String _selectedText = '';

  @override
  void dispose() {
    _trackingScroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.searchController,
      builder: (context, _) {
        final palette = widget.palette;
        final finder = widget.searchController;
        final search = finder.shouldSearch() ? finder.value.copyWith(currentMatchIndex: 0) : null;
        _prepare((
          palette: palette,
          input: (
            text: widget.text,
            language: widget.language,
            style: widget.style.copyWith(color: palette.foreground),
            brightness: ThemeData.estimateBrightnessForColor(palette.surface),
            preset: palette.fallbackPreset.preset,
            search: search,
          ),
        ));
        final completed = _completed;
        _completed = null;
        if (completed != null && completed.request == _requested) _ready = completed;
        final ready = _ready;
        if (ready == null || ready.document.text != widget.text) {
          return widget.frameBuilder(context, palette, SizedBox(width: double.infinity, height: widget.height));
        }
        final (:request, :document) = ready;
        if (request.input.search == search) _updateSearchPosition(document, search);
        return widget.frameBuilder(context, request.palette, _buildList(document, request.input.search != null));
      },
    );
  }

  void _prepare(_BodyDocumentRequest request) {
    if (_requested == request) return;
    _requested = request;
    _pending = null;
    if (_ready?.request == request) return;
    final input = request.input;
    if (!widget.prepareInBackground || input.style?.foreground != null || input.style?.background != null) {
      _ready = (request: request, document: HighlightTextDocument.prepare(input));
      return;
    }
    final task = compute(HighlightTextDocument.prepare, input);
    _pending = task;
    task.then((document) {
      if (!mounted || _pending != task) return;
      setState(() {
        _pending = null;
        _completed = (request: request, document: document);
      });
    }, onError: (Object error) {
      if (!mounted || _pending != task) return;
      logger.w('Background body preparation failed: $error');
      setState(() {
        _pending = null;
        _completed = (request: request, document: HighlightTextDocument.prepare(input));
      });
    });
  }

  void _updateSearchPosition(HighlightTextDocument document, SearchSettings? search) {
    final finder = widget.searchController;
    final position = (text: document.text, search: search, match: finder.currentMatchIndex.value);
    if (_searchUpdateScheduled ||
        (position == _reportedPosition && finder.totalMatchCount.value == document.totalMatchCount)) {
      return;
    }
    _searchUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchUpdateScheduled = false;
      if (!mounted || finder != widget.searchController || search != _requested?.input.search) return;
      finder.updateMatchCount(document.totalMatchCount);
      final current = (text: document.text, search: search, match: finder.currentMatchIndex.value);
      if (current != _reportedPosition) {
        _reportedPosition = current;
        final line = document.lineIndexForMatch(current.match);
        if (line != null && _items.isAttached) _items.jumpTo(index: line, alignment: .5);
      }
    });
  }

  Widget _buildList(HighlightTextDocument document, bool searching) {
    final chunkLines = searching ? 1 : 24;
    final currentMatch = widget.searchController.currentMatchIndex.value;
    final itemCount = max(1, (document.lines.length / chunkLines).ceil());
    return SizedBox(
      width: double.infinity,
      height: widget.height,
      child: SelectionArea(
        onSelectionChanged: (content) => _selectedText = content?.plainText ?? '',
        contextMenuBuilder: (context, state) => selectableRegionContextMenu(context, state, _selectedText),
        child: ScrollablePositionedList.builder(
          key: const ValueKey('virtualized-highlight-text'),
          physics: Platforms.isDesktop() ? null : const BouncingScrollPhysics(),
          scrollController: Platforms.isDesktop()
              ? null
              : (_trackingScroll ??= trackingScroll(widget.scrollController) ?? TrackingScrollController()),
          itemScrollController: _items,
          padding: const EdgeInsetsDirectional.only(end: 8, bottom: 10).resolve(Directionality.of(context)),
          minCacheExtent: max(3, (widget.height / 24).ceil()) * 48.0,
          itemCount: itemCount,
          itemBuilder: (context, index) {
            final start = index * chunkLines;
            final end = min(start + chunkLines, document.lines.length);
            return Text.rich(
              TextSpan(children: [
                for (var line = start; line < end; line++) ...[
                  if (line != start) TextSpan(text: '\n', style: document.rootStyle),
                  ...document.buildSpansForLine(context, line, currentMatchIndexOverride: currentMatch),
                ],
              ]),
              key: ValueKey('virtualized-code-chunk-$index'),
              style: document.rootStyle,
            );
          },
        ),
      ),
    );
  }
}
