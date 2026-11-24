import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/util/logger.dart';

class CapturedVideoPreview extends StatefulWidget {
  final List<int> bytes;
  final bool active;

  const CapturedVideoPreview({super.key, required this.bytes, required this.active});

  @override
  State<CapturedVideoPreview> createState() => _CapturedVideoPreviewState();
}

class _CapturedVideoPreviewState extends State<CapturedVideoPreview> {
  Future<void>? _opening;
  Directory? _directory;
  Player? _player;
  VideoController? _controller;
  StreamSubscription<String>? _errors;
  StreamSubscription<int?>? _widths;
  Timer? _timeout;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _opening = _open();
  }

  @override
  void didUpdateWidget(covariant CapturedVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active) {
      _opening ??= _open();
    } else if (oldWidget.active) {
      final player = _player;
      if (_ready && player != null) unawaited(player.pause());
    }
  }

  Future<void> _open() async {
    final bytes = widget.bytes;
    final format = _containerFormat(bytes);
    if (format == null) {
      _failed = true;
      return;
    }

    try {
      final directory = _directory = await Directory.systemTemp.createTemp('proxypin-video-');
      final file = await File('${directory.path}/body').writeAsBytes(bytes);
      if (!mounted) return;

      MediaKit.ensureInitialized();
      final player = _player = Player(configuration: const PlayerConfiguration(protocolWhitelist: ['file']));
      final native = player.platform as NativePlayer;
      final properties = {
        'access-references': 'no',
        'autoload-files': 'no',
        'demuxer': 'lavf',
        'demuxer-lavf-format': format,
        'pause': 'yes',
      };
      for (final property in properties.entries) {
        await native.setProperty(property.key, property.value);
        if (await native.getProperty(property.key) != property.value) {
          throw StateError('Cannot configure video property ${property.key}');
        }
      }
      if (!mounted) return;

      _controller = VideoController(player);
      _errors = player.stream.error.listen((error) {
        logger.w('Captured video preview: $error');
        _fail();
      });
      _widths = player.stream.width.listen((width) {
        if (!mounted || _ready || _failed || width == null || width <= 0) return;
        _timeout?.cancel();
        setState(() => _ready = true);
      });
      _timeout = Timer(const Duration(seconds: 10), _fail);
      await native.command(['loadfile', file.path, 'replace']);
    } catch (error) {
      logger.w('Captured video preview: $error');
      _fail();
    }
  }

  void _fail() {
    _timeout?.cancel();
    if (mounted && !_failed) setState(() => _failed = true);
  }

  static String? _containerFormat(List<int> bytes) {
    bool matches(int offset, List<int> signature) {
      if (bytes.length < offset + signature.length) return false;
      for (var index = 0; index < signature.length; index++) {
        if (bytes[offset + index] != signature[index]) return false;
      }
      return true;
    }

    if (matches(4, const [0x66, 0x74, 0x79, 0x70])) return 'mov';
    if (matches(0, const [0x1a, 0x45, 0xdf, 0xa3])) return 'matroska';
    if (matches(0, const [0x52, 0x49, 0x46, 0x46]) && matches(8, const [0x41, 0x56, 0x49, 0x20])) return 'avi';
    if (matches(0, const [0x4f, 0x67, 0x67, 0x53])) return 'ogg';
    return null;
  }

  @override
  void dispose() {
    unawaited(_close());
    super.dispose();
  }

  Future<void> _close() async {
    await _opening;
    _timeout?.cancel();
    await _errors?.cancel();
    await _widths?.cancel();
    try {
      await _player?.dispose();
    } finally {
      await _directory?.delete(recursive: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return Center(child: Text(AppLocalizations.of(context)!.detailMediaUnavailable));
    if (!_ready) {
      return Center(
        child: widget.active
            ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : null,
      );
    }
    return Video(controller: _controller!);
  }
}
