import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:proxypin/ui/component/floating_dialog.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/component/saved_theme.dart';
import 'package:proxypin/ui/component/theme_presets.dart';
import 'package:proxypin/ui/configuration.dart';

class ThemePaletteSettings extends StatefulWidget {
  final AppConfiguration configuration;

  const ThemePaletteSettings({super.key, required this.configuration});

  @override
  State<ThemePaletteSettings> createState() => _ThemePaletteSettingsState();
}

class _ThemePaletteSettingsState extends State<ThemePaletteSettings> {
  AppConfiguration get configuration => widget.configuration;
  bool _pickingFile = false;

  Future<void> _editTheme({SavedTheme? current}) async {
    if (_pickingFile) return;
    final labels = AppLocalizations.of(context)!;
    final initial = current ?? configuration.snapshotTheme(labels.theme);
    final brightness = Theme.brightnessOf(context);
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SavedThemeDialog(
        initial: initial,
        brightness: brightness,
        editing: current != null,
        canSave: (name) => configuration.canSaveTheme(name, replacing: current),
        onSave: (theme) => configuration.saveTheme(theme, replacing: current),
      ),
    );
    if (saved == true && mounted) _showMessage(labels.saveSuccess);
  }

  Future<void> _importTheme() async {
    final labels = AppLocalizations.of(context)!;
    await _pickThemeFile(() async {
      final file = await FilePicker.pickFile(
        dialogTitle: labels.themeImport,
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null || !mounted) return;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (chunk.length > SavedTheme.maxFileBytes - bytes.length) {
          throw const FormatException('Theme file is too large');
        }
        bytes.add(chunk);
      }
      final theme = SavedTheme.decode(utf8.decode(bytes.takeBytes()));
      if (!mounted) return;
      final saved = await configuration.saveTheme(theme);
      if (mounted) _showMessage(saved ? labels.importSuccess : labels.themeNameInUse);
    }, labels.importFailed);
  }

  Future<void> _exportTheme(SavedTheme theme) async {
    final labels = AppLocalizations.of(context)!;
    await _pickThemeFile(() async {
      final saved = await FilePicker.saveFile(
        dialogTitle: labels.themeExport,
        fileName: 'proxypin-theme.json',
        mimeType: 'application/json',
        bytes: utf8.encode(theme.encoded),
      );
      if (saved != null && mounted) _showMessage(labels.exportSuccess);
    }, labels.exportFailed);
  }

  Future<void> _pickThemeFile(Future<void> Function() pick, String failure) async {
    if (_pickingFile) return;
    final labels = AppLocalizations.of(context)!;
    setState(() => _pickingFile = true);
    try {
      await pick();
    } on UnsupportedThemeVersion {
      if (mounted) _showMessage(labels.themeUnsupportedVersion);
    } on FormatException {
      if (mounted) _showMessage(labels.themeInvalidFile);
    } catch (_) {
      if (mounted) _showMessage(failure);
    } finally {
      if (mounted) setState(() => _pickingFile = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

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
            for (final option in {...ThemePreset.values, ...configuration.savedThemes, preset})
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
          onChanged: _pickingFile
              ? null
              : (value) {
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
              for (final role in ThemeColorRole.values)
                _PaletteChip(
                  role,
                  colors,
                  onPressed: () async {
                    final result = await _pickColor(
                      context,
                      role,
                      configuration.paletteColor(role),
                      reset: role == ThemeColorRole.primary ? labels.reset : labels.automatic,
                    );
                    if (result != null && mounted) configuration.setPaletteColor(role, result.seed);
                  },
                )
            ],
          ),
        ],
        Wrap(
          spacing: 4,
          children: [
            TextButton(onPressed: _pickingFile ? null : () => _editTheme(), child: Text(labels.themeCreate)),
            if (preset is SavedTheme)
              TextButton(
                onPressed: _pickingFile ? null : () => _editTheme(current: preset),
                child: Text(labels.themeEdit),
              ),
            TextButton(onPressed: _pickingFile ? null : _importTheme, child: Text(labels.themeImport)),
            if (preset is SavedTheme)
              TextButton(onPressed: _pickingFile ? null : () => _exportTheme(preset), child: Text(labels.themeExport)),
          ],
        ),
      ],
    );
  }
}

