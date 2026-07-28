# Wallstats

Wallstats is a native macOS desktop and WidgetKit system monitor configured as
typechecked Rust. An invisible LaunchAgent runs the `rust-script` process that
owns collection, scheduling, layout, and user plugins. The same native editorial
renderer presents an optional desktop overlay and signed App Group snapshots for
the widget families.

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
typed collectors + four surface roots -- JSON Lines --> background companion
                                                    |                 |
                                           desktop overlay    signed App Group
                                                                      |
                                                                      v
                                                           WidgetKit families
```

The collector remains out of process. A bad plugin can fail collection without
corrupting the native renderer, and configuration reload replaces the process.
The wire contract is documented in [PROTOCOL.md](PROTOCOL.md).

The Rust config may independently provide up to four optional surfaces:
`desktop`, `widget_large`, `widget_medium`, and `widget_small`. Each has its own
root, so a small widget is not a lossy resize of the desktop or large-widget
tree. Missing kinds are simply disabled.

Every root is a StickyWM-style immutable layout AST made from `stack`, `section`,
`flow`, `split`, and `widget` nodes. The native solver is width-first: it derives
flow columns and weighted split tracks from available width, measures natural and
minimum height, and then packs the result. A split that cannot satisfy its track
widths re-homes those tracks to a source-ordered vertical stack. Runtime metric
values never affect geometry.

The desktop surface is the Conky-like overlay. Its `position(x, y, origin)` uses
inward offsets from `BottomLeft`, `TopLeft`, `BottomRight`, or `TopRight`; the
selected corner determines both the placement of `(0, 0)` and the axis
directions. Its configured `width` drives the width-first solve, and the natural
AST height determines the panel height. The current example uses
`.position(32.0, 32.0, SurfaceOrigin::BottomLeft).width(480.0)`, a subtle
12%-opaque black background, and click-through input. WidgetKit receives
separate large, medium, and small roots built from the same node types.

The renderer remains shape-first and omits versions, protocol details, and
status prose. Generic compact-status metrics render configured glyphs, a
shape-and-color status mark, and age; other leaves render plan-driven values,
gauges, plots, and tables.

- Cyan: CPU activity
- Blue: GPU activity
- Amber: disk reads
- Purple: disk writes
- Orange: disk usage

Each WidgetKit family renders only its explicitly configured Rust root. Missing
data leaves quiet neutral marks; snapshots older than 45 minutes fade.
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

The current example samples every two seconds while the desktop surface is
enabled. If desktop is disabled, it switches to a 30-second cadence for the
widget-only case, reducing streaming `macmon` wakeups and battery use. Snapshot
writes are still coalesced to at most once per minute and normal WidgetKit reload
requests to once per 30 minutes; macOS retains final control over widget budgets.

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

The complete working example is [examples/config.rs](examples/config.rs). The
essential surface structure looks like this:

```rust
let desktop_enabled = true;
let sampling = if desktop_enabled {
    Duration::from_secs(2)
} else {
    Duration::from_secs(30)
};
let mac = app.macmon(MacmonCollector::new().schedule(Schedule::every(sampling)))?;

let cpu = Widget::from(Stat::new("CPU", &mac.cpu_total).percent());
let gpu = Widget::from(Stat::new("GPU", &mac.gpu_ratio).percent());
let perf = LayoutNode::section(
    "PERF",
    Insets::symmetric(6.0, 8.0),
    LayoutNode::flow(
        6.0,
        6.0,
        72.0,
        vec![LayoutNode::widget(cpu.clone()), LayoutNode::widget(gpu.clone())],
    ),
);

let mut surfaces = Vec::new();
if desktop_enabled {
    surfaces.push(
        Surface::desktop(LayoutNode::stack(10.0, vec![perf.clone()]))
            .position(32.0, 32.0, SurfaceOrigin::BottomLeft)
            .width(480.0)
            .background_opacity(0.12)
            .click_through(true),
    );
}
surfaces.push(Surface::widget_large(LayoutNode::stack(8.0, vec![perf])));
surfaces.push(Surface::widget_medium(LayoutNode::split(
    8.0,
    140.0,
    vec![LayoutTrack::new(1.0, LayoutNode::widget(cpu.clone()))],
)));
surfaces.push(Surface::widget_small(LayoutNode::flow(
    4.0,
    4.0,
    62.0,
    vec![LayoutNode::widget(cpu), LayoutNode::widget(gpu)],
)));
app.set_surfaces(surfaces);
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

`check.sh` runs Rust tests and Clippy, compiles the four-surface example through
the exact Nix helper under a Finder-like empty environment, verifies the helper
process group and streaming-macmon cleanup, runs Swift tests, generates the Xcode
project, builds the host and WidgetKit extension with warnings as errors, and
guards the shared editorial renderer's visible controls. It does not launch the
GUI.

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

The embedded helper becomes a process-group leader before executing
`rust-script`. The compiled config and its long-lived `macmon` child inherit that
group, allowing reload and shutdown to terminate the full collector tree rather
than orphaning hardware samplers.

WidgetKit is intentionally not the collector. macOS launches extensions briefly
under a sandbox and controls timeline budgets, so arbitrary Rust plugins and log
access remain in the invisible companion.
