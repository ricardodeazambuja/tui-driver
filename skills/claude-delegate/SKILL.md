---
name: claude-delegate
description: >
  Delegate a self-contained task to an INDEPENDENT Claude Code (`claude`) CLI
  session driven via tui-driver, then collect the result. Use when you want a
  fresh, isolated context window (so a large sub-task does not bloat your own
  context), genuinely parallel work you can fire-and-poll, or a second opinion
  from a separate Claude instance. NOT for normal in-session work — only reach
  for this when isolation or parallelism is the point.
  Trigger on: delegate to Claude, spawn a sub-Claude, independent Claude
  session, second opinion, isolated context, run this in a separate Claude,
  parallel Claude task, offload to another Claude.
allowed-tools:
  - Bash(tui-driver*:*)
  - Read
  - Grep
---

# Delegate to an Independent Claude Code Session

Use `tui-driver` to drive a **separate** `claude` CLI session so you can hand it
a self-contained task and collect the result without spending your own context
window on the work. The driven session is a fully independent Claude instance:
its own context, its own working directory, its own tool calls.

When this is the right tool:

- **Isolated context** — a big, noisy sub-task (read 40 files, summarize a huge
  log, explore an unfamiliar subsystem) whose intermediate work you don't want
  in your own transcript. The sub-Claude does the slog; you keep just the answer.
- **Parallel work** — fire the task with `send-async`, run `poll --wait` in the
  background, and keep working. You're notified when it's done.
- **Second opinion** — pose a design/debugging question to a fresh instance with
  no priming from your conversation.

When NOT to use it: ordinary work in your current session, anything that needs
your existing context, or trivial tasks. Spawning a sub-Claude is heavier and
has a real cost (see below).

## Cost & resources — same plan as this session, not a separate bill

A driven `claude` session runs under the **same Claude Code authentication as
the session you're already in** (your subscription, or your API key). It is
*not* a separate or extra bill — it draws from the same usage and rate-limit
pool this session already uses. (This is unlike headless `claude -p` one-shots,
which some setups meter per invocation; driving the interactive TUI is just
another Claude Code session on your existing login.)

What it *does* cost: a second **concurrent** Claude consumes that shared rate
limit / plan quota faster and adds startup + token overhead. So reserve it for
genuine isolation or parallelism, don't spin them up in tight loops, and `stop`
each one when done so it isn't left running.

## Session Management

```bash
# Start an independent claude session in the current directory
tui-driver claude start

# ...or in a specific directory (the sub-Claude's working dir). Pass the SAME
# --dir on every later call too (send-async, poll, respond, stop): the default
# session is found by command + directory, and the directory defaults to the
# current one. Or use --session NAME, which needs --dir only on start.
tui-driver --dir /path/to/project claude start
tui-driver --dir /path/to/project claude send-async "..."

# When fully done, stop it (do not leave it running — it costs)
tui-driver claude stop
```

**Handle the startup prompt.** On first launch in a directory `claude` may show
a trust/onboarding dialog ("Do you trust the files in this folder?"). After
`start`, peek once and clear it if present:

```bash
tui-driver claude raw                       # one look: is a trust/onboarding dialog showing?
tui-driver claude respond --key Down Enter  # if so: move to "Yes, I trust this folder", confirm
```

The trust dialog is NOT numbered and its default is **"❯ No, exit"**: pressing
Enter alone (`respond ""`) quits the sub-Claude. Read the dialog, move the `❯`
to the option you want (`Down`/`Up`), then `Enter`. Only trust a directory the
user actually trusts.

**Parallel / multiple delegates.** The default session is keyed on
command+directory, so a second `tui-driver claude start` in the same directory
is refused. To run several independent sub-Claudes, give each its own session:

```bash
tui-driver --session claude-a claude start
tui-driver --session claude-b claude start
# pass the SAME --session NAME to every send/poll/respond/stop for that one
```

### Recovering a stuck or orphaned session

```bash
tui-driver list                              # every session + state (all dirs)
tui-driver claude reap                       # clear crashed/idle orphans only
tui-driver claude stop && tui-driver claude start   # force a clean restart
```

`reap` never touches a live or recently-active session.

**If the sub-Claude exits** (it crashed, was killed, or ran `/exit`), every call
exits 1 with "'claude' exited (status N)" on stderr. `tui-driver claude raw`
prints its saved last screen; after a clean exit that includes a
`claude --resume <id>` line. `start` launches a fresh session.

Requires tui-driver ≥ 0.4.0 (`tui-driver --version`).

## Delegating a Task (Async Pattern)

**Always use `send-async` + `poll --wait` (run in background).** A real Claude
Code task can take minutes (it reads files, runs tools), so never block on it.

```bash
# Step 1: Fire the task (returns immediately)
tui-driver claude send-async "<self-contained task — see prompt tips below>"

# Step 2: Wait for the result in a SEPARATE Bash call with run_in_background=true
TUI_TIMEOUT=900 tui-driver -q claude poll --wait
```

**Workflow:** call `send-async` in one Bash call, then `poll --wait` in a second
Bash call with `run_in_background: true`, and continue with other work — you'll
be notified when the result arrives.

