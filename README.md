# Wallstats

Wallstats is a native macOS WidgetKit system monitor configured as typechecked
Rust. An invisible LaunchAgent runs the `rust-script` process that owns
collection, scheduling, layout, and user plugins. It publishes compact snapshots
to the desktop widget through a signed App Group.

The current Conky-like example shows:

- Apple Silicon CPU/GPU load, clocks, temperatures, and power from `macmon`
- Root volume free/used space and disk read/write activity
- Aggregate network receive/transmit rates
- A compact status tile derived from the newest `backup-home` log

Wallstats is closer to Conky or XMonad than to a conventional preferences UI:
`~/.config/wallstats/config.rs` is the configuration language. It is ordinary
Rust linked against a small typed SDK. Invalid combinations such as formatting
memory as a percentage, plotting text, or putting an unbounded number in a
gauge fail at compile time.

## Architecture

```text
~/.config/wallstats/config.rs
        |
        | rust-script compiles and runs trusted Rust
        v
typed collectors and layout (engine/) -- JSON Lines --> background companion
                                                             |
                                                   signed App Group snapshot
                                                             |
                                                             v
                                                  WidgetKit desktop widget
```

The collector remains out of process. A bad plugin can fail collection without
corrupting the native renderer, and configuration reload replaces the process.
The wire contract is documented in [PROTOCOL.md](PROTOCOL.md).

The rendered widget consumes the section and widget plan emitted by the Rust
configuration; section titles, weights, metrics, formats, plots, tables, and
compact-status tiles are not hardcoded in Swift. The current example uses short
`perf`, `disk`, and `net` sections in a dense Conky-like layout. It remains
shape-first and omits versions, protocol details, and status prose. Generic
compact-status metrics render configured glyphs, a shape-and-color status mark,
and age; other values use plan-driven text, gauges, plots, and tables.

- Cyan: CPU activity
- Blue: GPU activity
- Amber: disk reads
- Purple: disk writes
- Orange: disk usage

The small family renders the highest-weight Rust section, medium arranges all
sections in a grid, and large stacks every section according to its configured
weight. Missing data leaves only quiet neutral marks; snapshots older than 45
minutes fade.
Accessibility descriptions remain available to VoiceOver.

macOS controls widget coloration. Choose **System Settings → Desktop & Dock →
Widgets → Widget style → Full-color** to preserve semantic colors and emoji.
In monochrome mode, status remains readable by shape: circle, diamond, triangle,
X, or hollow ring.

## Install

Requirements are macOS 14 or newer, Xcode command-line tools, and Nix.

```sh
./scripts/install.sh
```

Installation builds and signs `Wallstats.app`, installs it under
`~/Applications`, and creates `~/.config/wallstats/config.rs` only when that
file does not already exist. It also registers the embedded
`WallstatsWidgetExtension.appex` with PlugInKit and installs the invisible
`com.memorici.wallstats` LaunchAgent. The installer also places the `wallstats`
CLI at `~/.local/bin/wallstats`. Add Wallstats from macOS "Edit Widgets".
Clicking the widget opens the active Rust configuration in its default editor.

The WidgetKit timeline is intentionally low-frequency. The companion samples at
the Rust configuration's cadence, coalesces snapshot writes to at most once per
minute, and asks WidgetKit to reload at most once per 30 minutes. macOS retains
final control over widget refresh budgets.

## Daily workflow

For a configuration-only change, edit the Rust config and request an immediate
compiled snapshot:

```sh
$EDITOR ~/.config/wallstats/config.rs
wallstats reload
```

No full app rebuild is required. The invisible companion normally watches
`config.rs` and reloads after a save; `wallstats reload` additionally guarantees
an immediate forced snapshot write and WidgetKit timeline refresh, and waits for
the shared snapshot to change.

The remaining CLI commands are:

- `wallstats refresh`: request a WidgetKit timeline refresh without recompiling.
- `wallstats config`: open the active configuration in its default editor.
- `wallstats status`: report the supervised companion path/PID, registered
  extension, config path, and a concise shared-snapshot timestamp summary.
- `wallstats check-config`: compile and validate the config with the embedded
  pinned Nix helper while preserving compiler diagnostics.

For a full Rust engine, native UI, WidgetKit, runtime, or packaging change:

```sh
cd ~/Github/wallstats
./scripts/check.sh
./scripts/install.sh
```

The application is an invisible per-user LaunchAgent. It is not expected to
show a menu bar item or window. To preserve the widget's semantic colors and
emoji, use **System Settings → Desktop & Dock → Widgets → Widget style →
Full-color**.

### Finder and Nix

Finder does not load shell startup files and normally cannot find Nix commands.
Wallstats does not rely on Finder's `PATH`:

1. `nix build .#runtime` creates a native helper with absolute references to
   pinned `rust-script`, `cargo`, `rustc`, `macmon`, linker, certificates, and
   build tools.
2. `build-app.sh` embeds that helper at
   `Wallstats.app/Contents/Helpers/wallstats-rust-script`.
3. The app always prefers the bundled helper unless
   `WALLSTATS_RUST_SCRIPT` explicitly overrides it.