class _SavedThemeDialog extends StatefulWidget {
  final SavedTheme initial;
  final Brightness brightness;
  final bool editing;
  final bool Function(String) canSave;
  final Future<bool> Function(SavedTheme) onSave;

  const _SavedThemeDialog({
    required this.initial,
    required this.brightness,
    required this.editing,
    required this.canSave,
    required this.onSave,
  });

  @override
  State<_SavedThemeDialog> createState() => _SavedThemeDialogState();
}

class _SavedThemeDialogState extends State<_SavedThemeDialog> {
  late final _name = TextEditingController(text: widget.editing ? widget.initial.name : '');
  late Brightness _brightness = widget.brightness;
  final Map<(Brightness, ThemeColorRole), Color> _changes = {};
  bool _saving = false;
  String? _saveError;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  ColorScheme _palette(Brightness brightness) {
    var colors = widget.initial.colorScheme(brightness);
    for (final role in ThemeColorRole.values) {
      if (_changes[(brightness, role)] case final color?) colors = role.withColor(colors, color);
    }
    return colors;
  }

  Future<void> _save(String name, AppLocalizations labels) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    var error = labels.themeNameInUse;
    try {
      final saved = await widget.onSave(SavedTheme(
        name: name,
        light: _palette(Brightness.light),
        dark: _palette(Brightness.dark),
        lightString: widget.initial.lightString,
        darkString: widget.initial.darkString,
      ));
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context, true);
        return;
      }
    } catch (_) {
      error = labels.fail;
    }
    if (mounted) {
      setState(() {
        _saving = false;
        _saveError = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = AppLocalizations.of(context)!;
    final name = _name.text.trim();
    final valid = widget.canSave(name);
    final error = name.isEmpty || valid
        ? null
        : SavedTheme.isValidName(name)
            ? labels.themeNameInUse
            : labels.themeInvalidName;
    final colors = _palette(_brightness);
    return PopScope(
      canPop: !_saving,
      child: FloatingAlertDialog(
        scrollable: true,
        title: Text(widget.editing ? labels.themeEdit : labels.themeCreate),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                enabled: !_saving,
                maxLength: SavedTheme.maxNameLength,
                decoration: InputDecoration(labelText: labels.name, errorText: _saveError ?? error),
                onChanged: (_) => setState(() => _saveError = null),
              ),
              SegmentedButton<Brightness>(
                segments: [
                  ButtonSegment(value: Brightness.light, label: Text(labels.themeLight)),
                  ButtonSegment(value: Brightness.dark, label: Text(labels.themeDark)),
                ],
                selected: {_brightness},
                onSelectionChanged: _saving ? null : (selection) => setState(() => _brightness = selection.single),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final role in ThemeColorRole.values)
                    _PaletteChip(
                      role,
                      colors,
                      onPressed: _saving
                          ? null
                          : () async {
                              final brightness = _brightness;
                              final result = await _pickColor(context, role, SavedTheme.hex(role.color(colors)),
                                  reset: labels.reset);
                              if (result == null || !mounted) return;
                              setState(() {
                                final key = (brightness, role);
                                final original = role.color(widget.initial.colorScheme(brightness));
                                if (ThemeModel.parseColor(result.seed) case final color? when color != original) {
                                  _changes[key] = color;
                                } else {
                                  _changes.remove(key);
                                }
                              });
                            },
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: Text(labels.cancel)),
          TextButton(
            onPressed: valid && !_saving ? () => _save(name, labels) : null,
            child: Text(labels.save),
          ),
        ],
      ),
    );
  }
}

Future<({String? seed})?> _pickColor(BuildContext context, ThemeColorRole role, String? current,
        {required String reset}) =>
    showDialog<({String? seed})>(
      context: context,
      builder: (_) => _PaletteColorDialog(
        title: role.label(AppLocalizations.of(context)!),
        reset: reset,
        current: current,
      ),
    );

class _PaletteChip extends StatelessWidget {
  final ThemeColorRole role;
  final ColorScheme colors;
  final VoidCallback? onPressed;

