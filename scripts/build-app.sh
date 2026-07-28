#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "usage: $0 [OUTPUT_APP]" >&2
    exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
app_output="${1:-${WALLSTATS_APP_OUTPUT:-$repo_root/Wallstats.app}}"
output_parent="$(dirname "$app_output")"
/bin/mkdir -p "$output_parent"
output_parent="$(cd "$output_parent" && pwd -P)"
app_output="$output_parent/$(basename "$app_output")"

if [[ -z "${HOME:-}" ]]; then
    echo "build-app: HOME must be set" >&2
    exit 1
fi

signing_identity="${WALLSTATS_SIGNING_IDENTITY:-F710DD2FF401E3B9C9F6991B2BF7115D8829E332}"
valid_identities="$(/usr/bin/security find-identity -v -p codesigning)"
if [[ "$valid_identities" != *"$signing_identity"* ]]; then
    echo "build-app: signing identity is unavailable: $signing_identity" >&2
    echo "$valid_identities" >&2
    exit 1
fi

runtime_link="${WALLSTATS_NIX_RUNTIME_LINK:-$HOME/.local/state/wallstats/nix-runtime}"
runtime_parent="$(dirname "$runtime_link")"
/bin/mkdir -p "$runtime_parent"
runtime_parent="$(cd "$runtime_parent" && pwd -P)"
runtime_link="$runtime_parent/$(basename "$runtime_link")"

if ! nix_bin="$(command -v nix)"; then
    echo "build-app: nix was not found on PATH" >&2
    exit 1
fi
if ! nix_store_bin="$(command -v nix-store)"; then
    echo "build-app: nix-store was not found on PATH" >&2
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
    echo "build-app: Nix XcodeGen executable is missing: $xcodegen" >&2
    exit 1
fi

(
    cd "$repo_root"
    "$nix_bin" build "$flake_ref#runtime" --out-link "$runtime_link"
)

runtime_store_path="$(/usr/bin/readlink "$runtime_link")"
if [[ "$runtime_store_path" != /nix/store/* ]]; then
    echo "build-app: runtime out-link does not target the Nix store: $runtime_link" >&2
    exit 1
fi
root_record="$runtime_link -> $runtime_store_path"
if ! "$nix_store_bin" --gc --print-roots 2>/dev/null \
    | /usr/bin/grep -F -x "$root_record" >/dev/null; then
    /bin/rm -f "$runtime_link"
    "$nix_store_bin" --add-root "$runtime_link" --indirect \
        --realise "$runtime_store_path" >/dev/null
fi
if ! "$nix_store_bin" --gc --print-roots 2>/dev/null \
    | /usr/bin/grep -F -x "$root_record" >/dev/null; then
    echo "build-app: Nix runtime out-link was not registered as an indirect GC root" >&2
    exit 1
fi

runtime_helper="$runtime_link/bin/wallstats-rust-script"
if [[ ! -x "$runtime_helper" ]]; then
    echo "build-app: runtime helper is missing: $runtime_helper" >&2
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

staging_dir="$(/usr/bin/mktemp -d "$output_parent/.wallstats-app.XXXXXX")"
project_dir="$staging_dir/project"
derived_data="$staging_dir/DerivedData"
staged_app="$staging_dir/staged/Wallstats.app"
cleanup() {
    /bin/rm -rf "$staging_dir"
}
trap cleanup EXIT HUP INT TERM
/bin/mkdir -p "$project_dir" "$(dirname "$staged_app")"

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
/usr/bin/ditto "$xcode_app" "$staged_app"

/bin/mkdir -p \
    "$staged_app/Contents/Helpers" \
    "$staged_app/Contents/Resources/WallstatsDefaults"
/bin/cp "$runtime_helper" "$staged_app/Contents/Helpers/wallstats-rust-script"
/bin/cp "$repo_root/examples/config.rs" \
    "$staged_app/Contents/Resources/WallstatsDefaults/config.rs"
/bin/chmod 755 "$staged_app/Contents/Helpers/wallstats-rust-script"
/bin/chmod 644 "$staged_app/Contents/Resources/WallstatsDefaults/config.rs"
/usr/bin/cmp "$repo_root/examples/config.rs" \
    "$staged_app/Contents/Resources/WallstatsDefaults/config.rs"

while IFS= read -r -d '' dylib; do
    /usr/bin/codesign --force --sign "$signing_identity" --timestamp=none "$dylib"
done < <(/usr/bin/find "$staged_app/Contents" -depth -type f -name '*.dylib' -print0)
while IFS= read -r -d '' framework; do
    /usr/bin/codesign --force --sign "$signing_identity" --timestamp=none "$framework"
done < <(/usr/bin/find "$staged_app/Contents" -depth -type d -name '*.framework' -print0)

widget_path="$staged_app/Contents/PlugIns/WallstatsWidgetExtension.appex"
/usr/bin/codesign --force --sign "$signing_identity" --timestamp=none \
    "$staged_app/Contents/Helpers/wallstats-rust-script"
/usr/bin/codesign --force --sign "$signing_identity" --timestamp=none \
    --entitlements "$repo_root/macos/Support/WallstatsWidget.entitlements" \
    "$widget_path"
/usr/bin/codesign --force --sign "$signing_identity" --timestamp=none \
    --entitlements "$repo_root/macos/Support/Wallstats.entitlements" \
    "$staged_app"

"$script_dir/verify-app.sh" --signed "$staged_app"
"$script_dir/atomic-replace.sh" "$staged_app" "$app_output"

echo "Built $app_output"
echo "Signing identity: $signing_identity"
echo "Runtime GC root: $runtime_link -> $runtime_store_path"
