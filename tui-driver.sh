#!/usr/bin/env bash
# tui-driver - Drive any interactive TUI programmatically via tmux
#
# Usage:
#   tui-driver <tui-command> start
#   tui-driver <tui-command> send "your prompt"
#   tui-driver <tui-command> respond "y"
#   tui-driver <tui-command> stop | status | raw
#
# The first argument is always the TUI command (agy, claude, aichat, etc).
# No profiles, no special-casing. Works with any TUI.

set -euo pipefail

VERSION="0.3.0"
# Baked in at install time by cmd_install (git short hash, +-dirty if the
# source tree had uncommitted changes). Empty when running straight from a
# checkout, in which case _build_stamp falls back to live git.
BUILD_STAMP=""

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

if ! command -v tmux &>/dev/null; then
    echo "Error: tmux is not installed." >&2
    echo "Install it with:  sudo apt install tmux  (Debian/Ubuntu)" >&2
    echo "                   brew install tmux       (macOS)" >&2
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is not installed." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Defaults (override via env)
# ---------------------------------------------------------------------------

POLL_INTERVAL="${TUI_POLL:-2}"
MAX_WAIT="${TUI_TIMEOUT:-300}"
STABLE_COUNT="${TUI_STABLE:-2}"
WORK_DIR="${TUI_DIR:-$(pwd)}"
TERM_WIDTH="${TUI_WIDTH:-200}"
TERM_HEIGHT="${TUI_HEIGHT:-50}"
MIN_INTERVAL="${TUI_MIN_INTERVAL:-3}"   # minimum seconds between sends
JITTER="${TUI_JITTER:-2}"               # random 0..JITTER seconds added
PASTE_DELAY="${TUI_PASTE_DELAY:-0.5}"   # pause between paste and Enter
START_TIMEOUT="${TUI_START_TIMEOUT:-60}" # max wait for the TUI to come up
HEARTBEAT="${TUI_HEARTBEAT:-15}"        # "still waiting" log every N s (0=off)
DONE_PATTERN="${TUI_DONE_PATTERN:-}"    # regex in the response = done (opt-in)

# Per-session state lives in a user-private runtime dir, not world-shared
# /tmp: predictable /tmp names are a symlink/squat risk on shared machines,
# and tmpfiles cleaners that purge old /tmp entries can delete a live
# session's stamp — which the watchdog reads as "caller died" and kills the
# session. XDG_RUNTIME_DIR is per-user 0700 tmpfs; ~/.cache is the fallback.
# list/reap still scan the legacy /tmp names so sessions started by an older
# version can be discovered and cleaned up (but not driven — stop/reap them).
STATE_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}/tui-driver"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true
QUIET="${TUI_QUIET:-false}"             # suppress stderr logs (for agents)
SESSION_EXPLICIT=false                   # true once --session NAME is given

# ---------------------------------------------------------------------------
# Parse arguments: tui-driver [flags] <tui-command> <action> [args]
# ---------------------------------------------------------------------------

while [[ "${1:-}" == --* || "${1:-}" == -* ]]; do
    case "$1" in
        --session) TUI_SESSION="$2"; SESSION_EXPLICIT=true; shift 2 ;;
        --dir)     WORK_DIR="$2"; shift 2 ;;
        --until)   DONE_PATTERN="$2"; shift 2 ;;
        --quiet|-q) QUIET="true"; shift ;;
        --help|-h) set -- "help"; break ;;
        --version|-v) set -- "version"; break ;;
        *)         echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

# First positional arg = TUI command (unless it's "help" or "install")
TUI_CMD="${1:-}"
ACTION="${2:-}"

case "$TUI_CMD" in
    help|--help|-h|"")
        ACTION="help"
        ;;
    install|uninstall|version|list|reap)
        ACTION="$TUI_CMD"
        TUI_CMD=""
        ;;
    *)
        if [ -z "$ACTION" ]; then
            echo "Error: missing action. Usage: tui-driver $TUI_CMD <start|send|stop|...>" >&2
            exit 1
        fi
        shift 2  # consume TUI_CMD and ACTION, rest are args
        ;;
esac

# Session name: if a lock file exists for this TUI+dir combo, reuse that
# session name. Otherwise generate a new one with a random suffix.
_default_session() {
    local dir_hash
    if command -v md5sum &>/dev/null; then
        dir_hash=$(printf '%s' "$WORK_DIR" | md5sum | cut -c1-8)
    else
        dir_hash=$(printf '%s' "$WORK_DIR" | md5 | cut -c1-8)
    fi
    local lock="${STATE_DIR}/${TUI_CMD}-${dir_hash}.lock"
    if [ -f "$lock" ]; then
        local existing
        existing=$(cat "$lock")
        if tmux has-session -t "$existing" 2>/dev/null; then
            echo "$existing"
            return
        fi
    fi
    # New session: random suffix to avoid collisions with other callers
    echo "tui-${TUI_CMD}-${RANDOM}${RANDOM}"
}
# Explicit "--session NAME" is a full escape hatch: it bypasses the cmd+dir
# lock entirely, so multiple agents in the SAME directory can each drive their
# own independent session. Default (no --session) sessions stay keyed on
# cmd+dir via the lock, so separate start/send/stop invocations rediscover the
# same session. The global actions (list/reap/install/...) need no session.
case "$ACTION" in
    help|install|uninstall|version|list|reap) : ;;
    *)
        if [ -z "${TUI_SESSION:-}" ]; then
            TUI_SESSION="$(_default_session)"
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    [[ "$QUIET" == "true" ]] && return
    printf '[tui-driver:%s] %s\n' "${TUI_SESSION:-tui-driver}" "$*" >&2
}