  const _PaletteChip(this.role, this.colors, {required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (role) {
      ThemeColorRole.primary => (colors.primaryContainer, colors.onPrimaryContainer),
      ThemeColorRole.secondary => (colors.secondaryContainer, colors.onSecondaryContainer),
      ThemeColorRole.tertiary => (colors.tertiaryContainer, colors.onTertiaryContainer),
      ThemeColorRole.surface => (colors.surfaceContainerHigh, colors.onSurface),
    };
    return ActionChip(
      avatar: _Swatch(role.color(colors)),
      label: Text(role.label(AppLocalizations.of(context)!)),
      backgroundColor: background,
      labelStyle: TextStyle(color: foreground),
      onPressed: onPressed,
    );
  }
}

extension on ThemeColorRole {
  String label(AppLocalizations labels) => switch (this) {
        ThemeColorRole.primary => labels.themePrimary,
        ThemeColorRole.secondary => labels.themeSecondary,
        ThemeColorRole.tertiary => labels.themeTertiary,
        ThemeColorRole.surface => labels.themeSurface,
      };

  Color color(ColorScheme scheme) => switch (this) {
        ThemeColorRole.primary => scheme.primary,
        ThemeColorRole.secondary => scheme.secondary,
        ThemeColorRole.tertiary => scheme.tertiary,
        ThemeColorRole.surface => scheme.surface,
      };

  ColorScheme withColor(ColorScheme scheme, Color color) {
    final onColor = color.computeLuminance() > .179 ? Colors.black : Colors.white;
    final seed = ColorScheme.fromSeed(seedColor: color, brightness: scheme.brightness);
    return switch (this) {
      ThemeColorRole.primary => scheme.copyWith(
          primary: color,
          onPrimary: onColor,
          primaryContainer: seed.primaryContainer,
          onPrimaryContainer: seed.onPrimaryContainer,
          primaryFixed: seed.primaryFixed,
          primaryFixedDim: seed.primaryFixedDim,
          onPrimaryFixed: seed.onPrimaryFixed,
          onPrimaryFixedVariant: seed.onPrimaryFixedVariant,
          inversePrimary: seed.inversePrimary,
        ),
      ThemeColorRole.secondary => scheme.copyWith(
          secondary: color,
          onSecondary: onColor,
          secondaryContainer: seed.primaryContainer,
          onSecondaryContainer: seed.onPrimaryContainer,
          secondaryFixed: seed.primaryFixed,
          secondaryFixedDim: seed.primaryFixedDim,
          onSecondaryFixed: seed.onPrimaryFixed,
          onSecondaryFixedVariant: seed.onPrimaryFixedVariant,
        ),
      ThemeColorRole.tertiary => scheme.copyWith(
          tertiary: color,
          onTertiary: onColor,
          tertiaryContainer: seed.primaryContainer,
          onTertiaryContainer: seed.onPrimaryContainer,
          tertiaryFixed: seed.primaryFixed,
          tertiaryFixedDim: seed.primaryFixedDim,
          onTertiaryFixed: seed.onPrimaryFixed,
          onTertiaryFixedVariant: seed.onPrimaryFixedVariant,
        ),
      ThemeColorRole.surface => _surfaceColors(scheme, color, onColor),
    };
  }

  ColorScheme _surfaceColors(ColorScheme scheme, Color color, Color onColor) {
    final tint = onColor == Colors.white ? Colors.black : Colors.white;
    Color blend(double amount) => Color.alphaBlend(tint.withValues(alpha: amount), color);
    return scheme.copyWith(
      surface: color,
      onSurface: onColor,
      onSurfaceVariant: onColor,
      surfaceDim: blend(.16),
      surfaceBright: color,
      surfaceContainerLowest: blend(.18),
      surfaceContainerLow: blend(.1),
      surfaceContainer: blend(.05),
      surfaceContainerHigh: blend(.13),
      surfaceContainerHighest: blend(.16),
      outline: onColor,
      outlineVariant: Color.alphaBlend(onColor.withValues(alpha: .24), color),
      inverseSurface: onColor,
      onInverseSurface: tint,
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
  final String reset;
  final String? current;

  const _PaletteColorDialog({required this.title, required this.reset, required this.current});

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
    return FloatingAlertDialog(
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
        TextButton(onPressed: () => Navigator.pop(context, (seed: null)), child: Text(widget.reset)),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(labels.cancel)),
        TextButton(
          onPressed: valid ? () => Navigator.pop(context, (seed: customColor)) : null,
          child: Text(labels.save),
        ),
      ],
    );
  }
}
