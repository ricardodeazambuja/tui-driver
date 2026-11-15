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
    for s in pong delay spin dialog until pfx10 pfx1 miss once norm menu multi noecho \
             ovl ovloff static alt short; do
        $TD -q --session "${RUN_ID}-${s}" true stop >/dev/null 2>&1 || true
    done
    $TD -q --dir "$TMPDIR_T/dflt" "$TMPDIR_T/pong-tui.sh" stop >/dev/null 2>&1 || true
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
cat > "$TMPDIR_T/menu-tui.sh" <<'EOF'
#!/usr/bin/env bash
# A menu that acts on a single keypress, like claude/agy approvals.
read -r q
echo "Proceed? 1. Yes  4. No"
read -rsn1 k
case "$k" in 1) echo "menu-approved";; 4) echo "menu-denied";; *) echo "menu-other";; esac
read -r rest; echo "line-after-menu:${rest}"
read -r _
EOF
cat > "$TMPDIR_T/multi-tui.sh" <<'EOF'
#!/usr/bin/env bash
# Reads a whole multi-line paste (lines arrive together), then answers once.
while read -r first; do
    while read -r -t 1 _; do :; done
    echo "multi-answer"
done
EOF
cat > "$TMPDIR_T/noecho-tui.sh" <<'EOF'
#!/usr/bin/env bash
# Never echoes input, like a prompt swallowed by a dialog.
stty -echo
while read -r x; do echo "noecho-answer"; done
EOF
cat > "$TMPDIR_T/once-tui.sh" <<'EOF'
#!/usr/bin/env bash
read -r x; echo "bye-from-once"; exit 0
EOF
cat > "$TMPDIR_T/until-tui.sh" <<'EOF'
#!/usr/bin/env bash
read -r x
echo "answer-part"
echo "DONEZZZ"
while true; do date; sleep 1; done
EOF
cat > "$TMPDIR_T/agy-overlay-tui.sh" <<'EOF2'
#!/usr/bin/env bash
# Two startup notices over the input, like agy's: each swallows every key
# until Escape; the second shows only after the first is dismissed. Named
# agy-* so the built-in agy dismiss pattern applies.
for n in 1 2; do
    echo "Notice $n: something new  esc to dismiss"
    while IFS= read -rsn1 k; do [ "$k" = $'\e' ] && break; done
    clear
done
while read -r x; do echo "overlay-answer"; done
EOF2
cat > "$TMPDIR_T/static-tui.sh" <<'EOF2'
#!/usr/bin/env bash
# A long tool call: one static line for much longer than TUI_STABLE*TUI_POLL.
read -r x
echo "working..."
sleep 12
echo "answer-static"
echo "DONEZZZ"
read -r _
EOF2
cat > "$TMPDIR_T/alt-tui.sh" <<'EOF2'
#!/usr/bin/env bash
# Echoes the prompt, then answers on the alternate screen, where the echo is
# gone: a delivered prompt that later scrolls away is not an error.
while read -r x; do sleep 2; tput smcup; clear; echo "alt-answer"; done
EOF2
cat > "$TMPDIR_T/short-tui.sh" <<'EOF2'
#!/usr/bin/env bash
# A help overlay with many lines that contain a short prompt ("hi") as a
# substring; it is replaced by the alternate screen once a line arrives, so
# the screen holds FEWER needle lines after delivery than before.
for k in "shift+tab  cycle mode" "shift+up  history" "shift+down  history" "shift+click  select"; do
    echo "$k"
done
read -r x
tput smcup; clear; echo "> $x"; echo "short-answer"
read -r _
EOF2
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
check "state files in STATE_DIR"                [ -e "$STATE_DIR/${S}.stamp" ]

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
check "progress kept the query pending"        [ -e "$STATE_DIR/${S}.async" ]
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
# A bare poll right after send-async must not mistake "not started yet"
# (stable, empty) for an empty answer.
$TD -q --session "$S" "$TMPDIR_T/delay-tui.sh" send-async "go again" >/dev/null 2>&1
out=$($TD -q --session "$S" "$TMPDIR_T/delay-tui.sh" poll 2>/dev/null); rc=$?
check "bare poll before any output exits 2"     [ "$rc" -eq 2 ]
check "  and keeps the query pending"           [ -e "$STATE_DIR/${S}.async" ]
out=$($TD -q --session "$S" "$TMPDIR_T/delay-tui.sh" poll --wait 2>/dev/null)
check "  poll --wait then gets the answer"      grep -q "late-reply" <<<"$out"
$TD -q --session "$S" "$TMPDIR_T/delay-tui.sh" stop >/dev/null 2>&1

