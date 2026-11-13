---
name: antigravity-web
description: >
  LAST RESORT for web search, web page fetching, and document reading, using
  Antigravity CLI with grounded Google Search. Do NOT use it as the first option:
  try built-in WebSearch and WebFetch (or the web-fetch agent) first, and only
  use this when they have failed or come back thin, for example on
  JavaScript-heavy pages, dynamic content, or sites that refuse automated fetches.
  OUTPUT IS UNVERIFIED — everything this skill returns is a *suggestion* to be
  independently and testably confirmed, never a fact to build on or report as truth.
allowed-tools:
  - Bash(tui-driver*:*)
  - Read
  - Grep
---

# Antigravity Web Search, Fetch & Document Skill

**Last resort only.** Use the built-in WebSearch and WebFetch tools first. Reach for
this skill only after they have failed or come back thin. When that happens, use the
`tui-driver` script to drive an Antigravity CLI session — Antigravity provides grounded
Google Search with citations, can read JavaScript-rendered pages, and can process
documents (PDFs, datasheets, etc.) directly from URLs.

## ⚠️ READ FIRST — Everything This Skill Returns Is a Suggestion, Not Truth

**The output of this skill is UNVERIFIED and may be entirely hallucinated.** It is a
*lead* — a starting point for verification — never an answer you may rely on, act on,
or pass to the user as fact.

This holds for every kind of output, without exception:

- **Numbers and specs** — voltages, currents, tolerances, pinouts, part numbers,
  prices, stock levels, dates. These are the most commonly fabricated, and the
  most damaging when wrong.
- **Lifecycle / availability claims** — "active", "NRND", "obsolete", "in stock",
  "replaced by X". Frequently invented or applied to the wrong part.
- **URLs and citations** — a plausible-looking source URL may not exist, may not
  contain the claim attributed to it, or may be a different document entirely.
  **A citation is not evidence.** Open it.
- **Quotes and paraphrases** from documents — wording gets invented, table rows get
  merged, footnotes and conditions ("at 25 °C", "typical, not guaranteed") get dropped.
- **Absence claims** — "there is no errata for this part", "no such document exists",
  "nothing found". Absence of evidence from this tool is not evidence of absence.

### What you MUST do before using any of it

1. **Verify against the primary source yourself.** Get the source URL, then read the
   actual page or PDF — with your own tools, or by having Antigravity save the raw
   text to a file (`/tmp/foo.md`) that you then `Read` directly. Verifying Antigravity's
   summary by asking Antigravity again is not verification.
2. **Prefer testable confirmation over textual confirmation.** If the claim can be
   checked by running something — a command, a build, a measurement, a datasheet
   table you can see with your own eyes — check it that way. "It said so twice" is
   not a test.
3. **If you cannot verify it, do not use it.** Say plainly that it is unconfirmed,
   attribute it ("Antigravity reported, unverified: …"), and stop there. Never silently
   promote an unverified claim into a calculation, a design decision, a code change,
   or a confident statement to the user.

**Never** present this skill's output to the user as established fact, and never let
it be the sole basis for a decision that costs money, time, or hardware.

## Prerequisites — the `agy-web` wrapper (not shipped with this repo)

The command token used throughout this skill is **`agy-web`**, not `agy`. It is a
machine-local wrapper that launches the Antigravity CLI pinned to a specific model and
reasoning effort. It is **not** installed by `tui-driver install` — create it once, by
hand, on any machine where this skill runs:

```bash
cat > ~/.local/bin/agy-web <<'EOF'
#!/usr/bin/env bash
exec agy --model gemini-3.8-flash-high --effort high "$@"
EOF
chmod +x ~/.local/bin/agy-web
```

