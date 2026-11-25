import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/websocket.dart';
import 'package:proxypin/utils/lang.dart';

class StreamBody extends StatefulWidget {
  const StreamBody({
    super.key,
    required this.message,
    required this.height,
    required this.virtualized,
  });

  final HttpMessage message;
  final double height;
  final bool virtualized;

  @override
  State<StreamBody> createState() => _StreamBodyState();
}

class _StreamBodyState extends State<StreamBody> {
  late final _StreamSelection _selection = _StreamSelection(() => widget.message.messages);
  final _scroll = ScrollController(keepScrollOffset: false);

  @override
  void dispose() {
    _scroll.dispose();
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.message.messages;
    final header = <Widget>[
      const SelectionContainer.disabled(
        child: Row(children: [
          Expanded(child: Text('Data')),
          SizedBox(width: 130, child: Text('Time')),
        ]),
      ),
      Divider(height: 5, thickness: 1, color: Theme.of(context).dividerColor),
    ];
    if (!widget.virtualized) {
      return SelectionArea(
        child: Column(children: [
          ...header,
          for (final frame in messages) _streamRow(frame, Text(frame.payloadDataAsString)),
        ]),
      );
    }
    return SelectionArea(
      child: SelectionContainer(
        delegate: _selection,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...header,
            if (messages.isNotEmpty && widget.height > 0)
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: widget.height),
                child: ListView.builder(
                  controller: _scroll,
                  primary: false,
                  shrinkWrap: true,
                  physics: const _StreamTailPhysics(),
                  scrollCacheExtent: const ScrollCacheExtent.pixels(64),
                  addAutomaticKeepAlives: false,
                  padding: EdgeInsets.zero,
                  itemCount: messages.length,
                  itemBuilder: (_, index) => _StreamRow(
                    key: ValueKey(index),
                    index: index,
                    frame: messages[index],
                    selection: _selection,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Widget _streamRow(WebSocketFrame frame, Widget payload) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: payload),
          const SizedBox(width: 5),
          SizedBox(
            width: 130,
            child: SelectionContainer.disabled(
              child: Text(frame.time.format(), style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          ),
        ],
      ),
    );

class _StreamRow extends StatefulWidget {
  const _StreamRow({super.key, required this.index, required this.frame, required this.selection});

  final int index;
  final WebSocketFrame frame;
  final _StreamSelection selection;

  @override
  State<_StreamRow> createState() => _StreamRowState();
}

class _StreamRowState extends State<_StreamRow> {
  final _notifier = SelectionListenerNotifier();
  final _text = GlobalKey();
  late String _payload = widget.frame.payloadDataAsString;

  RenderParagraph? get paragraph {
    var render = _text.currentContext?.findRenderObject();
    while (render is RenderProxyBox) {
      render = render.child;
    }
    return render is RenderParagraph && render.attached && render.hasSize ? render : null;
  }

  SelectedContentRange? get nativeRange => _notifier.registered ? _notifier.selection.range : null;

  @override
  void initState() {
    super.initState();
    widget.selection.rows[widget.index] = this;
  }

  @override
  void didUpdateWidget(covariant _StreamRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frame != widget.frame) _payload = widget.frame.payloadDataAsString;
  }

  @override
  void dispose() {
    if (widget.selection.rows[widget.index] == this) widget.selection.rows.remove(widget.index);
    _notifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = DefaultSelectionStyle.of(context).selectionColor ?? DefaultSelectionStyle.defaultColor;
    return _streamRow(
      widget.frame,
      CustomPaint(
        painter: _StreamSelectionPainter(this, color),
        child: SelectionListener(
          selectionNotifier: _notifier,
          child: Text(_payload, key: _text, selectionColor: Colors.transparent),
        ),
      ),
    );
  }
}

class _StreamSelectionPainter extends CustomPainter {
  _StreamSelectionPainter(this.row, this.color) : super(repaint: row.widget.selection.repaint);

  final _StreamRowState row;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paragraph = row.paragraph;
    if (paragraph == null) return;
    final selection = row.widget.selection.rangeForRow(row.widget.index, row._payload.length);
    if (selection == null || selection.isCollapsed) return;
    final paint = Paint()..color = color;
    for (final box in paragraph.getBoxesForSelection(selection)) {
      canvas.drawRect(box.toRect(), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StreamSelectionPainter oldDelegate) => oldDelegate.color != color;
}

class _StreamTailPhysics extends ScrollPhysics {
  const _StreamTailPhysics({super.parent});

  @override
  _StreamTailPhysics applyTo(ScrollPhysics? ancestor) => _StreamTailPhysics(parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    if (!isScrolling &&
        oldPosition.maxScrollExtent > 0 &&
        oldPosition.extentAfter == 0 &&
        newPosition.pixels >= oldPosition.pixels) {
      return newPosition.maxScrollExtent;
    }
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }
}

typedef _StreamPoint = ({int index, int offset});
typedef _StreamRange = ({_StreamPoint first, _StreamPoint last});

class _StreamSelection extends StaticSelectionContainerDelegate {
  _StreamSelection(this.frames);

  final List<WebSocketFrame> Function() frames;
  final rows = <int, _StreamRowState>{};
  final repaint = ValueNotifier<int>(0);
  _StreamPoint? _start;
  _StreamPoint? _end;
  bool _all = false;

  _StreamRange? get _range {
    final start = _start;
    final end = _end;
    if (start == null || end == null) return null;
    return start.index < end.index || (start.index == end.index && start.offset <= end.offset)
        ? (first: start, last: end)
        : (first: end, last: start);
  }

  TextSelection? rangeForRow(int index, int length) {
    if (_all) return TextSelection(baseOffset: 0, extentOffset: length);
    final range = _range;
    if (range == null || index < range.first.index || index > range.last.index) return null;
    return TextSelection(
      baseOffset: index == range.first.index ? range.first.offset.clamp(0, length) : 0,
      extentOffset: index == range.last.index ? range.last.offset.clamp(0, length) : length,
    );
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final previous = (_start, _end, _all);
    _all = event is SelectAllSelectionEvent;
    if (event is ClearSelectionEvent || _all) _start = _end = null;
    final result = super.dispatchSelectionEvent(event);
    switch (event) {
      case ClearSelectionEvent() || SelectAllSelectionEvent():
        break;
      case SelectionEdgeUpdateEvent(:final globalPosition, :final granularity):
        final forEnd = event.type == SelectionEventType.endEdgeUpdate;
        final row = _nearestRow(globalPosition);
        final paragraph = row?.paragraph;
        if (row != null && paragraph != null) {
          final local = paragraph.globalToLocal(globalPosition);
          final native = granularity == TextGranularity.word ? row.nativeRange : null;
          final offset = (forEnd ? native?.endOffset : native?.startOffset) ??
              paragraph
                  .getPositionForOffset(SelectionUtils.adjustDragOffset(
                    Offset.zero & paragraph.size,
                    local,
                    direction: paragraph.textDirection,
                  ))
                  .offset;
          final point = (index: row.widget.index, offset: offset);
          if (forEnd) {
            _end = point;
          } else {
            _start = point;
          }
        }
      case SelectWordSelectionEvent(:final globalPosition) || SelectParagraphSelectionEvent(:final globalPosition):
        final row = _nearestRow(globalPosition);
        final range = row?.nativeRange;
        if (row != null && range != null) {
          _start = (index: row.widget.index, offset: range.startOffset);
          _end = (index: row.widget.index, offset: range.endOffset);
        }
      case GranularlyExtendSelectionEvent(:final isEnd) || DirectionallyExtendSelectionEvent(:final isEnd):
        _extendFromNative(isEnd);
    }
    if (previous != (_start, _end, _all)) repaint.value++;
    return result;
  }

  _StreamRowState? _nearestRow(Offset position) {
    _StreamRowState? nearest;
    var distance = double.infinity;
    for (final row in rows.values) {
      final paragraph = row.paragraph;
      if (paragraph == null) continue;
      final area = paragraph.localToGlobal(Offset.zero) & paragraph.size;
      if (!area.isFinite) continue;
      final gap = (position.dy - position.dy.clamp(area.top, area.bottom)).abs();
      if (gap == 0) return row;
      if (gap < distance) {
        distance = gap;
        nearest = row;
      }
    }
    return nearest;
  }

  void _extendFromNative(bool isEnd) {
    ({int index, SelectedContentRange range})? first;
    ({int index, SelectedContentRange range})? last;
    var reversed = false;
    for (final entry in rows.entries) {
      final range = entry.value.nativeRange;
      if (range == null) continue;
      final point = (index: entry.key, range: range);
      if (first == null || point.index < first.index) first = point;
      if (last == null || point.index > last.index) last = point;
      reversed |= range.startOffset > range.endOffset;
    }
    if (first == null || last == null) return;
    final start = reversed ? last : first;
    final end = reversed ? first : last;
    if (!isEnd || _start == null) _start = (index: start.index, offset: start.range.startOffset);
    if (isEnd || _end == null) _end = (index: end.index, offset: end.range.endOffset);
  }

  @override
  SelectionGeometry getSelectionGeometry() => super.getSelectionGeometry().copyWith(hasContent: frames().isNotEmpty);

  @override
  SelectionResult handleSelectAll(SelectAllSelectionEvent event) {
    currentSelectionStartIndex = -1;
    currentSelectionEndIndex = -1;
    for (var index = 0; index < selectables.length; index++) {
      final selectable = selectables[index];
      final origin = MatrixUtils.transformPoint(selectable.getTransformTo(null), Offset.zero);
      if (!origin.isFinite) continue;
      dispatchSelectionEventToChild(selectable, event);
      if (selectable.value.startSelectionPoint == null || selectable.value.endSelectionPoint == null) continue;
      if (currentSelectionStartIndex == -1) currentSelectionStartIndex = index;
      currentSelectionEndIndex = index;
    }
    didReceiveSelectionBoundaryEvents();
    return SelectionResult.none;
  }

  @override
  void didChangeSelectables() {
    super.didChangeSelectables();
    if (_all && selectables.isNotEmpty) {
      super.dispatchSelectionEvent(const SelectAllSelectionEvent());
    }
  }

  @override
  SelectedContent? getSelectedContent() {
    final messages = frames();
    if (messages.isEmpty) return null;
    if (_all) return SelectedContent(plainText: messages.map((frame) => frame.payloadDataAsString).join());
    final range = _range;
    if (range == null || range.first == range.last || range.last.index >= messages.length) return null;
    final text = StringBuffer();
    for (var index = range.first.index; index <= range.last.index; index++) {
      final payload = messages[index].payloadDataAsString;
      final selection = rangeForRow(index, payload.length)!;
      text.write(payload.substring(selection.start, selection.end));
    }
    return SelectedContent(plainText: text.toString());
  }

  @override
  void dispose() {
    repaint.dispose();
    super.dispose();
  }
}
