#!/bin/bash
# Non-physical installed-candidate acceptance. Production target only.
set -uo pipefail

ACCEPT_APP="/Applications/Let It Brew.app"
ACCEPT_HOLD_PID=""
ACCEPT_HOLD_LOG=""
ACCEPT_BASELINE=""
ACCEPT_FAIL=0
ACCEPT_INCOMPLETE=0

acceptance_check() {
    local description="$1"
    shift
    if "$@"; then
        echo "ok: $description"
    else
        echo "FAIL: $description" >&2
        ACCEPT_FAIL=1
    fi
}

acceptance_require() {
    local description="$1"
    shift
    if "$@"; then
        echo "ok: $description"
    else
        echo "FATAL: $description" >&2
        ACCEPT_FAIL=1
        return 1
    fi
}

acceptance_result() {
    local failed="$1"
    local incomplete="$2"
    if [ "$failed" -ne 0 ]; then return 1; fi
    if [ "$incomplete" -ne 0 ]; then return 2; fi
    return 0
}

acceptance_stop_hold_client() {
    local waited=0
    [ -n "$ACCEPT_HOLD_PID" ] || return 0
    if /bin/kill -0 "$ACCEPT_HOLD_PID" 2>/dev/null; then
        /bin/kill -TERM "$ACCEPT_HOLD_PID" 2>/dev/null || true
        while /bin/kill -0 "$ACCEPT_HOLD_PID" 2>/dev/null && [ "$waited" -lt 3 ]; do
            /bin/sleep 1
            waited=$((waited + 1))
        done
        if /bin/kill -0 "$ACCEPT_HOLD_PID" 2>/dev/null; then
            # Only the exact command-mode hold client launched by this script.
            /bin/kill -KILL "$ACCEPT_HOLD_PID" 2>/dev/null || true
        fi
    fi
    wait "$ACCEPT_HOLD_PID" 2>/dev/null || true
    ACCEPT_HOLD_PID=""
}

acceptance_cleanup() {
    local status=$?
    trap - EXIT
    acceptance_stop_hold_client
    if [ -n "$ACCEPT_BASELINE" ]; then
        baseline_wait_for "$ACCEPT_BASELINE" 15 >/dev/null 2>&1 || {
            echo "FAIL: cleanup could not confirm restoration to SleepDisabled=$ACCEPT_BASELINE." >&2
            [ "$status" -ne 0 ] || status=1
        }
    fi
    [ -n "$ACCEPT_HOLD_LOG" ] && /bin/rm -f "$ACCEPT_HOLD_LOG"
    [ -n "${UPGRADE_WORKDIR:-}" ] && /bin/rm -rf "$UPGRADE_WORKDIR"
    exit "$status"
}

