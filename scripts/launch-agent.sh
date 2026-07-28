#!/bin/bash
set -euo pipefail

if [[ -z "${HOME:-}" ]]; then
    echo "launch-agent: HOME must be set" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
label=com.memorici.wallstats
expected_app="$HOME/Applications/Wallstats.app"
expected_executable="$expected_app/Contents/MacOS/Wallstats"
launch_agents_dir="$HOME/Library/LaunchAgents"
logs_dir="$HOME/Library/Logs"
plist_path="$launch_agents_dir/$label.plist"
stdout_path="$logs_dir/wallstats.out.log"
stderr_path="$logs_dir/wallstats.err.log"
user_id="$(/usr/bin/id -u)"
domain="gui/$user_id"
service="$domain/$label"

fail() {
    echo "launch-agent: $*" >&2
    exit 1
}

plist_value() {
    /usr/bin/plutil -extract "$2" raw -o - "$1"
}

render_plist() {
    local output=$1

    /usr/bin/plutil -create xml1 "$output"
    /usr/bin/plutil -insert Label -string "$label" "$output"
    /usr/bin/plutil -insert Program -string "$expected_executable" "$output"
    /usr/bin/plutil -insert ProgramArguments -array "$output"
    /usr/bin/plutil -insert ProgramArguments.0 -string "$expected_executable" "$output"
    /usr/bin/plutil -insert RunAtLoad -bool true "$output"
    /usr/bin/plutil -insert KeepAlive -bool true "$output"
    /usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$output"
    /usr/bin/plutil -insert ProcessType -string Interactive "$output"
    /usr/bin/plutil -insert ThrottleInterval -integer 10 "$output"
    /usr/bin/plutil -insert StandardOutPath -string "$stdout_path" "$output"
    /usr/bin/plutil -insert StandardErrorPath -string "$stderr_path" "$output"
    /usr/bin/plutil -convert xml1 "$output"
    /usr/bin/plutil -lint "$output" >/dev/null
}

validate_plist() {
    local candidate=$1

    /usr/bin/plutil -lint "$candidate" >/dev/null
    [[ "$(plist_value "$candidate" Label)" == "$label" ]] || fail "wrong Label"
    [[ "$(plist_value "$candidate" Program)" == "$expected_executable" ]] \
        || fail "wrong Program path"
    [[ "$(plist_value "$candidate" ProgramArguments)" == 1 ]] \
        || fail "ProgramArguments must contain exactly one value"
    [[ "$(plist_value "$candidate" ProgramArguments.0)" == "$expected_executable" ]] \
        || fail "wrong ProgramArguments executable"
    [[ "$(plist_value "$candidate" RunAtLoad)" == true ]] || fail "RunAtLoad must be true"
    [[ "$(plist_value "$candidate" KeepAlive)" == true ]] || fail "KeepAlive must be true"
    [[ "$(plist_value "$candidate" LimitLoadToSessionType)" == Aqua ]] \
        || fail "LimitLoadToSessionType must be Aqua"
    [[ "$(plist_value "$candidate" ProcessType)" == Interactive ]] \
        || fail "ProcessType must be Interactive"
    [[ "$(plist_value "$candidate" ThrottleInterval)" == 10 ]] \
        || fail "ThrottleInterval must be 10"
    [[ "$(plist_value "$candidate" StandardOutPath)" == "$stdout_path" ]] \
        || fail "wrong stdout log path"
    [[ "$(plist_value "$candidate" StandardErrorPath)" == "$stderr_path" ]] \
        || fail "wrong stderr log path"
}

bootout_service() {
    if /bin/launchctl print "$service" >/dev/null 2>&1; then
        /bin/launchctl bootout "$service"
        for _ in {1..50}; do
            if ! /bin/launchctl print "$service" >/dev/null 2>&1; then
                return
            fi
            /bin/sleep 0.2
        done
        fail "service remained loaded after bootout: $service"
    fi
}

install_plist() {
    /bin/mkdir -p "$launch_agents_dir" "$logs_dir"
    local temporary_plist
    temporary_plist="$(/usr/bin/mktemp "$launch_agents_dir/.$label.plist.XXXXXX")"
    cleanup_plist() {
        /bin/rm -f "$temporary_plist"
    }
    trap cleanup_plist EXIT HUP INT TERM

    render_plist "$temporary_plist"
    validate_plist "$temporary_plist"
    /bin/chmod 644 "$temporary_plist"
    "$script_dir/atomic-replace.sh" "$temporary_plist" "$plist_path"

    trap - EXIT HUP INT TERM
    validate_plist "$plist_path"
}

running_wallstats_pids() {
    /usr/bin/pgrep -u "$user_id" -x Wallstats 2>/dev/null || true
}

process_path() {
    local process_id=$1
    local path
    path="$(/bin/ps -p "$process_id" -o comm=)"
    path="${path#"${path%%[![:space:]]*}"}"
    printf '%s\n' "$path"
}

verify_service() {
    local service_output process_ids service_pid path

    for _ in {1..50}; do
        service_output="$(/bin/launchctl print "$service" 2>/dev/null || true)"
        service_pid="$(printf '%s\n' "$service_output" \
            | /usr/bin/awk '$1 == "pid" && $2 == "=" { print $3; exit }')"
        process_ids=()
        while IFS= read -r process_id; do
            [[ -n "$process_id" ]] && process_ids+=("$process_id")
        done < <(running_wallstats_pids)

        if [[ "$service_output" == *"state = running"* \
            && "$service_output" == *"$expected_executable"* \
            && ${#process_ids[@]} -eq 1 \
            && "${process_ids[0]}" == "$service_pid" ]]; then
            path="$(process_path "$service_pid")"
            if [[ "$path" == "$expected_executable" ]]; then
                echo "LaunchAgent $label running as PID $service_pid: $path"
                return
            fi
        fi
        /bin/sleep 0.2
    done

    /bin/launchctl print "$service" >&2 || true
    for process_id in $(running_wallstats_pids); do
        echo "launch-agent: Wallstats PID $process_id: $(process_path "$process_id")" >&2
    done
    fail "expected exactly one running Wallstats process at $expected_executable"
}

bootstrap_service() {
    [[ -x "$expected_executable" ]] || fail "app executable is missing: $expected_executable"
    [[ -f "$plist_path" ]] || fail "LaunchAgent plist is missing: $plist_path"
    validate_plist "$plist_path"
    /bin/launchctl bootstrap "$domain" "$plist_path"
    /bin/launchctl kickstart -k "$service"
    verify_service
}

action=${1:-}
case "$action" in
    render)
        [[ $# -eq 2 ]] || fail "usage: $0 render OUTPUT"
        render_plist "$2"
        ;;
    validate)
        [[ $# -eq 2 ]] || fail "usage: $0 validate PLIST"
        validate_plist "$2"
        echo "Validated LaunchAgent plist: $2"
        ;;
    bootout)
        [[ $# -eq 1 ]] || fail "usage: $0 bootout"
        bootout_service
        ;;
    install)
        [[ $# -eq 1 ]] || fail "usage: $0 install"
        install_plist
        echo "Installed LaunchAgent plist: $plist_path"
        ;;
    bootstrap)
        [[ $# -eq 1 ]] || fail "usage: $0 bootstrap"
        bootstrap_service
        ;;
    verify)
        [[ $# -eq 1 ]] || fail "usage: $0 verify"
        verify_service
        ;;
    *)
        echo "usage: $0 {render OUTPUT|validate PLIST|bootout|install|bootstrap|verify}" >&2
        exit 64
        ;;
esac