# Errors and timeout notices must reach the caller even under --quiet:
# an agent that gets a bare exit code with no explanation cannot recover.
err() {
    printf '[tui-driver:%s] %s\n' "${TUI_SESSION:-tui-driver}" "$*" >&2
}

_stamp_file()    { echo "${STATE_DIR}/${TUI_SESSION}.stamp"; }
_watchdog_file() { echo "${STATE_DIR}/${TUI_SESSION}.watchdog"; }
_async_file()    { echo "${STATE_DIR}/${TUI_SESSION}.async"; }
_poll_hash_file(){ echo "${STATE_DIR}/${TUI_SESSION}.poll-hash"; }
_last_send_file(){ echo "${STATE_DIR}/${TUI_SESSION}.last-send"; }
_prompt_file()   { echo "${STATE_DIR}/${TUI_SESSION}.prompt"; }
_lock_file() {
    # Lock is keyed on command+directory, NOT session name.
    # This lets _default_session find the right session.
    local dir_hash
    if command -v md5sum &>/dev/null; then
        dir_hash=$(printf '%s' "$WORK_DIR" | md5sum | cut -c1-8)
    else
        dir_hash=$(printf '%s' "$WORK_DIR" | md5 | cut -c1-8)
    fi
    echo "${STATE_DIR}/${TUI_CMD}-${dir_hash}.lock"
}

_rm_owned_lock() {
    # Remove the cmd+dir lock ONLY if it still names the given session.
    # This stops one caller from clobbering another same-dir caller's lock,
    # and makes explicit --session callers (which never write the lock) safe
    # no-ops here.
    local owner="$1" lock
    lock=$(_lock_file)
    if [ -f "$lock" ] && [ "$(cat "$lock" 2>/dev/null)" = "$owner" ]; then
        rm -f "$lock"
    fi
    return 0
}

_start_watchdog() {
    # Background process that kills the tmux session if nobody has used it
    # for a while (meaning the caller likely died).  We track activity via
    # the stamp file: every send/respond updates it.  If no activity for
    # WATCHDOG_TIMEOUT seconds, assume the caller is gone and clean up.
    local session="$TUI_SESSION"
    local stamp watchdog async poll_hash last_send prompt_f
    stamp=$(_stamp_file)
    watchdog=$(_watchdog_file)
    async=$(_async_file)
    poll_hash=$(_poll_hash_file)
    last_send=$(_last_send_file)
    prompt_f=$(_prompt_file)
    local timeout="${TUI_WATCHDOG:-600}"  # 10 minutes default

    # Seed the stamp so the watchdog has a starting point
    date +%s > "$stamp"

    # Redirect the watchdog's stdio away from the caller's fds. Otherwise the
    # backgrounded subshell inherits our stdout/stderr and keeps them open for
    # its whole lifetime (up to TUI_WATCHDOG). A programmatic caller that
    # captures output (e.g. Node's execFile, which waits for pipe EOF, not just
    # process exit) would then block until the watchdog dies or it times out —
    # even though `start` itself returned in seconds. `disown` alone does not
    # close the inherited fds, so redirect them explicitly.
    (
        while true; do
            sleep 30
            # If the session is gone (stopped, crashed, killed elsewhere),
            # clean up our own per-session state so it does not leak into /tmp.
            if ! tmux has-session -t "$session" 2>/dev/null; then
                rm -f "$stamp" "$async" "$poll_hash" "$watchdog" "$last_send" "$prompt_f"
                _rm_owned_lock "$session"
                break
            fi
            # Check if stamp file has been updated recently
            if [ -f "$stamp" ]; then
                local last now idle
                last=$(cat "$stamp")
                now=$(date +%s)
                idle=$((now - last))
                if [ "$idle" -gt "$timeout" ]; then
                    tmux kill-session -t "$session" 2>/dev/null || true
                    rm -f "$stamp" "$async" "$poll_hash" "$watchdog" "$last_send" "$prompt_f"
                    _rm_owned_lock "$session"
                    break
                fi
            else
                # No stamp file — caller probably died without stopping
                tmux kill-session -t "$session" 2>/dev/null || true
                rm -f "$async" "$poll_hash" "$watchdog" "$last_send" "$prompt_f"
                _rm_owned_lock "$session"
                break
            fi
        done
    ) </dev/null >/dev/null 2>&1 &

    echo "$!" > "$watchdog"
    disown
}

_stop_watchdog() {
    local watchdog
    watchdog=$(_watchdog_file)
    if [ -f "$watchdog" ]; then
        kill "$(cat "$watchdog")" 2>/dev/null || true
        rm -f "$watchdog"
    fi
}

_throttle() {
    # Rate-limits SENDS only, keyed on the .last-send file. The watchdog
    # liveness stamp (.stamp) is deliberately not used here: start and every
    # wait-loop poll refresh it, which used to make the very first send after
    # start eat the full MIN_INTERVAL+jitter penalty for no reason.
    local send_file
    send_file=$(_last_send_file)
    if [ -f "$send_file" ]; then
        local last now elapsed wait_time jitter
        last=$(cat "$send_file")
        now=$(date +%s)
        elapsed=$((now - last))
        jitter=$(( RANDOM % (JITTER + 1) ))
        wait_time=$(( MIN_INTERVAL + jitter - elapsed ))
        if [ "$wait_time" -gt 0 ]; then
            log "Rate limit: waiting ${wait_time}s (${MIN_INTERVAL}s min + ${jitter}s jitter)"
            sleep "$wait_time"
        fi
    fi
}

_stamp() {
    date +%s > "$(_stamp_file)"
}

