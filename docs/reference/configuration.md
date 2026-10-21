# Configuration

Everything about a build's telemetry that is known before the build runs is an
`OtelZoneConfig`. What has to be read off the running device is an argument to
[`start()`](#start-arguments).

```dart
final config = OtelZoneConfig(
  serviceName: 'vaam-mobile',
  endpoint: 'https://otel.example.com',
  deploymentEnvironmentName: 'production',
  exportFloor: ExportFloor.parse('warning'),
);
```

Every field has the default the Vaam Store mobile app shipped with; a caller
that names only `serviceName` and `endpoint` gets that behaviour.

## `OtelZoneConfig` at a glance

| Option                      | Type                              | Default                            |
| --------------------------- | --------------------------------- | ---------------------------------- |
| `serviceName`               | `String`                          | required                           |
| `endpoint`                  | `String`                          | required                           |
| `loggerName`                | `String?`                         | `serviceName`                      |
| `deploymentEnvironmentName` | `String?`                         | `null` (left off the resource)     |
| `exportFloor`               | `ExportFloor`                     | `ExportFloor.of(LogLevel.warning)` |
| `breadcrumbCount`           | `int`                             | `12`                               |
| `breadcrumbLineLimit`       | `int`                             | `160`                              |
| `redact`                    | `Redactor?`                       | `null` (no scrubbing)              |
| `useConsoleLogs`            | `bool`                            | `kDebugMode`                       |
| `presentFlutterErrors`      | `bool`                            | `kDebugMode`                       |
| `enableLogs`                | `bool`                            | `true`                             |
| `enableMetrics`             | `bool`                            | `false`                            |
| `spoolDirectory`            | `FutureOr<Directory> Function()?` | `null` (no spool)                  |
| `spoolMaxBatches`           | `int`                             | `32`                               |
| `spoolMaxAge`               | `Duration?`                       | 7 days                             |
| `spoolMaxBytes`             | `int?`                            | 5 MiB (`5 * 1024 * 1024`)          |
| `spoolMaxAttempts`          | `int`                             | `5`                                |
| `secure`                    | `bool?`                           | whether `endpoint` is `https://`   |

## Identity

### `serviceName`

OpenTelemetry's `service.name`. One name per **service**, not per build
flavour: two flavours of one app are one service built twice, and splitting
them here makes them look unrelated to every backend that groups by this key.
Use `deploymentEnvironmentName` to tell them apart instead.

### `endpoint`

The OTLP endpoint records are exported to.

### `secure`

Whether the exporter uses TLS. Defaults to whether `endpoint` starts with
`https://` — plain HTTP to a collector on `localhost`, TLS to a deployed one.
Set it explicitly for a TLS endpoint behind a scheme this cannot see.

### `loggerName`

The OTel instrumentation-scope name log records (and recovered crash reports)
are emitted under. Defaults to `serviceName`.

### `deploymentEnvironmentName`

OpenTelemetry's `deployment.environment.name` — which tier of the service this
build is, `production` or `development`. Left off the resource entirely when
`null`. This is the stable semantic convention; the deprecated plain
`deployment.environment` is not used. It describes the **build's** tier, not
the backend's, so it usually cannot be derived from an API base URL and is a
build input of its own.

## What leaves the device

### `exportFloor`

The severity a record has to clear before it is exported. Records below it are
still recorded locally — they are what a fault's breadcrumb trail is built
from. Build it with `ExportFloor.parse(name)` from an untyped source (it falls
back to `warning` and reports the typo) or `ExportFloor.of(level)` in code.
See [The export floor](/concepts/export-floor).

### `breadcrumbCount`

How many preceding records ride along with an `error` or `critical` record, as
one extra record. Twelve, because that is roughly one screen of navigation
plus the provider transitions around it — the "what was the user doing"
question an error record cannot answer on its own.

### `breadcrumbLineLimit`

Breadcrumb lines are truncated to this many characters (after `redact`), so
one enormous value cannot turn a fault into a payload.

### `redact`

A `Redactor` — `String Function(String input)` — that scrubs every exported
string before it leaves the device: log records, crash reports and spans. With
a `redact` set, `start()` builds the trace pipeline itself so spans can be
scrubbed. A `redact` that throws drops the record or span (fail closed).
`null` means no scrubbing. See [Scrubbing with redact](/guide/redaction).

## Local behaviour

### `useConsoleLogs`

Whether Talker prints to the console. This gates the **console** and nothing
else — it is not a second export switch, and reading it as one is how a build
ships with `useConsoleLogs: kDebugMode` and a wide-open exporter. The wire is
gated by `exportFloor`.

### `presentFlutterErrors`

Whether `FlutterError.presentError` still runs for a framework error — the red
screen and the console dump. The log record is for the backend; the presented
error is for the person looking at the simulator.

## Signals

### `enableLogs`

Whether the OTel logs pipeline is started. Off means Talker records stay on
the device — and the native crash drain does not run.

### `enableMetrics`

Whether the OTel metrics pipeline is started. **Off, and that is a decision
rather than an oversight**: the periodic metric reader turns the first
instrument into a 60 s heartbeat for the life of the process. See
[Metrics are off, on purpose](/concepts/never-blocks#metrics-are-off-on-purpose).

Traces have no switch here: the trace pipeline is dartastic's, configured from
the environment (or rebuilt with the same variables when `redact` is set).

## The spool

See [The offline spool](/guide/spool) for how these interact.

### `spoolDirectory`

Where batches are spooled, or `null` for no spooling (a refused batch is
retried in memory and then dropped). A function returning a `Directory` or a
`Future` of one, so `path_provider`'s functions are passed as they are;
`start()` awaits it once, before the SDK is brought up. A provider that throws
leaves telemetry off for the process. Prefer a directory the OS does not back
up, and delete it on sign-out.

### `spoolMaxBatches`

The most spool files kept before the oldest is evicted — ordinary batches
before crash reports.

### `spoolMaxAge`

The age past which a spool file is discarded, or `null` for no age cap. The
one unconditional bound, including for a lone batch the collector will never
take.

### `spoolMaxBytes`

The most bytes, on disk, the spool files may hold together, or `null` for no
byte cap. The count alone is not a size bound: a file is one batch of up to
512 records, and a record's size is not capped. Enforced after every write and
when `start()` replays. A single batch larger than the cap is not spooled (one
warning) but is still sent. The crash journal and half-written temp files are
not counted.

### `spoolMaxAttempts`

How many **counted** failures a spooled batch survives before it is dropped,
with one warning. A failure is counted only in a replay pass where the
collector demonstrably works, so being offline never counts. Values below 1
are treated as 1.

## `start()` arguments

```dart
Future<void> start({
  required String serviceVersion,
  String? buildId,
  Map<String, String> resourceAttributes = const <String, String>{},
})
```

| Argument             | Becomes             | Notes                                                                                   |
| -------------------- | ------------------- | --------------------------------------------------------------------------------------- |
| `serviceVersion`     | `service.version`   | read from the installed artifact (`package_info_plus`'s `version`); must not be empty   |
| `buildId`            | `app.build_id`      | the semconv `app` entity's identifying attribute; tells two builds of one version apart |
| `resourceAttributes` | resource attributes | device model, OS version — anything fixed for the life of the process                   |

Without `serviceVersion` the SDK would write its own `'1.0.0'`, which every
build ever shipped would then report identically. An empty one makes
`OTel.initialize` throw, which `start()` swallows into "telemetry is off".
Resource attributes cannot be changed afterwards, so read them before calling
`start()`, and give them already-scrubbed values: `redact` does not touch them.

## The `OtelZone` constructor

```dart
OtelZone(
  OtelZoneConfig config, {
  Talker? talker,
  TalkerObserver? sink,
  NativeCrashSource? nativeCrashSource,
  CrashScreenSink? crashScreenSink,
})
```

Constructing it starts nothing and reaches no network. The named parameters
are injection points for tests; see [Testing against it](/guide/testing).

## Observer options

| Call                                   | Default | When `true`                                                                       |
| -------------------------------------- | ------- | --------------------------------------------------------------------------------- |
| `riverpodObserver(recordValues: …)`    | `false` | records the value's and previous value's `toString()`, scrubbed, cut at 256 chars |
| `riverpodObserver(recordArguments: …)` | `false` | keeps `riverpod.provider.argument` and `riverpod.mutation`                        |
| `routeObserver(recordArguments: …)`    | `false` | records route arguments                                                           |

Prefer leaving all three off: provider state, family arguments and route
arguments are where an app's own data lives, and `redact` is best-effort
pattern matching.

## Environment variables

`otel_zone` reads no variables of its own; dartastic's `OTelEnv` reads them,
from the environment or from `--dart-define`.

| Variable                                                                                | Effect here                                                                                         |
| --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_LOGS_HEADERS` (wins)                  | sent on every log path this package builds an exporter for: live records, spool replay, crash drain |
| `OTEL_TRACES_EXPORTER`                                                                  | with `redact` set: `otlp` and/or `console`; `none` leaves dartastic's own pipeline in place         |
| `OTEL_EXPORTER_OTLP_*` (traces: endpoint, protocol, timeout, compression, certificates) | read the same way dartastic reads them when the package rebuilds the trace pipeline                 |
| `OTEL_LOGS_EXPORTER`                                                                    | still honoured: the logs pipeline is built with the SDK's own `LogsConfiguration`                   |
| `OTEL_SDK_DISABLED`                                                                     | the SDK builds no pipelines; the package adds nothing behind them                                   |

Headers are resolved once at `start()` through one factory, so a header cannot
reach the live path and be missing from the crash path. Header values are
credentials and are never logged. dartastic splits the variable on `,` and `=`
and does not URL-decode values as the OTLP specification asks; that is
inherited, not worked around. Entries with an empty name or value are dropped.
