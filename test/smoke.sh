#!/usr/bin/env bash
# Smoke test for tui-driver. Uses throwaway --session names only, so it is
# safe to run while real sessions are active. Requires: tmux, python3.
#
#   ./test/smoke.sh            # test the repo script
#   TD=tui-driver ./test/smoke.sh   # test an installed copy
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TD="${TD:-${HERE}/../tui-driver.sh}"
STATE_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}/tui-driver"
RUN_ID="smoke-$$"
TMPDIR_T="$(mktemp -d)"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { # check <description> <condition...>
    local desc="$1"; shift
    if "$@"; then ok "$desc"; else fail "$desc"; fi
}

cleanup() {
    local s
    for s in pong delay spin dialog until pfx10 pfx1; do
        $TD -q --session "${RUN_ID}-${s}" true stop >/dev/null 2>&1 || true
    done
    rm -rf "$TMPDIR_T"
}
trap cleanup EXIT

# Helper TUIs. NOTE: none of them may echo the prompt back as the whole
# response — the prompt is the extraction anchor, so a pure-echo TUI (cat)
# has an empty response by definition and trips the non-empty guard.
# -----------------------------------------------------------------------------
cat > "$TMPDIR_T/pong-tui.sh" <<'EOF'
#!/usr/bin/env bash
while read -r x; do echo "pong-response"; done
EOF
cat > "$TMPDIR_T/delay-tui.sh" <<'EOF'
#!/usr/bin/env bash
while read -r x; do sleep 6; echo "late-reply"; done
EOF
cat > "$TMPDIR_T/spin-tui.sh" <<'EOF'
#!/usr/bin/env bash
read -r x
while true; do date; sleep 0.4; done
EOF
cat > "$TMPDIR_T/dialog-tui.sh" <<'EOF'
#!/usr/bin/env bash
read -r q
echo "Approve fetch? [y/n]"
read -r a
sleep 1
echo "final-answer-42"
read -r _
EOF
cat > "$TMPDIR_T/until-tui.sh" <<'EOF'
#!/usr/bin/env bash
read -r x
echo "answer-part"
echo "DONEZZZ"
while true; do date; sleep 1; done
EOF
chmod +x "$TMPDIR_T"/*.sh

# 1. Errors visible under -q, distinct exit codes ------------------------------
errmsg=$($TD -q --session "${RUN_ID}-none" cat poll 2>&1 >/dev/null); rc=$?
check "poll with no session exits 1"            [ "$rc" -eq 1 ]
check "error message shown despite -q"          [ -n "$errmsg" ]

# 2. Basic send: fast (no first-send throttle), correct text -------------------
S="${RUN_ID}-pong"
PONG="$TMPDIR_T/pong-tui.sh"
$TD -q --session "$S" "$PONG" start >/dev/null 2>&1 || fail "pong start"
t0=$(date +%s)
out=$($TD -q --session "$S" "$PONG" send "hello smoke test" 2>/dev/null); rc=$?
t1=$(date +%s)
check "send exits 0"                            [ "$rc" -eq 0 ]
check "send under 9s (throttle-skip)"           [ $((t1 - t0)) -lt 9 ]
check "response captured"                       grep -q "pong-response" <<<"$out"
check "state files in STATE_DIR"                ls "$STATE_DIR/${S}.stamp" >/dev/null 2>&1

# 3. Async: poll retrieves and clears; second poll errors ----------------------
$TD -q --session "$S" "$PONG" send-async "async question" >/dev/null 2>&1
sleep 5
out=$($TD -q --session "$S" "$PONG" poll 2>/dev/null); rc=$?
check "poll returns response (exit 0)"          [ "$rc" -eq 0 ]
check "poll response correct"                   grep -q "pong-response" <<<"$out"
$TD -q --session "$S" "$PONG" poll >/dev/null 2>&1; rc=$?
check "second poll: no pending (exit 1)"        [ "$rc" -eq 1 ]

# 4. progress: read-only, does not consume ------------------------------------
$TD -q --session "$S" "$PONG" send-async "progress probe" >/dev/null 2>&1
out=$($TD -q --session "$S" "$PONG" progress 2>/dev/null); rc=$?
check "progress exits 0 while pending"          [ "$rc" -eq 0 ]
check "progress reports pending=yes"            grep -q "pending=yes" <<<"$out"
check "progress kept the query pending"        ls "$STATE_DIR/${S}.async" >/dev/null 2>&1
$TD -q --session "$S" "$PONG" poll --wait >/dev/null 2>&1
$TD -q --session "$S" "$PONG" stop >/dev/null 2>&1
$TD -q --session "$S" "$PONG" progress >/dev/null 2>&1; rc=$?
check "progress after stop exits 1"             [ "$rc" -eq 1 ]

# 5. Non-empty guard: silent-then-late TUI is not returned empty ---------------
S="${RUN_ID}-delay"
$TD -q --session "$S" "$TMPDIR_T/delay-tui.sh" start >/dev/null 2>&1
out=$($TD -q --session "$S" "$TMPDIR_T/delay-tui.sh" send "go" 2>/dev/null); rc=$?
check "delayed response captured (exit 0)"      [ "$rc" -eq 0 ]
check "delayed response non-empty"              grep -q "late-reply" <<<"$out"
$TD -q --session "$S" "$TMPDIR_T/delay-tui.sh" stop >/dev/null 2>&1

# 6. Timeout keeps the query pending; cancel clears it -------------------------
S="${RUN_ID}-spin"
$TD -q --session "$S" "$TMPDIR_T/spin-tui.sh" start >/dev/null 2>&1
$TD -q --session "$S" "$TMPDIR_T/spin-tui.sh" send-async "spin" >/dev/null 2>&1
TUI_TIMEOUT=5 $TD -q --session "$S" "$TMPDIR_T/spin-tui.sh" poll --wait >/dev/null 2>&1; rc=$?
check "poll --wait timeout exits 3"             [ "$rc" -eq 3 ]
check "timeout kept .async"                     ls "$STATE_DIR/${S}.async" >/dev/null 2>&1
$TD -q --session "$S" "$TMPDIR_T/spin-tui.sh" send-async "x" >/dev/null 2>&1; rc=$?
check "send-async while pending exits 1"        [ "$rc" -eq 1 ]
$TD -q --session "$S" "$TMPDIR_T/spin-tui.sh" cancel >/dev/null 2>&1
check "cancel cleared .async"                   bash -c "! ls '$STATE_DIR/${S}.async' >/dev/null 2>&1"
$TD -q --session "$S" "$TMPDIR_T/spin-tui.sh" stop >/dev/null 2>&1

# 7. respond --async re-arms the poll flow -------------------------------------
S="${RUN_ID}-dialog"
$TD -q --session "$S" "$TMPDIR_T/dialog-tui.sh" start >/dev/null 2>&1
$TD -q --session "$S" "$TMPDIR_T/dialog-tui.sh" send-async "six times seven" >/dev/null 2>&1
sleep 5
out=$($TD -q --session "$S" "$TMPDIR_T/dialog-tui.sh" poll 2>/dev/null)
check "dialog text retrieved by poll"           grep -q "Approve fetch" <<<"$out"
$TD -q --session "$S" "$TMPDIR_T/dialog-tui.sh" respond --async "y" >/dev/null 2>&1; rc=$?
check "respond --async exits 0"                 [ "$rc" -eq 0 ]
out=$($TD -q --session "$S" "$TMPDIR_T/dialog-tui.sh" poll --wait 2>/dev/null); rc=$?
check "poll after respond --async exits 0"      [ "$rc" -eq 0 ]
check "final answer retrieved"                  grep -q "final-answer-42" <<<"$out"
$TD -q --session "$S" "$TMPDIR_T/dialog-tui.sh" stop >/dev/null 2>&1

# 8. --until returns on a never-stable screen ----------------------------------
S="${RUN_ID}-until"
$TD -q --session "$S" "$TMPDIR_T/until-tui.sh" start >/dev/null 2>&1
out=$(TUI_TIMEOUT=20 $TD -q --until 'DONEZZZ' --session "$S" "$TMPDIR_T/until-tui.sh" send "go" 2>/dev/null); rc=$?
check "--until exits 0 on marker"               [ "$rc" -eq 0 ]
check "--until response contains answer"        grep -q "answer-part" <<<"$out"
$TD -q --session "$S" "$TMPDIR_T/until-tui.sh" stop >/dev/null 2>&1

# 9. Exact session targets: "p1" must not resolve to a running "p10" ----------
S="${RUN_ID}-pfx10"
$TD -q --session "$S" "$PONG" start >/dev/null 2>&1
out=$($TD -q --session "${RUN_ID}-pfx1" "$PONG" status 2>/dev/null)
check "prefix name reports stopped"             [ "$out" = "stopped" ]
$TD -q --session "${RUN_ID}-pfx1" "$PONG" send-async "wrong session" >/dev/null 2>&1; rc=$?
check "send-async to prefix name exits 1"       [ "$rc" -eq 1 ]
$TD -q --session "${RUN_ID}-pfx1" "$PONG" stop >/dev/null 2>&1
out=$($TD -q --session "$S" "$PONG" status 2>/dev/null)
check "stop on prefix name spared the other"    [ "$out" = "running" ]
$TD -q --session "$S" "$PONG" stop >/dev/null 2>&1

# 10. stop cleans state; shellcheck -------------------------------------------
check "no state files left for this run"        bash -c "! ls '$STATE_DIR'/${RUN_ID}-* >/dev/null 2>&1"
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck clean"                    shellcheck -S style "$TD"
else
    echo "skip - shellcheck not installed"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