_mark_send() {
    date +%s > "$(_last_send_file)"
}

_capture() {
    tmux capture-pane -t "$TUI_SESSION" -p 2>/dev/null || true
}

_screen_hash() {
    if command -v md5sum &>/dev/null; then
        _capture | md5sum | cut -d' ' -f1
    else
        _capture | md5
    fi
}

_wait_stable() {
    # Wait for the screen to stop changing. With DONE_PATTERN set and a
    # prompt anchor given (send/poll paths), also return the moment the
    # pattern appears in the extracted response — no stability tail needed.
    local timeout="${1:-$MAX_WAIT}"
    local prompt="${2:-}"
    local elapsed=0
    local prev_hash=""
    local stable=0
    local last_change=0
    local next_beat="$HEARTBEAT"

    # Heartbeat: refresh the activity stamp on entry and on every poll below.
    # The active wait loop is proof the caller is still alive, so it holds the
    # watchdog off for the duration of a single response. This does NOT neuter
    # the watchdog: _wait_stable is bounded by MAX_WAIT (TUI_TIMEOUT), so the
    # hold-off lasts at most one response window; once the wait returns, normal
    # idle-counting resumes. Net semantics: TUI_TIMEOUT bounds a single
    # response, TUI_WATCHDOG bounds caller *absence*. The entry stamp also
    # narrows the race where the prior stamp is near-expiry as the wait begins
    # (the brief throttle+paste preamble before this point stays uncovered, but
    # that only matters if the caller was already idle ~TUI_WATCHDOG).
    _stamp

    sleep "$POLL_INTERVAL"
    elapsed=$POLL_INTERVAL

    while [ "$elapsed" -lt "$timeout" ]; do
        _stamp
        local cur_hash
        cur_hash=$(_screen_hash)

        if [ "$cur_hash" = "$prev_hash" ]; then
            stable=$((stable + 1))
        else
            stable=0
            last_change=$elapsed
        fi
        prev_hash="$cur_hash"

        # grep without -q so python never gets SIGPIPE (pipefail would turn
        # an early grep exit into a false negative on large responses).
        if [ -n "$DONE_PATTERN" ] && [ -n "$prompt" ] && \
           _extract_response "$prompt" | grep -E "$DONE_PATTERN" >/dev/null; then
            log "Done pattern matched"
            return 0
        fi

        if [ "$stable" -ge "$STABLE_COUNT" ]; then
            return 0
        fi

        if [ "$HEARTBEAT" -gt 0 ] && [ "$elapsed" -ge "$next_beat" ]; then
            log "still waiting — ${elapsed}s elapsed, screen last changed $((elapsed - last_change))s ago"
            next_beat=$((next_beat + HEARTBEAT))
        fi

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    return 1
}

# Shared by send and poll --wait: wait for a stable, NON-EMPTY response.
# Stability alone is not completion — a TUI that has not started printing
# yet (backend call, thinking pause before any output) also yields a stable
# screen, which used to return an empty response with exit 0. Prints the
# response; returns 0 when ready, 3 on timeout (printing what is on screen).
_await_response() {
    local prompt="$1"
    local t0 waited=0 remaining response
    t0=$(date +%s)
    while true; do
        remaining=$((MAX_WAIT - waited))
        if _wait_stable "$remaining" "$prompt"; then
            response=$(_extract_response "$prompt")
            if [ -n "$response" ]; then
                log "Screen stabilised"
                printf '%s\n' "$response"
                return 0
            fi
            log "Screen stable but response still empty — waiting on"
        fi
        waited=$(( $(date +%s) - t0 ))
        if [ "$waited" -ge "$MAX_WAIT" ]; then
            err "Timeout after ${MAX_WAIT}s - returning what is on screen"
            _extract_response "$prompt"
            return 3
        fi
    done
}

# ---------------------------------------------------------------------------
# Extract response: everything after our prompt (the only anchor we need)
# ---------------------------------------------------------------------------

