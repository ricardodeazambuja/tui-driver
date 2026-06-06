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

VERSION="0.2.0"
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
QUIET="${TUI_QUIET:-false}"             # suppress stderr logs (for agents)
SESSION_EXPLICIT=false                   # true once --session NAME is given

# ---------------------------------------------------------------------------
# Parse arguments: tui-driver [flags] <tui-command> <action> [args]
# ---------------------------------------------------------------------------

while [[ "${1:-}" == --* || "${1:-}" == -* ]]; do
    case "$1" in
        --session) TUI_SESSION="$2"; SESSION_EXPLICIT=true; shift 2 ;;
        --dir)     WORK_DIR="$2"; shift 2 ;;
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
    local lock="/tmp/.tui-driver-${TUI_CMD}-${dir_hash}.lock"
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

_stamp_file()    { echo "/tmp/.tui-driver-${TUI_SESSION}.stamp"; }
_watchdog_file() { echo "/tmp/.tui-driver-${TUI_SESSION}.watchdog"; }
_async_file()    { echo "/tmp/.tui-driver-${TUI_SESSION}.async"; }
_poll_hash_file(){ echo "/tmp/.tui-driver-${TUI_SESSION}.poll-hash"; }
_lock_file() {
    # Lock is keyed on command+directory, NOT session name.
    # This lets _default_session find the right session.
    local dir_hash
    if command -v md5sum &>/dev/null; then
        dir_hash=$(printf '%s' "$WORK_DIR" | md5sum | cut -c1-8)
    else
        dir_hash=$(printf '%s' "$WORK_DIR" | md5 | cut -c1-8)
    fi
    echo "/tmp/.tui-driver-${TUI_CMD}-${dir_hash}.lock"
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
    local stamp watchdog async poll_hash
    stamp=$(_stamp_file)
    watchdog=$(_watchdog_file)
    async=$(_async_file)
    poll_hash=$(_poll_hash_file)
    local timeout="${TUI_WATCHDOG:-600}"  # 10 minutes default

    # Seed the stamp so the watchdog has a starting point
    date +%s > "$stamp"

    (
        while true; do
            sleep 30
            # If the session is gone (stopped, crashed, killed elsewhere),
            # clean up our own per-session state so it does not leak into /tmp.
            if ! tmux has-session -t "$session" 2>/dev/null; then
                rm -f "$stamp" "$async" "$poll_hash" "$watchdog"
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
                    rm -f "$stamp" "$async" "$poll_hash" "$watchdog"
                    _rm_owned_lock "$session"
                    break
                fi
            else
                # No stamp file — caller probably died without stopping
                tmux kill-session -t "$session" 2>/dev/null || true
                rm -f "$async" "$poll_hash" "$watchdog"
                _rm_owned_lock "$session"
                break
            fi
        done
    ) &

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
    local stamp_file
    stamp_file=$(_stamp_file)
    if [ -f "$stamp_file" ]; then
        local last now elapsed wait_time jitter
        last=$(cat "$stamp_file")
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
    # Wait for the screen to stop changing.
    local timeout="${1:-$MAX_WAIT}"
    local elapsed=0
    local prev_hash=""
    local stable=0

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
        fi
        prev_hash="$cur_hash"

        if [ "$stable" -ge "$STABLE_COUNT" ]; then
            return 0
        fi

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    return 1
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

# Find the LAST line containing our prompt (the anchor)
prompt_line = -1
prompt_needle = prompt[:80].strip()

if prompt_needle:
    for i, line in enumerate(lines):
        if prompt_needle in line:
            prompt_line = i

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
        log "Error: session '$TUI_SESSION' is already running."
        log "Run 'tui-driver $TUI_CMD stop' first, then start again."
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
                log "Error: another session '$existing' is already running for this command+directory."
                log "Run 'tui-driver $TUI_CMD stop' first, or pass --session NAME to start a second, independent session."
                return 1
            fi
            rm -f "$lock"  # stale lock
        fi
    fi

    log "Creating tmux session '$TUI_SESSION' ..."
    tmux new-session -s "$TUI_SESSION" -d -x "$TERM_WIDTH" -y "$TERM_HEIGHT"
    tmux send-keys -t "$TUI_SESSION" "cd $(printf '%q' "$WORK_DIR") && $TUI_CMD" Enter
    if [ "$SESSION_EXPLICIT" = false ]; then
        echo "$TUI_SESSION" > "$lock"
    fi

    # Spawn a watchdog that kills the session if the caller dies.
    _start_watchdog

    log "Waiting for $TUI_CMD to start ..."
    if ! _wait_stable 60; then
        log "Warning: startup timed out after 60s"
        return 1
    fi

    log "$TUI_CMD is ready"
    return 0
}

