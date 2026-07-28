#!/bin/bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "usage: $0" >&2
    exit 64
fi
if [[ -z "${HOME:-}" ]]; then
    echo "request-wallstats-quit: HOME must be set" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
developer_dir="$(/usr/bin/env -u DEVELOPER_DIR -u SDKROOT /usr/bin/xcode-select -p)"
sdk_path="$(/usr/bin/env -u SDKROOT DEVELOPER_DIR="$developer_dir" \
    /usr/bin/xcrun --sdk macosx --show-sdk-path)"
architecture="$(/usr/bin/uname -m)"
case "$architecture" in
    arm64 | x86_64) ;;
    *)
        echo "request-wallstats-quit: unsupported architecture: $architecture" >&2
        exit 1
        ;;
esac

temporary_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/wallstats-quit.XXXXXX")"
quit_binary="$temporary_dir/request-wallstats-quit"
cleanup() {
    /bin/rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

/usr/bin/env -i \
    HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
    DEVELOPER_DIR="$developer_dir" SDKROOT="$sdk_path" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /usr/bin/xcrun --sdk macosx swiftc \
    -sdk "$sdk_path" \
    -target "$architecture-apple-macos14.0" \
    -swift-version 6 \
    -warnings-as-errors \
    -O \
    "$script_dir/request-wallstats-quit.swift" \
    -o "$quit_binary"

/usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin "$quit_binary"
