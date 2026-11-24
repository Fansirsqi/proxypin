import 'package:flutter/material.dart';
import 'package:proxypin/ui/configuration.dart';

TextStyle codeTextStyle(BuildContext context, {TextStyle? base, double? size, Color? color}) {
  final configuration = AppDisplaySettings.of(context);
  return (base ?? const TextStyle()).copyWith(
    fontFamily: configuration?.editorFontFamily ?? configuration?.appFontFamily,
    fontSize: configuration?.editorFontSize ?? size,
    color: color,
  );
}
