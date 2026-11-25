import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/ui/configuration.dart';

const _portRange = '0–65535';

List<TextInputFormatter> _portFormatters() => [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(5),
    ];

Future<String?> _savePort(ProxyServer server, String value, AppLocalizations localizations) async {
  final port = int.tryParse(value);
  if (port == null || port < 0 || port > 65535) return _portRange;
  try {
    await server.changePort(port);
    final settings = AppConfiguration.current;
    if (settings != null) settings.globalChange.value = !settings.globalChange.value;
    return null;
  } catch (error, stackTrace) {
    logger.w('Could not change the proxy port to $port', error: error, stackTrace: stackTrace);
    return error is SocketException ? localizations.proxyPortRepeat(port) : localizations.fail;
  }
}

class PortWidget extends StatefulWidget {
  final ProxyServer proxyServer;
  final TextStyle? textStyle;
  final String? title;

  /// 前导图标（手机端设置页传 22px 语义色淡色块；桌面端不传保持原样）
  final Widget? leading;

  const PortWidget({super.key, required this.proxyServer, this.textStyle, this.title, this.leading});

  @override
  State<StatefulWidget> createState() {
    return _PortState();
  }
}

class _PortState extends State<PortWidget> {
  final textController = TextEditingController();
  final FocusNode portFocus = FocusNode();
  bool _saving = false;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    textController.text = widget.proxyServer.port.toString();
    portFocus.addListener(() async {
      if (!mounted || _saving || portFocus.hasFocus || textController.text == widget.proxyServer.port.toString()) {
        return;
      }
      setState(() => _saving = true);
      final error = await _savePort(widget.proxyServer, textController.text, localizations);
      if (!mounted) return;
      textController.text = widget.proxyServer.port.toString();
      setState(() => _saving = false);
      if (error != null) FlutterToastr.show(error, context, duration: 3);
    });
  }

  @override
  void dispose() {
    portFocus.dispose();
    textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppDisplaySettings.of(context);
    if (!portFocus.hasFocus && !_saving && textController.text != widget.proxyServer.port.toString()) {
      textController.text = widget.proxyServer.port.toString();
    }
    return Row(children: [
      if (widget.leading != null) ...[
        // 对齐 menuTile 的 ListTile 节奏：14 内边距 + 28 图标 + 16 标题间隔（标题 x=58；
        // 本 SDK 的 ListTile 前导槽即图标自然宽，无 minLeadingWidth 补位）
        const Padding(padding: EdgeInsets.only(left: 14)),
        widget.leading!,
        const SizedBox(width: 16),
      ] else
        const Padding(padding: EdgeInsets.only(left: 15)),
      Text(widget.title ?? localizations.port, style: widget.textStyle),
      // 手机端（带 leading）：文案在左、输入框顶到右缘，与卡片内其他行尾控件对齐；桌面端保持紧跟文案
      if (widget.leading != null) const Spacer(),
      SizedBox(
          width: 80,
          child: TextFormField(
            focusNode: portFocus,
            controller: textController,
            textAlign: TextAlign.center,
            onTapOutside: (event) => portFocus.unfocus(),
            readOnly: _saving,
            keyboardType: TextInputType.number,
            inputFormatters: _portFormatters(),
            decoration: const InputDecoration(),
          )),
      if (widget.leading != null) const Padding(padding: EdgeInsets.only(right: 14)),
    ]);
  }
}

class ProxyPortDialog extends StatefulWidget {
  final ProxyServer proxyServer;

  const ProxyPortDialog({super.key, required this.proxyServer});

  @override
  State<ProxyPortDialog> createState() => _ProxyPortDialogState();
}

class _ProxyPortDialogState extends State<ProxyPortDialog> {
  late final _controller = TextEditingController(text: '${widget.proxyServer.port}');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await _savePort(widget.proxyServer, _controller.text, AppLocalizations.of(context)!);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(localizations.port.trim().replaceFirst(RegExp(r'[:：]$'), '')),
        content: SizedBox(
          width: 280,
          child: TextField(
            controller: _controller,
            autofocus: true,
            readOnly: _saving,
            keyboardType: TextInputType.number,
            inputFormatters: _portFormatters(),
            decoration: InputDecoration(helperText: _portRange, errorText: _error, errorMaxLines: 3),
            onSubmitted: (_) => _submit(),
          ),
        ),
        actions: [
          TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: Text(localizations.cancel)),
          FilledButton(onPressed: _saving ? null : _submit, child: Text(localizations.save)),
        ],
      ),
    );
  }
}
