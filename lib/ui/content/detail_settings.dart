import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/configuration.dart';

class DetailLayoutSettings extends StatelessWidget {
  final AppConfiguration configuration;
  final bool _asMenu;

  const DetailLayoutSettings({super.key, required this.configuration}) : _asMenu = false;

  const DetailLayoutSettings.menu({super.key, required this.configuration}) : _asMenu = true;

  void _update(DetailLayout value) {
    configuration.detailLayout.value = value;
    configuration.flushConfig();
  }

  @override
  Widget build(BuildContext context) {
    final labels = AppLocalizations.of(context)!;
    return ValueListenableBuilder<DetailLayout>(
      valueListenable: configuration.detailLayout,
      builder: (context, layout, _) {
        final options = [
          _options(
            title: labels.detailTabAlignment,
            choices: {
              DetailTabAlignment.left: labels.detailAlignLeft,
              DetailTabAlignment.center: labels.detailAlignCenter,
              DetailTabAlignment.right: labels.detailAlignRight,
            },
            selected: layout.tabs,
            onSelected: (value) => _update((tabs: value, labels: layout.labels, headers: layout.headers)),
          ),
          _options(
            title: labels.detailTabLabelAlignment,
            choices: {
              DetailTabLabelAlignment.top: labels.detailAlignTop,
              DetailTabLabelAlignment.center: labels.detailAlignCenter,
              DetailTabLabelAlignment.bottom: labels.detailAlignBottom,
            },
            selected: layout.labels,
            onSelected: (value) => _update((tabs: layout.tabs, labels: value, headers: layout.headers)),
          ),
          _options(
            title: labels.detailHeaderDensity,
            choices: {
              HeaderDensity.comfortable: labels.detailDensityComfortable,
              HeaderDensity.compact: labels.detailDensityCompact,
              HeaderDensity.dense: labels.detailDensityDense,
            },
            selected: layout.headers,
            onSelected: (value) => _update((tabs: layout.tabs, labels: layout.labels, headers: value)),
          ),
        ];
        if (!_asMenu) return Column(mainAxisSize: MainAxisSize.min, children: options);
        return MenuAnchor(
          builder: (context, controller, child) => IconButton(
            tooltip: labels.detailLayoutSettings,
            icon: const Icon(Icons.tune, size: 16),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            padding: EdgeInsets.zero,
            onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          ),
          menuChildren: options,
        );
      },
    );
  }

  Widget _options<T>({
    required String title,
    required Map<T, String> choices,
    required T selected,
    required ValueChanged<T> onSelected,
  }) {
    if (_asMenu) {
      return SubmenuButton(
        menuChildren: [
          for (final choice in choices.entries)
            MenuItemButton(
              leadingIcon: Icon(
                choice.key == selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 16,
              ),
              onPressed: () => onSelected(choice.key),
              child: Text(choice.value),
            ),
        ],
        child: Text(title),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title, style: Theme.of(context).textTheme.titleSmall),
        trailing: SizedBox(
          width: (constraints.maxWidth * .4).clamp(0.0, 200.0),
          child: DropdownButton<T>(
            isExpanded: true,
            value: selected,
            items: [
              for (final choice in choices.entries)
                DropdownMenuItem(value: choice.key, child: Text(choice.value, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (value) {
              if (value != null) onSelected(value);
            },
          ),
        ),
      ),
    );
  }
}
