/*
 * Copyright 2025 Hongen Wang All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
import 'package:code_forge/code_forge.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/search/highlight_text.dart';
import 'package:proxypin/ui/component/svg_icon.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/configuration.dart';

import '../component/search/search_controller.dart';
import 'detail_fields.dart';

/// A reusable panel to display request/response headers.
///
/// Supports two modes:
/// - table mode: each header shown as name/value rows
/// - text mode: raw header lines in a read-only code field
class HeadersWidget extends StatefulWidget {
  final String title;
  final HttpMessage? message;
  final HeaderDensity density;

  /// Optional shared controller for raw-text mode, so caller can reuse
  /// controllers between rebuilds (e.g. separate for Request/Response).
  final CodeForgeController? controller;

  const HeadersWidget({
    super.key,
    required this.title,
    required this.message,
    this.density = HeaderDensity.compact,
    this.controller,
  });

  @override
  State<HeadersWidget> createState() => _HeadersWidgetState();
}

class _HeadersWidgetState extends State<HeadersWidget> {
  /// 请求头/响应头上次展开状态（按 title 区分），跨详情保持（旧版行为）
  static final Map<String, bool> _lastExpanded = {};

  /// 头部区分区默认展开，可点击标签行折叠
  late bool _expanded;
  final _rawSearchController = SearchTextController();

  @override
  void initState() {
    super.initState();
    _expanded = _lastExpanded[widget.title] ?? true;
  }

  @override
  void dispose() {
    _rawSearchController.dispose();
    super.dispose();
  }

  Widget _buildCopyButton(BuildContext context, String text) {
    final localizations = AppLocalizations.of(context)!;
    return IconButton(
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      padding: EdgeInsets.zero,
      iconSize: 15,
      tooltip: localizations.copy,
      onPressed: text.isEmpty
          ? null
          : () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              FlutterToastr.show(localizations.copied, context);
            },
      icon: SvgIcon('copy', size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  Widget _buildHeaderModeToggle(BuildContext context, AppConfiguration config, bool isText) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      padding: EdgeInsets.zero,
      iconSize: 15,
      tooltip: isText
          ? AppLocalizations.of(context)!.detailShowHeaderTable
          : AppLocalizations.of(context)!.detailShowRawHeaders,
      onPressed: () {
        if (!_expanded) {
          setState(() {
            _expanded = true;
            _lastExpanded[widget.title] = true;
          });
        }
        config.headerViewMode.value = isText ? 'table' : 'text';
        config.flushConfig();
      },
      icon: SvgIcon(isText ? 'list' : 'lines', size: 15, color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = AppConfiguration.current;
    if (config == null) return _buildSection(context, null, false);
    return ValueListenableBuilder<String>(
      valueListenable: config.headerViewMode,
      builder: (context, mode, _) => _buildSection(context, config, mode == 'text'),
    );
  }

  Widget _buildSection(BuildContext context, AppConfiguration? config, bool isText) {
    final labels = AppLocalizations.of(context)!;
    final entries = <MapEntry<String, String>>[];
    widget.message?.headers.forEach((name, values) {
      entries.addAll(values.map((value) => MapEntry(name, value)));
    });
    final raw = entries.map((entry) => '${entry.key}: ${entry.value}').join('\n');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DetailSectionHeader(
        label: widget.title == 'Request' ? labels.requestHeader : labels.responseHeader,
        count: entries.length,
        expanded: _expanded,
        onTap: () => setState(() {
          _expanded = !_expanded;
          _lastExpanded[widget.title] = _expanded;
        }),
        actions: [
          _buildCopyButton(context, raw),
          if (config != null) _buildHeaderModeToggle(context, config, isText),
        ],
      ),
      if (_expanded && entries.isNotEmpty)
        if (isText)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: HighlightTextWidget(
              text: raw,
              style: detailFieldStyle(context),
              language: 'http',
              searchController: _rawSearchController,
              contextMenuBuilder: contextMenu,
            ),
          )
        else
          DetailTable(entries: entries, density: widget.density),
    ]);
  }
}