_extract_response() {
    local prompt="$1"
    tmux capture-pane -t "$TUI_SESSION" -p -S - | \
        _TUI_PROMPT="$prompt" \
        python3 -c '
import sys, os

lines = sys.stdin.read().split("\n")
prompt = os.environ.get("_TUI_PROMPT", "")

# Find the LAST line containing our prompt (the anchor). Use the first
# LINE of the prompt (a multi-line prompt slice would contain a newline
# and never match any captured line). If a long needle fails — narrow TUI
# input boxes wrap the echoed prompt — retry with a shorter one.
prompt_line = -1
first_line = prompt.strip().splitlines()[0].strip() if prompt.strip() else ""

for cut in (80, 40):
    prompt_needle = first_line[:cut].strip()
    if not prompt_needle:
        break
    for i, line in enumerate(lines):
        if prompt_needle in line:
            prompt_line = i
    if prompt_line >= 0:
        break
    if len(first_line) <= cut:
        break

# Everything after our prompt is the response
if prompt_line >= 0:
    lines = lines[prompt_line + 1:]

# Trim leading / trailing blank lines
while lines and not lines[0].strip():
    lines.pop(0)
while lines and not lines[-1].strip():
    lines.pop()

if lines:
    print("\n".join(lines))
'
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_start() {
    # Prevent starting if a session already exists for this TUI
    if tmux has-session -t "$TUI_SESSION" 2>/dev/null; then
        err "Error: session '$TUI_SESSION' is already running."
        err "Run 'tui-driver $TUI_CMD stop' first, then start again."
        return 1
    fi

    # Default sessions are keyed on cmd+dir via a lock so later send/stop
    # invocations rediscover them, and only one default session per cmd+dir is
    # allowed. Explicit --session sessions skip the lock entirely, so multiple
    # agents can drive the same command from the same directory independently.
    local lock=""
    if [ "$SESSION_EXPLICIT" = false ]; then
        lock=$(_lock_file)
        if [ -f "$lock" ]; then
            local existing
            existing=$(cat "$lock")
            if tmux has-session -t "$existing" 2>/dev/null; then
                err "Error: another session '$existing' is already running for this command+directory."
                err "Run 'tui-driver $TUI_CMD stop' first, or pass --session NAME to start a second, independent session."
                return 1
            fi
            rm -f "$lock"  # stale lock
        fi
        # Claim the cmd+dir lock atomically (noclobber) BEFORE creating the
        # session: if two starts race, exactly one wins; the loser sees the
        # winner's session instead of both writing the lock last-wins.
        if ! (set -C; printf '%s\n' "$TUI_SESSION" > "$lock") 2>/dev/null; then
            err "Error: another session '$(cat "$lock" 2>/dev/null)' just claimed this command+directory."
            err "Pass --session NAME to start an independent session."
            return 1
        fi
    fi

    log "Creating tmux session '$TUI_SESSION' ..."
    tmux new-session -s "$TUI_SESSION" -d -x "$TERM_WIDTH" -y "$TERM_HEIGHT"
    tmux send-keys -t "$TUI_SESSION" "cd $(printf '%q' "$WORK_DIR") && $TUI_CMD" Enter

    # Spawn a watchdog that kills the session if the caller dies.
    _start_watchdog

    log "Waiting for $TUI_CMD to start ..."
    if ! _wait_stable "$START_TIMEOUT"; then
        err "Warning: startup timed out after ${START_TIMEOUT}s"
        err "Session left running: inspect with 'raw', or 'stop' then 'start'."
        return 3
    fi

    log "$TUI_CMD is ready"
    return 0
}

cmd_send() {
    local prompt="${1:?Usage: tui-driver $TUI_CMD send \"your prompt\"}"

    if ! tmux has-session -t "$TUI_SESSION" 2>/dev/null; then
        err "Error: no session running. Run 'tui-driver $TUI_CMD start' first."
        return 1
    fi

    if [ -f "$(_async_file)" ]; then
        err "Error: async query pending. Poll first: tui-driver $TUI_CMD poll --wait"
        return 1
    fi

    _throttle

    # Send via bracketed paste (safe with !, ?, @, etc.)
    printf '%s' "$prompt" | tmux load-buffer -
    tmux paste-buffer -t "$TUI_SESSION" -p
    sleep "$PASTE_DELAY"
    tmux send-keys -t "$TUI_SESSION" Enter
    _mark_send
    # Remember the prompt: it is the extraction anchor for respond --async
    # and for a send that times out and converts to a pending async query.
    printf '%s\n' "$prompt" > "$(_prompt_file)"

    log "Prompt sent, waiting for screen to stabilise ..."

    local rc=0
    _await_response "$prompt" || rc=$?
    if [ "$rc" -eq 3 ]; then
        # Convert the timed-out send into a pending async query so the
        # response is not lost: the caller can keep polling for it.
        # Scrollback is kept too — the anchor must stay findable.
        printf '%s\n' "$prompt" > "$(_async_file)"
        rm -f "$(_poll_hash_file)"
        err "Query still pending: poll for the rest, raise TUI_TIMEOUT, or 'cancel'."
        _stamp
        return 3
    fi
    tmux clear-history -t "$TUI_SESSION" 2>/dev/null || true
    _stamp
    return "$rc"
}

cmd_respond() {
    # Send a short reply (e.g. to an approval prompt). Pass "" to press Enter.
    # --async: return immediately and (re-)arm the pending-async record using
    # the original prompt as anchor, so a follow-up poll / poll --wait picks
    # up the response — the dialog flow for async queries.
    local async_mode=false
    if [ "${1:-}" = "--async" ]; then
        async_mode=true
        shift
    fi
    local reply="${*:-}"

    if ! tmux has-session -t "$TUI_SESSION" 2>/dev/null; then
        err "Error: no session running."
        return 1
    fi

    # A blocking respond would fight a pending async query; respond --async
    # is fine (the reply just unblocks the dialog, the query stays pending).
    if [ -f "$(_async_file)" ] && [ "$async_mode" = false ]; then
        err "Error: async query pending. Poll first (tui-driver $TUI_CMD poll --wait) or use respond --async."
        return 1
    fi

    if [ -n "$reply" ]; then
        printf '%s' "$reply" | tmux load-buffer -
        tmux paste-buffer -t "$TUI_SESSION" -p
        sleep 0.3
    fi
    tmux send-keys -t "$TUI_SESSION" Enter

    if [ "$async_mode" = true ]; then
        local prompt_file
        prompt_file=$(_prompt_file)
        if [ -f "$prompt_file" ]; then
            cp "$prompt_file" "$(_async_file)"
        else
            # No recorded prompt (respond before any send): fall back to the
            # reply as anchor — poll returns everything after it.
            printf '%s\n' "$reply" > "$(_async_file)"
        fi
        rm -f "$(_poll_hash_file)"
        log "Reply sent (async). Use 'poll' or 'poll --wait' to retrieve the response."
        _stamp
        return 0
    fi

    log "Reply sent, waiting for screen to stabilise ..."

    # A 1-2 char reply like "y" is not a reliable anchor for
    # _extract_response, so we dump the whole screen and let the caller
    # pick out what they need.
    if _wait_stable; then
        log "Screen stabilised"
        _capture
        tmux clear-history -t "$TUI_SESSION" 2>/dev/null || true
        _stamp
        return 0
    fi

    err "Timeout after ${MAX_WAIT}s"
    _capture
    tmux clear-history -t "$TUI_SESSION" 2>/dev/null || true
    _stamp
    return 3
}

# ---------------------------------------------------------------------------
# Async send + poll: non-blocking alternative to cmd_send.
#
# send-async fires the prompt and returns immediately, storing the prompt
# text in a per-session .async file so poll knows the response anchor.
# poll then checks (once or in a loop) whether the screen has stabilised.
#
# State files (all per-session, cleaned up by stop/poll-complete):
#   .async     — prompt text (anchor for _extract_response)
#   .poll-hash — vestigial: older single-check poll persisted the last screen
#                hash here across calls; the current self-contained probe does
#                not need it. Still cleaned up so stale files never leak.
#
# Designed for AI agents that want to run poll --wait in the background
# and get notified when the response arrives, freeing them to do other
# work in the meantime.
# ---------------------------------------------------------------------------

cmd_send_async() {
    local prompt="${1:?Usage: tui-driver $TUI_CMD send-async \"your prompt\"}"

    if ! tmux has-session -t "$TUI_SESSION" 2>/dev/null; then
        err "Error: no session running. Run 'tui-driver $TUI_CMD start' first."
        return 1
    fi

    # Only one async query per session at a time — the caller must poll
    # for the previous response before sending another.
    local async_file
    async_file=$(_async_file)
    if [ -f "$async_file" ]; then
        err "Error: a send-async is already pending. Run 'poll' or 'poll --wait' first."
        return 1
    fi

    _throttle

    # Send via bracketed paste (safe with !, ?, @, etc.)
    printf '%s' "$prompt" | tmux load-buffer -
    tmux paste-buffer -t "$TUI_SESSION" -p
    sleep "$PASTE_DELAY"
    tmux send-keys -t "$TUI_SESSION" Enter
    _mark_send
    # Remember the prompt: it is the extraction anchor for respond --async
    # and for a send that times out and converts to a pending async query.
    printf '%s\n' "$prompt" > "$(_prompt_file)"

    # Save prompt anchor and reset poll state for this session
    printf '%s\n' "$prompt" > "$async_file"
    rm -f "$(_poll_hash_file)"

    log "Prompt sent (async). Use 'poll' or 'poll --wait' to retrieve the response."
    _stamp
}

cmd_poll() {
    local wait_mode=false
    if [ "${1:-}" = "--wait" ]; then
        wait_mode=true
    fi

    if ! tmux has-session -t "$TUI_SESSION" 2>/dev/null; then
        err "Error: no session running."
        return 1
    fi

    local async_file poll_hash_file
    async_file=$(_async_file)
    poll_hash_file=$(_poll_hash_file)

    if [ ! -f "$async_file" ]; then
        err "Error: no pending send-async. Use 'send-async' first."
        return 1
    fi

    local prompt
    prompt=$(cat "$async_file")

    if [ "$wait_mode" = true ]; then
        # Blocking mode: reuse _wait_stable's poll loop, then extract.
        # Intended to be run via `Bash(run_in_background)` so the caller
        # gets notified when the response arrives.
        log "Waiting for screen to stabilise (poll --wait) ..."
        local rc=0
        _await_response "$prompt" || rc=$?
        if [ "$rc" -eq 3 ]; then
            # Keep the query pending (and the scrollback anchor intact):
            # the caller can poll again for the rest of the response.
            err "Query still pending: poll again, raise TUI_TIMEOUT, or 'cancel'."
            _stamp
            return 3
        fi
        tmux clear-history -t "$TUI_SESSION" 2>/dev/null || true
        rm -f "$async_file" "$poll_hash_file"
        _stamp
        return "$rc"
    fi

    # Non-blocking mode: a SELF-CONTAINED stability probe. Sample the screen
    # a few times POLL_INTERVAL apart *within this single call* and require
    # STABLE_COUNT consecutive identical samples — the same stability rule as
    # _wait_stable, just bounded to a quick probe instead of MAX_WAIT.
    #
    # The previous design compared the current screen against the hash saved
    # by the *prior* poll call. That had two sharp edges: (1) the first poll
    # after send-async always reported "waiting" (there was no prior hash to
    # match) even when the response was already on screen, and (2) a single
    # poll could never clear a stale .async lock, so an interrupted poll/--wait
    # left the lock wedged and the next send-async failed with "already
    # pending". Probing within the call fixes both: a lone poll now detects an
    # already-finished response and always clears the lock when it returns the
    # answer. Worst case (still moving) the probe costs STABLE_COUNT *
    # POLL_INTERVAL seconds before reporting "waiting".
    local prev_hash="" cur_hash stable=0 i
    for (( i=0; i<=STABLE_COUNT; i++ )); do
        [ "$i" -gt 0 ] && sleep "$POLL_INTERVAL"
        cur_hash=$(_screen_hash)
        _stamp  # each sample is caller-liveness proof for the watchdog

        if [ "$cur_hash" = "$prev_hash" ]; then
            stable=$((stable + 1))
        else
            stable=0
        fi
        prev_hash="$cur_hash"

        if [ "$stable" -ge "$STABLE_COUNT" ]; then
            log "Screen stable"
            _extract_response "$prompt"
            tmux clear-history -t "$TUI_SESSION" 2>/dev/null || true
            rm -f "$async_file" "$poll_hash_file"
            return 0
        fi
    done

    # Still changing after the probe. The per-sample _stamp above already
    # refreshed liveness. The caller should poll again later; for long async
    # waits prefer `poll --wait` in the background, which heartbeats
    # continuously via _wait_stable.
    log "Still waiting ..."
    echo "waiting"
    return 2
}

cmd_cancel() {
    # Drop a pending async query without touching the session. The TUI may
    # still be generating; this only clears tui-driver's pending record so a
    # new send is allowed.
    if [ -f "$(_async_file)" ]; then
        rm -f "$(_async_file)" "$(_poll_hash_file)"
        log "Pending query cancelled (the TUI itself may still be generating)."
    else
        log "No pending query to cancel."
    fi
    return 0
}

cmd_stop() {
    _stop_watchdog
    if tmux has-session -t "$TUI_SESSION" 2>/dev/null; then
        tmux kill-session -t "$TUI_SESSION"
        log "Session stopped"
    else
        log "No session to stop"
    fi
    rm -f "$(_stamp_file)" "$(_async_file)" "$(_poll_hash_file)" "$(_last_send_file)" "$(_prompt_file)"
    _rm_owned_lock "$TUI_SESSION"
}

cmd_status() {
    if tmux has-session -t "$TUI_SESSION" 2>/dev/null; then
        echo "running"
    else
        echo "stopped"
    fi
}

cmd_raw() {
    _capture
}

cmd_progress() {
    # Read-only monitor for a caller watching a pending query. Unlike poll it
    # never consumes the response or clears the pending record, and unlike
    # raw it answers the actual question ("is it still working?") without a
    # screen dump. Safe to run at any time, any number of times.
    if ! tmux has-session -t "$TUI_SESSION" 2>/dev/null; then
        echo "session=stopped"
        return 1
    fi
    echo "session=running"

    local now async_file
    now=$(date +%s)
    async_file=$(_async_file)
    if [ -f "$async_file" ]; then
        local mtime prompt_head
        mtime=$(stat -c %Y "$async_file" 2>/dev/null || stat -f %m "$async_file" 2>/dev/null || echo "$now")
        echo "pending=yes"
        echo "sent_ago=$((now - mtime))s"
        prompt_head=$(head -c 60 "$async_file" | tr '\n' ' ')
        echo "prompt=${prompt_head}"
    else
        echo "pending=no"
    fi

    local h1 h2
    h1=$(_screen_hash)
    sleep 1
    h2=$(_screen_hash)
    if [ "$h1" = "$h2" ]; then
        echo "screen=still"
    else
        echo "screen=changing"
    fi

    echo "last_lines:"
    _capture | grep -v '^[[:space:]]*$' | tail -3

    # Checking on the session is caller activity — hold the watchdog off.
    _stamp
    return 0
}

# ---------------------------------------------------------------------------
# Orphan discovery and cleanup (global — across all dirs and commands).
#
# Every session tui-driver starts gets a per-session watchdog file
# (<STATE_DIR>/<session>.watchdog) holding the watchdog PID. That set of
# files is the authoritative registry of tui-driver-managed sessions — more
# reliable than matching tmux names, and it works for custom --session names.
# Legacy /tmp/.tui-driver-* files from older versions are scanned too, so
# pre-upgrade sessions stay discoverable and reapable.
#
# A session is an ORPHAN (safe to reap) only if BOTH hold:
#   * its watchdog process is dead (no auto-cleanup will ever run again), AND
#   * it has been idle longer than TUI_WATCHDOG seconds.
# A live parallel agent always has a live watchdog PID, so it is never reaped.
# ---------------------------------------------------------------------------

_watchdog_alive() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    [ "$pid" != "none" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # PID-recycling guard: the watchdog is a fork of this script, so its
    # command line still names tui-driver. A recycled PID would otherwise
    # make list/reap treat a long-dead watchdog as alive forever.
    # shellcheck disable=SC2009  # pgrep cannot inspect one specific PID's args
    ps -o args= -p "$pid" 2>/dev/null | grep -q tui-driver
}

_iter_managed_sessions() {
    # Emit "session<TAB>watchdog_pid<TAB>idle_seconds<TAB>alive(0/1)" per line.
    # idle_seconds is -1 when no stamp exists. Scans the current state dir
    # and the legacy /tmp layout; the sibling stamp is derived from the
    # watchdog file's own path so both layouts resolve correctly.
    local wd session pid stamp last now idle alive
    now=$(date +%s)
    shopt -s nullglob
    for wd in "$STATE_DIR"/*.watchdog /tmp/.tui-driver-*.watchdog; do
        session=${wd##*/}
        session=${session#.tui-driver-}
        session=${session%.watchdog}
        pid=$(cat "$wd" 2>/dev/null || echo "none")
        [ -n "$pid" ] || pid="none"
        stamp="${wd%.watchdog}.stamp"
        if [ -f "$stamp" ]; then
            last=$(cat "$stamp" 2>/dev/null || echo "$now")
            idle=$((now - last))
        else
            idle=-1
        fi
        if tmux has-session -t "$session" 2>/dev/null; then alive=1; else alive=0; fi
        printf '%s\t%s\t%s\t%s\n' "$session" "$pid" "$idle" "$alive"
    done
    # Stamps without a watchdog file: a watchdog that cleaned up can race a
    # blocking call whose heartbeat re-creates the stamp just after. Emit
    # them (pid "none") so list shows the leak and reap can clear it.
    local st
    for st in "$STATE_DIR"/*.stamp /tmp/.tui-driver-*.stamp; do
        [ -f "${st%.stamp}.watchdog" ] && continue
        session=${st##*/}
        session=${session#.tui-driver-}
        session=${session%.stamp}
        last=$(cat "$st" 2>/dev/null || echo "$now")
        idle=$((now - last))
        if tmux has-session -t "$session" 2>/dev/null; then alive=1; else alive=0; fi
        printf '%s\t%s\t%s\t%s\n' "$session" "none" "$idle" "$alive"
    done
    shopt -u nullglob
}

_clear_session_state() {
    # Remove every state file for the session, current and legacy layout.
    local session="$1" ext
    for ext in stamp watchdog async poll-hash last-send prompt; do
        rm -f "${STATE_DIR}/${session}.${ext}" \
              "/tmp/.tui-driver-${session}.${ext}"
    done
    # Drop any cmd+dir lock that still points at this (dead) session.
    local lf
    shopt -s nullglob
    for lf in "$STATE_DIR"/*.lock /tmp/.tui-driver-*.lock; do
        if [ "$(cat "$lf" 2>/dev/null)" = "$session" ]; then
            rm -f "$lf"
        fi
    done
    shopt -u nullglob
}

cmd_list() {
    local any=false session pid idle alive wdstate status
    printf '%-30s %-10s %-9s %s\n' "SESSION" "WATCHDOG" "IDLE(s)" "STATUS"
    while IFS=$'\t' read -r session pid idle alive; do
        any=true
        if _watchdog_alive "$pid"; then wdstate="alive"; else wdstate="dead"; fi
        if [ "$alive" = 0 ]; then
            status="dead (leaked state — reap clears it)"
        elif [ "$wdstate" = alive ]; then
            status="managed (live)"
        elif [ "$idle" -ge "${TUI_WATCHDOG:-600}" ]; then
            status="ORPHAN (reap will kill)"
        else
            status="unmanaged (recently active — kept)"
        fi
        printf '%-30s %-10s %-9s %s\n' "$session" "$pid" "$idle" "$status"
    done < <(_iter_managed_sessions)
    if [ "$any" != true ]; then
        echo "(no tui-driver sessions)"
    fi
}

cmd_reap() {
    local threshold="${TUI_WATCHDOG:-600}"
    local session pid idle alive reaped=0 skipped=0
    while IFS=$'\t' read -r session pid idle alive; do
        if [ "$alive" = 0 ]; then
            # Session already gone — just clear leaked state files.
            _clear_session_state "$session"
            log "cleared leaked state for dead session '$session'"
            reaped=$((reaped + 1))
            continue
        fi
        if _watchdog_alive "$pid"; then
            log "skipping '$session': watchdog PID $pid alive (managed/live agent)"
            skipped=$((skipped + 1))
            continue
        fi
        if [ "$idle" -lt 0 ] || [ "$idle" -lt "$threshold" ]; then
            log "skipping '$session': watchdog dead but idle ${idle}s < ${threshold}s (may still be in use)"
            skipped=$((skipped + 1))
            continue
        fi
        # Dead watchdog AND idle past threshold → true orphan.
        tmux kill-session -t "$session" 2>/dev/null || true
        _clear_session_state "$session"
        log "reaped orphan session '$session' (idle ${idle}s, watchdog dead)"
        reaped=$((reaped + 1))
    done < <(_iter_managed_sessions)
    log "reap complete: ${reaped} reaped/cleared, ${skipped} skipped"
}

INSTALL_DIR="${HOME}/.local/bin"
INSTALL_NAME="tui-driver"

# Produce a git build stamp: prefer the value baked in at install time; when
# running from a checkout, derive it live from the source tree.
_git_stamp() {
    local dir="$1" hash
    hash=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null) || return 1
    [ -n "$hash" ] || return 1
    if ! git -C "$dir" diff --quiet --ignore-submodules HEAD 2>/dev/null; then
        hash="${hash}-dirty"
    fi
    printf '%s' "$hash"
}

_build_stamp() {
    if [ -n "$BUILD_STAMP" ]; then
        printf '%s' "$BUILD_STAMP"
        return 0
    fi
    _git_stamp "$(cd "$(dirname "$0")" && pwd)" 2>/dev/null || printf 'unknown'
}

cmd_version() {
    echo "tui-driver ${VERSION} ($(_build_stamp))"
}

cmd_install() {
    local src dst
    local srcdir stamp
    srcdir="$(cd "$(dirname "$0")" && pwd)"
    src="${srcdir}/$(basename "$0")"
    dst="${INSTALL_DIR}/${INSTALL_NAME}"
    mkdir -p "$INSTALL_DIR"
    # Bake the source tree's git stamp into the installed copy so `version`
    # reports the exact commit it was built from (the install dir is not a
    # repo). Substitute during the copy — BSD/macOS sed has no GNU -i.
    stamp=$(_git_stamp "$srcdir" 2>/dev/null) || stamp=""
    if [ -n "$stamp" ]; then
        sed "s/^BUILD_STAMP=\"\"/BUILD_STAMP=\"${stamp}\"/" "$src" > "$dst"
    else
        cp "$src" "$dst"
    fi
    chmod +x "$dst"
    log "Installed to $dst${stamp:+ (${stamp})}"
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
        log "WARNING: ${INSTALL_DIR} is not in your PATH."
        log "Add to ~/.bashrc or ~/.zshrc:  export PATH=\"${INSTALL_DIR}:\$PATH\""
    else
        log "You can now run: tui-driver agy start"
    fi
}

cmd_uninstall() {
    # Also remove the legacy .sh + symlink layout from older installs.
    rm -f "${INSTALL_DIR}/${INSTALL_NAME}" "${INSTALL_DIR}/${INSTALL_NAME}.sh"
    log "Removed ${INSTALL_DIR}/${INSTALL_NAME}"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "$ACTION" in
    start)      cmd_start ;;
    send)       cmd_send "$*" ;;
    send-async) cmd_send_async "$*" ;;
    poll)       cmd_poll "$@" ;;
    respond)    cmd_respond "$@" ;;
    cancel)     cmd_cancel ;;
    stop)       cmd_stop ;;
    status)     cmd_status ;;
    raw)        cmd_raw ;;
    progress)   cmd_progress ;;
    list)       cmd_list ;;
    reap)       cmd_reap ;;
    install)    cmd_install ;;
    uninstall)  cmd_uninstall ;;
    version)    cmd_version ;;
    help|*)
        cat >&2 <<'USAGE'
tui-driver - Drive any interactive TUI programmatically via tmux

Usage:
  tui-driver [flags] <tui-command> <action> [args]

Actions:
  start             Start a TUI session
  send "prompt"     Send prompt, wait, return everything after the prompt
  send-async "p"    Send prompt and return immediately (non-blocking)
  poll              Check if send-async response is ready (single check)
  poll --wait       Block until send-async response is ready
  respond "reply"   Reply to an approval/dialog, "" = just press Enter
                    (blocking: prints the resulting screen itself)
  respond --async "reply"
                    Reply and return immediately, re-arming the pending
                    query so poll / poll --wait retrieves the response
  cancel            Drop a pending async query (session keeps running)
  stop              Kill the session
  status            Print running / stopped
  raw               Raw screen capture (for debugging)
  progress          Read-only check on a pending query: pending?, elapsed,
                    screen still changing?, last screen lines. Never
                    consumes the response — safe to run any time
  list              List all tui-driver sessions (any dir/command) + status
  reap              Kill orphaned sessions (dead watchdog + idle); never
                    touches live or recently-active sessions
  install           Copy to ~/.local/bin as 'tui-driver'
  uninstall         Remove from ~/.local/bin
  version           Print the tui-driver version

Flags:
  --session NAME    Use an independent named session (escape hatch): bypasses
                    the per-directory lock so multiple agents can drive the
                    same command from the same directory in parallel. Pass the
                    same NAME to every send/respond/poll/stop for that session.
  --dir DIR         Set the working directory
  --until REGEX     Treat the response as complete the moment REGEX appears
                    in it (no stability tail). Word the instruction so the
                    literal marker is NOT in your prompt, e.g. tell the TUI
                    "end with the word DONE and three exclamation marks"
                    and pass --until 'DONE!!!'
  --quiet, -q       Suppress stderr progress logs (errors still shown)
  --version, -v     Print the tui-driver version

Exit codes:
  0   success / response ready
  1   hard error (no session, no pending async, bad usage)
  2   poll: response not ready yet (prints "waiting")
  3   timeout (start/send/respond/poll --wait) — output may be incomplete

Environment (override any default):
  TUI_POLL          poll interval        (default: 2s)
  TUI_TIMEOUT       max wait             (default: 300s)
  TUI_STABLE        stable polls needed  (default: 2)
  TUI_MIN_INTERVAL  min gap between sends (default: 3s)
  TUI_JITTER        random 0..N jitter   (default: 2s)
  TUI_PASTE_DELAY   paste-to-Enter pause (default: 0.5s)
  TUI_START_TIMEOUT max wait at startup  (default: 60s)
  TUI_HEARTBEAT     "still waiting" log every N s while blocked (default: 15, 0=off)
  TUI_DONE_PATTERN  completion regex, same as --until (default: unset)
  TUI_DIR           working dir          (default: cwd)
  TUI_WIDTH         terminal width       (default: 200)
  TUI_HEIGHT        terminal height      (default: 50)
  TUI_WATCHDOG      idle-cleanup timeout (default: 600s)
  TUI_QUIET         suppress logs        (default: false)

Examples:
  tui-driver agy start
  tui-driver agy send "Explain this code"
  tui-driver agy stop

  tui-driver claude start
  tui-driver claude send "What does this repo do?"
  tui-driver claude stop

  tui-driver aichat start
  tui-driver aichat send "Hello"
  tui-driver aichat stop

Async (non-blocking) usage:
  tui-driver agy send-async "Search for KiCad 10 changelog"
  tui-driver agy poll            # returns "waiting" or the full response
  tui-driver agy poll --wait     # blocks until response is ready

How poll works (read this before driving from an agent):
  * Only ONE send-async may be pending per session. A second send-async
    while one is pending fails with "already pending" until you retrieve
    the first response with poll/poll --wait.
  * poll is self-contained: a single call samples the screen until it is
    stable, then prints the WHOLE response (exit 0) — or "waiting" (exit 2)
    if still changing. You do NOT need to call it twice. Retrieving a
    response is what clears the pending lock.
  * For long-running queries, run `poll --wait` in the BACKGROUND and keep
    working; it blocks until the response lands (up to TUI_TIMEOUT).
  * A timeout (exit 3) does NOT consume the query: it prints what is on
    screen and keeps it pending. Poll again for the rest, raise
    TUI_TIMEOUT, or run 'cancel' to drop it.
  * If a query stalls on an approval dialog, a plain `poll` returns the
    dialog text (and clears the pending record); reply with
    `respond --async "y"` and then poll again for the real response.
  * To check on a pending query WITHOUT retrieving it, use `progress`
    (safe, read-only). Do NOT use `raw` for that — it dumps the screen
    without answering "is it still working?". Use poll/poll --wait to
    retrieve, raw only for debugging.
  * Tune stability if responses get clipped or never settle: raise
    TUI_STABLE (more consecutive stable samples) or TUI_POLL (longer gap).

Recovering a stuck or orphaned session:
  tui-driver list                # show every session + state (all dirs)
  tui-driver agy reap            # clear crashed/idle orphans (never a live one)
  tui-driver agy stop && tui-driver agy start   # force-restart a wedged session
USAGE
        ;;
esac
