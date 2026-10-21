# The export floor

Everything is recorded locally. Only records at or above
`OtelZoneConfig.exportFloor` are exported, plus — for an `error` or
`critical` record only — one extra record carrying the trail of records that
came before it.

## Why a floor at all

The alternative was measured. 7,715 records sitting in a collector, off one
set of release builds of a Flutter app wired this way:

| Record              | Count |
| ------------------- | ----- |
| `[riverpod-add]`    | 3,020 |
| `[riverpod-update]` | 2,773 |
| `[route]`           | 1,498 |
| `[exception]`       | 261   |
| `[info]`            | 158   |

That is 5,793 debug and 1,656 info against 266 errors — **96.5% chatter**:
one record per provider initialisation, one per provider state change, one
per navigation. It scales with how much someone _uses the app_, which is the
worst shape a cost can have on a metered prepaid connection: the more someone
does, the more they pay to tell you they did.

## Why not drop the observers in release

Because the breadcrumbs are the point. An `[exception]` record with no
preceding route or provider transitions is a stack trace with no story, and
the route log is exactly what answers "which screen was this, and what had
just changed". So the observers stay attached in every build, every record
still lands in `talker.history` where it costs nothing, and the context rides
along with a fault instead of going one record at a time.

## What actually goes

`OtelBridge` sits between the `Talker` and the OpenTelemetry logs pipeline.
For each record:

1. **Below the floor?** It stops there. It is still in `talker.history`.
2. **An `error` or `critical`?** First, one extra record titled
   `breadcrumbs`, at the fault's own level, whose body is the last
   [`breadcrumbCount`](/reference/configuration#breadcrumbcount) records that
   came before it — one line each, `time [title] message`, each cut at
   [`breadcrumbLineLimit`](/reference/configuration#breadcrumblinelimit)
   characters. The fault itself is not in its own trail: `Talker` calls its
   observer before it writes history.
3. **The record itself**, scrubbed by [`redact`](/guide/redaction) when one
   is set.

So volume scales with faults rather than with interaction.

A `warning` gets no trail. It is an expected state — offline, a rejection the
server explained, a declined permission prompt — and nobody opens a stack
trace for it.

At a floor of `debug` or lower there is no trail either: every record a trail
could be built from is already on the wire, and the trail would be a second
copy of it.

A record with no level is treated as `info`, matching what
`OTelTalkerObserver` would have stamped on it.

::: details Why levels are ranked by priority, not by enum index
Talker's `LogLevel` is declared `error, critical, info, debug, verbose,
warning`. Comparing `LogLevel.index` would put `warning` below `verbose` and
export everything. `ExportFloor.priorityOf` uses Talker's own
`logLevelPriorityList` instead.
:::

## Choosing the floor: `ExportFloor`

A build's floor is almost always read from somewhere untyped — a
`--dart-define`, an `.env` key compiled in, a remote value — and a typo there
must not quietly change what the build sends. So the floor is a type, not a
bare `LogLevel`:

```dart
ExportFloor.parse('warning').level;      // LogLevel.warning
ExportFloor.parse('loud').level;         // LogLevel.warning — the fallback
ExportFloor.parse('loud').unrecognised;  // 'loud'

const ExportFloor.of(LogLevel.error);    // chosen in code, nothing to misspell
```

`ExportFloor.parse` is case- and whitespace-insensitive (`'  WARNING '` is
`warning`). When it cannot read the value it falls back to
`ExportFloor.defaultLevel` — `warning` — and keeps what was written, so
`start()` says both in its start-up line:

```text
OpenTelemetry: exporting to … as my-app 1.2.3, records at warning and above — the configured export level said "loud", which is not a level; fell back to warning
```

The direction of the fallback is deliberate. A misconfigured build that
defaults to _loud_ bills its users for the mistake, on whatever connection
they are paying for; one that defaults to quiet loses debug breadcrumbs from
the wire and keeps every fault — the cheaper way to be wrong.

`parse` takes an optional `fallback:` for a build that wants another one.

## The start-up line survives its own floor

`start()` logs its summary at `warning`, not `info`. It is the one record that
has to survive its own subject: at the shipped `warning` floor an `info` line
would be withheld, and a build would be unable to tell you why it is quiet.

## The readiness guard

`OtelBridge` forwards nothing until `start()` has brought the SDK up
(`bridge.ready`), and swallows anything its sink throws. Without that,
anything logged before start-up would crash the logger, and `start()`'s own
"could not reach the collector" warning would itself throw — turning "no
collector on this network" into a failed start-up. A failed forward is
deliberately not reported through Talker either: that would re-enter the
bridge and recurse.
