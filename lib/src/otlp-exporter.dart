import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

/// The headers dartastic's own logs exporter would send, resolved the way it
/// resolves them.
///
/// `OTEL_EXPORTER_OTLP_LOGS_HEADERS` wins over `OTEL_EXPORTER_OTLP_HEADERS`,
/// and either can come from the environment or from `--dart-define`. That
/// lookup is `OTelEnv.getOtlpConfig`, which is public, so it is called here
/// rather than re-parsed: a second parser is a second place for the two to
/// disagree about what an app's collector credentials are. One consequence
/// worth knowing: dartastic splits on `,` and `=` and does not URL-decode
/// values as the OTLP specification asks, and this inherits that rather than
/// fixing it for one caller.
///
/// Entries with an empty name or value are dropped. `OtlpHttpLogRecordExporterConfig`
/// throws on them, and a stray `a=,` in a build flag must not be the reason
/// the app has no telemetry at all.
///
/// Header values are credentials. Nothing here logs them.
Map<String, String> resolveOtlpHeaders() {
  final Map<String, String>? resolved = OTelEnv.getOtlpConfig(
    signal: 'logs',
  ).headers;
  if (resolved == null) return const <String, String>{};
  return <String, String>{
    for (final MapEntry<String, String> header in resolved.entries)
      if (header.key.isNotEmpty && header.value.isNotEmpty)
        header.key: header.value,
  };
}

/// The one place this package builds an OTLP log exporter.
///
/// The spool's delegate, the replay that runs through it, and the crash drain
/// without a spool all come from here, so a header — or, later, a per-request
/// header provider — cannot reach one path and be missing from another.
/// Building them by hand at each site is how the crash path ended up without
/// the headers the live path had.
LogRecordExporter buildOtlpLogExporter({
  required String endpoint,
  Map<String, String> headers = const <String, String>{},
}) {
  return OtlpHttpLogRecordExporter(
    OtlpHttpLogRecordExporterConfig(endpoint: endpoint, headers: headers),
  );
}
