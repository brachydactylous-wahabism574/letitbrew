#!/bin/bash
# Verifies that the pressure wrapper rejects an unsafe mktemp result before
# constructing cache paths or invoking Swift.
set -euo pipefail

TARGET="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-session-pressure.sh}"
HARNESS_ROOT="$(/usr/bin/mktemp -d /private/tmp/letitbrew-pressure-guard.XXXXXX)"
trap '/bin/rm -rf "$HARNESS_ROOT"' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAKE_BIN="$SCRIPT_DIR/fixtures/pressure-guard-bin"
export PRESSURE_GUARD_HARNESS_ROOT="$HARNESS_ROOT"

set +e
output="$(PATH="$FAKE_BIN:/usr/bin:/bin" /bin/bash "$TARGET" 2>&1)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
    echo "FAIL: unsafe test root was accepted" >&2
    exit 1
fi
if [ -e "$HARNESS_ROOT/swift-was-called" ]; then
    echo "FAIL: Swift ran after unsafe test root" >&2
    exit 1
fi
if [ -e "$HARNESS_ROOT/unsafe-root" ]; then
    echo "FAIL: cache paths were constructed below unsafe test root" >&2
    exit 1
fi
case "$output" in
    *"FATAL: unsafe session-pressure test root:"*) ;;
    *)
        echo "FAIL: wrapper did not explain unsafe test root" >&2
        exit 1
        ;;
esac

echo "PASS: pressure wrapper rejects unsafe setup before side effects"
