#!/bin/bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "usage: $0" >&2
    exit 64
fi
if [[ -z "${HOME:-}" ]]; then
    echo "install-cli: HOME must be set" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
source_cli="$script_dir/wallstats"
bin_dir="$HOME/.local/bin"
installed_cli="$bin_dir/wallstats"

[[ -f "$source_cli" ]] || { echo "install-cli: source CLI is missing: $source_cli" >&2; exit 1; }
/bin/mkdir -p "$bin_dir"
temporary_cli="$(/usr/bin/mktemp "$bin_dir/.wallstats.XXXXXX")"
cleanup() {
    /bin/rm -f "$temporary_cli"
}
trap cleanup EXIT HUP INT TERM

/bin/cp "$source_cli" "$temporary_cli"
/bin/chmod 755 "$temporary_cli"
/bin/bash -n "$temporary_cli"
"$script_dir/atomic-replace.sh" "$temporary_cli" "$installed_cli"

if [[ ! -x "$installed_cli" || "$(/usr/bin/stat -f '%Lp' "$installed_cli")" != 755 ]]; then
    echo "install-cli: installed CLI is not executable with mode 755: $installed_cli" >&2
    exit 1
fi
/usr/bin/cmp "$source_cli" "$installed_cli"
HOME="$HOME" "$installed_cli" help >/dev/null

echo "Installed Wallstats CLI: $installed_cli"
