#!/bin/bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "usage: $0" >&2
    exit 64
fi

if [[ -z "${HOME:-}" ]]; then
    echo "install: HOME must be set" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
built_app="$repo_root/Wallstats.app"
destination_app="$HOME/Applications/Wallstats.app"
destination_parent="$(dirname "$destination_app")"
/bin/mkdir -p "$destination_parent"
destination_parent="$(cd "$destination_parent" && pwd -P)"
destination_app="$destination_parent/$(basename "$destination_app")"

"$script_dir/build-app.sh" "$built_app"

staging_dir="$(/usr/bin/mktemp -d "$destination_parent/.wallstats-install.XXXXXX")"
staged_app="$staging_dir/Wallstats.app"

cleanup() {
    /bin/rm -rf "$staging_dir"
}
trap cleanup EXIT HUP INT TERM

/usr/bin/ditto "$built_app" "$staged_app"
"$script_dir/verify-app.sh" --signed "$staged_app"
"$script_dir/probe-app-group.sh"

config_dir="$HOME/.config/wallstats"
config_path="$config_dir/config.rs"
/bin/mkdir -p "$config_dir"
if [[ ! -e "$config_path" && ! -L "$config_path" ]]; then
    temporary_config="$(/usr/bin/mktemp "$config_dir/.config.rs.XXXXXX")"
    /bin/cp "$repo_root/examples/config.rs" "$temporary_config"
    /bin/chmod 644 "$temporary_config"
    /bin/mv -n "$temporary_config" "$config_path"
    if [[ -e "$temporary_config" || -L "$temporary_config" ]]; then
        /bin/rm -f "$temporary_config"
    fi
fi

if /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x Wallstats >/dev/null 2>&1; then
    "$script_dir/request-wallstats-quit.sh"
fi
"$script_dir/launch-agent.sh" bootout
for _ in {1..50}; do
    if ! /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x Wallstats >/dev/null 2>&1; then
        break
    fi
    /bin/sleep 0.2
done
if /usr/bin/pgrep -u "$(/usr/bin/id -u)" -x Wallstats >/dev/null 2>&1; then
    echo "install: Wallstats did not terminate gracefully" >&2
    exit 1
fi

"$script_dir/atomic-replace.sh" "$staged_app" "$destination_app"
"$script_dir/verify-app.sh" --signed "$destination_app"
"$script_dir/launch-agent.sh" install
"$script_dir/install-cli.sh"
installed_cli="$HOME/.local/bin/wallstats"
[[ -x "$installed_cli" ]] || { echo "install: CLI is missing: $installed_cli" >&2; exit 1; }
"$installed_cli" help >/dev/null

launch_services_register="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$launch_services_register" ]]; then
    "$launch_services_register" -f "$destination_app"
fi

widget_identifier=com.memorici.wallstats.widget
widget_path="$destination_app/Contents/PlugIns/WallstatsWidgetExtension.appex"
/usr/bin/pluginkit -a "$widget_path"
plugin_listing="$(/usr/bin/pluginkit -m -A -D -v -i "$widget_identifier")"
if [[ "$plugin_listing" != *"$widget_identifier"* || "$plugin_listing" != *"$widget_path"* ]]; then
    echo "install: pluginkit did not register $widget_identifier at $widget_path" >&2
    echo "$plugin_listing" >&2
    exit 1
fi

"$script_dir/launch-agent.sh" bootstrap

echo "Installed $destination_app"
echo "Configuration: $config_path"
echo "Registered widget extension: $widget_identifier"
echo "CLI: $installed_cli"
