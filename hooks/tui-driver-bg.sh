#!/usr/bin/env bash
# PreToolUse(Bash) — force tui-driver's blocking actions into the background.
#
# `send`, `respond` (without --async) and `poll --wait` block for as long as the
# driven TUI takes to answer — minutes for an Antigravity web search. Run in the
# foreground they stall the turn and get killed by the Bash tool's own timeout.
# Instructions in SKILL.md are advisory; this hook is not: it rewrites the tool
# input so run_in_background is always true for those calls.
#
# Output contract: updatedInput only, NO permissionDecision. Claude Code applies
# updatedInput and then runs the normal permission flow (allow/ask/deny rules,
# the user's prompt) on the rewritten input. Returning "allow" here used to
# approve the WHOLE command line, so "tui-driver ... send x; curl ... | sh"
# skipped the permission prompt for the curl part too. Backgrounding needs no
# permission change.
set -uo pipefail
set -f          # the command string is tokenised by word splitting; never glob it

input=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# Already backgrounded, or nothing to do with tui-driver.
[ "$(jq -r '.tool_input.run_in_background // false' <<<"$input")" = "true" ] && exit 0
[[ "$cmd" == *tui-driver* ]] || exit 0

# True when a shell segment is a tui-driver invocation using a blocking action.
# The segment is parsed positionally (env assignments, binary, global flags,
# TUI command, action) rather than string-matched, so an action word appearing
# inside the prompt text cannot trigger a false positive.
is_blocking_seg() {
    local seg="$1" i=0
    # shellcheck disable=SC2206  # deliberate word splitting; globbing off via set -f
    local toks=($seg)
    local n=${#toks[@]}

    # Leading VAR=value environment assignments (TUI_TIMEOUT=600 ...).
    while [ "$i" -lt "$n" ] && [[ "${toks[$i]}" == *=* && "${toks[$i]}" != -* ]]; do
        i=$((i + 1))
    done
    [ "$i" -lt "$n" ] || return 1
    [[ "$(basename -- "${toks[$i]}")" == "tui-driver" ]] || return 1
    i=$((i + 1))

    # Global flags, some of which take a value.
    while [ "$i" -lt "$n" ] && [[ "${toks[$i]}" == -* ]]; do
        case "${toks[$i]}" in
            --session | --dir | --until) i=$((i + 2)) ;;
            *) i=$((i + 1)) ;;
        esac
    done

    i=$((i + 1))               # the TUI command token (agy-web, claude, ...)
    [ "$i" -lt "$n" ] || return 1
    local action="${toks[$i]}"
    local a1="${toks[$((i + 1))]:-}" a2="${toks[$((i + 2))]:-}"
    # respond: --async counts among the leading flags, or anywhere after
    # --key (every argument after --key is a key name or --async).
    local j has_async=false key_mode=false
    for (( j = i + 1; j < n; j++ )); do
        case "${toks[$j]}" in
            --async) has_async=true; break ;;
            --key) key_mode=true ;;
            *) [ "$key_mode" = true ] || break ;;
        esac
    done

    case "$action" in
        send) return 0 ;;
        poll) [[ "$a1" == --wait || "$a2" == --wait ]] && return 0 ;;
        respond) [ "$has_async" = true ] || return 0 ;;
    esac
    return 1
}

blocking=false
# shellcheck disable=SC2020  # deliberate: each of ; | & becomes a newline
while IFS= read -r seg; do
    [ -n "${seg// /}" ] || continue
    if is_blocking_seg "$seg"; then blocking=true; break; fi
done < <(printf '%s\n' "$cmd" | tr ';|&' '\n\n\n')

[ "$blocking" = true ] || exit 0

jq -nc --argjson ti "$(jq -c '.tool_input' <<<"$input")" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: "tui-driver blocking call auto-backgrounded (hook: tui-driver-bg). You will be notified when the response lands - keep working, do not poll for it.",
    updatedInput: ($ti + {run_in_background: true})
  }
}'
