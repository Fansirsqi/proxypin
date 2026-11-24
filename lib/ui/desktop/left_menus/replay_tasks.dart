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

import 'package:flutter/material.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/util/logger.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';
import 'package:proxypin/ui/toolbox/viewer_app_bar.dart';
import 'package:proxypin/utils/replay_task.dart';

class ReplayTasksPage extends StatefulWidget {
  final String windowId;

  const ReplayTasksPage({super.key, required this.windowId});

  @override
  State<ReplayTasksPage> createState() => _ReplayTasksPageState();
}

class _ReplayTasksPageState extends State<ReplayTasksPage> {
  List<_ReplayTaskRow>? _tasks;
  late final Timer _refreshTimer;
  bool _refreshing = false;
  bool _updating = false;
  bool _failed = false;
  int _revision = 0;

  AppLocalizations get localizations => AppLocalizations.of(context)!;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
  }

  @override
  void dispose() {
    _refreshTimer.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing || _updating) return;
    _refreshing = true;
    try {
      await _loadTasks('getReplayTasks');
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _update(String action, [String? id]) async {
    if (_updating) return;
    setState(() => _updating = true);
    _revision++;
    try {
      await _loadTasks('updateReplayTask', {'action': action, 'id': id});
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _loadTasks(String method, [Map<String, dynamic>? arguments]) async {
    final revision = _revision;
    try {
      final result = await DesktopMultiWindow.invokeMainWindowMethod<List<dynamic>>(method, arguments);
      if (!mounted || revision != _revision) return;
      if (result == null) throw StateError('Main window is unavailable');
      final tasks = result.map((task) => _ReplayTaskRow.fromMap(task as Map)).toList(growable: false);
      setState(() {
        _tasks = tasks;
        _failed = false;
      });
    } catch (error, stackTrace) {
      if (!mounted || revision != _revision) return;
      if (!_failed) logger.e('Could not load replay tasks', error: error, stackTrace: stackTrace);
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _tasks;
    return Scaffold(
      appBar: viewerAppBar(context, localizations.replayTasks, windowId: widget.windowId),
      body: Column(children: [
        if (_failed || (tasks?.any((task) => !task.isActive) ?? false))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(children: [
              if (_failed) Text(localizations.fail, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const Spacer(),
              if (tasks?.any((task) => !task.isActive) ?? false)
                TextButton(
                  onPressed: _updating || _failed ? null : () => _update('clearFinished'),
                  child: Text(localizations.clearFinished),
                ),
            ]),
          ),
        Expanded(
          child: switch (tasks) {
            null when !_failed => const Center(child: CircularProgressIndicator()),
            null => const SizedBox(),
            [] => Center(child: Text(localizations.emptyData)),
            _ => ListView.builder(itemCount: tasks.length, itemBuilder: (_, index) => _tile(tasks[index])),
          },
        ),
      ]),
    );
  }

  Widget _tile(_ReplayTaskRow task) {
    final color = Theme.of(context).colorScheme.primary;
    final canUpdate = !_updating && !_failed;
    return ListTile(
            key: ValueKey(task.id),
            dense: true,
            visualDensity: const VisualDensity(vertical: -2),
            leading: Text(task.method,
                style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500)),
            title: Text(task.url,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            subtitle: Row(children: [
              _statusChip(task),
              const SizedBox(width: 10),
              Text("${task.executedCount}/${task.totalCount}", style: const TextStyle(fontSize: 11)),
              if (task.isActive && task.nextRunAt != null) ...[
                const SizedBox(width: 10),
                Text(_formatTime(task.nextRunAt!), style: const TextStyle(fontSize: 11)),
              ],
            ]),
            trailing: task.isActive
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    if (task.status == ReplayTaskStatus.paused)
                      IconButton(
                          iconSize: 18,
                          tooltip: localizations.resume,
                          onPressed: canUpdate ? () => _update('resume', task.id) : null,
                          icon: const Icon(Icons.play_arrow_outlined))
                    else
                      IconButton(
                          iconSize: 18,
                          tooltip: localizations.pause,
                          onPressed: canUpdate ? () => _update('pause', task.id) : null,
                          icon: const Icon(Icons.pause_circle_outline)),
                    IconButton(
                        iconSize: 18,
                        tooltip: localizations.cancel,
                        onPressed: canUpdate ? () => _update('cancel', task.id) : null,
                        icon: const Icon(Icons.cancel_outlined)),
                  ])
                : IconButton(
                    iconSize: 18,
                    tooltip: localizations.delete,
                    onPressed: canUpdate ? () => _update('delete', task.id) : null,
                    icon: const Icon(Icons.delete_outline)),
          );
  }

  Widget _statusChip(_ReplayTaskRow task) {
    final (label, color) = switch (task.status) {
      ReplayTaskStatus.waiting => (localizations.statusWaiting, Colors.grey),
      ReplayTaskStatus.running => (localizations.statusRunning, Colors.blue),
      ReplayTaskStatus.paused => (localizations.statusPaused, Colors.orange),
      ReplayTaskStatus.completed => (localizations.done, Colors.green),
      ReplayTaskStatus.cancelled => (localizations.statusCancelled, Colors.red),
    };
    return Text(label, style: TextStyle(fontSize: 11, color: color));
  }

  String _formatTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return "${two(time.hour)}:${two(time.minute)}:${two(time.second)}";
  }
}

class _ReplayTaskRow {
  final String id;
  final String method;
  final String url;
  final ReplayTaskStatus status;
  final int executedCount;
  final int totalCount;
  final DateTime? nextRunAt;

  _ReplayTaskRow.fromMap(Map<dynamic, dynamic> map)
      : id = map['id'] as String,
        method = map['method'] as String,
        url = map['url'] as String,
        status = ReplayTaskStatus.values.byName(map['status'] as String),
        executedCount = map['executedCount'] as int,
        totalCount = map['totalCount'] as int,
        nextRunAt = switch (map['nextRunAt']) {
          final int milliseconds => DateTime.fromMillisecondsSinceEpoch(milliseconds),
          _ => null,
        };

  bool get isActive => status != ReplayTaskStatus.completed && status != ReplayTaskStatus.cancelled;
}
