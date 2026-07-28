#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 SOURCE DESTINATION" >&2
    exit 64
fi

source_path=$1
destination_path=$2
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ ! -e "$source_path" && ! -L "$source_path" ]]; then
    echo "atomic-replace: source does not exist: $source_path" >&2
    exit 1
fi
if [[ "$source_path" == "$destination_path" ]]; then
    echo "atomic-replace: source and destination are identical" >&2
    exit 1
fi

if [[ ! -e "$destination_path" && ! -L "$destination_path" ]]; then
    /bin/mv "$source_path" "$destination_path"
    exit 0
fi

developer_dir="$(/usr/bin/env -u DEVELOPER_DIR -u SDKROOT /usr/bin/xcode-select -p)"
sdk_path="$(/usr/bin/env -u SDKROOT DEVELOPER_DIR="$developer_dir" \
    /usr/bin/xcrun --sdk macosx --show-sdk-path)"
temporary_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/wallstats-atomic-replace.XXXXXX")"

cleanup() {
    /bin/rm -rf "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

/usr/bin/env -i HOME="${HOME:-/var/empty}" TMPDIR="${TMPDIR:-/tmp}" \
    DEVELOPER_DIR="$developer_dir" SDKROOT="$sdk_path" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /usr/bin/xcrun --sdk macosx clang \
    -isysroot "$sdk_path" -mmacosx-version-min=14.0 \
    -O2 -Wall -Wextra -Werror \
    "$script_dir/atomic-replace.c" -o "$temporary_dir/atomic-replace"

"$temporary_dir/atomic-replace" "$source_path" "$destination_path"
/bin/rm -rf "$source_path"
