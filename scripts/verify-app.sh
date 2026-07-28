#!/bin/bash
set -euo pipefail

signed=false
if [[ ${1:-} == --signed ]]; then
    signed=true
    shift
fi
if [[ $# -ne 1 ]]; then
    echo "usage: $0 [--signed] APP" >&2
    exit 64
fi

app_path=$1
expected_team=22GNLKBRMV
expected_group=22GNLKBRMV.com.memorici.wallstats
expected_widget_id=com.memorici.wallstats.widget
widget_path="$app_path/Contents/PlugIns/WallstatsWidgetExtension.appex"
host_info="$app_path/Contents/Info.plist"

fail() {
    echo "verify-app: $*" >&2
    exit 1
}

plist_value() {
    /usr/bin/plutil -extract "$2" raw -o - "$1"
}

[[ -d "$app_path" ]] || fail "app bundle is missing: $app_path"
[[ -f "$host_info" ]] || fail "host Info.plist is missing"
[[ -x "$app_path/Contents/MacOS/Wallstats" ]] || fail "host executable is missing"
[[ -d "$app_path/Contents/PlugIns" ]] || fail "Contents/PlugIns is missing"

shopt -s nullglob
extensions=("$app_path/Contents/PlugIns/"*.appex)
shopt -u nullglob
[[ ${#extensions[@]} -eq 1 ]] || fail "expected exactly one embedded app extension"
[[ "${extensions[0]}" == "$widget_path" ]] || fail "unexpected embedded extension: ${extensions[0]}"

widget_info="$widget_path/Contents/Info.plist"
[[ -f "$widget_info" ]] || fail "widget Info.plist is missing"
widget_executable="$(plist_value "$widget_info" CFBundleExecutable)"
[[ -x "$widget_path/Contents/MacOS/$widget_executable" ]] || fail "widget executable is missing"

[[ "$(plist_value "$host_info" CFBundleIdentifier)" == com.memorici.wallstats ]] \
    || fail "wrong host bundle identifier"
[[ "$(plist_value "$host_info" CFBundlePackageType)" == APPL ]] \
    || fail "wrong host package type"
[[ "$(plist_value "$host_info" LSUIElement)" == true ]] \
    || fail "host must set LSUIElement=true"
[[ "$(plist_value "$host_info" CFBundleVersion)" == 6 ]] || fail "host build number must be 6"
[[ "$(plist_value "$widget_info" CFBundleVersion)" == 6 ]] || fail "widget build number must be 6"
[[ "$(plist_value "$host_info" CFBundleURLTypes)" == 1 ]] \
    || fail "host must declare exactly one URL type"
[[ "$(plist_value "$host_info" CFBundleURLTypes.0.CFBundleTypeRole)" == Editor ]] \
    || fail "wallstats URL role must be Editor"
[[ "$(plist_value "$host_info" CFBundleURLTypes.0.CFBundleURLName)" \
    == com.memorici.wallstats ]] || fail "wrong wallstats URL identifier"
[[ "$(plist_value "$host_info" CFBundleURLTypes.0.CFBundleURLSchemes)" == 1 ]] \
    || fail "host must declare exactly one URL scheme"
[[ "$(plist_value "$host_info" CFBundleURLTypes.0.CFBundleURLSchemes.0)" == wallstats ]] \
    || fail "wallstats URL scheme is missing"
[[ "$(plist_value "$widget_info" CFBundleIdentifier)" == "$expected_widget_id" ]] \
    || fail "wrong widget bundle identifier"
[[ "$(plist_value "$widget_info" CFBundlePackageType)" == 'XPC!' ]] \
    || fail "wrong widget package type"
[[ "$(plist_value "$widget_info" NSExtension.NSExtensionPointIdentifier)" \
    == com.apple.widgetkit-extension ]] || fail "wrong widget extension point"
nsextension_json="$(/usr/bin/plutil -extract NSExtension json -o - "$widget_info")"
[[ "$nsextension_json" == '{"NSExtensionPointIdentifier":"com.apple.widgetkit-extension"}' ]] \
    || fail "widget NSExtension dictionary contains unexpected keys: $nsextension_json"

if [[ "$signed" != true ]]; then
    echo "Validated unsigned app and WidgetKit extension layout."
    exit 0
fi

helper_path="$app_path/Contents/Helpers/wallstats-rust-script"
[[ -x "$helper_path" ]] || fail "Nix runtime helper is missing"

/usr/bin/codesign --verify --strict --verbose=2 "$helper_path"
/usr/bin/codesign --verify --strict --verbose=2 "$widget_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"

team_identifier() {
    /usr/bin/codesign --display --verbose=4 "$1" 2>&1 \
        | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }'
}

[[ "$(team_identifier "$app_path")" == "$expected_team" ]] \
    || fail "host TeamIdentifier is not $expected_team"
[[ "$(team_identifier "$widget_path")" == "$expected_team" ]] \
    || fail "widget TeamIdentifier is not $expected_team"
[[ "$(team_identifier "$helper_path")" == "$expected_team" ]] \
    || fail "helper TeamIdentifier is not $expected_team"

entitlements_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/wallstats-entitlements.XXXXXX")"
cleanup() {
    /bin/rm -rf "$entitlements_dir"
}
trap cleanup EXIT HUP INT TERM

/usr/bin/codesign --display --xml --entitlements - "$app_path" \
    > "$entitlements_dir/host.plist" 2>/dev/null
/usr/bin/codesign --display --xml --entitlements - "$widget_path" \
    > "$entitlements_dir/widget.plist" 2>/dev/null
/usr/bin/plutil -lint "$entitlements_dir/host.plist" >/dev/null
/usr/bin/plutil -lint "$entitlements_dir/widget.plist" >/dev/null

host_group="$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.application-groups:0' "$entitlements_dir/host.plist")"
widget_group="$(/usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.application-groups:0' "$entitlements_dir/widget.plist")"
[[ "$host_group" == "$expected_group" ]] || fail "host App Group is wrong: $host_group"
[[ "$widget_group" == "$expected_group" ]] || fail "widget App Group is wrong: $widget_group"
[[ "$host_group" == "$widget_group" ]] || fail "host and widget App Groups differ"
if /usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.application-groups:1' "$entitlements_dir/host.plist" \
    >/dev/null 2>&1; then
    fail "host has more than one App Group"
fi
if /usr/libexec/PlistBuddy -c \
    'Print :com.apple.security.application-groups:1' "$entitlements_dir/widget.plist" \
    >/dev/null 2>&1; then
    fail "widget has more than one App Group"
fi
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' \
    "$entitlements_dir/host.plist" >/dev/null 2>&1; then
    fail "host must remain unsandboxed"
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' \
    "$entitlements_dir/widget.plist")" == true ]] || fail "widget sandbox entitlement is missing"

echo "Validated signed app: TeamIdentifier=$expected_team, App Group=$expected_group"
