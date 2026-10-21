# What reaches the collector

A reference for whoever reads the other end: what each kind of telemetry
looks like on the wire, and the attributes this package adds.

## The resource

Set once, at `start()`:

| Attribute                     | From                                                 |
| ----------------------------- | ---------------------------------------------------- |
| `service.name`                | `OtelZoneConfig.serviceName`                         |
| `service.version`             | `start(serviceVersion:)`                             |
| `app.build_id`                | `start(buildId:)`, when given                        |
| `deployment.environment.name` | `OtelZoneConfig.deploymentEnvironmentName`, when set |
| anything else                 | `start(resourceAttributes:)`                         |

Resource attributes are not scrubbed by `redact`.

## Log records from the `Talker`

Every record at or above the [export floor](/concepts/export-floor), through
`otel_talker`'s `OTelTalkerObserver`, under the instrumentation scope
`OtelZoneConfig.loggerName`. Scrubbed field by field when `redact` is set.

- **The start-up line**, at `warning`:
  `OpenTelemetry: exporting to … as <service> <version> build <build> (<environment>), records at <level> and above`,
  with `, recovered N native crashes`, `, replayed N spooled batches` and an
  unrecognised-floor note when they apply.
- **A breadcrumb record** before each `error` or `critical` record (when the
  floor is above `debug`): title `breadcrumbs`, the fault's level, and a body
  of up to `breadcrumbCount` lines, `time [title] message`, each cut at
  `breadcrumbLineLimit`.
- **Warnings the package itself logs**: a failed `start()`, a spool file
  dropped after `spoolMaxAttempts`, an oversized batch, a crash report evicted
  from the spool, the first span a throwing `redact` dropped, the crash screen
  not reaching the platform, a failed platform read. Each is one `warning`
  on the talker, so at the default floor each is exported too.

## Native crash records

`Severity.FATAL`, `event.name` `device.crash` or `device.anr`, not gated by the
floor. The full field list is on the [native crashes](/guide/native-crashes#fatal-and-not-a-breadcrumb)
page. The attributes this package defines:

| Attribute                           | Meaning                                                                     |
| ----------------------------------- | --------------------------------------------------------------------------- |
| `device.crash.kind`                 | `jvm`, `native`, `anr`, `nsexception`, `signal` or `hang`                   |
| `device.crash.threads`              | per-thread frames, one per line                                             |
| `otel_zone.crashed.service.version` | the version that **died**, when known — not the one reporting it            |
| `otel_zone.crashed.app.build_id`    | the build that died, when known                                             |
| `otel_zone.crashed.screen`          | the route pattern the app showed when it died, when known                   |
| `otel_zone.duplicate_of`            | iOS: on a late MetricKit crash, the id of the exception report already sent |
| `otel_zone.late_metrickit`          | iOS: marks that late MetricKit crash, so a backend can collapse the pair    |

Standard ones carried as well: `exception.type`, `exception.message`,
`exception.stacktrace`, `session.id`. Android exit records add `exit.reason`,
`exit.status`, `exit.importance`, `process.pid` and, for a native crash with a
tombstone, `signal.*` and `crash.thread.*` details.

**Absent means unknown.** None of the `otel_zone.crashed.*` attributes is ever
filled in with the reporting launch's values.

## Replayed records

A record delivered from the [spool](/guide/spool) on a later launch carries
`otel_zone.replayed = true`, and keeps the resource it was recorded under.

## `enduser.id`

On every span started and every log record emitted while
[`setEndUser`](/guide/end-user) holds an id. Never set by the package on its
own, never on recovered crash reports, and exempt from `redact`.

## Spans from the observers

`riverpodObserver()` (from `otel_riverpod`) and `routeObserver()` (from
`otel_go_router`) emit spans through the SDK's trace pipeline. Spans skip the
export floor and the spool.

Each provider event is a span carrying the provider's name, runtime type,
family and the value's runtime type. A failed provider adds the error's
message and stack trace as an exception event and as the status description
— so those spans are not free of app text, and `redact` scrubs them.

What they leave out by default:

| Left out                                             | Unless                                    |
| ---------------------------------------------------- | ----------------------------------------- |
| provider values (`toString()` of value and previous) | `riverpodObserver(recordValues: true)`    |
| `riverpod.provider.argument` (family argument)       | `riverpodObserver(recordArguments: true)` |
| `riverpod.mutation` (a keyed mutation, key included) | `riverpodObserver(recordArguments: true)` |
| route arguments                                      | `routeObserver(recordArguments: true)`    |

The two `recordArguments` attributes are dropped by this package rather than
by `otel_riverpod`, whose observer records both whatever `recordValues` says
([Dartastic/otel_riverpod#3](https://github.com/Dartastic/otel_riverpod/issues/3)).
`riverpod.mutation` is the mutation's `toString()`, which for a keyed mutation
is `Mutation<int>#d9771(<key>, label: addToCart)`, key included.

## Metrics

None, by default. [`enableMetrics`](/reference/configuration#enablemetrics)
is off on purpose.
