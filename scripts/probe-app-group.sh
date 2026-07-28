#!/bin/bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "usage: $0" >&2
    exit 64
fi
if [[ -z "${HOME:-}" ]]; then
    echo "probe-app-group: HOME must be set" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
entitlements="$repo_root/macos/Support/Wallstats.entitlements"
signing_identity="${WALLSTATS_SIGNING_IDENTITY:-F710DD2FF401E3B9C9F6991B2BF7115D8829E332}"
expected_team=22GNLKBRMV
expected_group=22GNLKBRMV.com.memorici.wallstats

valid_identities="$(/usr/bin/security find-identity -v -p codesigning)"
if [[ "$valid_identities" != *"$signing_identity"* ]]; then
    echo "probe-app-group: signing identity is unavailable: $signing_identity" >&2
    echo "$valid_identities" >&2
    exit 1
fi
if [[ ! -f "$entitlements" ]]; then
    echo "probe-app-group: entitlements are missing: $entitlements" >&2
    exit 1
fi

developer_dir="$(/usr/bin/env -u DEVELOPER_DIR -u SDKROOT /usr/bin/xcode-select -p)"
sdk_path="$(/usr/bin/env -u SDKROOT DEVELOPER_DIR="$developer_dir" \
    /usr/bin/xcrun --sdk macosx --show-sdk-path)"
architecture="$(/usr/bin/uname -m)"
case "$architecture" in
    arm64 | x86_64) ;;
    *)
        echo "probe-app-group: unsupported architecture: $architecture" >&2
        exit 1
        ;;
esac

temporary_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/wallstats-app-group-probe.XXXXXX")"
probe_binary="$temporary_dir/wallstats-app-group-probe"
signed_entitlements="$temporary_dir/signed-entitlements.plist"
cleanup() {
    /bin/rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

xcrun() {
    /usr/bin/env -i \
        HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
        DEVELOPER_DIR="$developer_dir" SDKROOT="$sdk_path" \
        PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        /usr/bin/xcrun --sdk macosx "$@"
}

xcrun swiftc \
    -sdk "$sdk_path" \
    -target "$architecture-apple-macos14.0" \
    -swift-version 6 \
    -warnings-as-errors \
    -O \
    "$script_dir/app-group-probe.swift" \
    -o "$probe_binary"

/usr/bin/codesign --force \
    --sign "$signing_identity" \
    --timestamp=none \
    --identifier com.memorici.wallstats \
    --entitlements "$entitlements" \
    "$probe_binary"
/usr/bin/codesign --verify --strict --verbose=2 "$probe_binary"

team_identifier="$(/usr/bin/codesign --display --verbose=4 "$probe_binary" 2>&1 \
    | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
if [[ "$team_identifier" != "$expected_team" ]]; then
    echo "probe-app-group: TeamIdentifier is '$team_identifier', expected '$expected_team'" >&2
    exit 1
fi

/usr/bin/codesign --display --xml --entitlements - "$probe_binary" \
    > "$signed_entitlements" 2>/dev/null
/usr/bin/plutil -lint "$signed_entitlements" >/dev/null
signed_group="$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.application-groups:0' "$signed_entitlements")"
if [[ "$signed_group" != "$expected_group" ]]; then
    echo "probe-app-group: signed App Group is '$signed_group', expected '$expected_group'" >&2
    exit 1
fi
if /usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.application-groups:1' "$signed_entitlements" \
    >/dev/null 2>&1; then
    echo "probe-app-group: signed probe has more than one App Group" >&2
    exit 1
fi

container_path="$(/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin "$probe_binary")"
if [[ "$container_path" != /* || ! -d "$container_path" ]]; then
    echo "probe-app-group: probe returned an invalid container path: $container_path" >&2
    exit 1
fi

printf '%s\n' "$container_path"
