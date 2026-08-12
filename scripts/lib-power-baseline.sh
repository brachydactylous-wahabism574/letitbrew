# Shared helpers for capturing and verifying the pre-existing `disablesleep`
# (`SleepDisabled`) value around live power operations. Sourced, not executed.
#
# The parser is deliberately three-way: exactly one canonical 0/1 value is
# accepted; missing, duplicated, conflicting, malformed, and unreadable output
# are refusals. Callers must check every nonzero return.

baseline_parse_sleepdisabled() {
    /usr/bin/awk '
        $1 == "SleepDisabled" {
            count += 1
            if (NF != 2 || ($2 != "0" && $2 != "1")) invalid = 1
            value = $2
        }
        END {
            if (count == 1 && invalid == 0) {
                print value
                exit 0
            }
            exit 1
        }
    '
}

baseline_read_sleepdisabled() {
    local output value
    if ! output="$(/usr/bin/pmset -g 2>/dev/null)"; then
        echo "FATAL: pmset -g failed; refusing to infer SleepDisabled." >&2
        return 1
    fi
    if ! value="$(printf '%s\n' "$output" | baseline_parse_sleepdisabled)"; then
        echo "FATAL: pmset -g did not contain exactly one canonical SleepDisabled 0/1 value." >&2
        return 1
    fi
    printf '%s\n' "$value"
}

# Polls until SleepDisabled equals $1, or returns nonzero after $2 seconds.
# An unreadable value stops immediately instead of consuming the timeout.
baseline_wait_for() {
    local expected="$1"
    local timeout="${2:-15}"
    local waited=0
    local actual

    case "$expected" in
        0|1) ;;
        *)
            echo "FATAL: invalid expected SleepDisabled value '$expected'." >&2
            return 1
            ;;
    esac
    case "$timeout" in
        ''|*[!0-9]*)
            echo "FATAL: invalid SleepDisabled timeout '$timeout'." >&2
            return 1
            ;;
    esac

    while :; do
        actual="$(baseline_read_sleepdisabled)" || return 1
        [ "$actual" = "$expected" ] && return 0
        if [ "$waited" -ge "$timeout" ]; then
            echo "FAIL: timed out after ${timeout}s waiting for SleepDisabled=$expected (still $actual)." >&2
            return 1
        fi
        /bin/sleep 1
        waited=$((waited + 1))
    done
}

baseline_assert() {
    local expected="$1"
    local label="${2:-baseline}"
    local actual

    case "$expected" in
        0|1) ;;
        *)
            echo "FATAL: invalid expected SleepDisabled value '$expected'." >&2
            return 1
            ;;
    esac
    actual="$(baseline_read_sleepdisabled)" || return 1
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: $label — SleepDisabled is $actual, expected $expected." >&2
        echo "Recovery requires an explicit, evidence-backed restore to $expected; this script will not guess." >&2
        return 1
    fi
    echo "ok: $label — SleepDisabled=$actual"
}
