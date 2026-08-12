#!/bin/bash
# Hook install / repair / uninstall must never damage configuration
# Let It Brew did not write.
#
# Runs the real signed CLI against a throwaway LETITBREW_TEST_HOME, so the
# user's live ~/.claude/settings.json and ~/.codex/hooks.json are never
# touched. Asserts the user's own config survives every operation
# semantically, and that none of it moves the system power setting.
#
# Usage: scripts/test-hook-safety.sh ["/Applications/Let It Brew Dev.app/Contents/Helpers/letitbrew"]
set -uo pipefail

CLI="${1:-/Applications/Let It Brew Dev.app/Contents/Helpers/letitbrew}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-power-baseline.sh
source "$SCRIPT_DIR/lib-power-baseline.sh"

[ -x "$CLI" ] || { echo "FATAL: $CLI not found or not executable." >&2; exit 1; }

fail=0
check() {
    local desc="$1"
    shift
    if "$@"; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc" >&2
        fail=1
    fi
}

TEST_HOME="$(mktemp -d /tmp/letitbrew-hooks-test.XXXXXX)"
trap 'rm -rf "$TEST_HOME"' EXIT
export LETITBREW_TEST_HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.codex"

echo "== Hook and config preservation =="
echo "CLI:       $CLI"
echo "test home: $TEST_HOME"

BASELINE="$(baseline_read_sleepdisabled)"
echo "SleepDisabled baseline: $BASELINE"

# The user's own configuration: unrelated hooks plus settings Let It Brew must
# never model, let alone drop on a round trip.
cat >"$TEST_HOME/.claude/settings.json" <<'JSON'
{
  "model": "claude-opus-5",
  "theme": "dark",
  "permissions": { "allow": ["Bash(git status)"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "/usr/local/bin/my-own-hook" } ] }
    ],
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "echo mine" } ] }
    ]
  }
}
JSON
cat >"$TEST_HOME/.codex/hooks.json" <<'JSON'
{
  "description": "my own codex hooks",
  "hooks": {
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "/usr/local/bin/my-codex-hook" } ] }
    ]
  }
}
JSON
cp "$TEST_HOME/.claude/settings.json" "$TEST_HOME/claude-before.json"
cp "$TEST_HOME/.codex/hooks.json" "$TEST_HOME/codex-before.json"

# Claude and Codex carry deliberately DIFFERENT ownership markers, so that
# removing one integration can never strip the other's entries. Both must be
# recognized here — matching only Claude's makes every Codex assertion pass
# vacuously against zero entries.
# Compares two config files ignoring Let It Brew-owned hook entries and
# formatting. Anything else that differs is damage to the user's file.
compare_ignoring_letitbrew() {
    python3 - "$1" "$2" <<'PY'
import json, sys

MARKERS = ("__letitbrew_hook", "__letitbrew_codex_hook")

def owned(h):
    return isinstance(h, dict) and any(m in h.get("command", "") for m in MARKERS)

def strip(doc):
    doc = json.loads(json.dumps(doc))
    hooks = doc.get("hooks", {})
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        kept = [
            g for g in groups
            if not any(owned(h) for h in g.get("hooks", []))
        ]
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if "hooks" in doc and not doc["hooks"]:
        del doc["hooks"]
    return doc

a = strip(json.load(open(sys.argv[1])))
b = strip(json.load(open(sys.argv[2])))
sys.exit(0 if a == b else 1)
PY
}

letitbrew_entry_count() {
    python3 - "$1" <<'PY'
import json, sys
MARKERS = ("__letitbrew_hook", "__letitbrew_codex_hook")
doc = json.load(open(sys.argv[1]))
n = sum(
    1
    for groups in doc.get("hooks", {}).values() if isinstance(groups, list)
    for g in groups
    for h in g.get("hooks", [])
    if isinstance(h, dict) and any(m in h.get("command", "") for m in MARKERS)
)
print(n)
PY
}

echo
echo "-- install --"
"$CLI" install >/dev/null 2>&1
check "install exits 0" [ $? -eq 0 ]
check "Claude: unrelated user config preserved" \
    compare_ignoring_letitbrew "$TEST_HOME/claude-before.json" "$TEST_HOME/.claude/settings.json"
