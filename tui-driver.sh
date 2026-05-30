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

# ---------------------------------------------------------------------------
# Parse arguments: tui-driver [flags] <tui-command> <action> [args]
# ---------------------------------------------------------------------------

while [[ "${1:-}" == --* || "${1:-}" == -* ]]; do
    case "$1" in
        --session) TUI_SESSION="$2"; shift 2 ;;
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
    install|uninstall|version)
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
TUI_SESSION="${TUI_SESSION:-$(_default_session)}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    [[ "$QUIET" == "true" ]] && return
    printf '[tui-driver:%s] %s\n' "$TUI_SESSION" "$*" >&2
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

_start_watchdog() {
    # Background process that kills the tmux session if nobody has used it
    # for a while (meaning the caller likely died).  We track activity via
    # the stamp file: every send/respond updates it.  If no activity for
    # WATCHDOG_TIMEOUT seconds, assume the caller is gone and clean up.
    local session="$TUI_SESSION"
    local stamp lock watchdog
    stamp=$(_stamp_file)
    lock=$(_lock_file)
    watchdog=$(_watchdog_file)
    local timeout="${TUI_WATCHDOG:-600}"  # 10 minutes default

    # Seed the stamp so the watchdog has a starting point
    date +%s > "$stamp"

    (
        while true; do
            sleep 30
            # If session no longer exists, we're done
            if ! tmux has-session -t "$session" 2>/dev/null; then
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
                    rm -f "$stamp" "$lock" "$watchdog"
                    break
                fi
            else
                # No stamp file — caller probably died without stopping
                tmux kill-session -t "$session" 2>/dev/null || true
                rm -f "$lock" "$watchdog"
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

    sleep "$POLL_INTERVAL"
    elapsed=$POLL_INTERVAL

    while [ "$elapsed" -lt "$timeout" ]; do
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

    # Prevent starting if another tui-driver session exists (any TUI)
    local lock
    lock=$(_lock_file)
    if [ -f "$lock" ]; then
        local existing
        existing=$(cat "$lock")
        if tmux has-session -t "$existing" 2>/dev/null; then
            log "Error: another session '$existing' is already running."
            log "Run 'tui-driver $TUI_CMD stop' first."
            return 1
        fi
        rm -f "$lock"  # stale lock
    fi

    log "Creating tmux session '$TUI_SESSION' ..."
    tmux new-session -s "$TUI_SESSION" -d -x "$TERM_WIDTH" -y "$TERM_HEIGHT"
    tmux send-keys -t "$TUI_SESSION" "cd $(printf '%q' "$WORK_DIR") && $TUI_CMD" Enter
    echo "$TUI_SESSION" > "$lock"

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

    # Still changing
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
    rm -f "$(_stamp_file)" "$(_lock_file)" "$(_async_file)" "$(_poll_hash_file)"
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

INSTALL_DIR="${HOME}/.local/bin"
INSTALL_NAME="tui-driver"

cmd_version() {
    echo "tui-driver ${VERSION}"
}

cmd_install() {
    local src dst
    src="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    dst="${INSTALL_DIR}/${INSTALL_NAME}"
    mkdir -p "$INSTALL_DIR"
    cp "$src" "$dst"
    chmod +x "$dst"
    log "Installed to $dst"
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
  install           Copy to ~/.local/bin as 'tui-driver'
  uninstall         Remove from ~/.local/bin
  version           Print the tui-driver version

Flags:
  --session NAME    Override tmux session name (default: tui-<command>)
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
