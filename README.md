# tui-driver

Drive any interactive TUI programmatically via tmux. No profiles, no
pattern-matching, no TUI-specific code. One shell script that works with
**any** terminal application -- Antigravity CLI, Claude Code, aichat, btop,
you name it.

```
tui-driver agy start
response=$(tui-driver agy send "Summarise the LICENSE file")
echo "$response"
tui-driver agy stop
```

## Why AI agents?

tui-driver works for any TUI, but it was built for one use case in
particular: letting an **AI agent drive other AI CLIs as sub-agents**.
An agent such as Claude Code can use it to:

- **Fan out work in parallel.** Fire queries at several sessions with
  `send-async`, keep working, and collect results with `poll` — whose
  exit codes (0 = ready, 2 = still working, 3 = timed out but the query
  stays pending, 4 = the prompt never arrived) are designed to be loop conditions in a script.
- **Isolate context.** Delegate a large, self-contained sub-task to an
  independent CLI session with its own fresh context window, so the
  sub-task's output never bloats the orchestrating agent's context.
- **Cross-check across models and vendors.** Send the same question to
  `claude`, `agy`, `aichat`, ... side by side and compare answers — a
  cheap second opinion that no single-vendor API offers.
- **Monitor without interfering.** `progress` answers "is it still
  working?" read-only, any number of times, without consuming the
  pending response.
- **Survive crashes.** Every session has a watchdog that cleans up when
  its caller dies, and `list` / `reap` recover orphans — an agent that
  gets killed mid-task never leaks tmux sessions.

