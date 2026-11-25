import 'dart:convert';
import 'dart:isolate';

import 'package:proxypin/network/http/http.dart';

class StandaloneWindowPayload {
  static const _chunkSize = 2880;
  final HttpRequest? request;
  final HttpResponse? response;
  final String? _responseUrl;

  StandaloneWindowPayload(HttpRequest? request, HttpResponse? response)
      : request = request == null ? null : _snapshotRequest(request),
        response = response == null ? null : _snapshotResponse(response),
        _responseUrl = response?.requestUrl;

  static HttpRequest _snapshotRequest(HttpRequest request) =>
      HttpRequest(request.method, request.requestUrl, protocolVersion: request.protocolVersion)
        ..requestId = request.requestId
        ..requestTime = request.requestTime
        ..packageSize = request.packageSize
        ..headers.addAll(request.headers)
        ..body = request.body
        ..messages = List.of(request.messages);

  static HttpResponse _snapshotResponse(HttpResponse response) =>
      HttpResponse(response.status, protocolVersion: response.protocolVersion)
        ..responseTime = response.responseTime
        ..packageSize = response.packageSize
        ..headers.addAll(response.headers)
        ..body = response.body
        ..messages = List.of(response.messages);

  Future<List<String>> encode() => _encodePayload(request, response, _responseUrl);

  static Future<Map<String, Object?>> decode(List<String> chunks) => Isolate.run(() {
        Map<String, dynamic>? json;
        final sink = utf8.decoder.fuse(JsonDecoder()).startChunkedConversion(
          ChunkedConversionSink<Object?>.withCallback((values) => json = values.single as Map<String, dynamic>),
        );
        for (final chunk in chunks) {
          sink.add(base64Decode(chunk));
        }
        sink.close();
        final requestJson = json!['request'] as Map<String, dynamic>?;
        final responseJson = json!['response'] as Map<String, dynamic>?;
        return {
          'request': requestJson == null ? null : HttpRequest.fromJson(requestJson),
          'response': responseJson == null ? null : HttpResponse.fromJson(responseJson),
        };
      });
}

Future<List<String>> _encodePayload(HttpRequest? request, HttpResponse? response, String? responseUrl) =>
    Isolate.run(() {
      final responseJson = response?.toJson();
      if (responseJson != null) responseJson['requestUrl'] = responseUrl;
      final bytes = JsonUtf8Encoder().convert({'request': request, 'response': responseJson});
      return [
        for (var offset = 0; offset < bytes.length; offset += StandaloneWindowPayload._chunkSize)
          base64Encode(bytes.sublist(offset, (offset + StandaloneWindowPayload._chunkSize).clamp(0, bytes.length))),
      ];
    });
