import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/utils/platform.dart';

TextStyle? detailSectionStyle(BuildContext context) {
  final theme = Theme.of(context);
  return theme.textTheme.labelLarge?.copyWith(
    color: theme.colorScheme.onSurfaceVariant,
    fontWeight: FontWeight.w500,
  );
}

Widget detailDivider(BuildContext context) {
  return Divider(height: 1, thickness: 1, color: Theme.of(context).dividerColor.withValues(alpha: 0.35));
}

TextStyle? detailFieldStyle(BuildContext context) => Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.35);

class DetailSectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final bool expanded;
  final VoidCallback onTap;
  final List<Widget> actions;

  const DetailSectionHeader({
    super.key,
    required this.label,
    required this.count,
    required this.expanded,
    required this.onTap,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = detailSectionStyle(context);
    return Column(children: [
      detailDivider(context),
      Row(children: [
        Expanded(
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(children: [
                  Icon(
                    expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Flexible(child: Text(label, style: style)),
                  if (!expanded && count > 0) Text(' · $count', style: style),
                ]),
              ),
            ),
          ),
        ),
        ...actions,
        if (actions.isNotEmpty) const SizedBox(width: 6),
      ]),
    ]);
  }
}

class DetailTable extends StatelessWidget {
  final Iterable<MapEntry<String, String>> entries;
  final HeaderDensity density;

  const DetailTable({super.key, required this.entries, required this.density});

  @override
  Widget build(BuildContext context) {
    return DetailRows(rows: [
      for (final entry in entries)
        DetailField(name: entry.key, value: entry.value, density: density, copyBothCells: true),
    ]);
  }
}

class DetailRows extends StatelessWidget {
  final List<Widget> rows;

  const DetailRows({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var index = 0; index < rows.length; index++) ...[
        if (index > 0) detailDivider(context),
        rows[index],
      ],
    ]);
    if (Platforms.isDesktop()) return content;

    final theme = Theme.of(context);
    final borderRadius = BorderRadius.circular(10);
    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border.all(
          color: theme.brightness == Brightness.light ? theme.dividerColor.withValues(alpha: 0.6) : theme.dividerColor,
        ),
        color: theme.colorScheme.surface,
      ),
      child: ClipRRect(borderRadius: borderRadius, child: content),
    );
  }
}

class DetailField extends StatelessWidget {
  final String name;
  final String value;
  final Color? valueColor;
  final HeaderDensity density;
  final bool copyBothCells;

  const DetailField({
    super.key,
    required this.name,
    required this.value,
    required this.density,
    this.valueColor,
    this.copyBothCells = false,
  });

  Widget _fieldMenu(BuildContext context, EditableTextState state, {required bool nameCell}) {
    final labels = AppLocalizations.of(context)!;
    return contextMenu(
      context,
      state,
      copyValueLabel: nameCell ? labels.detailCopyHeaderName : labels.detailCopyHeaderValue,
      customItem: ContextMenuButtonItem(
        label: nameCell ? labels.detailCopyHeaderValue : labels.detailCopyHeaderName,
        onPressed: () async {
          unSelect(state);
          state.hideToolbar();
          await Clipboard.setData(ClipboardData(text: nameCell ? value : name));
          if (context.mounted) FlutterToastr.show(labels.copied, context);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = detailFieldStyle(context);
    final nameStyle = style?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final verticalPadding = switch (density) {
      HeaderDensity.comfortable => 8.0,
      HeaderDensity.compact => 4.0,
      HeaderDensity.dense => 2.0,
    };
    return LayoutBuilder(builder: (context, constraints) {
      final inset = Platforms.isDesktop() ? 12.0 : 14.0;
      final width = ((constraints.maxWidth - 2 * inset) * 0.33).clamp(0.0, 220.0);
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: inset, vertical: verticalPadding),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: width,
            child: copyBothCells
                ? SelectableText(name, style: nameStyle, contextMenuBuilder: (context, state) {
                    return _fieldMenu(context, state, nameCell: true);
                  })
                : Text(name, style: nameStyle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              value,
              style: style?.copyWith(color: valueColor ?? theme.colorScheme.onSurface),
              contextMenuBuilder:
                  copyBothCells ? (context, state) => _fieldMenu(context, state, nameCell: false) : contextMenu,
            ),
          ),
        ]),
      );
    });
  }
}