check "Codex: unrelated user config preserved" \
    compare_ignoring_letitbrew "$TEST_HOME/codex-before.json" "$TEST_HOME/.codex/hooks.json"
claude_installed="$(letitbrew_entry_count "$TEST_HOME/.claude/settings.json")"
codex_installed="$(letitbrew_entry_count "$TEST_HOME/.codex/hooks.json")"
echo "Let It Brew entries — Claude: $claude_installed, Codex: $codex_installed"
check "Claude gained Let It Brew hook entries" [ "$claude_installed" -gt 0 ]
check "Codex gained Let It Brew hook entries" [ "$codex_installed" -gt 0 ]

echo
echo "-- doctor reports healthy --"
doctor_out="$("$CLI" doctor 2>&1)"
echo "$doctor_out"
check "doctor reports Claude healthy" grep -q "Claude Code: healthy" <<<"$doctor_out"
check "doctor reports Codex healthy" grep -q "Codex: healthy" <<<"$doctor_out"

echo
echo "-- reinstall is idempotent --"
"$CLI" install >/dev/null 2>&1
check "Claude entry count unchanged after reinstall" \
    [ "$(letitbrew_entry_count "$TEST_HOME/.claude/settings.json")" -eq "$claude_installed" ]
check "Codex entry count unchanged after reinstall" \
    [ "$(letitbrew_entry_count "$TEST_HOME/.codex/hooks.json")" -eq "$codex_installed" ]

echo
echo "-- repair: damage ONLY Let It Brew's entry --"
python3 - "$TEST_HOME/.claude/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
# Drop Let It Brew's PreToolUse entry, leaving the user's alongside it.
groups = doc["hooks"].get("PreToolUse", [])
doc["hooks"]["PreToolUse"] = [
    g for g in groups
    if not any("__letitbrew_hook" in h.get("command", "") for h in g.get("hooks", []))
]
json.dump(doc, open(path, "w"), indent=2)
PY
damaged_out="$("$CLI" doctor 2>&1)"
check "doctor detects the damaged install" grep -qE "needs repair|missing" <<<"$damaged_out"
"$CLI" install >/dev/null 2>&1
repaired_out="$("$CLI" doctor 2>&1)"
check "install repairs it back to healthy" grep -q "Claude Code: healthy" <<<"$repaired_out"
check "repair did not disturb unrelated user config" \
    compare_ignoring_letitbrew "$TEST_HOME/claude-before.json" "$TEST_HOME/.claude/settings.json"

echo
echo "-- uninstall removes only Let It Brew's entries --"
"$CLI" uninstall >/dev/null 2>&1
check "uninstall exits 0" [ $? -eq 0 ]
check "Claude: no Let It Brew entries remain" \
    [ "$(letitbrew_entry_count "$TEST_HOME/.claude/settings.json")" -eq 0 ]
check "Codex: no Let It Brew entries remain" \
    [ "$(letitbrew_entry_count "$TEST_HOME/.codex/hooks.json")" -eq 0 ]
check "Claude: user config still intact after uninstall" \
    compare_ignoring_letitbrew "$TEST_HOME/claude-before.json" "$TEST_HOME/.claude/settings.json"
check "Codex: user config still intact after uninstall" \
    compare_ignoring_letitbrew "$TEST_HOME/codex-before.json" "$TEST_HOME/.codex/hooks.json"

echo
echo "-- uninstall is idempotent --"
"$CLI" uninstall >/dev/null 2>&1
check "second uninstall exits 0" [ $? -eq 0 ]
check "Claude: still intact" \
    compare_ignoring_letitbrew "$TEST_HOME/claude-before.json" "$TEST_HOME/.claude/settings.json"

echo
echo "-- hook operations never move the power setting --"
check "SleepDisabled unchanged across all hook operations" baseline_assert "$BASELINE" "post-hook-operations"

echo
echo "=================================="
if [ "$fail" -eq 0 ]; then
    echo "PASS: hook/config preservation checks"
else
    echo "FAIL: one or more hook/config checks failed — see above" >&2
fi
exit "$fail"
