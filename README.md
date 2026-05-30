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

Some TUIs ask follow-up questions (e.g. "Apply changes? [y/n]"). Use
`respond` for these:

```bash
tui-driver aichat send "Refactor this function"
tui-driver aichat respond "y"
```

Pass an empty string to just press Enter:

```bash
tui-driver aichat respond ""
```

### Working directory

Tell the TUI which directory to start in:

```bash
tui-driver --dir /path/to/project agy start
tui-driver agy send "Explain the code in main.py"
```

Or via environment variable:

```bash
TUI_DIR=/path/to/project tui-driver agy start
```

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

# Check back (non-blocking): exits 0 if ready, 1 if still working
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

### Debugging

Grab the raw screen capture (no extraction, no waiting):

```bash
tui-driver agy raw
```

Check whether a session is running:

```bash
tui-driver agy status   # prints "running" or "stopped"
```

## Full API reference

### Actions

| Action | Description | Blocking | Exit code |
|--------|-------------|----------|-----------|
| `start` | Launch TUI in tmux, wait for it to be ready | Yes | 0 = ready, 1 = timeout |
| `send "prompt"` | Send prompt, wait for response | Yes | 0 = stable, 1 = timeout |
| `send-async "prompt"` | Send prompt, return immediately | No | 0 = sent, 1 = error |
| `poll` | Single check: is the async response ready? | No | 0 = ready, 1 = still changing |
| `poll --wait` | Block until async response is ready | Yes | 0 = stable, 1 = timeout |
| `respond "reply"` | Send a short reply (e.g. `y`, `n`, `""`) | Yes | 0 = stable, 1 = timeout |
| `stop` | Kill session and clean up | No | 0 |
| `status` | Print `running` or `stopped` | No | 0 |
| `raw` | Dump raw screen content | No | 0 |
| `list` | List all tui-driver sessions (any dir/command) and their status | No | 0 |
| `reap` | Kill orphaned sessions and clear leaked state (see below) | No | 0 |
| `install` | Copy to `~/.local/bin` | No | 0 |
| `uninstall` | Remove from `~/.local/bin` | No | 0 |

`list` and `reap` are global — they operate across every working directory
and TUI command, so you can inspect or clean up sessions you started from
elsewhere (or that were orphaned when a caller died).

### Flags

| Flag | Description |
|------|-------------|
| `--session NAME` | Run an independent named session. Bypasses the per-directory lock, so multiple agents can drive the same command from the same directory in parallel (see below). Pass the same NAME to every `send`/`respond`/`poll`/`stop`. |
| `--dir DIR` | Set the working directory for the TUI process |
| `--quiet`, `-q` | Suppress stderr logs |

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
| `TUI_QUIET` | `false` | Suppress logs (same as `--quiet`) |

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
predictable `tui-agy`. This avoids accidental collisions when
multiple callers share the same TUI command, and makes it harder for
unrelated processes to stumble onto the wrong session.

The mapping from (command + working directory) to session name is stored
in a lock file under `/tmp`. This means:

- The **same caller** (same command, same directory) reconnects to its
  existing session automatically.
- A **different caller** (different working directory) hashes to a
  different lock file and gets its own session.

Note: `$RANDOM` is not a cryptographic RNG — treat this as collision
avoidance, not a security boundary. If two principals share a
filesystem, they can read each other's `/tmp` lock files.

### Watchdog for orphaned sessions

If the calling process dies without running `stop`, the tmux session
would linger forever. tui-driver spawns a background watchdog that
monitors a timestamp file:

- Every `send`, `respond`, or `poll` updates the timestamp — and while a
  blocking call is *waiting* for a response, its poll loop keeps refreshing
  the timestamp too, so a long-running response is never mistaken for a dead
  caller (`TUI_TIMEOUT` bounds a single response; `TUI_WATCHDOG` bounds caller
  absence).
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
- `poll` does a single non-blocking check (one hash comparison), ideal
  for polling loops.
- `poll --wait` blocks until the response is ready, intended to run in
  the background so the agent gets notified on completion.

Only one async query is allowed per session at a time to prevent
ambiguous state.

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

# Poll every 5 seconds, do other work in between
while ! tui-driver -q agy poll 2>/dev/null; do
    echo "Still waiting... doing other work"
    sleep 5
done

# Response was printed to stdout by the successful poll
tui-driver agy stop
```

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
