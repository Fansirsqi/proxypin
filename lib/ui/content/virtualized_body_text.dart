part of 'read_only_body.dart';

typedef _BodyDocumentRequest = ({_BodyPalette palette, HighlightDocumentInput input});
typedef _PreparedBodyDocument = ({_BodyDocumentRequest request, HighlightTextDocument document});
typedef _BodySearchRequest = ({String text, SearchSettings settings});
typedef _BodySearchPosition = ({_BodySearchRequest? query, int match});

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
  static const _searchDelay = Duration(milliseconds: 90);
  static const _searchTimeout = Duration(seconds: 2);
  static const _documentTimeout = Duration(seconds: 10);
  static const _spanCacheSize = 16;
  static const _cacheableChunkLength = 4096;
  static const _cacheableChunkSpans = 256;

  final _items = ItemScrollController();
  final _chunkSpans = <(int, int), TextSpan>{};
  ScrollController? _trackingScroll;
  _BodyDocumentRequest? _requested;
  _PreparedBodyDocument? _ready;
  _PreparedBodyDocument? _completed;
  PreviewTask<HighlightTextDocument>? _pendingDocument;
  _BodySearchRequest? _requestedSearch;
  PreviewTask<List<HighlightSearchMatch>>? _pendingSearch;
  List<HighlightSearchMatch> _matches = const [];
  bool _searchFailed = false;
  bool _showSearchLines = false;
  HighlightTextDocument? _baseDocument;
  HighlightTextDocument? _paintedDocument;
  ({HighlightTextDocument document, int line, BuildContext context})? _matchChunk;
  _BodySearchPosition? _reportedPosition;
  bool _searchUpdateScheduled = false;
  String _selectedText = '';

  @override
  void dispose() {
    _pendingDocument?.cancel();
    _pendingSearch?.cancel();
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
        final query = _searchRequest(finder);
        _prepareSearch(query);
        _prepareDocument((
          palette: palette,
          input: (
            text: widget.text,
            language: widget.language,
            style: widget.style.copyWith(color: palette.foreground),
            brightness: ThemeData.estimateBrightnessForColor(palette.surface),
            preset: palette.fallbackPreset.preset,
            search: null,
          ),
        ));
        final completed = _completed;
        _completed = null;
        if (completed != null && completed.request == _requested) _ready = completed;
        final ready = _ready;
        if (ready == null || ready.document.text != widget.text) {
          return widget.frameBuilder(context, palette, SizedBox(width: double.infinity, height: widget.height));
        }
        final (:request, document: base) = ready;
        final searching = query != null && _showSearchLines;
        if (_baseDocument != base || _paintedDocument?.matches != _matches) {
          _baseDocument = base;
          _paintedDocument = base.withMatches(_matches);
          _matchChunk = null;
          _chunkSpans.clear();
        }
        final document = _paintedDocument!;
        _updateSearchPosition(document, query);
        return widget.frameBuilder(context, request.palette, _buildList(document, searching));
      },
    );
  }

  void _prepareDocument(_BodyDocumentRequest request) {
    if (_requested == request) return;
    _requested = request;
    _pendingDocument?.cancel();
    _pendingDocument = null;
    if (_ready?.request == request) return;
    final input = request.input;
    if (!widget.prepareInBackground || input.style?.foreground != null || input.style?.background != null) {
      _ready = (request: request, document: HighlightTextDocument.prepare(input));
      return;
    }
    final task = PreviewTask.start(HighlightTextDocument.prepare, input, timeout: _documentTimeout);
    _pendingDocument = task;
    task.result.then((document) {
      if (!mounted || _pendingDocument != task) return;
      setState(() {
        _pendingDocument = null;
        if (document != null) {
          _completed = (request: request, document: document);
        } else {
          logger.w('Background body preparation stopped');
          _completed = (
            request: request,
            document: HighlightTextDocument.prepare((
              text: input.text,
              language: null,
              style: input.style,
              brightness: input.brightness,
              preset: input.preset,
              search: null,
            )),
          );
        }
      });
    });
  }

  _BodySearchRequest? _searchRequest(SearchTextController finder) =>
      finder.shouldSearch() ? (text: widget.text, settings: finder.value.copyWith(currentMatchIndex: 0)) : null;

  void _prepareSearch(_BodySearchRequest? query) {
    if (_requestedSearch == query) return;
    if (query == null || _requestedSearch?.text != query.text) _showSearchLines = false;
    _requestedSearch = query;
    _pendingSearch?.cancel();
    _pendingSearch = null;
    _matches = const [];
    _searchFailed = false;
    _reportedPosition = null;
    _chunkSpans.clear();
    if (query == null) return;

    final task = PreviewTask.start(
      findHighlightMatches,
      (query.text, query.settings),
      timeout: _searchTimeout,
      delay: _searchDelay,
    );
    _pendingSearch = task;
    task.result.then((matches) {
      if (!mounted || _pendingSearch != task) return;
      setState(() {
        _pendingSearch = null;
        _matches = matches ?? const [];
        _searchFailed = matches == null;
        if (!_showSearchLines && _matches.isNotEmpty) {
          _showSearchLines = true;
          _chunkSpans.clear();
        }
      });
    });
  }

  void _updateSearchPosition(HighlightTextDocument document, _BodySearchRequest? query) {
    final finder = widget.searchController;
    final position = (query: query, match: finder.currentMatchIndex.value);
    if (_searchUpdateScheduled ||
        (position == _reportedPosition &&
            finder.totalMatchCount.value == document.totalMatchCount &&
            finder.searchFailed.value == _searchFailed)) {
      return;
    }
    _searchUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchUpdateScheduled = false;
      if (!mounted ||
          finder != widget.searchController ||
          query != _searchRequest(finder) ||
          document != _paintedDocument) {
        return;
      }
      finder.updateMatchCount(document.totalMatchCount);
      finder.searchFailed.value = _searchFailed;
      if (_pendingSearch != null) return;
      final current = (query: query, match: finder.currentMatchIndex.value);
      if (current != _reportedPosition) {
        _reportedPosition = current;
        final line = document.lineIndexForMatch(current.match);
        if (line != null) _revealMatch(document, current, line);
      }
    });
  }

  void _revealMatch(HighlightTextDocument document, _BodySearchPosition position, int line) {
    final offset = document.matches[position.match].start - document.lines[line].start;
    bool revealInChunk() {
      final chunk = _matchChunk;
      return chunk != null &&
          chunk.document == document &&
          chunk.line == line &&
          revealHighlightOffset(chunk.context, offset);
    }

    if (revealInChunk() || !_items.isAttached) return;
    _items.jumpTo(index: line, alignment: .5);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _paintedDocument != document || _reportedPosition != position) return;
      final finder = widget.searchController;
      if (_searchRequest(finder) == position.query && finder.currentMatchIndex.value == position.match) {
        revealInChunk();
      }
    });
  }

  Widget _buildList(HighlightTextDocument document, bool searching) {
    final chunkLines = searching ? 1 : 24;
    final currentMatch = widget.searchController.currentMatchIndex.value;
    final matchLine = searching ? document.lineIndexForMatch(currentMatch) : null;
    final itemCount = (document.lines.length + chunkLines - 1) ~/ chunkLines;
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
            final text = Text.rich(
              _spansForChunk(context, document, index, chunkLines, currentMatch),
              key: ValueKey('virtualized-code-chunk-$index'),
              style: document.rootStyle,
            );
            return Builder(builder: (context) {
              if (index == matchLine) _matchChunk = (document: document, line: index, context: context);
              return text;
            });
          },
        ),
      ),
    );
  }

  TextSpan _spansForChunk(
    BuildContext context,
    HighlightTextDocument document,
    int index,
    int chunkLines,
    int currentMatch,
  ) {
    final start = index * chunkLines;
    final end = min(start + chunkLines, document.lines.length);
    final startOffset = document.lines[start].start;
    final endOffset = document.lines[end - 1].end;
    final match = currentMatch >= 0 && currentMatch < document.matches.length ? document.matches[currentMatch] : null;
    final activeMatch = match != null && match.start < endOffset && match.end > startOffset ? currentMatch : -1;
    final key = (index, activeMatch);
    final cached = _chunkSpans.remove(key);
    if (cached != null) {
      _chunkSpans[key] = cached;
      return cached;
    }
    final children = <InlineSpan>[
      for (var line = start; line < end; line++) ...[
        if (line != start) TextSpan(text: '\n', style: document.rootStyle),
        ...document.buildSpansForLine(context, line, currentMatchIndexOverride: activeMatch),
      ],
    ];
    final spans = TextSpan(children: children);
    if (endOffset - startOffset <= _cacheableChunkLength && children.length <= _cacheableChunkSpans) {
      if (_chunkSpans.length == _spanCacheSize) _chunkSpans.remove(_chunkSpans.keys.first);
      _chunkSpans[key] = spans;
    }
    return spans;
  }
}
