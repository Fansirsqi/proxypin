import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/component/code_font_setting.dart';
import 'package:proxypin/ui/configuration.dart';
import 'package:proxypin/utils/system_fonts.dart';

/// 整体界面字体（代码窗口另有「代码字体」设置，互不影响）。
class AppFontFamilyTile extends StatefulWidget {
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final bool showSubtitle;

  const AppFontFamilyTile({super.key, this.titleStyle, this.subtitleStyle, this.showSubtitle = true});

  @override
  State<AppFontFamilyTile> createState() => _AppFontFamilyTileState();
}

class _AppFontFamilyTileState extends State<AppFontFamilyTile> {
  static const String _custom = '__custom__';

  List<String> _families = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    SystemFonts.families().then((families) {
      if (!mounted) {
        return;
      }
      setState(() {
        _families = families;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final config = AppDisplaySettings.of(context);
    final current = config?.appFontFamily;

    final items = <DropdownMenuItem<String?>>[
      DropdownMenuItem(value: null, child: FontFamilyLabel(localizations.appFontSystem)),
      ..._families.map((family) => DropdownMenuItem(value: family, child: FontFamilyLabel(family))),
      if (current != null && current.isNotEmpty && !_families.contains(current))
        DropdownMenuItem(value: current, child: FontFamilyLabel(current)),
      DropdownMenuItem(value: _custom, child: FontFamilyLabel(localizations.codeFontCustom)),
    ];

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(localizations.appFont, style: widget.titleStyle),
      subtitle: widget.showSubtitle
          ? Text(localizations.appFontSubtitle, style: widget.subtitleStyle ?? const TextStyle(fontSize: 12))
          : null,
      trailing: SizedBox(
        width: 200,
        child: DropdownButton<String?>(
          value: current == null || current.isEmpty ? null : current,
          isExpanded: true,
          focusColor: Colors.transparent,
          hint:
              _loading ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)) : null,
          onChanged: (selected) async {
            if (selected == _custom) {
              final family = await _ask(context, current);
              if (family == null) {
                return;
              }
              config?.applyDisplaySetting(() => config.appFontFamily = family.trim().isEmpty ? null : family.trim());
            } else {
              config?.applyDisplaySetting(() => config.appFontFamily = selected);
            }
            if (mounted) {
              setState(() {});
            }
          },
          items: items,
        ),
      ),
    );
  }

  Future<String?> _ask(BuildContext context, String? current) async {
    final localizations = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: current ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(localizations.appFont),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(labelText: localizations.codeFontFamily, hintText: 'Noto Sans CJK SC'),
            onSubmitted: (value) => Navigator.pop(context, value),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(localizations.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(localizations.confirm)),
        ],
      ),
    );
    controller.dispose();
    return result;
  }
}

/// 整体界面字号缩放。
class AppFontScaleTile extends StatelessWidget {
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final bool showSubtitle;

  const AppFontScaleTile({super.key, this.titleStyle, this.subtitleStyle, this.showSubtitle = true});

  static const List<double> scales = [0.85, 0.9, 0.95, 1.0, 1.05, 1.1, 1.15, 1.2, 1.25];

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final config = AppDisplaySettings.of(context);
    final current = config?.appFontScale ?? 1.0;
    final values = scales.contains(current) ? scales : ([...scales, current]..sort());

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(localizations.appFontScale, style: titleStyle),
      subtitle: showSubtitle
          ? Text(localizations.appFontScaleSubtitle, style: subtitleStyle ?? const TextStyle(fontSize: 12))
          : null,
      trailing: SizedBox(
        width: 200,
        child: DropdownButton<double>(
          value: current,
          isExpanded: true,
          focusColor: Colors.transparent,
          onChanged: (scale) {
            if (scale == null) {
              return;
            }
            config?.applyDisplaySetting(() => config.appFontScale = scale);
          },
          items: values
              .map((scale) => DropdownMenuItem<double>(value: scale, child: Text('${(scale * 100).round()}%')))
              .toList(),
        ),
      ),
    );
  }
}

/// 整体界面密度（不影响抓包列表行，那一项单独设置）。
class UiDensityTile extends StatelessWidget {
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final bool showSubtitle;

  const UiDensityTile({super.key, this.titleStyle, this.subtitleStyle, this.showSubtitle = true});

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final config = AppDisplaySettings.of(context);

    return _DensityTile(
      configuration: config,
      setting: DisplayDensitySetting.interface,
      density: config?.uiDensity,
      title: localizations.uiDensity,
      titleStyle: titleStyle,
      subtitle: showSubtitle ? localizations.uiDensitySubtitle : null,
      subtitleStyle: subtitleStyle,
    );
  }
}

class CaptureDensityTile extends StatelessWidget {
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final bool showSubtitle;

  const CaptureDensityTile({super.key, this.titleStyle, this.subtitleStyle, this.showSubtitle = true});

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final config = AppDisplaySettings.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DensityTile(
          configuration: config,
          setting: DisplayDensitySetting.captureList,
          density: config?.captureListDensity,
          title: localizations.captureListDensity,
          titleStyle: titleStyle,
          subtitle: showSubtitle ? localizations.captureListDensitySubtitle : null,
          subtitleStyle: subtitleStyle,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(localizations.alwaysShowCaptureRowDetails, style: titleStyle),
          subtitle: showSubtitle
              ? Text(
                  localizations.alwaysShowCaptureRowDetailsSubtitle(AppConfiguration.captureRowDetailsThreshold),
                  style: subtitleStyle ?? const TextStyle(fontSize: 12),
                )
              : null,
          value: config?.alwaysShowCaptureRowDetails ?? false,
          onChanged: config == null
              ? null
              : (value) => config.applyDisplaySetting(() => config.alwaysShowCaptureRowDetails = value),
        ),
      ],
    );
  }
}

class _DensityTile extends StatelessWidget {
  final AppConfiguration? configuration;
  final DisplayDensitySetting setting;
  final double? density;
  final String title;
  final TextStyle? titleStyle;
  final String? subtitle;
  final TextStyle? subtitleStyle;

  const _DensityTile({
    required this.configuration,
    required this.setting,
    required this.density,
    required this.title,
    this.titleStyle,
    this.subtitle,
    this.subtitleStyle,
  });

  @override
  Widget build(BuildContext context) {
    final percent = density ?? AppConfiguration.defaultDisplayDensity;
    final config = configuration;
    String format(double value) => '${setting == DisplayDensitySetting.captureList ? value.floor() : value.round()}%';

    final style = subtitleStyle ?? const TextStyle(fontSize: 12);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ExcludeSemantics(
                  child: Text(title, style: titleStyle ?? Theme.of(context).textTheme.bodyLarge),
                ),
              ),
              const SizedBox(width: 12),
              ExcludeSemantics(child: Text(format(percent), style: style)),
            ],
          ),
          if (subtitle case final description?) Text(description, style: style),
          MergeSemantics(
            child: Semantics(
              label: title,
              child: Slider(
                value: percent,
                min: AppConfiguration.minimumDisplayDensity,
                max: AppConfiguration.maximumDisplayDensity,
                showValueIndicator: ShowValueIndicator.never,
                semanticFormatterCallback: format,
                onChanged: config == null ? null : (value) => config.setDisplayDensity(setting, value, commit: false),
                onChangeEnd: config == null ? null : (value) => config.setDisplayDensity(setting, value, commit: true),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
