import 'dart:convert';
import 'dart:typed_data';

import 'package:dartastic_opentelemetry/proto/opentelemetry_proto_dart.dart'
    as pb;

import 'local-collector.dart';

/// The SDK's own protobuf decoder over what a [LocalCollector] received, so a
/// test reads an attribute off a particular span or record instead of
/// searching a body for a string.
///
/// The collector keeps a body as Latin-1 text, which maps every byte to one
/// character, so encoding it back is lossless.
extension OtlpWire on LocalCollector {
  Uint8List _bytes(CollectedRequest request) =>
      Uint8List.fromList(latin1.encode(request.body));

  /// Every span received on `/v1/traces`, in arrival order.
  List<pb.Span> get wireSpans => <pb.Span>[
    for (final CollectedRequest request in requests)
      if (request.path == '/v1/traces')
        for (final pb.ResourceSpans resource
            in pb.ExportTraceServiceRequest.fromBuffer(
              _bytes(request),
            ).resourceSpans)
          for (final pb.ScopeSpans scope in resource.scopeSpans) ...scope.spans,
  ];

  /// Every log record received on `/v1/logs`, in arrival order.
  List<pb.LogRecord> get wireLogs => <pb.LogRecord>[
    for (final CollectedRequest request in requests)
      if (request.path == '/v1/logs')
        for (final pb.ResourceLogs resource
            in pb.ExportLogsServiceRequest.fromBuffer(
              _bytes(request),
            ).resourceLogs)
          for (final pb.ScopeLogs scope in resource.scopeLogs)
            ...scope.logRecords,
  ];
}

/// The string value of [key] in [attributes], or `null` when it is absent.
String? wireString(List<pb.KeyValue> attributes, String key) {
  for (final pb.KeyValue attribute in attributes) {
    if (attribute.key == key) return attribute.value.stringValue;
  }
  return null;
}

/// How many attributes in [attributes] are named [key].
int wireCount(List<pb.KeyValue> attributes, String key) =>
    attributes.where((pb.KeyValue a) => a.key == key).length;
