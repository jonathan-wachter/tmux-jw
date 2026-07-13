# PLAN — cockpit v3.1 + boxbar/heartbeat improvements (2026-07-08)

## STATUS (2026-07-08): ALL SHIPPED EXCEPT P8 (deferred)

Implemented and tested (`tests/run-tests.sh` = **131/131**) in the same session:
**V1** flush-left dividers · **V2** highlight-inside-brackets · **V3** header
focus-blue fix · **P10** rename chip · **P9** `/` filter · **P1** measure=all ·
**P4** instant bar refresh (⚠️ needs `tmux source-file ~/.tmux.conf` to arm the
new hooks) · **P5** cache hygiene (`tmux-claude-prune.sh`) · **P2** single-jq
registry · **P3** recap mtime gate.

Plus mid-session additions not in the original plan: a **move** chip (teleport
to an absolute slot, reusing `tmux-window-teleport.sh` in a new quiet mode); the
rename editor prefills the **displayed** name (`@ccname`), not the version-comm
window name; the terminal **cursor is hidden** while the popup is open (its blink
on the footer's leading ↑ read as an always-selected arrow); and the selected
row's title keeps its reverse-video highlight.

**P8 (below) is DEFERRED** — the only remaining item. It was marked optional; it
tightens the version-comm Claude detector, which touches close/move/filter
detection across three call sites for a false-positive that doesn't occur in
practice. Left as a documented, well-scoped task. Everything below this banner
is the original plan text, kept for the P8 spec + rationale.

---

Handoff plan for the next work session on this repo. Written by the session that
shipped **cockpit v3** (chips-in-divider, Claude-active session filter,
graceful close) and the **full-name selected boxbar tab** — see commit
`060fad5` for that feature summary. Everything below builds on that state.

**Read these files before writing any code:**

| File | What it is |
|---|---|
| `hooks/tmux-claude-dashboard.sh` | The cockpit popup (prefix+o). Model/draw/keys/chips all live here. |
| `hooks/tmux-claude-dashboard-open.sh` | Size-to-fit launcher for the popup. |
| `hooks/tmux-claude-bar-render.sh` | 3-row status ribbon, stale-while-revalidate reader/builder. |
| `hooks/tmux-claude-reconcile.sh` | 30s truth reconciler (states, names, recaps, summary). |
| `hooks/tmux-claude-heartbeat.sh` | Throttled status-right entrypoint that drives the reconciler. |
| `hooks/tmux-claude-state.sh` | Claude Code hook → @ccstate; the `state.dirty` signal pattern. |
| `hooks/tmux-window-park.sh` | Shared window-move engine (park/restore verbs). |
| `tests/run-tests.sh` | Headless e2e suite (scratch tmux server on socket `jwdash`). |
| `2026-06-spawn-storm-fix-plan.md` | WHY the perf discipline below exists. Skim it. |

## Standing constraints — violate none of these

1. **bash 3.2** (macOS `/bin/bash` semantics; scripts run via `bash` from tmux).
   No associative arrays, no namerefs, `[[ =~ ]]` patterns via a variable
   (`CCRE=...; [[ $x =~ $CCRE ]]`). ⚠️ **Never chain locals**:
   `local a=$1 b=$a` leaves `b` EMPTY (expansion happens before assignment).
   This exact bug broke `wrap2` for weeks; assign in separate statements.
2. **Storm safety** (see 2026-06-spawn-storm-fix-plan.md): the bar READER path and anything
   on the per-redraw/per-hook hot path must stay fork-light. The bar BUILDER is
   fork-free by design (`printf -v` out-vars, no `$(...)` in loops) — keep it
   that way. Never re-arm status-format/status-right from a hot path. Heavy
   work rides the throttled heartbeat, ≤ once/INTERVAL.
3. **Emoji width math**: `export LC_ALL=en_US.UTF-8` everywhere; the wide-emoji
   set for display-width math is `🤖💬🔴✅🟠📚📺` (see `dwidth()` in
   bar-render.sh and the `dw()` helper in tests). New glyphs must be added to
   BOTH.
4. **Testing**: after EVERY item, run `bash tests/run-tests.sh` — currently
   **82/82**; keep it green and ADD tests per item (the suite is the only
   safety net; there are no unit tests). The dashboard is headless-testable via
   `JW_DASH_TEST=1 JW_DASH_COLS=… JW_DASH_ROWS=… JW_TMUX="tmux -L <sock>"`,
   keys piped as raw bytes on stdin, `ACTION …` lines printed for assertions.
5. **Git**: an auto-save hook commits (and pushes) every file save as
   `auto-save: <file>` — don't fight it; when an item is done, make one curated
   summary commit on top (docs or a touched file) describing the change.
6. **Live rollout**: scripts are exec'd fresh per use — no tmux restart needed
   unless you edit `tmux.conf` (then `tmux source-file ~/.tmux.conf`).
   `~/.config/tmux-jw` is a symlink to this repo; edits are live immediately.

## Recommended order

V1 → V2 → V3 (small, reshape the draw code others touch; V3 is a BUG fix —
do it before any new chip/focus work) → P10 → P9 → P1 → P4 → P5 → P2 → P3 →
P8 (optional). Each item independently shippable.

---

## V1 — Divider restyle: drop the T-bars, flush-left title

**File:** `hooks/tmux-claude-dashboard.sh`, `draw_entry_rule()`.

Current entry divider:

```
├─4) agent-world-helper────────────────────────────────────────────────┤
```

Target (unselected):

```
4) agent-world-helper ──────────────────────────────────────────────────
```

- No `├─` prefix, no trailing `┤`. Title starts at column 1 (the `•`
  active-window marker, when present, is column 1: `•4) agent-world-helper …`).
- ONE space between the title and the dash run; dashes run to the last column.

Target (selected, chips stay right-aligned; no trailing `┤` either — end the
line with a short `──` tail after the last chip):

```
4) agent-world-helper ────────────────❯ open ❮─❯ cc-parking ❮─❯ new ❮─❯ close ❮──
```

**Geometry** (all display cells; remember a status glyph in the title is
2 cells / 1 char — the existing `gx` correction):

- unselected: `tw + 1 + fillw = cols`
- selected:   `tw + 1 + fillw + chipsw + 2 = cols` (min `fillw` 1; shrink the
  TITLE first when it doesn't fit, exactly as the current code does)
- `chip_lo/chip_hi` mouse spans shift left by 2 (no more `├─` prefix) — they
  are computed from a running `col` cursor, so just make sure the cursor
  starts at `1 + tw + 1 + fillw` under the new layout.

**Tests to update** (they key on the old shape):
- `"entry divider-titles drawn (3 ├─)"` → count lines matching
  `^•\{0,1\}[0-9]\{1,\}) .*──` instead.
- Section 5 sort-order extraction regex `'^├─•?[0-9]+\)'` →
  `'^•?[0-9]+\)'`.
- Section 1/2b/12 greps that pipe through `grep "^├─"` → grep for the title
  pattern instead (e.g. `grep -E '^•?[0-9]+\)'`).
- Re-verify line widths == cols with the python width check pattern used in
  tests section 8 (`dw()`); add one explicit width assertion for a selected
  divider line at JW_DASH_COLS.

## V2 — Highlight only INSIDE the chip/tab brackets

**File:** `hooks/tmux-claude-dashboard.sh` — two places.

1. **Control chips** (`draw_entry_rule()`): today the whole `❯ open ❮` gets
   the armed style. Target: the `❯` / `❮` delimiters stay UNSTYLED (default
   popup colors); only the inner ` open ` (spaces included) carries the
   style — `REV+BOLD` when armed, `REDCH+BOLD` for armed close / `close?`,
   `REDFG` inner for the idle close chip, `BOLD` inner for idle chips.
   Build each chip as three runs: `❯` + styled ` label ` + `❮`.
   Mouse spans (`chip_lo/chip_hi`) still cover the WHOLE chip including
   brackets — don't shrink the tap target.
2. **Session picker tabs** (`build_header()`): same treatment for the
   `❯ name ❮` capsules — `REV`/`TABFOC`/`BOLD` apply to ` name ` only,
   brackets plain. ⚠️ Every `RESET` kills the `SHADE` background of the tab
   zone — re-open `${SHADE}` after each styled run (the existing NB comment in
   `build_header` explains this; follow the pattern). Tab click spans
   (`tab_lo/tab_hi`) unchanged.

**Tests:** frame assertions strip ANSI, so text-level tests won't change; add
a raw-frame (NOT stripped) assertion that the armed chip's inner text is
preceded by the reverse-video sequence and that `❯` is not, e.g.
`[[ "$rawframe" == *$'\033[7m\033[1m open \033[0m'* ]]` (match the actual
sequences the code emits; don't over-specify order beyond one chip).

## V3 — BUG: session-bar focus blue doesn't appear on ↑ (stale header cache)

**File:** `hooks/tmux-claude-dashboard.sh`.

**Symptom** (reported by JW): press ↑ to lift focus onto the session tab bar —
nothing visibly changes; only after the first ←/→ does the viewed tab get its
blue `TABFOC` fill. The blue should be there the moment the bar has focus (and
gone the moment it loses it).

**Root cause**: `draw()` prints a CACHED `hdr_out` string; the focus-dependent
styling (blue `TABFOC` vs plain `REV` on the viewed tab, plus the header's
short hint text) is baked in by `build_header()`. The focus TRANSITIONS don't
rebuild it:
- `k_up()` sets `FOCUS=tabs` → no `build_header` → stale non-focused tab.
- `k_down()` / `k_enter()` leaving the bar → no `build_header` → the blue
  LINGERS after focus returned to the list (inverse bug, same cause).
- ←/→ on the bar call `view_session()` → which calls `build_header` → that's
  why the blue "suddenly" appears there.
The footer is immune because it's composed inside `draw()` every frame.

**Fix (recommended)**: make the header follow the codebase's own stated rule —
"model built with NO styling; styling applied at DRAW time". Call
`build_header` at the top of `draw()` every frame and stop relying on the
scattered call sites (leave them or remove them — they become harmless
redundancy; removing keeps things honest). `build_header` is pure string
assembly over the already-loaded `SESS_LIST` (no tmux calls), so per-keystroke
cost is negligible next to the body loop.
- Alternative (minimal diff, NOT preferred): add `build_header` calls to the
  three transition points (`k_up` entering tabs, `k_down`/`k_enter` leaving).
  Rejected because the next focus-touching feature will reintroduce the bug.
- ⚠️ Do NOT move `load_sessions` into draw — session LISTING should stay
  event-driven; only the styling pass moves to draw time.

**Tests** (raw frames, NOT ANSI-stripped — this class of bug is invisible to
the stripped assertions):
- `'\033[A'` → last frame contains the TABFOC sequence
  (`\033[48;2;83;155;245m`) on the viewed tab.
- `'\033[A\033[B'` → last frame contains NO TABFOC sequence (blue cleared on
  the way out — catches the linger half of the bug).
- `'\033[A'` → header hint shows the tabs-focus variant (`←→ session · ↓
  list`), guarding the hint-staleness sibling symptom.

## P10 — `rename` chip

**File:** `hooks/tmux-claude-dashboard.sh`.

Add a fifth verb between `new` and `close`:
`open · <sessions…> · new · rename · close`.

- **Chip bookkeeping**: `NACT = 1 + #targets + 3`. Keep `close = NACT-1`
  (tests overshoot with 8×→ and rely on clamping to land on close — that must
  keep working), `rename = NACT-2`, `new = NACT-3`. Update `run_action()`
  dispatch accordingly.
- **Input**: on Enter, enter an inline INPUT MODE (new state var, e.g.
  `INPUT_MODE=rename`, `INPUT_TEXT=` prefilled with the current display name).
  The footer renders `rename to: <text>▌`; printable bytes append, backspace
  (`\x7f` and `\b`) deletes, Enter commits, Esc cancels. While in input mode
  ALL other key handling (digits, q, s, arrows) is suspended — characters are
  text. Reuse this editor for P9's filter (build it as a small shared
  mechanism: a mode flag + a text buffer + a commit callback).
- **Commit**: `tmux rename-window -t "$__wid" "$INPUT_TEXT"` (also
  `set-option -w -t "$__wid" automatic-rename off` so the shell doesn't rename
  it back). Toast the result. **Caveat to note in a comment**: when a live
  Claude pane has `@ccname` published by the reconciler, the bar/cockpit show
  `@ccname`, not the tmux window name — renaming affects the tmux name only.
  That is accepted behavior for v1 (the real rename for Claude windows is
  Claude's own `/rename`).
- **Tests**: arm rename via exact arrow count on the scratch server (window
  with no @ccname), type a name, Enter; assert `ACTION rename <sess>:<win>
  <newname>` (add the test-mode print) and `list-windows` shows the new name.
  Also test Esc cancels without renaming.

## P9 — Type-to-filter in the cockpit

**File:** `hooks/tmux-claude-dashboard.sh`.

- `/` (body focus, not in input mode) enters FILTER input mode using the P10
  editor: footer shows `filter: <text>▌ (N match)`; every keystroke rebuilds
  the model live.
- **Matching**: case-insensitive SUBSTRING against the display name
  (`@ccname`-or-window-name). Keep it substring for v1 — no fuzzy scoring.
  Apply the filter inside `build_model()` (skip non-matching windows after the
  sort step) via a global `FILTER` var; empty = no filter.
- Enter in filter mode: commit → leave input mode, keep the filter applied,
  cursor on first match (a subsequent plain Enter opens it). Esc: clear filter
  entirely and rebuild. `q` while a committed filter is active: first press
  clears the filter, second quits (or just keep q=quit — decide, document in
  the header comment).
- Digits typed in filter mode are TEXT (the digit-jump shortcut is suspended).
- Session switches (Tab/bar) keep the filter applied — it's a view filter, and
  the footer keeps showing it.
- **Edge**: filter matches zero windows → body shows a dim `no match` line;
  ↑/↓/Enter no-op; `nwin=0` paths must not crash (check `move_sel`,
  `win_order[sel]` accesses).
- **Tests**: pipe `/camp\r\r` → opens the summer-camp window; `/zzz` → `no
  match` frame; Esc restores the full list.

## P1 — Popup-open latency: single-pass measure

**Files:** `hooks/tmux-claude-dashboard-open.sh` + a small addition to
`hooks/tmux-claude-dashboard.sh`.

**Problem**: the launcher's size-to-fit loop re-execs
`JW_DASH_MEASURE=1 bash tmux-claude-dashboard.sh <session>` once PER SESSION,
serially; each run builds the whole model (list-windows + wrap). With many
sessions this dominates prefix+o latency.

**Fix**: add `JW_DASH_MEASURE=all` to the dashboard: ONE bash process loads
the session list (post Claude-active FILTER — only sessions the popup can
actually show; that alone shrinks the work), loops `VSESS` over them calling
`build_model`, prints the MAX `total`. The launcher calls it once. The
per-session `JW_DASH_MEASURE=1` mode stays for tests/back-compat.

- Measure must reuse the REAL `build_model`/`wrap2` at the popup's inner width
  (`JW_DASH_COLS=$iw`) — never approximate line counts with division; wrapped
  recap lines and future filter behavior must stay in lockstep with reality.
- **Acceptance**: `time` the launcher's measure section before/after on the
  live server (~3 sessions, 15 windows: expect ~Nx fewer bash+tmux spawns; on
  the scratch server assert `MEASURE=all` output == max of the three
  single-session outputs).

## P4 — Instant bar update on rename / new / closed window

**Files:** `tmux.conf`, new tiny hook `hooks/tmux-claude-dirty.sh`,
`hooks/tmux-claude-reconcile.sh`.

**Problem**: the bar reader only rebuilds early when `state.dirty` moves
(@ccstate transitions). Window renames, new windows, and closed windows wait
out the 30s INTERVAL.

**Fix**:
1. New `hooks/tmux-claude-dirty.sh`: computes
   `d="${TMPDIR:-/tmp}/tmux-claude-bar"`, `mkdir -p`, `: > "$d/state.dirty"`,
   then `tmux refresh-client -S` (the touch alone doesn't force a redraw —
   follow the exact pattern at the bottom of `tmux-claude-state.sh`). Must be
   idempotent and silent.
2. `tmux.conf`: indexed hooks (so re-sourcing never stacks — same trick as
   `client-attached[50]`):
   ```
   set-hook -g window-renamed[52]  'run-shell -b "~/.config/tmux-jw/hooks/tmux-claude-dirty.sh"'
   set-hook -g window-linked[52]   'run-shell -b "~/.config/tmux-jw/hooks/tmux-claude-dirty.sh"'
   set-hook -g window-unlinked[52] 'run-shell -b "~/.config/tmux-jw/hooks/tmux-claude-dirty.sh"'
   ```
   ⚠️ Requires a conf reload to arm; say so in the final summary to the user.
3. `reconcile.sh`: when its apply-loop wrote at least one `name` or `state`
   correction, touch `state.dirty` ONCE at the end (the hooks above don't
   cover `@ccname` publishes). Do NOT touch when nothing changed —
   same-state spam staying off the dirty path is what keeps this storm-safe.
- **Storm check**: window-renamed fires on shell auto-rename too (directory
  changes with `automatic-rename on`) — the dirty touch is one `:>` + one
  `refresh-client`; the bar rebuild is still gated by the reader's mkdir lock
  and per-build cost, and `refresh-client -S` re-reads CACHED rows. Cheap, but
  note it in the hook's header comment.
- **Tests**: scratch server — build rows, `rename-window`, run the dirty hook,
  re-run the READER (not `--build`) and assert it kicked a rebuild (row file
  mtime advanced / new name present after a short wait).

## P5 — Bar cache hygiene (prune dead-client files)

**File:** `hooks/tmux-claude-heartbeat.sh` (read it first — it's the throttled
gate; add the prune INSIDE the gated section, additionally gated to ~1/hour by
its own stamp file).

- Prune targets under `${TMPDIR:-/tmp}/tmux-claude-bar/`:
  `cache/row{0,1,2}_<pid>`, `cache/hash_<pid>`, `cache/seendirty_<pid>`,
  `cache/lock_<pid>.d`, `vp_<pid>_<session>`.
- Rule: extract `<pid>` from the filename; delete when the pid is NOT in
  `tmux list-clients -F '#{client_pid}'` AND file mtime > 1h (the age guard
  protects a client mid-reconnect and the test harness's fake pids).
- Also reap stale `lock_*.d` dirs older than 10 min (belt over the reader's
  own 60s reap).
- Fork budget: one `list-clients`, one `find`/glob loop with `stat -f %m` —
  fine at 1/hour.
- **Tests**: fabricate files with a bogus pid and an old mtime
  (`touch -t 202601010000`), run the prune function directly, assert removed;
  live-pid + fresh files retained.

## P2 — Reconciler: one jq for the whole registry

**File:** `hooks/tmux-claude-reconcile.sh` (the per-file loop near the top).

Replace the `for f in "$REG_DIR"/*.json … jq` loop (one jq fork per live
session, every 30s) with a single jq over all files:

```sh
jq -r '[input_filename, .kind // "", .status // "", .sessionId // ""] | join("|")' \
  "$REG_DIR"/*.json 2>/dev/null
```

then in the shell loop: strip dir + `.json` from field 1 to get the pid, keep
the existing `kill -0` liveness filter. Guards:
- empty glob (no sessions): keep the `[ -e ]` check before invoking jq;
- one MALFORMED file must not sink the batch — jq aborts on invalid JSON, so
  either accept the degradation (2>/dev/null, partial output up to the bad
  file) or pre-filter with a cheap `head -c1` sanity check; document the
  choice. **Output-equivalence test**: fixture dir with 2 valid + 1 dead-pid
  file → same `sessions` string as the old loop.

## P3 — Recap harvesting: mtime gate

**File:** `hooks/tmux-claude-reconcile.sh` (`sid)` branch of the apply loop).

Before the `tail -c 262144 | grep | jq` pipeline, check whether the transcript
changed since last harvest:

- Stamp store: `$HOME/.cache/tmux-claude/recap_seen_<sessionId>` containing
  the transcript's mtime from the previous harvest (files, not tmux options —
  survives pane churn, easy to prune: delete stamps > 7d in the same pass).
- `cur=$(stat -f %m "$tf")`; if equal to stamp → skip entirely (zero tail/jq).
  On harvest (changed or first time) → write the stamp AFTER a successful
  read.
- Steady state with N idle Claudes goes from N×(tail+grep+jq) per 30s tick to
  N×stat.
- **Test**: hard to e2e — add a targeted test that runs reconcile twice
  against a fixture transcript and asserts (via a debug env var like
  `JW_RECONCILE_TRACE=1` printing `harvest`/`skip` lines) second run skips,
  then `touch` the transcript and assert it harvests again.

## P8 (optional, last) — Tighten the version-comm Claude detector

**Files:** `hooks/tmux-window-park.sh` (`session_has_claude`),
`hooks/tmux-claude-dashboard.sh` (`CCRE` uses), `hooks/tmux-claude-reconcile.sh`
(comment only).

Today any process comm matching `[0-9]+(\.[0-9]+){1,3}` counts as Claude. Keep
the regex but corroborate bare-version comms: a version-named comm counts ONLY
if the pane ALSO has a nonempty `#{pane_title}` differing from `#{host}` /
`#{pane_current_path}` tail, OR the pane/window carries `@ccstate`/`@ccname`.
Literal `claude` comm always counts. Implement as one shared helper if
practical; otherwise keep the two copies in sync with a cross-reference
comment. LOW priority — do not let this destabilize close/move; if the
heuristic gets fiddly, skip and leave a note.

---

## Definition of done (whole plan)

1. `bash tests/run-tests.sh` green with NEW tests for V1, V2, P10, P9, P1, P4,
   P5, P2 (P3 via trace test; P8 if attempted).
2. Manual smoke on the LIVE server: prefix+o (open speed, chips, rename,
   filter), a window rename reflecting in the bar within ~1s, no spawn storm
   (watch `ps aux | grep -c tmux-claude` stays flat for a minute).
3. `tmux.conf` changed (P4) → remind the user to `tmux source-file
   ~/.tmux.conf`.
4. One curated summary commit at the end (the auto-save hook will have
   committed everything already — that's expected).
5. Update `KEYBINDINGS.md` cockpit row (rename chip, `/` filter) and delete
   this plan file when everything is done.
