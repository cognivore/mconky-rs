#!/bin/bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "usage: $0" >&2
    exit 64
fi

if [[ -z "${HOME:-}" ]]; then
    echo "check: HOME must be set" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
runtime_link="${WALLSTATS_NIX_RUNTIME_LINK:-$HOME/.local/state/wallstats/nix-runtime}"
runtime_parent="$(dirname "$runtime_link")"
/bin/mkdir -p "$runtime_parent"
runtime_parent="$(cd "$runtime_parent" && pwd -P)"
runtime_link="$runtime_parent/$(basename "$runtime_link")"

if ! nix_bin="$(command -v nix)"; then
    echo "check: nix was not found on PATH" >&2
    exit 1
fi

flake_ref=.
if [[ -d "$repo_root/.git" ]] \
    && ! /usr/bin/git -C "$repo_root" ls-files --error-unmatch flake.nix >/dev/null 2>&1; then
    flake_ref="path:$repo_root"
fi

xcodegen_output="$(
    cd "$repo_root"
    "$nix_bin" build "$flake_ref#xcodegen" --no-link --print-out-paths
)"
xcodegen="$xcodegen_output/bin/xcodegen"
if [[ ! -x "$xcodegen" ]]; then
    echo "check: Nix XcodeGen executable is missing: $xcodegen" >&2
    exit 1
fi
"$xcodegen" --version

(
    cd "$repo_root"
    "$nix_bin" develop "$flake_ref#default" --command cargo test --workspace
    "$nix_bin" develop "$flake_ref#default" --command \
        cargo clippy --workspace --all-targets -- -D warnings
    "$nix_bin" build "$flake_ref#runtime" --out-link "$runtime_link"
)

runtime_helper="$runtime_link/bin/wallstats-rust-script"
if [[ ! -x "$runtime_helper" ]]; then
    echo "check: runtime helper is missing: $runtime_helper" >&2
    exit 1
fi