The [bundled skills](#bundled-skills-for-claude-code) package two of
these patterns ready-to-use for Claude Code, and the
[examples](#example-orchestrating-two-ai-tools-from-a-script) at the
bottom show the raw scripting patterns.

## How it works

1. **start** launches the TUI inside a tmux session.
2. **send** pastes your prompt, waits for the screen to stop changing,
   then returns everything that appeared after the prompt.
3. **stop** tears down the session and cleans up temp files.

The prompt itself is the only anchor needed to extract the response.
There is no regex to maintain, no list of known TUI prompts, and nothing
to update when a TUI changes its UI.

## Requirements

| Dependency | Why |
|------------|-----|
| **tmux** | Session management, screen capture |
| **bash** | Script runtime |
| **python3** | Response extraction (small inline script) |

All three are available on every major Linux distro and macOS.

```bash
# Debian / Ubuntu
sudo apt install tmux python3

# macOS
brew install tmux python3
```

## Installation

```bash
# Option 1: install to ~/.local/bin
./tui-driver.sh install

# Option 2: just run it directly
chmod +x tui-driver.sh
./tui-driver.sh agy start
```

After `install`, make sure `~/.local/bin` is in your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Uninstall with:

```bash
tui-driver uninstall
```

## Quick start

### Basic session

```bash
tui-driver agy start
tui-driver agy send "What is the mass of the Sun?"
tui-driver agy stop
```

### Multiple TUIs at once

Each TUI command gets its own tmux session, so you can run them in
parallel:

```bash
tui-driver agy start
tui-driver claude start

agy_answer=$(tui-driver agy send "Explain quantum tunnelling")
claude_answer=$(tui-driver claude send "Explain quantum tunnelling")

echo "=== Antigravity ==="
echo "$agy_answer"
echo "=== Claude ==="
echo "$claude_answer"

tui-driver agy stop
tui-driver claude stop
```

### Replying to confirmation dialogs

There are two kinds of dialog, and they need different replies.

**Line prompts** (e.g. "Apply changes? [y/n]" read as a line): `respond`
types the reply and presses Enter.

```bash
tui-driver aichat send "Refactor this function"
tui-driver aichat respond "y"
tui-driver aichat respond ""      # just press Enter
```

**Menus that act on a keypress** (the tool-approval menus of `claude` and
`agy`: "1. Yes … 4. No"): use `respond --key`, which sends tmux key names
and **no Enter**:

```bash
tui-driver claude respond --key 1        # approve (option 1)
tui-driver claude respond --key Escape   # deny / cancel
tui-driver agy respond --key 4           # agy: "4. No, cancel"
```

Why it matters: these menus ignore pasted text, and an Enter after a
keypress lands on whatever appears next. When a model issues two tool calls
at once, `claude` shows the second approval immediately, so a reply with an
Enter after it would approve that second call unseen. (Before 0.4.0,
`respond "n"` pasted the "n" and pressed Enter, which **approved** the
command.) Read the menu first and pick the number it shows.

`respond` blocks and prints the resulting screen itself. When the dialog
interrupted an **async** query, add `--async`: it replies, returns
immediately, and re-arms the pending query so a follow-up `poll` /
`poll --wait` retrieves the real response:

```bash
tui-driver agy send-async "Fetch https://example.com and summarise"
tui-driver agy poll                      # → returns the approval dialog text
tui-driver agy respond --async --key 1   # approve
tui-driver agy poll --wait               # → the actual response
```

### Working directory

Tell the TUI which directory to start in:

```bash
tui-driver --dir /path/to/project agy start
tui-driver --dir /path/to/project agy send "Explain the code in main.py"
tui-driver --dir /path/to/project agy stop
```

Pass the same `--dir` on **every** call (or run every call from that
directory): a default session is found by command + directory, and the
directory defaults to the current one, so a `send` without `--dir` looks
for a different session. With `--session NAME` the directory only matters
for `start`.

Or via environment variable:

```bash
export TUI_DIR=/path/to/project
tui-driver agy start
tui-driver agy send "Explain the code in main.py"
```

The command must be a real program on your `PATH` (or a path to one), not
a shell alias or function: the pane's shell is replaced by tui-driver's
supervisor before the command runs. To pass flags, put them in a small
wrapper script (see the `agy-web` example under Bundled skills).

### Attaching to an existing tmux session

tui-driver only speaks tmux — it cannot drive a plain xterm, gnome-terminal,
or GNU screen session. If you want to attach to a TUI you started yourself
(for example, to inspect it interactively while a script also drives it),
launch it inside a named tmux session first:

```bash
# Start the TUI inside a named, detached tmux session
tmux new-session -d -s mysession agy

# Attach interactively any time with:
#   tmux attach -t mysession

# Point tui-driver at that same session via --session
tui-driver --session mysession agy send "Hello"
```

Notes:

- Skip `tui-driver ... start` — the session already exists. Go straight to
  `send` / `respond` / `poll`.
- The TUI command passed to tui-driver (`agy` above) is only used as a
  label; the actual process is whatever you launched in the tmux session.
- `stop` will kill the session you attached to, so use plain `tmux kill-session
  -t mysession` (or just detach) if you want to keep it alive.
- If that session keeps dead panes (`remain-on-exit on`), tui-driver will not
  paste into one: on tmux 3.2a pasting into a dead pane crashes the tmux server
  and every session on it. Sessions started by tui-driver force it off.

### Multiple agents in parallel (same command, same directory)

By default, a session is keyed on the **TUI command + working directory**: a
`start` records a lock so that later `send`/`stop` calls — even from a separate
process — rediscover the same session without you passing a name around. The
flip side is that two callers driving the same command from the same directory
would otherwise share one session (the second `start` errors, and a blind
`send` lands in the first caller's session).

When you need genuinely independent sessions — e.g. several AI agents each
driving `agy` in the same repo — give each one its own `--session NAME`. That
bypasses the lock entirely:

```bash
# Agent 1
tui-driver --session agent1 agy start
tui-driver --session agent1 agy send "Summarise file A"
tui-driver --session agent1 agy stop

# Agent 2 — same directory, fully independent, runs concurrently
tui-driver --session agent2 agy start
tui-driver --session agent2 agy send "Summarise file B"
tui-driver --session agent2 agy stop
```

Each named session keeps its own state and watchdog; they never collide.
Names may use only letters, digits, `_` and `-` (tmux rewrites `.` and `:`),
and are matched exactly: `--session p1` never touches a session called `p10`
(before 0.4.0 it did, by tmux prefix matching).

> **Requires 0.3.1 or newer.** Up to 0.3.0 every send pasted through tmux's
> *unnamed* buffer, which is a server-wide stack. Two sessions sending at the
> same instant could race, and a pane could receive the other session's prompt —
> silently, producing a confident answer to a question you never asked. Sends now
> use a buffer named after the session. Check with `tui-driver --version`.

### Listing and reaping sessions

Every session tui-driver starts is watched by a background watchdog that
auto-kills it after `TUI_WATCHDOG` seconds of inactivity (in case the caller
dies). If a watchdog itself dies (reboot, OOM, kill), its session can be left
orphaned. `list` and `reap` handle discovery and cleanup across **all**
directories and commands:

```bash
tui-driver list   # show every session, its watchdog state, idle time, status
tui-driver reap   # kill true orphans and clear any leaked state files
```

`reap` is conservative and safe to run while other agents are working: it only
kills a session when its watchdog process is **dead** *and* it has been idle
longer than `TUI_WATCHDOG`. A live agent always has a live watchdog, so it is
never touched — anything skipped is logged.

### When the TUI exits or crashes

If the TUI ends on its own — a clean `/exit` or `/quit`, a crash, a
`kill -9`, a command that was never found — tui-driver keeps its **last
screen** (scrollback included) and its exit status, and the session ends.
Nothing is left behind to read a prompt. Before 0.4.0 the pane fell back to
a shell and the next `send` **ran the prompt as a shell command**.

Every later call says so, on stderr even with `-q`, and exits 1:

```
$ tui-driver claude send "hello"
[tui-driver:tui-claude-123] Error: 'claude' exited (status 137); the session is gone.
[tui-driver:tui-claude-123] Its last screen was saved. Read it with: tui-driver --session tui-claude-123 claude raw
[tui-driver:tui-claude-123]   (or the file /run/user/1000/tui-driver/tui-claude-123.screen). Run 'start' to launch it again.
```

- `status` prints `exited`; `progress` prints `session=exited`,
  `exit_status=N` and `last_screen=FILE`; `list` shows `EXITED`.
- `raw` prints the saved screen. A blocking `send` / `poll --wait` that was
  waiting returns 1 the same way and drops the pending query.
- What the screen holds depends on the TUI: after `kill -9` or a crash it
  is the TUI's last UI; on a clean `/exit`, `claude` clears its UI and leaves
  a `claude --resume <id>` line, which is saved.
- The record (`<session>.exit` and `.screen` in the state dir) is kept after
  `stop`, replaced by the next `start` of the same session, and cleared by
  `reap` after a day. A `stop` of a live session leaves none.

### Quiet mode (for AI agents)

Suppress stderr logs to save tokens when an AI agent is the caller:

```bash
tui-driver -q agy start
tui-driver -q agy send "Hello"
```

### Non-blocking (async) usage

For AI agents that need to fire a query and do other work while waiting:

```bash
# Fire the prompt and return immediately
tui-driver agy send-async "Analyse all files in this repo"

# Do other work ...

# Check back (non-blocking): exits 0 if ready, 2 if still working
if tui-driver agy poll; then
    echo "Response is ready (printed to stdout above)"
else
    echo "Still thinking..."
fi

# Or block until the response arrives
tui-driver agy poll --wait
```

Only one async query can be pending per session. Call `poll` to retrieve
the response before sending another `send-async`.

To check on a pending query **without** retrieving it, use `progress` —
it is read-only and safe to run any number of times:

```bash
$ tui-driver agy progress
session=running
pending=yes
sent_ago=42s
prompt=Analyse all files in this repo
screen=changing
last_lines:
... last three non-empty screen lines ...
```

If a blocking call times out (exit 3), the query is **not** lost: it stays
pending, and the scrollback is preserved. Poll again for the rest, raise
`TUI_TIMEOUT`, or drop it explicitly:

```bash
tui-driver agy cancel   # clears the pending record; session keeps running
```

### Tuning timing parameters

All timing is configurable via environment variables:

```bash
# Fast-responding TUI: poll every second, require 1 stable check
TUI_POLL=1 TUI_STABLE=1 tui-driver agy send "Hi"

# Slow API behind the TUI: wait up to 10 minutes
TUI_TIMEOUT=600 tui-driver claude send "Write a long essay"

# Cautious rate limiting: 10s minimum gap + up to 5s jitter
TUI_MIN_INTERVAL=10 TUI_JITTER=5 tui-driver agy send "Query 1"
```

**Exact completion with a marker (`--until`).** Screen stability is a
heuristic: it adds a `TUI_POLL × TUI_STABLE` latency tail, and a TUI whose
screen never settles (spinners, clocks) or that pauses mid-response can
fool it. When you control the prompt — always true with AI TUIs — you can
opt into exact completion instead: instruct the TUI to end with a marker
and pass `--until REGEX` (or `TUI_DONE_PATTERN`). The response is returned
the moment the marker appears in it, no stability tail — and **only** then:
with `--until`, a still screen never ends the wait (before 0.5.0 it did, so
a TUI sitting on a long build or git hook was reported finished, exit 0):

```bash
tui-driver --until 'DONE!!!' agy send \
  "Summarise the README. End your reply with the word DONE and three exclamation marks."
```

Word the instruction so the literal marker is **not** in your prompt
(describe it, as above). If it is spelled out anyway, tui-driver requires
the marker to appear more times on screen than in the prompt, so the echo
alone cannot end the wait.

The flip side of a strict marker: an approval dialog, or a TUI that never
prints the marker, holds the wait until `TUI_TIMEOUT` (exit 3, query kept
pending). On long waits, check with `progress`; answer a dialog with
`respond --async --key ...` and poll again.

**Delivery check (exit 4).** `send` and `send-async` confirm that the prompt
reached the TUI: after Enter, a line holding the prompt's first line must
show up on screen more often than it did before the paste (compared line by
line, after letting the screen settle) within `TUI_DELIVER_WAIT` seconds. If a dialog
or overlay swallowed it, they fail with **exit 4** and print the screen;
nothing is left pending. `poll` also returns 4 for a pending prompt that was
never seen arriving and is not on screen. (A prompt that *was* seen arriving
and later scrolled away — full-screen TUIs do that on long answers — is
fine: `poll` returns the whole screen with a warning, exit 0.) The check
proves the text landed, not that the TUI accepted the Enter.

**Overlays at startup.** Some TUIs draw notices over the input box that eat
the next keystrokes — agy shows "... esc to dismiss" banners after an
update. `start` (and every send) presses `TUI_DISMISS_KEY` (Escape) while
`TUI_DISMISS_PATTERN` matches the bottom of the visible screen, up to
`TUI_DISMISS_TRIES` times, logging each press, and `start` fails (exit 1)
if one is still there. The default pattern is `esc to dismiss|esc Close` (the
startup notices and agy's `?` shortcuts screen) for commands
named `agy*` and none for anything else: in `claude`, Escape at the prompt is
not harmless, and its trust dialog is a decision to make, not a notice to
click away. Set `TUI_DISMISS_PATTERN=''` to turn it off.

**`TUI_TIMEOUT` vs `TUI_WATCHDOG`.** These bound two different things and do
not interfere:

- `TUI_TIMEOUT` bounds a **single response** — how long one `send` /
  `poll --wait` will wait for the screen to stabilise.
- `TUI_WATCHDOG` bounds **caller absence** — how long a session may sit with no
  caller activity before it is auto-reaped (in case the caller died).

While a blocking call is waiting, its poll loop heartbeats the activity stamp,
so the watchdog never reaps a session mid-response — even when a single response
takes longer than `TUI_WATCHDOG`. You can therefore set `TUI_TIMEOUT` well above
`TUI_WATCHDOG` safely. The one case the heartbeat can't cover is non-blocking
`poll`: it only refreshes liveness at the moment each poll runs, so a caller
using `send-async` + manual `poll` should poll more often than `TUI_WATCHDOG`
(or use `poll --wait` in the background, which heartbeats continuously).

### Debugging

Grab the raw screen capture (no extraction, no waiting):

```bash
tui-driver agy raw
```

Check whether a session is running:

```bash
tui-driver agy status   # prints "running", "exited" or "stopped"
```

## Bundled skills (for Claude Code)

The `skills/` directory ships ready-to-use [Claude Code](https://claude.com/claude-code)
skills that drive a TUI through `tui-driver`. Drop one into your project's (or
`~/.claude/`) `skills/` directory and Claude Code will load it automatically.

- **`antigravity-web`** — web search, URL fetching, and online-document reading
  via an Antigravity CLI (`agy`) session: grounded Google Search with
  citations, JavaScript-rendered pages, and PDF/datasheet extraction that the
  built-in fetch can't handle. Last resort only: try the built-in WebSearch/WebFetch first.
  **Needs a one-line wrapper on your PATH** that pins the model — `tui-driver`
  launches the bare command token and can't forward flags to it:

  ```bash
  printf '#!/usr/bin/env bash\nexec agy --model gemini-3.8-flash-high --effort high "$@"\n' \
      > ~/.local/bin/agy-web && chmod +x ~/.local/bin/agy-web
  ```
- **`claude-delegate`** — hand a self-contained task to an *independent*
  `claude` CLI session (its own fresh context window) and collect the result:
  for isolated sub-tasks you don't want bloating your own context, genuinely
  parallel fire-and-poll work, or a second opinion. Runs under the same login
  and usage pool as your current session — not a separate bill.

Both follow the same `send-async` + `poll --wait` (in background) pattern
described above and include session-recovery steps. See each
`skills/<name>/SKILL.md` for full usage.

### Keeping the agent from blocking on you (`hooks/tui-driver-bg.sh`)

A skill can *tell* an agent to background its calls; it cannot make it. When the
agent runs `poll --wait` in the foreground it stalls its own turn and Claude
Code kills the call at its two-minute tool timeout — the query survives (it stays
pending), but the turn is wasted.

`hooks/tui-driver-bg.sh` is a Claude Code `PreToolUse` hook that removes the
choice: it parses the Bash command, and if it is a tui-driver invocation using a
blocking action (`send`, `respond` without `--async` or `--key`, or `poll --wait`) that is
not already backgrounded, it rewrites the tool input to set
`run_in_background: true`. It grants no permission: Claude Code applies the
rewritten input and then runs its normal permission flow (your rules, your
prompt) on it, exactly as if the hook were absent. (Before 0.4.0 it answered
"allow", which also approved anything chained after the tui-driver call.)
Non-blocking actions, other people's commands, and
prompts that merely contain the word "send" are left alone — `hooks/test-hook.sh`
covers those cases.

```bash
install -m 755 hooks/tui-driver-bg.sh ~/.claude/hooks/tui-driver-bg.sh
```

then in `~/.claude/settings.json`:

```json
"hooks": {
  "PreToolUse": [
    {
      "matcher": "Bash",
      "hooks": [{ "type": "command", "command": "~/.claude/hooks/tui-driver-bg.sh" }]
    }
  ]
}
```

Hooks are snapshotted at startup, so restart Claude Code afterwards.

## Full API reference

### Actions

| Action | Description | Blocking | Exit code |
|--------|-------------|----------|-----------|
| `start` | Launch TUI in tmux, wait for it to be ready, dismiss startup overlays | Yes | 0 = ready, 1 = error / overlay stuck, 3 = timeout |
| `send "prompt"` | Send prompt, confirm delivery, wait for a non-empty response | Yes | 0 = ready, 3 = timeout (query stays pending), 4 = not delivered |
| `send-async "prompt"` | Send prompt, confirm delivery (≤ `TUI_DELIVER_WAIT`s), return | Brief | 0 = sent, 1 = error, 4 = not delivered |
| `poll` | Self-contained stability probe (~`TUI_STABLE`×`TUI_POLL`s): returns the full response if ready, else `waiting` | Brief | 0 = ready, 2 = still changing, 4 = not delivered |
| `poll --wait` | Block until async response is ready | Yes | 0 = ready, 3 = timeout (query stays pending), 4 = not delivered |
| `progress` | Read-only check on a pending query: pending?, elapsed, screen changing?, last lines. Never consumes anything | ~1s | 0, 1 = no session |
| `respond "reply"` | Type a short reply + Enter (line prompts; `""` = just Enter), print resulting screen | Yes | 0 = stable, 3 = timeout |
| `respond --key K [K...]` | Send tmux key names (`1`, `4`, `Escape`, `Down`, `C-c`, ...) with **no** Enter — for menus that act on a keypress. Prints the screen one `TUI_POLL` later (no stability wait) | Brief | 0 |
| `respond --async [--key] ...` | Same reply, return at once and re-arm the pending query for `poll` | No | 0 = sent, 1 = error |
| `cancel` | Drop a pending async query (session keeps running) | No | 0 |
| `stop` | Kill session and clean up | No | 0 |
| `status` | Print `running`, `exited` (the TUI ended on its own; see `raw`) or `stopped` | No | 0 |
| `raw` | Dump raw screen content; after the TUI exited, its saved last screen | No | 0 |
| `list` | List all tui-driver sessions (any dir/command) and their status | No | 0 |
| `reap` | Kill orphaned sessions and clear leaked state (see below) | No | 0 |
| `install` | Copy to `~/.local/bin` | No | 0 |
| `uninstall` | Remove from `~/.local/bin` | No | 0 |
| `version` | Print the tui-driver version (includes a git build stamp when run from a checkout) | No | 0 |

Exit code 1 always means a hard error (no session, the TUI exited, no
pending async, bad usage) and is explained on stderr — even under `--quiet`. Code 2 means
"not ready yet, ask again"; code 3 means "timed out" (for `send`/`poll
--wait` the query stays pending and can still be retrieved). Code 4 means
"the prompt was not delivered": a dialog or overlay took it, the screen is
printed, nothing is pending; dismiss it and send again.

`list` and `reap` are global — they operate across every working directory
and TUI command, so you can inspect or clean up sessions you started from
elsewhere (or that were orphaned when a caller died).

### Flags

| Flag | Description |
|------|-------------|
| `--session NAME` | Run an independent named session. Bypasses the per-directory lock, so multiple agents can drive the same command from the same directory in parallel (see below). Pass the same NAME to every `send`/`respond`/`poll`/`stop`. |
| `--dir DIR` | Set the working directory for the TUI process |
| `--until REGEX` | The response is complete when REGEX appears in it, and only then — screen stability no longer counts (see "Exact completion with a marker") |
| `--quiet`, `-q` | Suppress stderr progress logs (errors are always shown) |
| `--version`, `-v` | Print the tui-driver version |

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TUI_POLL` | `2` | Seconds between screen-hash checks |
| `TUI_TIMEOUT` | `300` | Max seconds to wait for stabilisation |
| `TUI_STABLE` | `2` | Consecutive identical hashes needed |
| `TUI_MIN_INTERVAL` | `3` | Minimum seconds between sends |
| `TUI_JITTER` | `2` | Random 0..N seconds added to rate limit |
| `TUI_DIR` | `$(pwd)` | Working directory |
| `TUI_WIDTH` | `200` | Terminal width in columns |
| `TUI_HEIGHT` | `50` | Terminal height in rows |
| `TUI_WATCHDOG` | `600` | Seconds of inactivity before auto-cleanup |
| `TUI_QUIET` | `false` | Suppress progress logs (same as `--quiet`) |
| `TUI_PASTE_DELAY` | `0.5` | Pause between pasting the prompt and pressing Enter |
| `TUI_START_TIMEOUT` | `60` | Max seconds to wait for the TUI at startup |
| `TUI_HEARTBEAT` | `15` | "still waiting" log line every N seconds while blocked (0 = off) |
| `TUI_DONE_PATTERN` | unset | Completion regex, same as `--until` |
| `TUI_DELIVER_WAIT` | `10` | Max seconds for a sent prompt to appear on screen before exit 4 (0 = don't check at send time) |
| `TUI_DISMISS_PATTERN` | `esc to dismiss\|esc Close` for `agy*`, else unset | Regex of an input-eating overlay to dismiss at start and before each send (`''` = off) |
| `TUI_DISMISS_KEY` | `Escape` | Key that dismisses it |
| `TUI_DISMISS_TRIES` | `5` | Max presses per check |

## Design decisions

### The prompt is the only anchor

Most TUI automation tools rely on recognising the TUI's own prompt
character (like `>` or `$`), or on regex patterns that match specific
output formats. This is fragile: every TUI looks different, updates
break patterns, and you end up maintaining a library of profiles.

tui-driver takes a different approach. When you call `send "What is
recursion?"`, the tool:

1. Pastes "What is recursion?" into the TUI.
2. Waits for the screen to stop changing.
3. Searches the screen capture for the **last line containing your
   prompt text**.
4. Returns everything after that line.

Your prompt is the delimiter. No regex. No profiles. This works with any
TUI that echoes input -- which is virtually all of them.

A multi-line prompt is echoed line by line, so after the anchor the
response also skips past the echo of the prompt's last line. If the prompt
is not on screen at all (a dialog took it — e.g. a startup trust prompt),
the whole screen is returned and a warning is printed on stderr.

### Screen stabilisation, not parsing

How do you know the TUI is done responding? You don't parse its output.
You don't look for a cursor. You watch the screen as a bitmap:

- Every `TUI_POLL` seconds, compute an MD5 hash of the screen capture.
- If the hash matches the previous one, increment a "stable" counter.
- When the counter reaches `TUI_STABLE`, the screen hasn't changed and
  the response is complete.

This is deliberately simple. It works whether the TUI streams tokens one
at a time, renders markdown, draws progress bars, or does anything else.
The cost is latency: you always wait at least `TUI_POLL * TUI_STABLE`
seconds after the last change. The default (2s poll, 2 stable = 4s
extra) is a good tradeoff for most interactive AI tools.

Two guards keep the heuristic honest. A stable screen with an **empty**
extracted response is not accepted — a TUI that has not started printing
yet (backend call, thinking pause) also has a stable screen, and returning
early there is how partial/empty answers happen. And when even that is not
enough — screens that never settle, long mid-response pauses — `--until`
(above) replaces the heuristic with an exact completion marker.

### Exact tmux targets

tmux resolves `-t NAME` by exact name, then by prefix, then by glob. Every
tmux call in tui-driver therefore uses `=NAME` (session) or `=NAME:` (pane),
which only ever matches exactly. Without it, with `p10` running, a call for
`p1` was answered by `p10` and `stop` killed it.

### The pane supervisor

`start` does not type the TUI command into the pane's shell. It types
`exec tui-driver __run SESSION DIR CMD`: the shell (which has already read
your rc files, so `PATH` and exported variables are as usual) is replaced by
a few lines of tui-driver that run the TUI as their child. When the TUI
exits on its own, they save the pane and the exit status and exit, which
closes the session. This is what guarantees that a prompt is never read by
a shell, and what keeps the last screen (see "When the TUI exits or
crashes").

tmux's `remain-on-exit` (keep the dead pane readable) looks simpler and was
rejected: on tmux 3.2a, `paste-buffer` into a dead pane crashes the tmux
server, and a paste racing the TUI's exit cannot be ruled out.

### One tmux paste buffer per session

Input is delivered with `load-buffer` + `paste-buffer -p` (bracketed paste) rather
than `send-keys`, so a prompt containing `!`, `?`, `@`, quotes or newlines reaches
the TUI verbatim instead of being interpreted as keystrokes.

The subtlety is *which* buffer. Up to 0.3.0 these calls used tmux's unnamed
buffer, which is not per-session or per-process — it is a stack shared by the
whole tmux server. Two drivers pasting at the same instant interleave: A loads,
B loads, A pastes and gets B's text. With parallel `--session` sessions that
surfaced as one session answering another session's question, and because the
answer was fluent and well-formed there was nothing to alert the caller. Sends
now use a buffer named after the session and delete it on paste (`-b "$SESSION"
… -d`), which makes concurrent sends independent.

The lesson generalises: anything tui-driver touches outside its own tmux session
is shared state, and parallel sessions are a supported use case.

### Robustness over clean output

The screen capture includes whatever the TUI drew: ANSI formatting
artefacts, line-wrapping, status bars. tui-driver does **not** attempt
to strip these. Why?

- Stripping is heuristic-based and breaks across TUIs.
- AI agents (the primary consumer) handle messy text just fine.
- A wrong strip (eating part of a code block, for example) is worse
  than a little noise.

If you need clean output, pipe through a post-processor of your choice.
The raw capture is always available via `raw`.

### Random session names

Session names look like `tui-agy-1038314688` instead of a
predictable `tui-agy` (characters tmux would rewrite — `.`, `:`, `/`,
spaces — become `_`, so `./my.sh` gets `tui-__my_sh-…`). This avoids accidental collisions when
multiple callers share the same TUI command, and makes it harder for
unrelated processes to stumble onto the wrong session.

The mapping from (command + working directory) to session name is stored
in a lock file under `${XDG_RUNTIME_DIR:-~/.cache}/tui-driver/` — a
user-private (0700) directory, which keeps other local users away from the
session state and keeps `/tmp` cleaners from deleting a live session's
liveness stamp. This means:

- The **same caller** (same command, same directory) reconnects to its
  existing session automatically.
- A **different caller** (different working directory) hashes to a
  different lock file and gets its own session.

Note: `$RANDOM` is not a cryptographic RNG — treat this as collision
avoidance, not a security boundary. Sessions started by a pre-0.3 version
kept their state under `/tmp`; `list` and `reap` still scan that legacy
layout, but drive such sessions with the old binary or reap them.

### Watchdog stdio (programmatic callers)

The background watchdog spawned by `start` redirects its own stdin/stdout/stderr
to `/dev/null`. This matters for callers that **capture** tui-driver's output:
Node's `child_process.execFile`, for example, resolves only when the stdout/stderr
pipes reach EOF, not merely when the process exits. If the watchdog inherited
those pipes it would hold them open for its whole lifetime (up to
`TUI_WATCHDOG`), so `start` would appear to hang for minutes even though it
finished in seconds. `disown` alone does not close inherited fds — the explicit
redirect does.

### Watchdog for orphaned sessions

If the calling process dies without running `stop`, the tmux session
would linger forever. tui-driver spawns a background watchdog that
monitors a timestamp file:

- Every `send`, `respond`, `poll`, or `progress` updates the timestamp — and
  while a blocking call is *waiting* for a response, its poll loop keeps
  refreshing the timestamp too, so a long-running response is never mistaken
  for a dead caller (`TUI_TIMEOUT` bounds a single response; `TUI_WATCHDOG`
  bounds caller absence).
- The watchdog checks every 30 seconds.
- If no activity for `TUI_WATCHDOG` seconds (default: 10 minutes), it
  kills the session and removes all temp files.

This is essential for agent workflows where crashes are expected.

If a watchdog itself dies (reboot, OOM, kill), its session can be orphaned.
`tui-driver list` shows every session and its state across all directories, and
`tui-driver reap` cleans up orphans — but only sessions whose watchdog is dead
**and** which have been idle past `TUI_WATCHDOG`, so live agents are never
touched.

### Bracketed paste

Input is sent using
[bracketed paste mode](https://en.wikipedia.org/wiki/Bracketed-paste)
via tmux's `paste-buffer -p` flag, which wraps the pasted text in
`\033[200~`...`\033[201~` escape sequences. This prevents the shell or
TUI from interpreting special characters (`!`, `?`, `@`, history
expansion triggers) in your prompt.

### Rate limiting with jitter

A configurable minimum interval (`TUI_MIN_INTERVAL`) plus random jitter
(`TUI_JITTER`) is enforced between sends. This prevents overwhelming
the TUI with rapid-fire queries, which can cause dropped input or
confused state in some applications.

### Async for agent parallelism

The `send-async` / `poll` pair exists specifically for AI agent
workflows:

- `send-async` fires the prompt and returns immediately, so the agent
  can schedule other work.
- `poll` does a self-contained stability probe: within the single call it
  samples the screen a few times (`TUI_STABLE` samples, `TUI_POLL` apart) and
  returns the full response the moment the screen is stable, or `waiting` if
  it's still changing. One call is enough — you never need a priming poll, and
  retrieving the response is what clears the pending lock.
- `poll --wait` blocks until the response is ready, intended to run in
  the background so the agent gets notified on completion.
- `progress` answers "is it still working?" without touching the pending
  query — elapsed time, screen activity, last screen lines.

Only one async query is allowed per session at a time to prevent
ambiguous state. A timeout never discards the query: it stays pending
until retrieved by a poll or dropped with `cancel`.

## Example: orchestrating two AI tools from a script

```bash
#!/usr/bin/env bash
set -euo pipefail

# Start both
tui-driver -q agy start
tui-driver -q claude start

# Ask both the same question (async)
tui-driver -q agy send-async "List 5 uses of Fourier transforms"
tui-driver -q claude send-async "List 5 uses of Fourier transforms"

# Wait for both
agy_response=$(tui-driver -q agy poll --wait)
claude_response=$(tui-driver -q claude poll --wait)

echo "=== Antigravity ==="
echo "$agy_response"
echo ""
echo "=== Claude ==="
echo "$claude_response"

# Clean up
tui-driver agy stop
tui-driver claude stop
```

## Example: agent loop with polling

```bash
#!/usr/bin/env bash
set -euo pipefail

tui-driver -q agy start
tui-driver -q agy send-async "Write a detailed analysis of merge sort"

# Poll every 5 seconds, do other work in between.
# Exit 2 = still working; anything else (0 = ready, 1 = session died,
# 3 = timeout) ends the loop instead of spinning forever.
while tui-driver -q agy poll; rc=$?; [ "$rc" -eq 2 ]; do
    echo "Still waiting... doing other work"
    sleep 5
done

# Response was printed to stdout by the successful poll
tui-driver agy stop
```

## Testing

The repo ships a self-contained smoke test that exercises the full
lifecycle (start/send/async/poll/dialog/`--until`/timeout/cleanup, plus
exact session names, TUI exit and crash handling, keypress menus and
multi-line prompts)
against tiny synthetic TUIs — no AI CLI needed, just tmux and python3:

```bash
./test/smoke.sh                  # test the repo script
TD=tui-driver ./test/smoke.sh    # test an installed copy
```

It uses throwaway `--session` names only, so it is safe to run while
real sessions are active.

The Claude Code hook has its own test, which needs neither tmux nor a TUI — it
feeds sample `PreToolUse` payloads to the hook and asserts which ones get
rewritten to run in the background:

```bash
./hooks/test-hook.sh
```

Both suites are shellcheck-clean; `./test/smoke.sh` runs shellcheck over
`tui-driver.sh` as its last case.

## License

Copyright 2026 Ricardo de Azambuja

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

> <http://www.apache.org/licenses/LICENSE-2.0>

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