**How `poll` behaves (so you don't get stuck):**
- Only **one** `send-async` may be pending per session. Sending another while
  one is pending fails with `already pending` until you retrieve the result.
  Retrieving the result is what releases the lock.
- A single `poll` is **self-contained**: one call returns the *whole* response
  when the screen is stable (exit 0), or `waiting` (exit 2) if still working.
  You never need to call `poll` twice in a row.
- A **timeout (exit 3) does not lose the task** — it stays pending. Poll again
  (or with a larger `TUI_TIMEOUT`) for the rest, or drop it with
  `tui-driver claude cancel`.
- **To check on a running task without retrieving it**, use
  `tui-driver claude progress` (read-only: pending?, elapsed, screen
  changing?, last screen lines). Never use `raw` for monitoring; it's for
  debugging a session that already misbehaves.
- Exit codes: `0` ready, `1` hard error (reason on stderr even with `-q`),
  `2` still working, `3` timeout, `4` the prompt was **not delivered** (a
  dialog took it; the screen is printed, nothing is pending — answer the
  dialog, then send again). Never treat a non-zero exit as a result.

**Long tasks need a bigger timeout.** The default `TUI_TIMEOUT` is 300s. A
substantial coding/exploration task can exceed that — set `TUI_TIMEOUT` (e.g.
`900` or more) on the `poll --wait` call. If output gets clipped or never
settles, raise `TUI_STABLE` (more consecutive stable samples) too.

**Exact completion marker (recommended for delegates).** Since you control
the delegate's prompt, ask it to end with a marker and pass `--until` — the
result returns the moment it's done, with no risk of a mid-task pause being
mistaken for completion:

```bash
tui-driver claude send-async "…do the task… When completely finished, print the word DONE followed by three exclamation marks on its own line."
TUI_TIMEOUT=900 tui-driver -q --until 'DONE!!!' claude poll --wait
```

With `--until`, only the marker ends the wait: a still screen (a long build,
a git hook) does not. The flip side is that a permission dialog holds the wait
until `TUI_TIMEOUT` (exit 3, task kept pending), so check long waits with
`progress`.

(Describe the marker in the prompt rather than spelling it out, so the echo
of your own prompt can't match the pattern.)

## Handling the Sub-Claude's Permission Prompts

A driven `claude` will pause on tool-permission dialogs (edit a file, run a
command, etc.). Without `--until`, your `poll` returns with the dialog text on
screen instead of a final answer. **With `--until`** (recommended above), a dialog
does not end the wait: `poll --wait` holds until `TUI_TIMEOUT` (exit 3, task
kept pending). So on a long wait, check with `tui-driver claude progress`: it
shows the last screen lines, dialog included, without consuming anything. It is a numbered menu (`1. Yes`, `2. Yes, and always
allow …`, …, `4. No`). Read it, decide, and reply with `respond --async --key N`,
which presses that one key (no Enter) and re-arms the pending task so the next
`poll --wait` picks up where it left off:

```bash
tui-driver claude respond --async --key 1        # approve this one tool use
tui-driver claude respond --async --key Escape   # deny (or the "No" number shown)
```

Do **not** answer with `"y"`/`"n"` text or a bare Enter. The menu ignores the
text, and the Enter accepts the highlighted default, which is "Yes". Worse, when
the sub-Claude issues two tool calls at once, the second approval appears
immediately and a stray Enter approves it unseen. Answer each dialog with
`--key`, then poll again; the next dialog, if any, comes back the same way.

After responding, start a new `poll --wait` (in the background) to get the
next state or the final result.

**Safety:** you are approving tool use in a *separate* agent. Don't blindly
`respond "y"` to everything — inspect the dialog first. If you want the sub-task
to run without interactive approvals, agree the permission posture with the user
up front (e.g. launching with a permission flag), rather than auto-approving
whatever it asks.

## Writing a Good Delegate Prompt

The sub-Claude has **none** of your context. The prompt must be fully
self-contained.

1. **State the goal and the working directory's relevance** — it starts fresh in
   whatever `--dir` you gave it.
2. **Specify the exact deliverable and format** — "Return a bullet list of the
   files that define routes and the HTTP method each handles" beats "look at the
   routing."
3. **Have it write results to a file you then read.** This is the most reliable
   way to get clean, verifiable output past the TUI chrome:
   ```bash
   tui-driver claude send-async "Explore the auth module under ./src/auth and write a summary of the login flow (entry points, token handling, where sessions are stored) to /tmp/auth-summary.md. Keep it under 300 words."
   ```
   Then `Read /tmp/auth-summary.md` directly — don't rely on scraping the
   terminal.
4. **Bound the scope** — give it a clear stopping point so it doesn't wander.

## Collecting and Trusting Results

- The captured response is everything after your prompt, **including TUI chrome**
  (boxes, status bars, the input line). Ignore those and extract the actual
  answer — or, better, read the file you asked it to write (tip #3).
- Treat the sub-Claude's output as a colleague's report, not ground truth. If
  you'll act on it (apply a patch, make a decision), spot-check the key claims
  against the actual files yourself.

## Rules

1. **Same plan, not a separate bill** — a sub-Claude shares this session's auth
   and usage pool; a concurrent one just burns shared rate limits faster, so
   don't spawn frivolously or in loops.
2. **Only for isolation / parallelism / second opinion** — not routine work.
3. **Always `send-async` + `poll --wait` (background)** — never block.
4. **One pending task per session**; retrieve before sending again. A
   timeout keeps the task pending — poll again or `cancel`.
5. **Monitor with `progress`, retrieve with `poll`/`poll --wait`** — never
   monitor with `raw`.
6. **Raise `TUI_TIMEOUT`** for substantial tasks (default 300s is often
   short) and prefer an `--until` completion marker.
7. **Self-contained prompts** — the sub-Claude has none of your context.
8. **Prefer file output** (`write … to /tmp/…`) and read it back to verify.
9. **Inspect permission dialogs** before responding, answer with
   `respond --async --key N` (never `"y"`/`"n"`), and don't auto-approve.
10. **`stop` when done** — never leave a sub-Claude running.