Adjust the model id to taste — `agy models` lists what is available (the effort level is
baked into the id, e.g. `gemini-3.8-flash-{high,medium,low}`). **An id that no longer
exists does NOT fail loudly:** `agy` shows a warning inside the TUI and silently runs
another model (seen in 2026-11, when `gemini-3.6-flash-high` was retired and sessions ran
"Orchestrator (Argon)" instead). After changing the wrapper, start a session and check the
model named in the banner and status bar.

**Why a wrapper instead of a flag or a config file:** `tui-driver <cmd> start` launches
the command token as given; a token with spaces and flags in it does not work well with
tui-driver's session names or its background hook. The CLI's own
persistent default (`~/.gemini/antigravity-cli/settings.json`) is global and gets silently
rewritten by any in-TUI `/model` switch, so it cannot be relied on either. Pinning at
launch is the only thing that guarantees the model. To confirm which model a live session
actually got, `tmux capture-pane -p -t <session>` — the status bar shows it.

If `agy-web` is missing, `tui-driver agy-web start` exits 1 with "'agy-web' exited
(status 127)"; `raw` shows the command-not-found. Create the wrapper; do NOT fall back to
bare `agy`.

**If the session dies** (agy crashed, was killed, or quit), every call exits 1 with
"'agy-web' exited (status N)" on stderr. `tui-driver agy-web raw` prints its saved last
screen; `start` launches a fresh session.

## Session Management

Before sending any query, ensure an Antigravity session is running. If one is already
running, `start` will tell you — that's fine, just proceed with `send-async`.