# 6. Timeout keeps the query pending; cancel clears it -------------------------
S="${RUN_ID}-spin"
$TD -q --session "$S" "$TMPDIR_T/spin-tui.sh" start >/dev/null 2>&1
$TD -q --session "$S" "$TMPDIR_T/spin-tui.sh" send-async "spin" >/dev/null 2>&1
TUI_TIMEOUT=5 $TD -q --session "$S" "$TMPDIR_T/spin-tui.sh" poll --wait >/dev/null 2>&1; rc=$?
check "poll --wait timeout exits 3"             [ "$rc" -eq 3 ]
check "timeout kept .async"                     [ -e "$STATE_DIR/${S}.async" ]
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
$TD -q --session "$S" "$TMPDIR_T/until-tui.sh" start >/dev/null 2>&1
$TD -q --session "$S" "$TMPDIR_T/until-tui.sh" send-async "go" >/dev/null 2>&1
sleep 3
out=$($TD -q --until 'DONEZZZ' --session "$S" "$TMPDIR_T/until-tui.sh" poll 2>/dev/null); rc=$?
check "bare poll honours --until (exit 0)"      [ "$rc" -eq 0 ]
check "  response contains answer"              grep -q "answer-part" <<<"$out"
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

# 10. Names: default session for a path command; invalid explicit name --------
DFLT="$TMPDIR_T/dflt"; mkdir -p "$DFLT"
$TD -q --dir "$DFLT" "$PONG" start >/dev/null 2>&1; rc=$?
check "default session for ./path.sh starts"    [ "$rc" -eq 0 ]
out=$($TD -q --dir "$DFLT" "$PONG" send "dotted name" 2>/dev/null)
check "default session for ./path.sh answers"   grep -q "pong-response" <<<"$out"
$TD -q --dir "$DFLT" "$PONG" stop >/dev/null 2>&1
out=$($TD -q --dir "$DFLT" "$PONG" status 2>/dev/null)
check "default session for ./path.sh stopped"   [ "$out" = "stopped" ]
$TD -q --session "bad.name" "$PONG" status >/dev/null 2>&1; rc=$?
check "session name with '.' rejected (exit 1)" [ "$rc" -eq 1 ]

# 11. TUI exit: never falls back to a shell; last screen is kept ---------------
S="${RUN_ID}-miss"
errmsg=$($TD -q --session "$S" nonexistent-tui-xyz start 2>&1 >/dev/null); rc=$?
check "start of a missing command exits 1"      [ "$rc" -eq 1 ]
check "  says it exited with status 127"        grep -q "exited (status 127)" <<<"$errmsg"
out=$($TD -q --session "$S" nonexistent-tui-xyz status 2>/dev/null)
check "  status reports exited"                 [ "$out" = "exited" ]
out=$($TD -q --session "$S" nonexistent-tui-xyz raw 2>/dev/null)
check "  raw prints the saved last screen"      grep -q "not found" <<<"$out"
$TD -q --session "$S" nonexistent-tui-xyz stop >/dev/null 2>&1
S="${RUN_ID}-once"
$TD -q --session "$S" "$TMPDIR_T/once-tui.sh" start >/dev/null 2>&1
$TD -q --session "$S" "$TMPDIR_T/once-tui.sh" send "first" >/dev/null 2>&1
$TD -q --session "$S" "$TMPDIR_T/once-tui.sh" send "touch $TMPDIR_T/ran-as-shell" >/dev/null 2>&1; rc=$?
check "send after the TUI exited exits 1"       [ "$rc" -eq 1 ]
check "  prompt was not run by a shell"         [ ! -e "$TMPDIR_T/ran-as-shell" ]
$TD -q --session "$S" "$TMPDIR_T/once-tui.sh" stop >/dev/null 2>&1
S="${RUN_ID}-norm"
$TD -q --session "$S" "$PONG" start >/dev/null 2>&1
$TD -q --session "$S" "$PONG" stop >/dev/null 2>&1
sleep 1
check "normal stop leaves no exit record"       [ ! -e "$STATE_DIR/${S}.exit" ]
rm -f "$STATE_DIR/${RUN_ID}"-*.exit "$STATE_DIR/${RUN_ID}"-*.screen