acceptance_main() {
    [ "$#" -eq 0 ] || { echo "usage: verify-installed-app.sh" >&2; return 1; }
    [ "$(/usr/bin/id -u)" -ne 0 ] || { echo "FATAL: do not run installed-app acceptance as root." >&2; return 1; }
    [ -d "$ACCEPT_APP" ] && [ ! -L "$ACCEPT_APP" ] || { echo "FATAL: production app is not installed directly at $ACCEPT_APP." >&2; return 1; }

    local script_dir app_bin daemon info version build cdhash before_count after_count
    local lid_output lid_status result
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    # shellcheck source=lib-power-baseline.sh
    source "$script_dir/lib-power-baseline.sh"
    # Reuse the exact bounded-command, process, launchd, and strict JSON gates
    # used by the installer. Sourcing never executes its production main.
    # shellcheck source=upgrade-installed-app.sh
    source "$script_dir/upgrade-installed-app.sh"
    UPGRADE_SCRIPT_DIR="$script_dir"
    UPGRADE_WORKDIR="$(/usr/bin/mktemp -d /private/tmp/letitbrew-acceptance.XXXXXX)" || return 1
    UPGRADE_TIMEOUT=20
    trap acceptance_cleanup EXIT
    trap 'exit 130' INT TERM HUP

    app_bin="$ACCEPT_APP/Contents/MacOS/LetItBrew"
    daemon="$ACCEPT_APP/Contents/Library/LaunchServices/LetItBrewDaemon"
    info="$ACCEPT_APP/Contents/Info.plist"
    [ -x "$app_bin" ] && [ -x "$daemon" ] || { echo "FATAL: installed executables are missing." >&2; return 1; }

    "$script_dir/verify-artifact.sh" "$ACCEPT_APP" || return 1
    version="$(upgrade_plist_value "$info" CFBundleShortVersionString)" || return 1
    build="$(upgrade_plist_value "$info" CFBundleVersion)" || return 1
    cdhash="$(upgrade_native_cdhash "$daemon")"
    [ -n "$cdhash" ] || { echo "FATAL: installed daemon has no native CDHash." >&2; return 1; }
    ACCEPT_BASELINE="$(baseline_read_sleepdisabled)" || return 1

    echo "== Installed-app verification: $ACCEPT_APP =="
    echo "candidate: $version ($build), native daemon CDHash $cdhash"
    echo "SleepDisabled baseline: $ACCEPT_BASELINE"

    before_count="$(upgrade_process_count_for_path LetItBrew "$app_bin")"
    acceptance_require "exactly one ordinary Let It Brew process before testing" test "$before_count" -eq 1 || return 1
    acceptance_require "exactly one current launch daemon" upgrade_wait_service_current "$daemon" "$build" || return 1

    echo
    echo "-- authenticated identity-aware XPC probe --"
    acceptance_require "probe matches installed daemon CDHash/version/build" \
        upgrade_probe_new_strict "$app_bin" "$version" "$build" "$cdhash" || return 1
    acceptance_require "probe leaves only the original app process" \
        test "$(upgrade_process_count_for_path LetItBrew "$app_bin")" -eq "$before_count" || return 1
    acceptance_require "probe preserves exact baseline" \
        baseline_assert "$ACCEPT_BASELINE" "post-probe" || return 1

    echo
    echo "-- diagnostic scene isolation --"
    UPGRADE_COMMAND_COUNTER=$((UPGRADE_COMMAND_COUNTER + 1))
    lid_output="$UPGRADE_WORKDIR/lid-probe-$UPGRADE_COMMAND_COUNTER.log"
    upgrade_run_bounded "$UPGRADE_TIMEOUT" "$lid_output" "$app_bin" --probe-lid-display
    lid_status=$?
    /bin/cat "$lid_output"
    acceptance_require "probe-lid-display exits 0" test "$lid_status" -eq 0 || return 1
    acceptance_require "probe-lid-display reports clamshell state" /usr/bin/grep -q '^Clamshell:' "$lid_output" || return 1
    acceptance_require "probe-lid-display reports display topology" /usr/bin/grep -q '^Active displays:' "$lid_output" || return 1
    acceptance_require "diagnostic leaves only the original app process" \
        test "$(upgrade_process_count_for_path LetItBrew "$app_bin")" -eq "$before_count" || return 1
    acceptance_require "diagnostic preserves exact baseline" \
        baseline_assert "$ACCEPT_BASELINE" "post-lid-probe" || return 1

    echo
    echo "-- hold/release lifecycle --"
    if [ "$ACCEPT_BASELINE" != 0 ]; then
        echo "INCOMPLETE: SleepDisabled began at $ACCEPT_BASELINE, so a 0 -> 1 -> 0 hold transition is not observable."
        echo "All non-mutating checks continue, but this run will exit 2 and cannot be accepted as a full pass."
        ACCEPT_INCOMPLETE=1
    else
        ACCEPT_HOLD_LOG="$UPGRADE_WORKDIR/hold-client.log"
        "$app_bin" --hold-daemon >"$ACCEPT_HOLD_LOG" 2>&1 &
        ACCEPT_HOLD_PID=$!
        if baseline_wait_for 1 15; then
            echo "ok: command client engaged SleepDisabled 0 -> 1"
        else
            ACCEPT_FAIL=1
        fi
        /bin/cat "$ACCEPT_HOLD_LOG"
        acceptance_check "hold client remains alive while engaged" /bin/kill -0 "$ACCEPT_HOLD_PID"
        acceptance_stop_hold_client
        acceptance_check "disconnect restores exact baseline" baseline_wait_for "$ACCEPT_BASELINE" 15
    fi

    echo
    after_count="$(upgrade_process_count_for_path LetItBrew "$app_bin")"
    acceptance_check "process count returns exactly to $before_count" test "$after_count" -eq "$before_count"
    acceptance_check "one current daemon remains" upgrade_wait_service_current "$daemon" "$build"
    acceptance_check "final SleepDisabled matches exact baseline" baseline_assert "$ACCEPT_BASELINE" final

    echo
    echo "=================================="
    acceptance_result "$ACCEPT_FAIL" "$ACCEPT_INCOMPLETE"
    result=$?
    case "$result" in
        0) echo "PASS: installed-candidate verification" ;;
        1) echo "FAIL: one or more acceptance gates failed" >&2 ;;
        2) echo "INCOMPLETE: observable hold/release evidence was not obtained" >&2 ;;
    esac
    return "$result"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    acceptance_main "$@"
    exit $?
fi
