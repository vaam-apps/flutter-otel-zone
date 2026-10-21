# The offline spool

Without a spool, a batch the collector refuses is retried in memory and then
dropped, and one in flight when the process is killed is simply gone. That is
how a fault recorded in a tunnel is lost.

Point `spoolDirectory` at app-private storage and every batch is written to
disk **before** it is sent, and what is left is replayed on the next
`start()`:

```dart
final OtelZone observability = OtelZone(
  OtelZoneConfig(
    serviceName: 'my-app',
    endpoint: Env.otelEndpoint,
    // `getApplicationCacheDirectory` from `path_provider`, which returns a
    // `Future<Directory>`. `start()` awaits it once, so it is read after the
    // binding exists. A plain `() => directory` works too.
    spoolDirectory: getApplicationCacheDirectory,
  ),
);

await observability.start(serviceVersion: '1.2.3');
```

`spoolDirectory` is a `FutureOr<Directory> Function()` — a function, because
the directory cannot be named until the platform channels exist, which is
after the config is built. A provider that throws, or whose future fails,
leaves telemetry off for the process, as any other failure of `start()` does.
`test/spool-directory-async_test.dart` compiles a provider of exactly
`path_provider`'s shape, a top-level `Future<Directory> Function()`.

The spool covers **log records** (including recovered crash reports). Spans
are not spooled.

## How it behaves

### Write-ahead

A batch is written to a temp file and renamed _before_ the network is tried,
and deleted once the collector has taken it. A process killed mid-request
therefore leaves a whole batch on disk for the next launch to replay, never
half of one. The price is one extra write per exported batch, which is small
above the `warning` floor.

Trying the network first looked cheaper, but the exporter's own retries can
hold a batch in memory for tens of seconds — exactly the window a dying
process needs the batch to be safe in.

### Deleted on acceptance, and offline never counts

`start()` replays oldest first, without waiting for it. When a file is
refused, one more file is tried as a probe:

- **The probe is accepted** — the collector works, so the refusal is the
  file's own. It is counted in the file's name (a rename, so it is atomic and
  survives a kill) and the pass carries on.
- **The probe is refused too** — the phone is offline. Nothing is counted and
  the pass stops.

Being offline never spends a file's attempts, however many launches it lasts.

### A batch that is never taken is dropped

The exporter reports only success or failure, so a batch the collector
refuses for good (a 400, a 413) looks like one refused because the phone is
offline. After [`spoolMaxAttempts`](/reference/configuration#spoolmaxattempts)
counted failures (default 5) the file is dropped with one warning on the
talker, and replay moves on.

With no second file to probe with, a batch this process delivered in the last
few minutes stands in for the probe; with none, nothing is counted. A lone
poisoned file with no traffic behind it is therefore never dropped by count —
[`spoolMaxAge`](/reference/configuration#spoolmaxage) is its bound. Failed
live sends never count on their own; only a later replay does.

A file that cannot be decoded is deleted rather than retried.

### Bounded

A phone that never reconnects must not fill its disk with telemetry nobody
collected.

| Cap               | Default | What it bounds                                           |
| ----------------- | ------- | -------------------------------------------------------- |
| `spoolMaxBatches` | `32`    | the number of spool files; the oldest is evicted past it |
| `spoolMaxBytes`   | 5 MiB   | the bytes the files occupy on disk (`null` for no cap)   |
| `spoolMaxAge`     | 7 days  | the age past which a file is dropped, whatever it holds  |

Ordinary batches are evicted before crash reports, by both the count and the
byte cap.

The count alone is not a size bound: a file is a whole export batch of up to
512 records, and a record's size is not capped. The byte cap is checked after
every write and when `start()` replays, so a directory an older release left
over it is trimmed on the next launch. A single batch larger than the cap is
not spooled — with one warning on the talker — and evicts nothing; it is still
sent to the collector. A cap below the size of one batch therefore turns
spooling off in effect.

Every batch is written before it is sent, and the cap is checked against that
file, so the room for undelivered backlog is about the cap minus the largest
batch in flight: a live export can evict an older undelivered batch while the
collector is healthy.

A crash report dropped by any of the three caps is warned about, and taken
off the crash journal so the platform offers it again; an ordinary batch goes
silently. How the crash drain uses the spool is on the
[native crashes](/guide/native-crashes#acknowledged-only-when-durable) page.

### Failure is not fatal

An unwritable directory sends the batch straight to the collector, as if there
were no spool, and nothing is thrown into the app.

### The original resource rides along

A crash stays filed under the version that crashed rather than whichever one
was running when it was finally delivered. Replayed records carry
`otel_zone.replayed = true`.

### The start-up line reports it

With a spool, the start-up line waits for the replay (off the `runApp` path)
and ends with `, replayed N spooled batches`.

## Where the spool lives

The spool is a store of telemetry: ordinary batches, already scrubbed by
`redact`, and recovered crash reports, kept for up to `spoolMaxAge`. Put it
where the OS does not copy it off the device.

`getApplicationSupportDirectory` is included in Android Auto Backup and in iOS
device and iCloud backups. Instead:

- **`getApplicationCacheDirectory`** (also `path_provider`) is backed up on
  neither platform. The price is that the OS may clear it when storage runs
  low, which costs an undelivered batch and nothing else.
- **Or keep the directory under app support and exclude it from backup
  yourself:** an exclude rule for it in the Android backup rules, and
  `isExcludedFromBackup` on the directory on iOS. The package does the same
  for its own native crash files; it cannot for a directory the app names.

## Clear it on sign-out

Delete the directory you passed (the spool creates it again on the next
write). Otherwise a batch spooled while one person was signed in is delivered,
possibly days later, after they have left, and stays on the phone until it is.
It may also carry their [`enduser.id`](/guide/end-user#on-sign-out).