# 12. respond --key: single keypress, no Enter ---------------------------------
S="${RUN_ID}-menu"
MENU="$TMPDIR_T/menu-tui.sh"
$TD -q --session "$S" "$MENU" start >/dev/null 2>&1
$TD -q --session "$S" "$MENU" send-async "deploy" >/dev/null 2>&1
sleep 4
$TD -q --session "$S" "$MENU" poll >/dev/null 2>&1
$TD -q --session "$S" "$MENU" respond --key 4 --async >/dev/null 2>&1; rc=$?
check "respond --key 4 --async exits 0"         [ "$rc" -eq 0 ]
check "  --async after the key re-armed poll"   [ -e "$STATE_DIR/${S}.async" ]
sleep 2
out=$($TD -q --session "$S" "$MENU" raw 2>/dev/null)
check "  key reached the menu (denied)"         grep -q "menu-denied" <<<"$out"
check "  no Enter was sent after the key"       bash -c "! grep -q 'line-after-menu' <<<\"\$1\"" _ "$out"
$TD -q --session "$S" "$MENU" cancel >/dev/null 2>&1
$TD -q --session "$S" "$MENU" respond "typed-reply" >/dev/null 2>&1
out=$($TD -q --session "$S" "$MENU" raw 2>/dev/null)
check "respond types the reply + Enter"         grep -q "line-after-menu:typed-reply" <<<"$out"
$TD -q --session "$S" "$MENU" stop >/dev/null 2>&1

