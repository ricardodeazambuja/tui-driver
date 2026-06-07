---
name: antigravity-web
description: >
  Web search, web page fetching, and document reading using Antigravity CLI with
  grounded Google Search. Use INSTEAD of built-in WebSearch and WebFetch
  whenever you need to search the web, fetch/read URLs, or read online
  documents (PDFs, datasheets, specs). Antigravity handles JavaScript-heavy pages,
  dynamic content, and document summarization that WebFetch cannot.
  Trigger on: web search, search for, look up online, fetch URL, read URL,
  check website, product status, datasheet lookup, component availability,
  NRND, lifecycle status, DigiKey, Mouser, LCSC, Octopart, read PDF, fetch
  document, summarize document, extract from PDF.
allowed-tools:
  - Bash(tui-driver*:*)
  - Read
  - Grep
---

# Antigravity Web Search, Fetch & Document Skill

Use the `tui-driver` script to drive an Antigravity CLI session for ALL web search,
URL fetching, and online document reading tasks. Do NOT use the built-in
WebSearch or WebFetch tools — Antigravity provides grounded Google Search with
citations, can read JavaScript-rendered pages, and can process documents
(PDFs, datasheets, etc.) directly from URLs.

## Session Management

Before sending any query, ensure an Antigravity session is running. If one is already
running, `start` will tell you — that's fine, just proceed with `send-async`.

```bash
# Start an Antigravity session (safe to call if unsure — errors if already running)
tui-driver agy start

# When completely done with all web tasks, stop the session
tui-driver agy stop
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
tui-driver agy reap

# Force a clean restart of a live-but-wedged session
tui-driver agy stop && tui-driver agy start
```

`reap` is safe to run anytime: it never kills a session that is actively in
use. For a session that is alive but stuck, `stop` then `start` is the fix.

## Sending Queries (Async Pattern)

**Always use `send-async` + `poll --wait` (run in background).** This avoids
blocking while Antigravity processes the query. The background Bash call will notify
you when the response is ready.

```bash
# Step 1: Fire the query (returns immediately)
tui-driver agy send-async "Search for: <your detailed query here>"

# Step 2: Wait for response in background (you'll be notified when done)
# Run this as a SEPARATE Bash call with run_in_background=true
tui-driver -q agy poll --wait
```

**Workflow:** Call `send-async` in one Bash call, then immediately call
`poll --wait` in a second Bash call with `run_in_background: true`. Continue
with other work — you'll be notified when the response arrives.

**If you need to check without blocking** (e.g. to peek at progress):
```bash
tui-driver agy poll    # prints "waiting" if not ready, or the full response
```

