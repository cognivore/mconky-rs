# Wallstats protocol v1

The rust-script configuration is a long-running collector process. It writes
UTF-8 JSON Lines to stdout; diagnostics belong on stderr. The native app never
executes a shell.

Each JSON record is limited to 1 MiB, excluding its trailing newline. Both the
Rust runtime and native decoder enforce this limit.

## Child to app

The first two records are `hello` and `plan`:

```json
{"type":"hello","protocol_major":1,"protocol_minor":0,"sdk_version":"0.1.0"}
{"type":"plan","title":"My Mac","metrics":[{"id":"cpu.total","value_type":"ratio","stale_after_ms":3000}],"window":{"width":420,"anchor":"top_right","margin":20,"layer":"desktop","opacity":0.94},"sections":[{"title":"Performance","widgets":[{"kind":"sparkline","label":"CPU","metric":"cpu.total","format":"percent","accent":"cyan","history":60}]}]}
```

`plan` is immutable for the lifetime of a child. Configuration reload replaces
the child process.

Updates contain typed values or explicit collection errors:

```json
{"type":"update","sequence":1,"timestamp_ms":1785168000123,"values":[{"metric":"cpu.total","value":{"kind":"ratio","value":0.42}},{"metric":"backup.errors","error":"log is not readable"}]}
```

Supported value kinds are:

```json
{"kind":"ratio","value":0.42}
{"kind":"bytes","value":123456}
{"kind":"bytes_per_second","value":1048576.5}
{"kind":"count","value":7}
{"kind":"duration_seconds","value":12.5}
{"kind":"number","value":3.14}
{"kind":"text","value":"healthy"}
{"kind":"boolean","value":true}
{"kind":"table","columns":["PID","CPU","MEM","COMMAND"],"rows":[["42","18%","64 MiB","worker"]]}
```

The child may also emit:

```json
{"type":"heartbeat","sequence":2,"timestamp_ms":1785168005123}
{"type":"fatal","message":"collector runtime stopped"}
```

## Process modes

The SDK recognizes arguments after rust-script's `--` separator:

- `--check`: validate the configuration, emit `hello` and `plan`, then exit.
- `--once`: emit `hello`, `plan`, and one update, then exit.
- no mode: serve until terminated, with a heartbeat at least every five seconds.

Protocol major versions must match. Minor versions may only add optional fields.
Metric IDs match `[a-z][a-z0-9_.-]{0,127}` and are unique.
