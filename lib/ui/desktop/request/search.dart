/*
 * Copyright 2023 Hongen Wang All rights reserved.
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
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/http/content_type.dart';
import 'package:proxypin/ui/component/search_condition.dart';
import 'package:proxypin/ui/component/utils.dart';

import '../../component/model/search_model.dart';

/// @author wanghongen
/// 2023/10/8
class Search extends StatefulWidget {
  final Function(SearchModel searchModel)? onSearch;

  const Search({super.key, this.onSearch});

  @override
  State<StatefulWidget> createState() {
    return SearchState();
  }
}

class SearchState extends State<Search> {
  SearchModel searchModel = SearchModel();
  bool searched = false;
  final TextEditingController keywordController = TextEditingController();
  Timer? _keywordTimer;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void dispose() {
    _keywordTimer?.cancel();
    keywordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final height = math.max(32.0, MediaQuery.textScalerOf(context).scale(13) + 12);
    return Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
        child: LayoutBuilder(builder: (context, constraints) {
          final compact = constraints.maxWidth < 160;
          return TextField(
            controller: keywordController,
            style: const TextStyle(fontSize: 13),
            onChanged: _onKeywordChanged,
            decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: colors.surfaceContainer,
                constraints: BoxConstraints(minHeight: height),
                contentPadding: const EdgeInsets.symmetric(vertical: 6),
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: colors.outline), borderRadius: BorderRadius.circular(6)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: colors.primary), borderRadius: BorderRadius.circular(6)),
                prefixIconConstraints: BoxConstraints.tightFor(width: 32, height: height),
                prefixIcon: IconButton(
                    tooltip: localizations.search,
                    icon: Icon(Icons.search, size: 17, color: searched ? okColor(theme) : colors.onSurfaceVariant),
                    padding: EdgeInsets.zero,
                    onPressed: searchDialog),
                hintText: localizations.search,
                hintMaxLines: 1,
                hintStyle: TextStyle(color: colors.onSurfaceVariant),
                suffixIconConstraints: BoxConstraints.tightFor(width: compact ? 32 : 76, height: height),
                suffixIcon: _ContentTypeSelect(
                    compact: compact,
                    selected: searchModel.responseContentTypes,
                    onSelected: (contentType) {
                      if (_keywordTimer?.isActive == true) {
                        _keywordTimer!.cancel();
                        _setKeywordOptions();
                      }
                      setState(() {
                        searchModel.responseContentTypes = contentType == null ? {} : {contentType};
                        searchModel.protocols = {};
                        searched = searchModel.isNotEmpty;
                      });
                      widget.onSearch?.call(searchModel.clone());
                    })),
          );
        }));
  }

  void _onKeywordChanged(String keyword) {
    searchModel.keyword = keyword;
    if (_keywordTimer?.isActive == true) {
      return;
    }
    _keywordTimer = Timer(const Duration(milliseconds: 500), () {
      _setKeywordOptions();
      widget.onSearch?.call(searchModel.clone());
    });
  }

  void _setKeywordOptions() {
    if (!searched) {
      searchModel.searchOptions = {Option.url, Option.method, Option.responseContentType};
    }
  }

  void searchDialog() {
    final conditions = searchModel.clone();
    if (!searched) {
      conditions.searchOptions = {Option.url};
    }
    final theme = Theme.of(context);
    final box = context.findRenderObject() as RenderBox;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final offset = box.localToGlobal(Offset.zero, ancestor: overlay);
    final anchor = offset & box.size;
    const edge = 8.0;
    const gap = 4.0;
    final above = anchor.top - edge - gap;
    final below = overlay.size.height - anchor.bottom - edge - gap;
    final openBelow = below >= above;
    final actionTextStyle = theme.textTheme.labelLarge?.copyWith(fontSize: 14);
    final textDirection = Directionality.of(context);
    final textScaler = MediaQuery.textScalerOf(context);
    final actionsWidth =
        [localizations.cancel, localizations.clearSearch, localizations.confirm].fold(0.0, (sum, label) {
      final textWidth = TextPainter.computeWidth(
          text: TextSpan(text: label, style: actionTextStyle), textDirection: textDirection, textScaler: textScaler);
      return sum + math.max(64.0, textWidth + 24);
    });
    final contentWidth = math.max(340.0, actionsWidth + 30);
    final width = math.min(contentWidth, math.max(0.0, overlay.size.width - edge * 2));
    final left = (anchor.left + edge).clamp(edge, math.max(edge, overlay.size.width - width - edge)).toDouble();
    final maxHeight = math.max(0.0, openBelow ? below : above);

    showGeneralDialog<void>(
        context: context,
        useRootNavigator: false,
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 120),
        pageBuilder: (dialogContext, animation, secondaryAnimation) {
          final content = SizedBox(
              width: contentWidth,
              child: Padding(
                  padding: const EdgeInsets.fromLTRB(15, 10, 15, 5),
                  child: DefaultTextStyle.merge(
                      style: theme.textTheme.bodyMedium?.copyWith(fontSize: 14),
                      child: SearchConditions(
                          searchModel: conditions,
                          onClose: () => Navigator.of(dialogContext).pop(),
                          onSearch: (value) {
                            _keywordTimer?.cancel();
                            setState(() {
                              searchModel = value;
                              searched = searchModel.isNotEmpty;
                              keywordController.text = searchModel.keyword ?? '';
                            });
                            widget.onSearch?.call(searchModel.clone());
                          }))));
          return Stack(children: [
            Positioned(
                left: left,
                top: openBelow ? anchor.bottom + gap : null,
                bottom: openBelow ? null : overlay.size.height - anchor.top + gap,
                width: width,
                child: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(8),
                    clipBehavior: Clip.antiAlias,
                    color: theme.cardColor,
                    shadowColor: theme.shadowColor,
                    child: ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: maxHeight),
                        child: SingleChildScrollView(
                            child: width < contentWidth
                                ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: content)
                                : content)))),
          ]);
        });
  }
}

class _ContentTypeSelect extends StatelessWidget {
  final bool compact;
  final Set<ContentType> selected;
  final ValueChanged<ContentType?> onSelected;

  const _ContentTypeSelect({required this.compact, required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final type = selected.length == 1 ? selected.single.name.toUpperCase() : localizations.all;
    final types = ['JSON', 'IMAGE', 'HTML', 'XML', 'JS', 'CSS', 'TEXT', localizations.all];
    final colors = Theme.of(context).colorScheme;
    final color = selected.isEmpty ? colors.onSurfaceVariant : colors.primary;

    return PopupMenuButton<String>(
      initialValue: type,
      position: PopupMenuPosition.under,
      tooltip: '${localizations.responseType} · $type',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 80),
      child: compact
          ? Icon(Icons.filter_list, size: 17, color: color)
          : Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              Flexible(
                  child: Text(type,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: color))),
              Icon(Icons.arrow_drop_down, size: 18, color: color),
              const SizedBox(width: 6),
            ]),
      onSelected: (value) {
        if (value != type || selected.length > 1) {
          onSelected(value == localizations.all ? null : ContentType.valueOf(value));
        }
      },
      itemBuilder: (context) => types
          .map((value) =>
              PopupMenuItem<String>(height: 30, value: value, child: Text(value, style: const TextStyle(fontSize: 12))))
          .toList(),
    );
  }
}
