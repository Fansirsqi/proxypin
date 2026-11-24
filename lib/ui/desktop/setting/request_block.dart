/*
 * Copyright 2023 Hongen Wang
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
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/network/components/manager/request_block_manager.dart';
import 'package:proxypin/ui/component/utils.dart';
import 'package:proxypin/ui/component/widgets.dart';
import 'package:proxypin/ui/component/multi_window_compat.dart';

class RequestBlock extends StatefulWidget {
  final RequestBlockManager requestBlockManager;

  const RequestBlock({super.key, required this.requestBlockManager});

  @override
  State<RequestBlock> createState() => _RequestBlockState();
}

class _RequestBlockState extends State<RequestBlock> {
  AppLocalizations get localizations => AppLocalizations.of(context)!;

  Future<void> _save() => DesktopMultiWindow.saveStandaloneChanges(() async {
        await widget.requestBlockManager.flushConfig();
        await DesktopMultiWindow.invokeMainWindowMethod('refreshRequestBlock');
      });

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): _close,
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true): _close,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: DesktopMultiWindow.isStandalone ? null : AppBar(title: Text(localizations.requestBlock)),
          body: Padding(
            padding: const EdgeInsets.fromLTRB(15, 8, 15, 12),
            child: Column(children: [
              Row(children: [
                const SizedBox(width: 8),
                Text(localizations.enable),
                const SizedBox(width: 10),
                SwitchWidget(
                    scale: 0.8,
                    value: widget.requestBlockManager.enabled,
                    onChanged: (value) {
                      setState(() => widget.requestBlockManager.enabled = value);
                      _save();
                    }),
                const Expanded(child: SizedBox()),
                TextButton.icon(
                    icon: const Icon(Icons.add, size: 18), onPressed: showEdit, label: Text(localizations.add)),
                const SizedBox(width: 5),
              ]),
              const SizedBox(height: 8),
              Expanded(
                  child: Container(
                      decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor)),
                      child: Column(children: [
                        const SizedBox(height: 5),
                        Row(children: [
                          Container(width: 15),
                          const Expanded(child: Text('URL', style: TextStyle(fontSize: 14))),
                          SizedBox(width: 80, child: Text(localizations.enable, style: const TextStyle(fontSize: 14))),
                          Container(width: 18),
                          SizedBox(width: 120, child: Text(localizations.action, style: const TextStyle(fontSize: 14))),
                        ]),
                        const Divider(thickness: 0.5),
                        Expanded(
                            child: ListView.builder(
                                itemCount: widget.requestBlockManager.list.length,
                                itemBuilder: (_, index) => row(index)))
                      ])))
            ]),
          ),
        ),
      ),
    );
  }

  void _close() {
    final windowId = DesktopMultiWindow.currentWindowId;
    if (windowId != null) WindowController.fromWindowId(windowId).close();
  }

  Widget row(int index) {
    var primaryColor = Theme.of(context).colorScheme.primary;
    bool isCN = localizations.localeName == 'zh';
    var list = widget.requestBlockManager.list;

    return InkWell(
        highlightColor: Colors.transparent,
        splashColor: Colors.transparent,
        hoverColor: primaryColor.withOpacity(0.3),
        onSecondaryTapDown: (details) => showMenus(details, index),
        onDoubleTap: () => showEdit(index),
        child: Container(
            color: index.isEven ? Colors.grey.withOpacity(0.10) : null,
            height: 36,
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                const SizedBox(width: 10),
                Expanded(child: Text(list[index].url, style: const TextStyle(fontSize: 14))),
                const SizedBox(width: 20),
                SwitchWidget(
                    scale: 0.65,
                    value: list[index].enabled,
                    onChanged: (val) {
                      setState(() => list[index].enabled = val);
                      _save();
                    }),
                const SizedBox(width: 40),
                SizedBox(
                    width: 130,
                    child: Text(isCN ? list[index].type.label : list[index].type.name,
                        style: const TextStyle(fontSize: 14)))
              ],
            )));
  }

  //点击菜单
  showMenus(TapDownDetails details, int index) {
    var list = widget.requestBlockManager.list;

    showContextMenu(context, details.globalPosition, items: [
      PopupMenuItem(height: 35, child: Text(localizations.edit), onTap: () => showEdit(index)),
      PopupMenuItem(
          height: 35,
          child: list[index].enabled ? Text(localizations.disabled) : Text(localizations.enable),
          onTap: () {
            setState(() => list[index].enabled = !list[index].enabled);
            _save();
          }),
      const PopupMenuDivider(),
      PopupMenuItem(
          height: 35,
          child: Text(localizations.delete),
          onTap: () {
            setState(() => list.removeAt(index));
            _save();
          })
    ]);
  }

  showEdit([int? index]) {
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return RequestBlockAddDialog(requestBlockManager: widget.requestBlockManager, index: index);
        }).then((value) {
      if (value != null && mounted) {
        setState(() {});
        _save();
      }
    });
  }
}

class RequestBlockAddDialog extends StatelessWidget {
  final RequestBlockManager requestBlockManager;
  final int? index;

  const RequestBlockAddDialog({super.key, required this.requestBlockManager, this.index});

  @override
  Widget build(BuildContext context) {
    AppLocalizations localizations = AppLocalizations.of(context)!;
    bool isCN = localizations.localeName == 'zh';

    GlobalKey formKey = GlobalKey<FormState>();
    RequestBlockItem item =
        index == null ? RequestBlockItem(true, '', BlockType.values.first) : requestBlockManager.list.elementAt(index!);
    bool enabled = item.enabled;
    return AlertDialog(
        scrollable: true,
        content: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Form(
                key: formKey,
                child: Column(children: <Widget>[
                  SwitchWidget(title: localizations.enable, value: item.enabled, onChanged: (val) => enabled = val),
                  const SizedBox(height: 20),
                  TextFormField(
                      initialValue: item.url,
                      decoration: const InputDecoration(
                          isDense: true,
                          labelText: 'URL',
                          hintText: 'https://example.com/*',
                          border: OutlineInputBorder()),
                      validator: (val) => val == null || val.trim().isEmpty ? localizations.cannotBeEmpty : null,
                      onSaved: (val) => item.url = val!.trim()),
                  const SizedBox(height: 20),
                  DropdownButtonFormField(
                      value: item.type,
                      decoration: InputDecoration(
                          isDense: true, labelText: localizations.type, border: const OutlineInputBorder()),
                      items: BlockType.values
                          .map((e) => DropdownMenuItem(
                              value: e, child: Text(isCN ? e.label : e.name, style: const TextStyle(fontSize: 14))))
                          .toList(),
                      onSaved: (val) => item.type = val!,
                      onChanged: (val) {}),
                ]))),
        actions: [
          TextButton(child: Text(localizations.close), onPressed: () => Navigator.of(context).pop()),
          TextButton(
              child: Text(localizations.save),
              onPressed: () {
                if (!(formKey.currentState as FormState).validate()) {
                  return;
                }
                (formKey.currentState as FormState).save();

                item.enabled = enabled;
                item.urlReg = null;
                if (index != null) {
                  requestBlockManager.list[index!] = item;
                } else {
                  requestBlockManager.list.add(item);
                }
                Navigator.of(context).pop(item);
              }),
        ]);
  }
}