cmd_send() {
    local prompt="${1:?Usage: tui-driver $TUI_CMD send \"your prompt\"}"

    if ! tmux has-session -t "$TUI_SESSION" 2>/dev/null; then
        log "Error: no session running. Run 'tui-driver $TUI_CMD start' first."
        return 1
    fi

    if [ -f "$(_async_file)" ]; then
        log "Error: async query pending. Poll first: tui-driver $TUI_CMD poll --wait"
        return 1
    fi

    _throttle

    # Send via bracketed paste (safe with !, ?, @, etc.)
    printf '%s' "$prompt" | tmux load-buffer -
    tmux paste-buffer -t "$TUI_SESSION" -p
    sleep 0.5
    tmux send-keys -t "$TUI_SESSION" Enter

    log "Prompt sent, waiting for screen to stabilise ..."

    if _wait_stable; then
        log "Screen stabilised"
        _extract_response "$prompt"
        tmux clear-history -t "$TUI_SESSION" 2>/dev/null || true
        _stamp
        return 0
    fi

    log "Timeout after ${MAX_WAIT}s - returning what is on screen"
    _extract_response "$prompt"
    tmux clear-history -t "$TUI_SESSION" 2>/dev/null || true
    _stamp
    return 1
}

cmd_respond() {
    # Send a short reply (e.g. to an approval prompt). Pass "" to press Enter.
    local reply="${1:-}"

    if ! tmux has-session -t "$TUI_SESSION" 2>/dev/null; then
        log "Error: no session running."
        return 1
    fi

    if [ -f "$(_async_file)" ]; then
        log "Error: async query pending. Poll first: tui-driver $TUI_CMD poll --wait"
        return 1
    fi

    if [ -n "$reply" ]; then
        printf '%s' "$reply" | tmux load-buffer -
        tmux paste-buffer -t "$TUI_SESSION" -p
        sleep 0.3
    fi
    tmux send-keys -t "$TUI_SESSION" Enter

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

    log "Timeout after ${MAX_WAIT}s"
    _capture
    tmux clear-history -t "$TUI_SESSION" 2>/dev/null || true
    _stamp
    return 1
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
#   .poll-hash — last screen hash (for single-check poll mode)
#
# Designed for AI agents that want to run poll --wait in the background
# and get notified when the response arrives, freeing them to do other
# work in the meantime.
# ---------------------------------------------------------------------------

cmd_send_async() {
    local prompt="${1:?Usage: tui-driver $TUI_CMD send-async \"your prompt\"}"

    if ! tmux has-session -t "$TUI_SESSION" 2>/dev/null; then
        log "Error: no session running. Run 'tui-driver $TUI_CMD start' first."
        return 1
    fi

    # Only one async query per session at a time — the caller must poll
    # for the previous response before sending another.
    local async_file
    async_file=$(_async_file)
    if [ -f "$async_file" ]; then
        log "Error: a send-async is already pending. Run 'poll' or 'poll --wait' first."
        return 1
    fi

    _throttle

    # Send via bracketed paste (safe with !, ?, @, etc.)
    printf '%s' "$prompt" | tmux load-buffer -
    tmux paste-buffer -t "$TUI_SESSION" -p
    sleep 0.5
    tmux send-keys -t "$TUI_SESSION" Enter

    # Save prompt anchor and reset poll state for this session
    echo "$prompt" > "$async_file"
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
        log "Error: no session running."
        return 1
    fi

    local async_file poll_hash_file
    async_file=$(_async_file)
    poll_hash_file=$(_poll_hash_file)

    if [ ! -f "$async_file" ]; then
        log "Error: no pending send-async. Use 'send-async' first."
        return 1
    fi

    local prompt
    prompt=$(cat "$async_file")

    if [ "$wait_mode" = true ]; then
        # Blocking mode: reuse _wait_stable's poll loop, then extract.
        # Intended to be run via `Bash(run_in_background)` so the caller
        # gets notified when the response arrives.
        log "Waiting for screen to stabilise (poll --wait) ..."
        if _wait_stable; then
            log "Screen stabilised"
            _extract_response "$prompt"
            tmux clear-history -t "$TUI_SESSION" 2>/dev/null || true
            rm -f "$async_file" "$poll_hash_file"
            _stamp
            return 0
        fi

        log "Timeout after ${MAX_WAIT}s - returning what is on screen"
        _extract_response "$prompt"
        tmux clear-history -t "$TUI_SESSION" 2>/dev/null || true
        rm -f "$async_file" "$poll_hash_file"
        _stamp
        return 1
    fi

    # Non-blocking mode: compare current screen hash to the one saved
    # from the last poll call. If identical, the screen is stable — extract
    # and return the response. Otherwise, save the new hash and report
    # "waiting" (exit 1).
    local cur_hash prev_hash=""
    cur_hash=$(_screen_hash)

    if [ -f "$poll_hash_file" ]; then
        prev_hash=$(cat "$poll_hash_file")
    fi

    echo "$cur_hash" > "$poll_hash_file"

    if [ "$cur_hash" = "$prev_hash" ]; then
        log "Screen stable"
        _extract_response "$prompt"
        tmux clear-history -t "$TUI_SESSION" 2>/dev/null || true
        rm -f "$async_file" "$poll_hash_file"
        _stamp
        return 0
    fi

    # Still changing. Refresh the stamp so each poll counts as caller liveness.
    # Note: this only beats at the moments polls happen — a manual poller that
    # does more than TUI_WATCHDOG seconds of work *between* polls can still be
    # reaped (not polling is not demonstrable liveness). For long async waits,
    # prefer `poll --wait` in the background, which heartbeats continuously via
    # _wait_stable.
    _stamp
    log "Still waiting ..."
    echo "waiting"
    return 1
}

cmd_stop() {
    _stop_watchdog
    if tmux has-session -t "$TUI_SESSION" 2>/dev/null; then
        tmux kill-session -t "$TUI_SESSION"
        log "Session stopped"
    else
        log "No session to stop"
    fi
    rm -f "$(_stamp_file)" "$(_async_file)" "$(_poll_hash_file)"
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

# ---------------------------------------------------------------------------
# Orphan discovery and cleanup (global — across all dirs and commands).
#
# Every session tui-driver starts gets a per-session watchdog file
# (/tmp/.tui-driver-<session>.watchdog) holding the watchdog PID. That set of
# files is the authoritative registry of tui-driver-managed sessions — more
# reliable than matching tmux names, and it works for custom --session names.
#
# A session is an ORPHAN (safe to reap) only if BOTH hold:
#   * its watchdog process is dead (no auto-cleanup will ever run again), AND
#   * it has been idle longer than TUI_WATCHDOG seconds.
# A live parallel agent always has a live watchdog PID, so it is never reaped.
# ---------------------------------------------------------------------------

_watchdog_alive() {
    local pid="$1"
    [ -n "$pid" ] && [ "$pid" != "none" ] && kill -0 "$pid" 2>/dev/null
}

_iter_managed_sessions() {
    # Emit "session<TAB>watchdog_pid<TAB>idle_seconds<TAB>alive(0/1)" per line.
    # idle_seconds is -1 when no stamp exists.
    local wd session pid stamp last now idle alive
    now=$(date +%s)
    shopt -s nullglob
    for wd in /tmp/.tui-driver-*.watchdog; do
        session=${wd#/tmp/.tui-driver-}
        session=${session%.watchdog}
        pid=$(cat "$wd" 2>/dev/null || echo "none")
        [ -n "$pid" ] || pid="none"
        stamp="/tmp/.tui-driver-${session}.stamp"
        if [ -f "$stamp" ]; then
            last=$(cat "$stamp" 2>/dev/null || echo "$now")
            idle=$((now - last))
        else
            idle=-1
        fi
        if tmux has-session -t "$session" 2>/dev/null; then alive=1; else alive=0; fi
        printf '%s\t%s\t%s\t%s\n' "$session" "$pid" "$idle" "$alive"
    done
    shopt -u nullglob
}

_clear_session_state() {
    local session="$1"
    rm -f "/tmp/.tui-driver-${session}.stamp" \
          "/tmp/.tui-driver-${session}.watchdog" \
          "/tmp/.tui-driver-${session}.async" \
          "/tmp/.tui-driver-${session}.poll-hash"
    # Drop any cmd+dir lock that still points at this (dead) session.
    local lf
    shopt -s nullglob
    for lf in /tmp/.tui-driver-*.lock; do
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
    cp "$src" "$dst"
    chmod +x "$dst"
    # Bake the source tree's git stamp into the installed copy so `version`
    # reports the exact commit it was built from (the install dir is not a repo).
    stamp=$(_git_stamp "$srcdir" 2>/dev/null) || stamp=""
    if [ -n "$stamp" ]; then
        sed -i "s/^BUILD_STAMP=\"\"/BUILD_STAMP=\"${stamp}\"/" "$dst"
    fi
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
    poll)       cmd_poll "$*" ;;
    respond)    cmd_respond "$*" ;;
    stop)       cmd_stop ;;
    status)     cmd_status ;;
    raw)        cmd_raw ;;
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
  stop              Kill the session
  status            Print running / stopped
  raw               Raw screen capture (for debugging)
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
  --quiet, -q       Suppress stderr logs (saves tokens for agents)
  --version, -v     Print the tui-driver version

Environment (override any default):
  TUI_POLL          poll interval        (default: 2s)
  TUI_TIMEOUT       max wait             (default: 300s)
  TUI_STABLE        stable polls needed  (default: 2)
  TUI_MIN_INTERVAL  min gap between sends (default: 3s)
  TUI_JITTER        random 0..N jitter   (default: 2s)
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
  tui-driver agy poll            # returns "waiting" or the response
  tui-driver agy poll --wait     # blocks until response is ready
USAGE
        ;;
esac
