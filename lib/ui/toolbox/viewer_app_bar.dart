import 'dart:io';

import 'package:flutter/material.dart';
import 'package:proxypin/utils/platform.dart';

bool hasToolWindowTitle(String? windowId) => windowId != null && (Platform.isWindows || Platform.isLinux);

AppBar? viewerAppBar(
  BuildContext context,
  String title, {
  String? windowId,
  PreferredSizeWidget? bottom,
  List<Widget>? actions,
}) {
  if (hasToolWindowTitle(windowId)) {
    if (bottom == null && actions == null) return null;
    return AppBar(toolbarHeight: actions == null ? 0 : null, actions: actions, bottom: bottom);
  }

  final hasBackButton = ModalRoute.of(context)?.impliesAppBarDismissal ?? false;
  final compact = Platforms.isDesktop() && !hasBackButton;
  return AppBar(
    toolbarHeight: compact ? 23 : null,
    title: Text(
      title,
      style: compact ? const TextStyle(fontSize: 14, fontWeight: FontWeight.w300) : const TextStyle(fontSize: 16),
    ),
    centerTitle: true,
    actions: actions,
    bottom: bottom,
  );
}