temporary_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/wallstats-check.XXXXXX")"
process_group_pid=
once_group_pid=
cleanup() {
    for group in "$process_group_pid" "$once_group_pid"; do
        if [[ -n "$group" ]]; then
            /bin/kill -TERM "-$group" 2>/dev/null || true
        fi
    done
    /bin/rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

process_group_members() {
    /bin/ps -axo pid=,pgid=,comm= \
        | /usr/bin/awk -v group="$1" '$2 == group { print }'
}

wait_for_group_leader() {
    local process_id=$1
    local description=$2
    local process_group

    for _ in {1..100}; do
        process_group="$(/bin/ps -p "$process_id" -o pgid= 2>/dev/null \
            | /usr/bin/awk '{ print $1 }')"
        if [[ "$process_group" == "$process_id" ]]; then
            return
        fi
        if ! /bin/kill -0 "$process_id" 2>/dev/null; then
            break
        fi
        /bin/sleep 0.05
    done
    echo "check: $description did not become process-group leader PID $process_id" >&2
    return 1
}

(
    cd "$repo_root"
    /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin \
        "$runtime_helper" --force "$repo_root/examples/config.rs" -- --check \
        > "$temporary_dir/check.jsonl"
)

(
    cd "$repo_root"
    exec /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin \
        "$runtime_helper" --force "$script_dir/process-group-probe.rs"
) > "$temporary_dir/process-group.txt" 2> "$temporary_dir/process-group.err" &
process_group_pid=$!
wait_for_group_leader "$process_group_pid" "runtime helper"
for _ in {1..100}; do
    [[ -s "$temporary_dir/process-group.txt" ]] && break
    /bin/sleep 0.05
done
if [[ ! -s "$temporary_dir/process-group.txt" ]]; then
    echo "check: process-group config produced no identity output" >&2
    /bin/cat "$temporary_dir/process-group.err" >&2
    exit 1
fi
config_pid="$(/usr/bin/awk '{ for (i = 1; i <= NF; i++) { split($i, part, "="); if (part[1] == "pid") print part[2] } }' \
    "$temporary_dir/process-group.txt")"
config_pgid="$(/usr/bin/awk '{ for (i = 1; i <= NF; i++) { split($i, part, "="); if (part[1] == "pgid") print part[2] } }' \
    "$temporary_dir/process-group.txt")"
if [[ "$config_pgid" != "$process_group_pid" ]]; then
    echo "check: config did not inherit helper process group $process_group_pid" >&2
    /bin/cat "$temporary_dir/process-group.txt" >&2
    exit 1
fi
if ! wait "$process_group_pid"; then
    echo "check: process-group probe failed" >&2
    /bin/cat "$temporary_dir/process-group.err" >&2
    exit 1
fi
/bin/sleep 0.2
remaining_group="$(process_group_members "$process_group_pid")"
if [[ -n "$remaining_group" ]]; then
    echo "check: process-group probe left descendants running" >&2
    echo "$remaining_group" >&2
    exit 1
fi
echo "Process-group probe: helper PID/PGID $process_group_pid; config PID $config_pid inherited PGID $config_pgid; clean exit."
process_group_pid=

(
    cd "$repo_root"
    exec /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin \
        "$runtime_helper" --force "$repo_root/examples/config.rs" -- --once
) > "$temporary_dir/once.jsonl" 2> "$temporary_dir/once.err" &
once_group_pid=$!
wait_for_group_leader "$once_group_pid" "forced example"
if ! wait "$once_group_pid"; then
    echo "check: forced example --once failed" >&2
    /bin/cat "$temporary_dir/once.err" >&2
    exit 1
fi
/bin/sleep 0.2
remaining_group="$(process_group_members "$once_group_pid")"
if [[ -n "$remaining_group" ]]; then
    echo "check: forced example left streaming macmon descendants running" >&2
    echo "$remaining_group" >&2
    exit 1
fi
echo "Streaming macmon probe: process group $once_group_pid exited with no remaining descendants."
once_group_pid=

/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin \
    "$runtime_helper" --force "$script_dir/macmon-probe.rs" \
    > "$temporary_dir/macmon-resolution.txt"

if [[ ! -s "$temporary_dir/check.jsonl" || ! -s "$temporary_dir/once.jsonl" ]]; then
    echo "check: rust-script checks produced no protocol output" >&2
    exit 1
fi
if ! /usr/bin/grep -Eq \
    '^/nix/store/[a-z0-9]+-macmon-0\.8\.0/bin/macmon[[:space:]]+macmon 0\.8\.0$' \
    "$temporary_dir/macmon-resolution.txt"; then
    echo "check: runtime helper did not resolve pinned Nix macmon 0.8.0" >&2
    /bin/cat "$temporary_dir/macmon-resolution.txt" >&2
    exit 1
fi
for protocol_output in "$temporary_dir/check.jsonl" "$temporary_dir/once.jsonl"; do
    if ! /usr/bin/grep -Fq '"type":"plan"' "$protocol_output" \
        || ! /usr/bin/grep -Fq '"surfaces":[{' "$protocol_output"; then
        echo "check: forced example produced no nonempty surfaces array" >&2
        exit 1
    fi
    for surface_kind in desktop widget_large widget_medium widget_small; do
        if ! /usr/bin/grep -Fq "\"kind\":\"$surface_kind\"" "$protocol_output"; then
            echo "check: forced example is missing $surface_kind surface" >&2
            exit 1
        fi
    done
    for layout_kind in stack section flow split widget; do
        if ! /usr/bin/grep -Fq "\"kind\":\"$layout_kind\"" "$protocol_output"; then
            echo "check: forced example is missing $layout_kind layout node" >&2
            exit 1
        fi
    done
done
for metric in \
    macmon.cpu.total \
    macmon.gpu.ratio \
    macmon.temperature.cpu \
    macmon.temperature.gpu \
    disk.io.read \
    disk.io.write; do
    if ! /usr/bin/grep -Fq "\"metric\":\"$metric\",\"value\":" \
        "$temporary_dir/once.jsonl"; then
        echo "check: forced example produced no value for $metric" >&2
        exit 1
    fi
done

widget_sources=("$repo_root/macos/Sources/WallstatsWidget/"*.swift)
editorial_renderer_source="$repo_root/macos/Sources/WallstatsCore/EditorialSurfaceView.swift"
render_sources=("${widget_sources[@]}" "$editorial_renderer_source")
if /usr/bin/grep -En \
    '(^|[^[:alnum:]_])(Label|Image|Gauge|ProgressView)[[:space:]]*\(' \
    "${render_sources[@]}"; then
    echo "check: render source contains a prohibited visible view type" >&2
    exit 1
fi
if /usr/bin/grep -En \
    '(^|[^[:alnum:]_])Text[[:space:]]*\(' \
    "${widget_sources[@]}"; then
    echo "check: WallstatsWidget sources must not contain direct Text calls" >&2
    exit 1
fi
editorial_text_count="$(/usr/bin/grep -Ec \
    '(^|[^[:alnum:]_])Text[[:space:]]*\(' "$editorial_renderer_source")"
if [[ "$editorial_text_count" -ne 15 ]]; then
    echo "check: EditorialSurfaceView.swift must contain exactly 15 Text calls" >&2
    exit 1
fi
if /usr/bin/grep -Ein '"[^"]*(version|protocol|header|footer)[^"]*"' \
    "${render_sources[@]}"; then
    echo "check: render source contains a visible version/protocol/header/footer string" >&2
    exit 1
fi

host_entitlements="$repo_root/macos/Support/Wallstats.entitlements"
widget_entitlements="$repo_root/macos/Support/WallstatsWidget.entitlements"
expected_group=22GNLKBRMV.com.memorici.wallstats
for plist in \
    "$repo_root/macos/Support/Wallstats-Info.plist" \
    "$repo_root/macos/Support/WallstatsWidget-Info.plist" \
    "$host_entitlements" \
    "$widget_entitlements"; do
    /usr/bin/plutil -lint "$plist" >/dev/null
done

launch_agent_plist="$temporary_dir/com.memorici.wallstats.plist"
launch_agent_home="$temporary_dir/Home & Wallstats"
HOME="$launch_agent_home" "$script_dir/launch-agent.sh" render "$launch_agent_plist"
HOME="$launch_agent_home" "$script_dir/launch-agent.sh" validate "$launch_agent_plist"

cli_home="$temporary_dir/CLI Home"
HOME="$cli_home" "$script_dir/install-cli.sh" >/dev/null
installed_cli="$cli_home/.local/bin/wallstats"
[[ -x "$installed_cli" ]] || { echo "check: temporary CLI install failed" >&2; exit 1; }
for command in reload refresh config help; do
    HOME="$cli_home" WALLSTATS_CLI_DRY_RUN=1 "$installed_cli" "$command" >/dev/null
done
set +e
HOME="$cli_home" WALLSTATS_CLI_DRY_RUN=1 "$installed_cli" unknown \
    >"$temporary_dir/cli-unknown.out" 2>"$temporary_dir/cli-unknown.err"
cli_unknown_status=$?
set -e
if [[ "$cli_unknown_status" -ne 64 ]]; then
    echo "check: unknown CLI command returned $cli_unknown_status instead of 64" >&2
    exit 1
fi
host_group="$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.application-groups:0' "$host_entitlements")"
widget_group="$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.application-groups:0' "$widget_entitlements")"
if [[ "$host_group" != "$expected_group" || "$widget_group" != "$expected_group" ]]; then
    echo "check: source entitlements do not contain the exact shared App Group" >&2
    exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' \
    "$host_entitlements" >/dev/null 2>&1; then
    echo "check: host entitlement must remain unsandboxed" >&2
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' \
    "$widget_entitlements")" != true ]]; then
    echo "check: widget sandbox entitlement is missing" >&2
    exit 1
fi

developer_dir="$(/usr/bin/env -u DEVELOPER_DIR -u SDKROOT /usr/bin/xcode-select -p)"
sdk_path="$(/usr/bin/env -u SDKROOT DEVELOPER_DIR="$developer_dir" \
    /usr/bin/xcrun --sdk macosx --show-sdk-path)"

xcrun() {
    /usr/bin/env -i \
        HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        DEVELOPER_DIR="$developer_dir" SDKROOT="$sdk_path" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        /usr/bin/xcrun --sdk macosx "$@"
}

xcrun swiftc \
    -typecheck \
    -sdk "$sdk_path" \
    -target "$(/usr/bin/uname -m)-apple-macos14.0" \
    -swift-version 6 \
    -warnings-as-errors \
    "$script_dir/request-wallstats-quit.swift"

xcrun swift test \
    --package-path "$repo_root/macos" \
    --sdk "$sdk_path" \
    -Xswiftc -warnings-as-errors
xcrun swift build \
    --package-path "$repo_root/macos" \
    --configuration release \
    --sdk "$sdk_path" \
    -Xswiftc -warnings-as-errors

project_dir="$temporary_dir/project"
derived_data="$temporary_dir/DerivedData"
/bin/mkdir -p "$project_dir"
WALLSTATS_MACOS_ROOT="$repo_root/macos" "$xcodegen" \
    --spec "$repo_root/macos/project.yml" \
    --project "$project_dir" \
    --project-root "$repo_root/macos"
xcrun xcodebuild \
    -quiet \
    -project "$project_dir/Wallstats.xcodeproj" \
    -scheme Wallstats \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    -destination 'generic/platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    REGISTER_WITH_LAUNCH_SERVICES=NO \
    "CODE_SIGN_IDENTITY=" \
    "ARCHS=$(/usr/bin/uname -m)" \
    ONLY_ACTIVE_ARCH=YES \
    build

xcode_app="$derived_data/Build/Products/Release/Wallstats.app"
"$script_dir/verify-app.sh" "$xcode_app"
if [[ -d "$xcode_app/Contents/_CodeSignature" \
    || -d "$xcode_app/Contents/PlugIns/WallstatsWidgetExtension.appex/Contents/_CodeSignature" ]]; then
    echo "check: unsigned Xcode build unexpectedly contains a bundle signature" >&2
    exit 1
fi

echo "All checks passed."