**How `poll` behaves (so you don't get stuck):**
- Only **one** `send-async` can be pending per session at a time. If you try
  to send another while one is pending, you'll get `already pending` — you
  must retrieve the first response (with `poll` or `poll --wait`) before
  sending again. Retrieving the response is what releases the lock.
- A single `poll` is **self-contained**: one call returns the *whole*
  response when the screen is stable (exit 0), or `waiting` (exit 1) if it's
  still generating. You never need to call `poll` twice in a row.
- **Never use `raw` to "monitor" a pending query.** `raw` does not consume the
  response or release the lock, so the query stays pending and your next send
  fails. Use `poll`/`poll --wait` to retrieve; use `raw` only for debugging a
  session that already misbehaves.
- If a query seems to return clipped or empty output, raise `TUI_STABLE`
  (more consecutive stable samples) or `TUI_POLL` (longer gap between samples)
  on that invocation, e.g. `TUI_STABLE=3 tui-driver -q agy poll --wait`.

### Web Search Examples

```bash
tui-driver agy send-async "Search for MP2359 product lifecycle status NRND on DigiKey and Mouser"
tui-driver agy send-async "Search for STM32G431 errata and known silicon bugs 2025 2026"
tui-driver agy send-async "Search for IRS2104 gate driver reference design application notes"
```

### Web Fetch Examples

```bash
tui-driver agy send-async "Read https://www.digikey.com/en/products/detail/xxx and report the product status, price, and stock level"
tui-driver agy send-async "Read https://www.monolithicpower.com/en/mp2359.html and check if it is marked NRND or has a recommended replacement"
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
tui-driver agy send-async "Read the PDF at https://example.com/irs2104.pdf and extract: input voltage range, output current rating, propagation delay, and recommended bootstrap capacitor value"

# Summarize a technical document
tui-driver agy send-async "Read https://example.com/app-note-AN1234.pdf and summarize the key design recommendations for half-bridge gate driver layout"

# Compare specs across documents
tui-driver agy send-async "Read https://example.com/mosfet-a.pdf and extract: Vds max, Rds(on) at 10V Vgs, Qg total, and package type"

# Extract tables or pinouts
tui-driver agy send-async "Read https://example.com/connector-spec.pdf and extract the pin assignments table for the 8-pin variant"
```

### Tips for Document Processing

1. **Be specific about what to extract** — "extract the absolute maximum ratings table" is better than "read this datasheet"
2. **Ask for structured output** — "list as: parameter, min, typ, max, unit" helps get clean results
3. **Chain queries** — first ask Antigravity to find the document URL via search, then in a follow-up query ask it to read and extract from that URL
4. **Large documents** — Antigravity handles large PDFs well; ask it to focus on specific sections if you only need part of the document

## Handling Approvals

If Antigravity needs approval for a tool (e.g., to fetch a URL), `send-async` will
return the approval dialog on the next `poll`. Read it, decide, and reply:

```bash
tui-driver agy respond "y"     # approve
tui-driver agy respond "n"     # deny
tui-driver agy respond ""      # press Enter (accept default)
```

After responding, start a new `poll --wait` to get the actual response.

## Accuracy Warning — Antigravity Uses a Simpler Model

Antigravity runs with a lighter model by default, which means **its summarizations can
be inaccurate** — numbers get rounded, specs get mixed up, details get lost or
conflated. Treat Antigravity's summaries as a starting point, not ground truth.

**When accuracy matters** (component specs, pin assignments, voltage/current
ratings, lifecycle status, pricing, or any data you'll use for design decisions):

1. **Ask Antigravity to save raw results to a file** so you can read and verify them
   yourself. For example:
   ```bash
   tui-driver agy send-async "Search for IRS2104 absolute maximum ratings. Save the raw search results to /tmp/irs2104_specs.md"
   ```
   Then read `/tmp/irs2104_specs.md` directly with the Read tool to verify.

2. **Ask Antigravity to provide source URLs** and then fetch/read the original source
   yourself if the data is critical.

3. **Cross-check numbers** — if Antigravity says "Vds max = 30V", don't trust it
   blindly. Ask for the raw data or verify against a local datasheet PDF.

**Rule of thumb:** If you would run a calculation or make a design decision based
on a value Antigravity returned, get the raw data first. Don't build on top of a
potentially garbled summary.

## Rules

1. **Always prefer Antigravity** over built-in WebSearch/WebFetch for any web access or document reading.
2. **Always use send-async + poll --wait (background)** — never use blocking `send`.
3. **Start the session once**, send multiple queries, stop when done.
4. **Be specific** in the prompt — tell Antigravity exactly what information you need.
5. **Include citations** — ask Antigravity to include source URLs when searching.
6. **Multiple URLs** — you can include several URLs in a single send.
7. **Report results** — summarize Antigravity's output for the user, including source URLs.
8. **The output includes TUI chrome** (borders, status bars) — just ignore those lines and extract the actual response content.
9. **For documents** — always specify what to extract; don't ask Antigravity to dump entire documents.
10. **Be patient** — Antigravity searches take time (1-3 minutes for complex queries with multiple Google searches). After launching `poll --wait` in the background, **do NOT check raw screen output** to monitor progress — it wastes tokens and doesn't speed anything up. Trust the background notification and do other work while waiting.
11. **Verify critical data** — when accuracy matters, ask Antigravity to save raw output to a file (e.g. `/tmp/result.md`) so you can read and verify it yourself. Don't rely solely on Antigravity's summaries for design decisions.
