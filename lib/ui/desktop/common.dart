import 'package:flutter/material.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/l10n/app_localizations.dart';
import 'package:proxypin/ui/component/multi_window.dart';

import 'setting/request_rewrite.dart';

Future<void> openCapturedRewrite(
  BuildContext context,
  HttpRequest request, {
  HttpResponse? response,
  RuleType? ruleType,
}) async {
  response ??= request.response;
  final requestDraft = HttpRequest(request.method, request.requestUrl, protocolVersion: request.protocolVersion)
    ..headers.addAll(request.headers)
    ..body = request.body;
  final responseDraft = response == null
      ? null
      : (HttpResponse(response.status, protocolVersion: response.protocolVersion)
        ..headers.addAll(response.headers)
        ..body = response.body);
  await MultiWindow.openCapturedWindow(
    AppLocalizations.of(context)!.requestRewriteRule,
    RewriteRuleEdit.windowName,
    const Size(800, 680),
    request: requestDraft,
    response: responseDraft,
    args: {
      'ruleType': (ruleType ?? (response == null ? RuleType.requestReplace : RuleType.responseReplace)).name,
    },
  );
}