# 13. Extraction: multi-line prompt echo skipped; missing anchor warned ------
S="${RUN_ID}-multi"
$TD -q --session "$S" "$TMPDIR_T/multi-tui.sh" start >/dev/null 2>&1
out=$($TD -q --session "$S" "$TMPDIR_T/multi-tui.sh" send "first-line-of-prompt
second-line-of-prompt
last-line-of-prompt" 2>/dev/null)
check "multi-line: answer returned"             grep -q "multi-answer" <<<"$out"
check "  prompt lines 2+ not in the response"   bash -c "! grep -q 'line-of-prompt' <<<\"\$1\"" _ "$out"
$TD -q --session "$S" "$TMPDIR_T/multi-tui.sh" stop >/dev/null 2>&1
S="${RUN_ID}-noecho"
$TD -q --session "$S" "$TMPDIR_T/noecho-tui.sh" start >/dev/null 2>&1
errmsg=$(TUI_DELIVER_WAIT=3 $TD -q --session "$S" "$TMPDIR_T/noecho-tui.sh" send "never shown on screen" 2>&1 >/dev/null); rc=$?
check "prompt never on screen: send exits 4"    [ "$rc" -eq 4 ]
check "  says not delivered on stderr (-q)"     grep -q "not delivered" <<<"$errmsg"
$TD -q --session "$S" "$TMPDIR_T/noecho-tui.sh" stop >/dev/null 2>&1
S="${RUN_ID}-alt"
$TD -q --session "$S" "$TMPDIR_T/alt-tui.sh" start >/dev/null 2>&1
out=$($TD -q --session "$S" "$TMPDIR_T/alt-tui.sh" send "alt screen question" 2>"$TMPDIR_T/alt.err"); rc=$?
check "delivered prompt later scrolled away: exit 0" [ "$rc" -eq 0 ]
check "  answer returned"                       grep -q "alt-answer" <<<"$out"
check "  missing anchor still warned"           grep -q "not found on screen" "$TMPDIR_T/alt.err"
$TD -q --session "$S" "$TMPDIR_T/alt-tui.sh" stop >/dev/null 2>&1

# 13b. Overlays: start dismisses them; without dismissal the send fails -------
S="${RUN_ID}-ovl"
OVL="$TMPDIR_T/agy-overlay-tui.sh"
errmsg=$($TD --session "$S" "$OVL" start 2>&1 >/dev/null); rc=$?
check "start with two overlays exits 0"         [ "$rc" -eq 0 ]
check "  logged both dismissals"                [ "$(grep -c 'Dismissing overlay' <<<"$errmsg")" -eq 2 ]
out=$($TD -q --session "$S" "$OVL" raw 2>/dev/null)
check "  no overlay left on screen"             bash -c "! grep -q 'esc to dismiss' <<<\"\$1\"" _ "$out"
out=$($TD -q --session "$S" "$OVL" send "after the overlays" 2>/dev/null); rc=$?
check "  send then reaches the TUI (exit 0)"    [ "$rc" -eq 0 ]
check "  answer returned"                       grep -q "overlay-answer" <<<"$out"
$TD -q --session "$S" "$OVL" stop >/dev/null 2>&1
S="${RUN_ID}-ovloff"
TUI_DISMISS_PATTERN='' $TD -q --session "$S" "$OVL" start >/dev/null 2>&1
out=$(TUI_DISMISS_PATTERN='' TUI_DELIVER_WAIT=3 $TD -q --session "$S" "$OVL" send-async "eaten by the overlay" 2>/dev/null); rc=$?
check "overlay eats send-async: exit 4"         [ "$rc" -eq 4 ]
check "  screen printed"                        grep -q "esc to dismiss" <<<"$out"
check "  nothing left pending"                  [ ! -e "$STATE_DIR/${S}.async" ]
# A query armed by an older version (no delivery record) whose prompt is
# not on screen: poll must not hand back the screen as the answer.
printf 'eaten by the overlay\n' > "$STATE_DIR/${S}.async"
$TD -q --session "$S" "$OVL" poll --wait >/dev/null 2>&1; rc=$?
check "poll of an undelivered prompt exits 4"   [ "$rc" -eq 4 ]
check "  and drops the pending query"           [ ! -e "$STATE_DIR/${S}.async" ]
t0=$(date +%s)
TUI_DISMISS_PATTERN='' TUI_TIMEOUT=60 $TD -q --session "$S" "$OVL" respond --key Escape >/dev/null 2>&1; rc=$?
t1=$(date +%s)
check "respond --key returns quickly (exit 0)"  [ "$rc" -eq 0 ] && [ $((t1 - t0)) -lt 6 ]
$TD -q --session "$S" "$OVL" stop >/dev/null 2>&1

# 13b2. Short prompt whose needle fills the old screen: still delivered ----
S="${RUN_ID}-short"
$TD -q --session "$S" "$TMPDIR_T/short-tui.sh" start >/dev/null 2>&1
out=$(TUI_DELIVER_WAIT=4 $TD -q --session "$S" "$TMPDIR_T/short-tui.sh" send "hi" 2>/dev/null); rc=$?
check "short prompt, needle-heavy old screen: exit 0" [ "$rc" -eq 0 ]
check "  answer returned"                       grep -q "short-answer" <<<"$out"
$TD -q --session "$S" "$TMPDIR_T/short-tui.sh" stop >/dev/null 2>&1

# 13c. --until is strict: a long static screen does not end the wait ----------
S="${RUN_ID}-static"
ST="$TMPDIR_T/static-tui.sh"
$TD -q --session "$S" "$ST" start >/dev/null 2>&1
$TD -q --session "$S" "$ST" send-async "run the long job" >/dev/null 2>&1
sleep 3
TUI_POLL=1 $TD -q --until 'DONEZZZ' --session "$S" "$ST" poll >/dev/null 2>&1; rc=$?
check "bare poll --until on a static screen: 2" [ "$rc" -eq 2 ]
t0=$(date +%s)
out=$(TUI_POLL=1 TUI_TIMEOUT=40 $TD -q --until 'DONEZZZ' --session "$S" "$ST" poll --wait 2>/dev/null); rc=$?
t1=$(date +%s)
check "poll --wait --until waits for the marker" [ "$rc" -eq 0 ] && grep -q "answer-static" <<<"$out"
check "  (held through the static stretch)"     [ $((t1 - t0)) -ge 5 ]
$TD -q --session "$S" "$ST" stop >/dev/null 2>&1
$TD -q --session "$S" "$ST" start >/dev/null 2>&1
t0=$(date +%s)
out=$(TUI_POLL=1 TUI_TIMEOUT=40 $TD -q --until 'DONEZZZ' --session "$S" "$ST" send "finish with DONEZZZ" 2>/dev/null); rc=$?
t1=$(date +%s)
check "marker spelled in prompt: echo is not done" [ "$rc" -eq 0 ] && grep -q "answer-static" <<<"$out"
check "  (waited for the real marker)"          [ $((t1 - t0)) -ge 10 ]
$TD -q --session "$S" "$ST" stop >/dev/null 2>&1

# 14. stop cleans state; shellcheck -------------------------------------------
check "no state files left for this run"        bash -c "! ls '$STATE_DIR'/${RUN_ID}-* >/dev/null 2>&1"
if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck clean"                    shellcheck -S style "$(command -v "$TD" || echo "$TD")"
else
    echo "skip - shellcheck not installed"
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