4. The out-link at `~/.local/state/wallstats/nix-runtime` is registered as an
   indirect GC root, so Nix cannot collect the helper's runtime closure while
   the app still uses it.

The app bundle contains only the small launcher. Compiler and Cargo paths stay
deduplicated in the Nix store.

## Configuration

The complete working example is [examples/config.rs](examples/config.rs). Its
layout reads like this:

```rust
let system = app.system(
    SystemCollector::new()
        .schedule(Schedule::every(Duration::from_secs(1)))
        .top_processes(8),
)?;
let mac = app.macmon(MacmonCollector::new())?;
let disk_io = app.disk_io(DiskIoCollector::new())?;

app.set_sections(sections![
    Section::new("perf", widgets![
        Stat::new("CPU", &mac.cpu_total).percent(),
        Stat::new("GPU", &mac.gpu_ratio).percent(),
        Stat::new("CPU °C", &mac.cpu_temperature).celsius(),
        Stat::new("GPU °C", &mac.gpu_temperature).celsius(),
        Plot::new("activity", vec![
            PlotSeries::new(&mac.cpu_total, "cyan"),
            PlotSeries::new(&mac.gpu_ratio, "blue"),
            PlotSeries::new(&disk_io.read, "amber"),
            PlotSeries::new(&disk_io.write, "purple"),
        ]).history(90),
    ]).weight(6),
    Section::new("disk", widgets![
        Stat::new("free", &system.root_disk_available).bytes(),
        Gauge::new("used", &system.root_disk_ratio).percent(),
    ]).weight(2),
    Section::new("net", widgets![
        Stat::new("down", &system.network_down).bytes_per_second(),
        Stat::new("up", &system.network_up).bytes_per_second(),
    ]).weight(1),
]);
```

The important types are:

| Rust type | Meaning | Compatible presentation |
| --- | --- | --- |
| `Ratio` | finite value from 0 through 1 | value, gauge, sparkline, percent |
| `Bytes` | byte count | value, sparkline, IEC bytes |
| `BytesPerSecond` | nonnegative byte rate | value, sparkline, IEC bytes/sec |
| `Count` | nonnegative count | value, sparkline |
| `Number` | arbitrary finite scalar | value, sparkline |
| `DurationSeconds` | nonnegative duration | value, sparkline |
| `Text` / `Boolean` | state | value |
| `CompactStatus` | glyphs, status light, optional age | compact tile |
| `Table` | validated rectangular rows | table |

`Metric<T>` carries this type through collector registration and widget
construction. The serialized protocol is type-erased only after Rust has
validated the configuration.

`TextFileSet` is generic: it selects ordinary files with a user predicate and
reads only bounded tails. The example's backup policy is plain Rust in the
configuration, not engine behavior. `CompactStatus` is likewise generic and can
represent any two-glyph status with a light and optional age.

### Plugins

A plugin is any `Send + 'static` value implementing `Collector<T>`:

```rust
struct QueueDepth(PathBuf);

impl Collector<Count> for QueueDepth {
    fn collect(&mut self) -> CollectResult<u64> {
        let text = std::fs::read_to_string(&self.0)
            .map_err(|error| CollectError::new(error.to_string()))?;
        text.trim()
            .parse()
            .map_err(|error| CollectError::new(format!("invalid queue depth: {error}")))
    }
}

let queue = app.metric::<Count>(
    "build.queue",
    Schedule::every(Duration::from_secs(2)),
    QueueDepth("/tmp/build-queue".into()),
)?;
```

Closures implementing the same signature work without defining a struct.
Built-in `LogCountCollector` reads only a bounded tail and reports missing,
unreadable, non-regular, or invalid UTF-8 files as visible per-metric errors.

The invisible companion fingerprints `config.rs`, debounces direct writes and
atomic editor replacements, and recompiles automatically. Collector failures
leave the widget's last valid snapshot intact.

## Development

```sh
nix develop
./scripts/check.sh
./scripts/build-app.sh
```

`check.sh` runs Rust tests and Clippy, compiles the example through the exact
Nix helper under a Finder-like empty environment, runs Swift tests, generates
the Xcode project, builds the host and WidgetKit extension with warnings as
errors, and rejects visible text constructs in widget rendering sources. It
does not launch the GUI.

Useful collector-only checks:

```sh
~/.local/state/wallstats/nix-runtime/bin/wallstats-rust-script \
  examples/config.rs -- --check

~/.local/state/wallstats/nix-runtime/bin/wallstats-rust-script \
  examples/config.rs -- --once
```

## Security and limitations

The Rust configuration and all Cargo dependencies are trusted code running as
the logged-in user. Wallstats never invokes a shell for collection and does not
request root. The companion remains unsandboxed so it can read configured logs;
the WidgetKit extension is sandboxed. Both are signed with the same stable Apple
Development identity and share only App Group
`22GNLKBRMV.com.memorici.wallstats`.

WidgetKit is intentionally not the collector. macOS launches extensions briefly
under a sandbox and controls timeline budgets, so arbitrary Rust plugins and log
access remain in the invisible companion.