**First run in a new directory:** `agy` shows a trust dialog ("Do you trust the contents
of this project? ❯ Yes, I trust this folder / No, exit"). A query sent while it is up is
swallowed by it (tui-driver then warns that the prompt was not found on screen). After a
`start` in a directory agy has not seen, look once with `tui-driver agy-web raw` and, if
the dialog is there and the directory is one the user trusts, confirm the highlighted
"Yes" with `tui-driver agy-web respond --key Enter`.

```bash
# Start an Antigravity session (safe to call if unsure — errors if already running)
tui-driver agy-web start

# When completely done with all web tasks, stop the session
tui-driver agy-web stop
```

**Important:** Do NOT stop the session between queries. Keep it alive for the
duration of the task — this preserves conversation context and avoids
unnecessary startup time. Only stop when you are fully done with web access.

### Recovering a stuck or orphaned session

If a session misbehaves — `poll` never returns, `start` reports one is already
running but `send` does nothing, or a previous run crashed and left a session
behind — use these to recover:

```bash
# See every tui-driver session and its state (across all directories)
tui-driver list

# Clear sessions orphaned by a crashed/killed prior run
# (only touches dead-watchdog, idle sessions — never a live one)
tui-driver agy-web reap

# Force a clean restart of a live-but-wedged session
tui-driver agy-web stop && tui-driver agy-web start
```

`reap` is safe to run anytime: it never kills a session that is actively in
use. For a session that is alive but stuck, `stop` then `start` is the fix.

## Sending Queries — ONE call, ALWAYS in the background

**Every query is a single Bash call with `run_in_background: true`.** Copy this
shape verbatim:

```bash
tui-driver -q agy-web start 2>/dev/null
tui-driver -q agy-web send-async "Search for: <your detailed query here>" \
  && tui-driver -q agy-web poll --wait
```

That one backgrounded call starts the session if needed, sends the query, waits,
and hands you the whole response through the completion notification.

**Why one call and not the old two-step:** there is nothing left to forget. The
`start` prefix is a free no-op on a live session (exit 1 in ~0 s, session
untouched), `send-async` takes the pending lock so a second query cannot corrupt
the pane, and `&&` means a failed send never leaves a stray poll behind.

**Never run `send`, `respond`, or `poll --wait` in the foreground.** Foreground
blocking stalls the whole turn and the Bash tool kills it at 2 minutes, so you
burn the wait and still have no answer. After firing the call, **go do other
work** — writing files, reading code, planning. Do not idle, and do not poll to
"check". The notification will find you.

**To check on a pending query without retrieving it**, use `progress` —
read-only, safe to run any number of times:
```bash
tui-driver agy-web progress   # pending?, sent_ago, screen changing?, last lines
```

**If you need to retrieve without blocking:**
```bash
tui-driver agy-web poll    # prints "waiting" (exit 2) if not ready, or the full response (exit 0)
```

**Exit codes (same for send/poll/respond):** `0` = response ready, `1` =
hard error (no session, no pending query — the reason is printed to stderr
even with `-q`), `2` = still working (`poll`), `3` = timeout.

**How `poll` behaves (so you don't get stuck):**
- Only **one** `send-async` can be pending per session at a time. If you try
  to send another while one is pending, you'll get `already pending` — you
  must retrieve the first response (with `poll` or `poll --wait`) before
  sending again. Retrieving the response is what releases the lock.
- A single `poll` is **self-contained**: one call returns the *whole*
  response when the screen is stable (exit 0), or `waiting` (exit 2) if it's
  still generating. You never need to call `poll` twice in a row.
- A **timeout (exit 3) does not lose the query** — it stays pending. Poll
  again (or with a larger `TUI_TIMEOUT`) for the rest, or drop it with
  `tui-driver agy-web cancel` if you no longer want it.
- **Never use `raw` to "monitor" a pending query** — use `progress` for that.
  Use `poll`/`poll --wait` to retrieve; `raw` only for debugging a session
  that already misbehaves.
- If a query seems to return clipped or empty output, raise `TUI_STABLE`
  (more consecutive stable samples) or `TUI_POLL` (longer gap between samples)
  on that invocation, e.g. `TUI_STABLE=3 tui-driver -q agy-web poll --wait`.

### Several independent lookups at once

One session answers one query at a time — the pending lock is per session. When
you have N *unrelated* lookups, don't queue them: give each its own session with
`--session NAME` (which bypasses the per-directory lock) and fire N background
Bash calls **in a single message** so they run concurrently.

```bash
# call 1 (background)
tui-driver --session web1 -q agy-web start 2>/dev/null
tui-driver --session web1 -q agy-web send-async "<query 1>" \
  && tui-driver --session web1 -q agy-web poll --wait

# call 2 (background) — same shape, --session web2, and so on
```

Three parallel lookups cost about what one costs. Rules:

- Pass the same `--session NAME` to **every** action for that session —
  `send-async`, `poll`, `progress`, `stop`. Omitting it silently talks to the
  default session instead.
- **Stop them explicitly when done** (`tui-driver --session web1 agy-web stop`);
  each is a full Antigravity process. The 600 s idle watchdog is a backstop, not
  a plan.
- Keep it to ~3 concurrent sessions. More buys little and costs memory.
- Needs tui-driver ≥ 0.4.0 (check with `tui-driver --version`). Before 0.3.1, sends
  pasted through tmux's *unnamed* buffer, which is shared process-wide: parallel sends
  raced and a session could receive another session's prompt — silently, with a
  plausible answer to the wrong question. Before 0.4.0, session names were matched by
  prefix (`web1` could reach `web10`), and approvals needed `--key` to work at all.

### Where the wall-clock actually goes

Measured on this machine (Gemini 3.6 Flash, high effort — since retired; the current
Flash should be in the same range, but it has not been re-measured):

| Step | Cost |
|------|------|
| cold `start` | ~6 s, once |
| `start` when already running | ~0 s (exits 1, session untouched) |
| `send-async` | <1 s |
| trivial question, default `TUI_POLL=2 TUI_STABLE=2` | ~6 s |
| same question, `TUI_POLL=1` | ~3 s |
| grounded search, 2 Google queries + answer | ~12 s |
| 3 such searches in parallel sessions | ~20 s total |

So a normal search is **seconds, not minutes** — heavy PDF extraction is where
minutes happen. Most of that time is Antigravity thinking and searching and is
not tunable from here. What *is* tunable is the settle tail — the
`TUI_STABLE × TUI_POLL` seconds of unchanged screen that `poll` waits out after
the answer is complete:

- `TUI_POLL=1` halves it and cost nothing in the tests above, including on a
  multi-line datasheet answer. If a reply ever comes back clipped, drop back to
  the default or raise `TUI_STABLE`.
- `--until` removes the tail entirely — it's a **global** flag, so it goes
  before the command token:
  ```bash
  tui-driver -q agy-web send-async "<query>; end your reply with the word DONE followed by three exclamation marks"
  tui-driver --until 'DONE!!!' -q agy-web poll --wait
  ```
  Word the prompt so the literal marker never appears in it, or the pattern
  matches the echoed prompt immediately.

None of this matters as much as the one habit that does: **fire the call in the
background and go do something else.** A 12-second search costs zero if you
spend those 12 seconds on other work, and a 3-minute one costs zero too.

### Web Search Examples

```bash
tui-driver agy-web send-async "Search for MP2359 product lifecycle status NRND on DigiKey and Mouser"
tui-driver agy-web send-async "Search for STM32G431 errata and known silicon bugs 2025 2026"
tui-driver agy-web send-async "Search for IRS2104 gate driver reference design application notes"
```

### Web Fetch Examples

```bash
tui-driver agy-web send-async "Read https://www.digikey.com/en/products/detail/xxx and report the product status, price, and stock level"
tui-driver agy-web send-async "Read https://www.monolithicpower.com/en/mp2359.html and check if it is marked NRND or has a recommended replacement"
```

## Document Fetching & Processing

Antigravity can read documents (PDFs, datasheets, specs) directly from URLs. Use
this for any online document that needs to be read, summarized, or have
specific information extracted.

**Always tell Antigravity exactly what to extract** — don't just say "read this PDF."
Give it specific questions or extraction targets so it returns structured,
useful information rather than a raw dump.

### Document Examples

```bash
# Extract specific specs from a datasheet
tui-driver agy-web send-async "Read the PDF at https://example.com/irs2104.pdf and extract: input voltage range, output current rating, propagation delay, and recommended bootstrap capacitor value"

# Summarize a technical document
tui-driver agy-web send-async "Read https://example.com/app-note-AN1234.pdf and summarize the key design recommendations for half-bridge gate driver layout"

# Compare specs across documents
tui-driver agy-web send-async "Read https://example.com/mosfet-a.pdf and extract: Vds max, Rds(on) at 10V Vgs, Qg total, and package type"

# Extract tables or pinouts
tui-driver agy-web send-async "Read https://example.com/connector-spec.pdf and extract the pin assignments table for the 8-pin variant"
```

### Tips for Document Processing

1. **Be specific about what to extract** — "extract the absolute maximum ratings table" is better than "read this datasheet"
2. **Ask for structured output** — "list as: parameter, min, typ, max, unit" helps get clean results
3. **Chain queries** — first ask Antigravity to find the document URL via search, then in a follow-up query ask it to read and extract from that URL
4. **Large documents** — Antigravity handles large PDFs well; ask it to focus on specific sections if you only need part of the document

## Handling Approvals

If Antigravity needs approval for a tool (e.g., to run a command or fetch a URL),
`send-async` will return the approval dialog on the next `poll`. It is a numbered menu
(`1. Yes, run command` … `4. No, cancel`). Read it, decide, and reply with
`respond --async --key N`, which presses that one key (no Enter) and re-arms the pending
query so the next `poll` / `poll --wait` retrieves the real response:

```bash
tui-driver agy-web respond --async --key 1        # approve once
tui-driver agy-web respond --async --key 4        # deny ("4. No, cancel")
tui-driver agy-web respond --async --key Escape   # cancel
```

Use the numbers the menu actually shows. Do **not** reply with `"y"`/`"n"` text: the menu
ignores it, and the Enter that follows a text reply accepts the highlighted default —
which is "Yes". (Before tui-driver 0.4.0, `respond "n"` approved the command.)

After responding, run `poll --wait` (in the background) to get the actual
response. (Plain `respond` without `--async` blocks and prints the resulting
screen itself — fine for quick dialogs in synchronous flows.)

## Verification Recipes (see the READ FIRST warning above)

Antigravity runs a fast model and **its summarizations are routinely inaccurate** —
numbers get rounded, specs get mixed up, details get lost, conflated, or invented
outright. Pinning the model to a stronger tier reduces this; it does not remove it.
No prompt makes the output trustworthy. Only checking the source does.

**This applies to everything, and non-negotiably to** component specs, pin
assignments, voltage/current ratings, lifecycle status, pricing, or any data you'll
use for design decisions:

1. **Ask Antigravity to save raw results to a file** so you can read and verify them
   yourself. For example:
   ```bash
   tui-driver agy-web send-async "Search for IRS2104 absolute maximum ratings. Save the raw search results to /tmp/irs2104_specs.md"
   ```
   Then read `/tmp/irs2104_specs.md` directly with the Read tool to verify.

2. **Ask Antigravity to provide source URLs** and then fetch/read the original source
   yourself if the data is critical.

3. **Cross-check numbers** — if Antigravity says "Vds max = 30V", don't trust it
   blindly. Ask for the raw data or verify against a local datasheet PDF.

4. **Check that the citation says what it's claimed to say** — fetching the URL is
   only half of it; the claim has to actually be on the page. A URL that 404s, or a
   real page that never mentions the number, means the claim was fabricated.

**Rule of thumb:** If you would run a calculation, write code, or make a design
decision based on a value Antigravity returned, get the raw data first. Don't build on
top of a potentially garbled summary. If verification isn't possible right now, label
the value as unverified and let the user decide — do not quietly use it anyway.

## Rules

1. **Last resort only** — use built-in WebSearch/WebFetch first; use Antigravity only after they have failed or come back thin.
2. **One backgrounded Bash call per query** — `start; send-async && poll --wait`, with
   `run_in_background: true`. Never run `send`, `respond`, or `poll --wait` in the
   foreground: it stalls the turn and the Bash tool kills it at 2 minutes.
3. **Start the session once**, send multiple queries, stop when done. For unrelated
   lookups, run them concurrently in separate `--session NAME` sessions rather than
   one after another.
4. **Be specific** in the prompt — tell Antigravity exactly what information you need.
5. **Include citations** — ask Antigravity to include source URLs when searching.
6. **Multiple URLs** — you can include several URLs in a single send.
7. **Report results as unverified** — when you summarize Antigravity's output for the
   user, attribute it and say what you did or did not confirm. Include source URLs.
   Never state it as your own finding or as established fact.
8. **The output includes TUI chrome** (borders, status bars) — just ignore those lines and extract the actual response content.
9. **For documents** — always specify what to extract; don't ask Antigravity to dump entire documents.
10. **Never wait idly** — a typical grounded search lands in ~10-20 s and a heavy PDF
    extraction in minutes, but either way the call is in the background: do other work
    and trust the completion notification. Do not re-poll to "check". If you genuinely
    suspect a stall, `tui-driver agy-web progress` is read-only and safe — never `raw`.
11. **Verify before you use, always** — the output is a suggestion, not truth. Ask Antigravity to save raw output to a file (e.g. `/tmp/result.md`), read it yourself, and confirm against the primary source — testably where a test is possible. If you can't verify it, label it unverified and don't build on it. See the READ FIRST section at the top.
12. **Never use plain `agy`** — the command token is `agy-web`, a wrapper that pins the model to Gemini 3.8 Flash at high reasoning effort (see Prerequisites above; create it if missing). Bare `agy` follows a mutable global default that any in-TUI `/model` switch silently changes.
