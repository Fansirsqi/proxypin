import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/component/theme_presets.dart';
import 'package:proxypin/ui/configuration.dart';

class ThemePaletteSettings extends StatelessWidget {
  final AppConfiguration configuration;

  const ThemePaletteSettings({super.key, required this.configuration});

  @override
  Widget build(BuildContext context) {
    final labels = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final preset = configuration.themePreset;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButton<ThemePreset>(
          isExpanded: true,
          value: preset,
          items: [
            for (final option in ThemePreset.values)
              DropdownMenuItem(
                value: option,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        option == ThemePreset.custom ? labels.custom : option.label(colors.brightness),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    for (final color in option.swatches(colors.brightness))
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: _Swatch(color, size: 12),
                      ),
                  ],
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) configuration.themePreset = value;
          },
        ),
        if (preset == ThemePreset.custom) ...[
          DropdownButton<PaletteStyle>(
            isExpanded: true,
            value: configuration.paletteStyle,
            items: [
              for (final (style, name) in [
                (PaletteStyle.classic, labels.paletteClassic),
                (PaletteStyle.soft, labels.paletteSoft),
                (PaletteStyle.vivid, labels.paletteVivid),
                (PaletteStyle.neutral, labels.paletteNeutral),
              ])
                DropdownMenuItem(value: style, child: Text(name)),
            ],
            onChanged: (style) {
              if (style != null) configuration.paletteStyle = style;
            },
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (role, label, color, container, onContainer) in [
                (
                  ThemeColorRole.primary,
                  labels.themePrimary,
                  colors.primary,
                  colors.primaryContainer,
                  colors.onPrimaryContainer
                ),
                (
                  ThemeColorRole.secondary,
                  labels.themeSecondary,
                  colors.secondary,
                  colors.secondaryContainer,
                  colors.onSecondaryContainer,
                ),
                (
                  ThemeColorRole.tertiary,
                  labels.themeTertiary,
                  colors.tertiary,
                  colors.tertiaryContainer,
                  colors.onTertiaryContainer,
                ),
                (
                  ThemeColorRole.surface,
                  labels.themeSurface,
                  colors.surface,
                  colors.surfaceContainerHigh,
                  colors.onSurface
                ),
              ])
                ActionChip(
                  avatar: _Swatch(color),
                  label: Text(label),
                  backgroundColor: container,
                  labelStyle: TextStyle(color: onContainer),
                  onPressed: () async {
                    final result = await showDialog<({String? seed})>(
                      context: context,
                      builder: (_) => _PaletteColorDialog(
                        title: label,
                        role: role,
                        current: configuration.paletteColor(role),
                      ),
                    );
                    if (result != null) configuration.setPaletteColor(role, result.seed);
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final double size;

  const _Swatch(this.color, {this.size = 18});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: SizedBox.square(dimension: size),
      );
}

class _PaletteColorDialog extends StatefulWidget {
  final String title;
  final ThemeColorRole role;
  final String? current;

  const _PaletteColorDialog({required this.title, required this.role, required this.current});

  @override
  State<_PaletteColorDialog> createState() => _PaletteColorDialogState();
}

class _PaletteColorDialogState extends State<_PaletteColorDialog> {
  late final TextEditingController controller = TextEditingController(
    text: ColorMapping.colors.containsKey(widget.current) ? '' : widget.current,
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = AppLocalizations.of(context)!;
    final customColor = controller.text.trim();
    final valid = ThemeModel.parseColor(customColor) != null && !ColorMapping.colors.containsKey(customColor);
    final reset = widget.role == ThemeColorRole.primary ? labels.reset : labels.automatic;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              children: [
                for (final entry in ColorMapping.colors.entries)
                  IconButton(
                    tooltip: entry.key,
                    isSelected: widget.current == entry.key,
                    icon: _Swatch(entry.value),
                    onPressed: () => Navigator.pop(context, (seed: entry.key)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'HEX', hintText: '#4A6CF7'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (valid) Navigator.pop(context, (seed: customColor));
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, (seed: null)), child: Text(reset)),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(labels.cancel)),
        TextButton(
          onPressed: valid ? () => Navigator.pop(context, (seed: customColor)) : null,
          child: Text(labels.save),
        ),
      ],
    );
  }
}
