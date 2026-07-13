# tmux-jw spawn-storm — INSTALL-READY state
Generated from workflow wjkotmn1r. Pairs with 2026-06-spawn-storm-fix-plan.md + 2026-06-spawn-storm-handoff.md.

## ✅ RESOLUTION (2026-06-26, post-compaction) — all blockers closed, install-ready
Live state on resume: load draining (9.6 1-min, was 302); storm signature clean
(bar-render 0, continuum_save 0). BUT the firefighter's LIVE stopgaps had reverted
(status 3, status-interval 5, status-right back to continuum+statusline, save-interval 5)
— only the `exit 0` script STUBS are holding the storm back now. Do NOT naked-un-stub.

Blockers resolved:
1. CONTINUUM RE-PREPEND → fix = append a status-right re-assert at the END of tmux.conf
   (after the `run '.../tpm'` line). EMPIRICALLY VERIFIED: a `set -g status-right` after
   `run-shell` in a sourced conf wins (tpm sources plugins synchronously, foreground).
   This strips continuum's prepend; continuum_save then runs ONLY via the heartbeat.
2. tmux.conf NOT in changeset → patch: status-interval 5→30 on BOTH lines (54 + 110);
   status-right (112) → heartbeat path; @continuum-save-interval (243) keep '5' (5 min,
   continuum_save's own gate fires a real save every 5 min when the heartbeat calls it).
3. INSTALL ORDER → state.sh-staged lands on live state.sh FIRST (kills the per-hook
   source-file re-arm) before un-stubbing anything else.
4. **NEW blocker found this pass (workflow's render-only verify missed it):** staged
   bar.sh stripped #{T:status-right} from ALL rows → status-right NEVER evaluates →
   heartbeat NEVER fires → no reconciler, no autosave (silent freeze). EMPIRICALLY
   VERIFIED with a pty-attached client: 0 heartbeat fires without the suffix, fires WITH
   it. FIXED in bar.sh.stormfix-staged: L1 restored to `#($R 1 $A)#{T:status-right}`
   (the original proven mechanism; status-right's payload is now the cheap throttled
   heartbeat instead of continuum+statusline).

GATED INSTALL SEQUENCE (phased; continuum = the riskiest, goes LAST):
  Phase A (bar + wiring, continuum autosave still OFF):
   a. cp state.sh.stormfix-staged        → hooks/tmux-claude-state.sh   (FIRST)
   b. cp bar.sh/bar-render/heartbeat .stormfix-staged → their live hooks
   c. cp reconcile.sh.bak-stormfix-*     → hooks/tmux-claude-reconcile.sh (heartbeat needs it)
   d. leave continuum_save.sh STUBBED
   e. patch tmux.conf (4 edits above)
   f. re-arm: tmux source-file ~/.tmux.conf
   g. VERIFY ~60s under a forced refresh-client burst: 3 rows render correctly; heartbeat
      fires (reconcile cache/@ccrecap mtime advances); pgrep bar-render≈0 idle;
      continuum_save=0; procs<2s low; load flat.
  Phase B (re-enable continuum autosave = storm's biggest contributor):
   h. cp continuum_save.sh.bak-stormfix-* → live continuum_save.sh (un-stub)
   i. VERIFY ~60s: continuum_save fires ONLY via heartbeat (≤once/30s, not per-redraw);
      pgrep save.sh ≤1 (no stacking); load flat.
  ROLLBACK (instant): re-stub bar-render + continuum_save (printf '#!/bin/bash\\nexit 0\\n'),
   tmux set -g status off, tmux set -gu status-format.
─────────────────────────────────────────────────────────────────────────────────────
## Status: core fix VERIFIED; un-stub BLOCKED on 3 install fixes (NO-GO until resolved)
- **Isolation verify = PASS**: staged bar-render renders BYTE-FOR-BYTE identical to the
  pre-stub `.bak-stormfix-20260626-141949` (incl. #[...] codes), reader is a cheap cat,
  idle = 0 background builders, builder mkdir-locked + 30s mtime-gated.
- **Review = NO-GO** until the BLOCKING required-fixes below are done.

## Staged files (NOT installed; live hooks still stubbed `exit 0`)
- `~/projects/tmux-jw/hooks/tmux-claude-bar-render.sh.stormfix-staged`
- `~/projects/tmux-jw/hooks/tmux-claude-state.sh.stormfix-staged`
- `~/projects/tmux-jw/hooks/tmux-claude-bar.sh.stormfix-staged`
- `~/projects/tmux-jw/hooks/tmux-claude-heartbeat.sh.stormfix-staged`

## BUILD summary (what each staged file changes)
```
tmux-claude-bar-render.sh.stormfix-staged: split into a fast #() READER (stat+cat the per-client cached row, kick a mkdir-locked detached BUILDER only when stale by mtime>30s or cheap-hash mismatch) and a BUILDER that runs the 2 tmux list-windows once and builds all 3 rows with every dwidth/repeat/head_w/tail_w/glyph/blanks/border rewritten to printf -v out-vars (zero per-cell forks); output verified byte-identical to the pre-storm bak.
tmux-claude-state.sh.stormfix-staged: stripped the per-hook self-heal re-arm (the show-options|grep || source-file ~/.tmux.conf that re-ran bar.sh every tool call); now sets ONLY @ccstate (+refresh-client) — no status-format/status-right/status/bar.sh touch.
tmux-claude-bar.sh.stormfix-staged: dropped #{T:status-right} from status-format[1] (rows are pure content), set status-interval 30, and moved continuum-save + reconciler-kick to a separate self-throttling heartbeat installed in the default status-right slot.
tmux-claude-heartbeat.sh.stormfix-staged: new throttled driver (mkdir lock + 30s mtime stamp gate) that fires the reconciler + continuum_save at most once per INTERVAL server-wide, so tmux-resurrect save.sh can never stack.
```

## VERIFY measurements (isolation)
- pass: True
- render_ok: True
- reader_cheap: True
- idle_zero: True
- throttled: True
```
VERDICT: PASS. Verified hooks/tmux-claude-bar-render.sh.stormfix-staged in isolation on `tmux -L stormtest` (config-free server, 16 mock windows: names incl. a long name + an @ccname override; @ccstate set via `set -p` on 7 windows covering all 5 states working×2/question/needs_you/done×2/stalled). Isolated cache via TMPDIR. Default socket NEVER touched (every tmux call was -L stormtest or had TMUX pointed at stormtest); confirmed cc-0624-0 (11 win, attached) + projects (2 win) intact before/after; live `exit 0` stubs and the staged file both unmodified. stormtest killed at end.

(a) RENDER CORRECTNESS — PASS. At width=200, cur=window3: all 3 warm (cached) staged rows matched the pre-stub script (.bak-stormfix-20260626-141949) BYTE-FOR-BYTE *including* the #[...] style/range codes, and each plain row width = exactly 200. Current tab (3•db-migrate) inverted, global status box `🤖2•💬1•🔴1•🟠1•✅2` top-right, session name `sess` top-left, ◀/▶ scroll cells — all identical. Re-checked a narrow case (width=90, cur=window9) exercising scroll + partial-cell + viewport persistence: all 3 rows byte-identical to pre-stub. Repeated under a single fresh consolidated server run: row0/1/2 MATCH, width=200.

(b) READER FORKS ~0 — PASS. PATH-shim fork trace of a WARM #() read: steady-state external procs (excluding the one `bash $RENDER` shell tmux already provides for any #()) = `date +%s` (×1) + `stat -f %m` (×1) + `cat <rowfile>` (×1). NO builder, NO `tmux list-windows`, NO per-cell dwidth/repeat/head_w subshells. Just a freshness probe + a cat — vs the pre-stub's ~30 subshells/cell × cells.

(c) IDLE = 0 BUILDERS — PASS. After a 90-read burst (30 redraws × 3 rows) + 1s settle: `pgrep -fc 'bar-render.*--build'` = 0, no lock dir present. Re-confirmed 0 in the consolidated run and after full teardown.

(d) BUILDER mkdir-LOCKED + mtime-GATED, <=once/INTERVAL (INTERVAL=30s) — PASS (instrumented a counting copy that logs each builder entry):
  d.1 mtime gate: 100 tight serial reads on a warm/fresh cache => 0 extra builders (only the 1 cold warm-up build).
  d.2 mkdir lock: 40 PARALLEL forced-stale (no-cache) reads, 5 trials against the LIVE server => exactly 1 builder run every trial, final row1 = full 929-byte real render. (An earlier "2" occurred only when the stormtest server had died and `tmux list-windows` returned instantly, collapsing the lock-hold window — not reproducible against a live server.) Steady-state: 40 parallel warm/fresh reads => 0 builders.
  d.3 interval honored: back-date cache 40s (>INTERVAL) + 1 read => exactly 1 rebuild.
So the builder cannot pile up: serialized by the per-client mkdir lock and gated to <=once/30s by cache mtime; redraw rate is fully decoupled from render cost.

Relevant files: ~/projects/tmux-jw/hooks/tmux-claude-bar-render.sh.stormfix-staged (verified); ~/projects/tmux-jw/hooks/tmux-claude-bar-render.sh.bak-stormfix-20260626-141949 (pre-stub reference). Live stubs untouched. RESIDUAL NOTE (not blocking): under heavy cold-start concurrency the double-build is theoretically bounded at ~2 if a build returns near-instantly; with a real tmux read it was always exactly 1, and it self-limits because the next reader sees a fresh cache.
```

## ⚠️ REVIEW — VERDICT: NO-GO

### BLOCKING required-fixes (must resolve BEFORE un-stub)
- CONTINUUM RE-PREPEND (blocking): tmux-continuum's add_resurrect_save_interpolation() in ~/.tmux/plugins/tmux-continuum/continuum.tmux unconditionally PREPENDS '#(continuum_save.sh)' onto whatever status-right is, at TPM init. tmux.conf runs bar.sh (line 129) BEFORE tpm (line 246), so after install the final status-right becomes '#(continuum_save.sh) #(heartbeat.sh)' -> continuum_save runs on EVERY redraw of EVERY client again (the exact per-redraw save path the fix targets, and the single biggest storm contributor per STORM-HANDOFF Delta #1). The heartbeat's throttle does NOT cover this because continuum's #() is a separate sibling job, not invoked via the heartbeat. Each no-op continuum_save still forks ~5 procs/~23ms (sources 3 helpers + check_tmux_version.sh + several tmux show-option). Fix: at install, neutralize continuum's status-right ride. Cleanest = drop @plugin tmux-continuum's autosave hook OR set status-right AFTER tpm runs OR keep @continuum-save-interval driving continuum's OWN timer and remove the heartbeat's direct continuum call. As staged it is BOTH double-driven (heartbeat line 79 AND continuum's prepend) AND back on the hot path.

- tmux.conf NOT in the changeset (blocking): tmux.conf still has status-interval 5 (TWICE, lines 54+110), status-right '#(...statusline.sh)' (line 112, points at a now-permanently-stubbed script), and @continuum-save-interval '5' (line 243). The staged bar.sh only fixes these on a fresh run-shell invocation; a bare 'tmux source-file ~/.tmux.conf' (which the OLD live state.sh STILL does on every hook until state.sh is installed, and which any /config or reload triggers) resets status-interval to 5 and status-right to the stub. The plan's own INSTALL step #2 calls for patching tmux.conf but it is not staged. Required: bump BOTH status-interval lines 5->30, repoint/remove the line-112 status-right (bar.sh now owns status-right via the heartbeat), and resolve @continuum-save-interval to the intended value, BEFORE/with un-stubbing.

- INSTALL ORDER (blocking sequencing): state.sh.stormfix-staged must be installed to the live hooks/tmux-claude-state.sh BEFORE un-stubbing bar-render/statusline/reconcile/continuum_save. The current live state.sh still runs 'tmux source-file ~/.tmux.conf' on every hook whenever the status-right sentinel misses (which it will, since status-right will no longer contain 'tmux-claude-statusline'). If you un-stub before swapping state.sh, the old state.sh re-sources the conf on every tool call across all sessions = re-arms the whole machine = re-storm. Install order: (1) state.sh, (2) patch tmux.conf, (3) neutralize continuum prepend, (4) swap bar.sh + bar-render + heartbeat, (5) restore continuum_save.sh, (6) re-arm once via bar.sh.


### Non-blocking risks (address or consciously accept)
- Stale-pid cache files never pruned (LOW, not a re-storm): bar-render writes row{0,1,2}_<client_pid>, hash_<pid>, vp_<pid>_<session> per client_pid and NOTHING ever deletes them for departed clients. Each mosh reconnect / Jump attach is a new client_pid -> a new permanent ~3KB set in ${TMPDIR}/tmux-claude-bar/cache. No fork amplification (readers only touch their own live pid's files), and TMPDIR clears on reboot, so it is pure inode growth, not load. Minimal mitigation: have the throttled heartbeat prune row*/hash*/vp_* whose mtime is older than a few INTERVALs, or whose pid is not in `tmux list-clients -F #{client_pid}`.

- ✅ RESOLVED 2026-06-26 (was: glyph-state visual lag up to 30s). Instant glyphs restored WITHOUT re-storming, exactly via the suggested global-marker approach: state.sh touches a global `state.dirty` marker ONLY on an actual @ccstate transition (old != new — same-state hook spam like working→working touches nothing, so it stays off the storm path), and the bar-render reader rebuilds whenever `state.dirty` is newer than the per-client `seendirty_<pid>` stamp the builder writes. Race-free: the builder snapshots `state.dirty`'s mtime BEFORE reading @ccstate, so a transition landing mid-build bumps the marker past the recorded mtime → the next read rebuilds again (never a missed change). The 30s INTERVAL gate remains as the backstop. Verified isolated (throwaway server + isolated TMPDIR) AND live: real transition → glyph in <1s; working→working leaves the marker untouched.

- Heartbeat 'stamp FIRST' means a crashed heavy run blocks the next run for a full INTERVAL even though no work completed (LOW): heartbeat writes the stamp before doing reconcile/continuum, so if that run dies mid-way, the reconciler/continuum simply skip one INTERVAL. Self-corrects next tick; only risk is a single missed reconcile cycle. No storm, no wedge (the 120s lock reap covers the lock). Fine as-is; noted for completeness.

- state.sh refresh-client -S is ungated (acknowledged in-code): every tool call still forces a full status redraw across all clients/rows. This is SAFE only because the readers are now pure cats — it is entirely dependent on the bar-render cache being installed and warm. If bar-render is ever stubbed/reverted while state.sh's refresh stays armed, the redraws hit whatever status-format points at. Keep the rollback (re-stub bar-render + status off) as the documented circuit breaker; do not leave state.sh's refresh armed pointing at an un-cached renderer.


## MAP (mechanism reference)
### state.sh re-arm path
```
REFINED — the claim is CORRECT IN EFFECT but the mechanism is INDIRECT/CONDITIONAL, not a direct set. state.sh does NOT itself contain `set status-format/status-right/status`. It re-arms via a self-heal grep guard:

hooks/tmux-claude-state.sh lines 72-73 (the ONLY re-arm path):
  tmux show-options -gv status-right 2>/dev/null | grep -q 'tmux-claude-statusline' \
    || tmux source-file ~/.tmux.conf 2>/dev/null

`~/.tmux.conf` -> dotfiles/tmux/tmux.conf (== repo tmux.conf). Sourcing it re-executes the TOP-LEVEL line tmux.conf:129  `run-shell '~/.config/tmux-jw/hooks/tmux-claude-bar.sh 3'`, and bar.sh:29-35 apply_3() then re-sets `status 3` + `status-format[0/1/2]` (the entire #() job set) and tmux.conf:112 re-sets `status-right`. So sourcing the conf = full re-arm of the bar machine.

WHY IT FIRED EVERY TOOL CALL DURING THE STORM: the firefighter set `status-right ''` live (2026-06-spawn-storm-handoff.md:62). With status-right empty, the grep on line 72 MISSES on EVERY hook event -> line 73 source-file runs on EVERY Pre/PostToolUse/Notification/Stop/UserPromptSubmit hook across ~8 sessions -> bar.sh re-arms the whole #() machine per tool call. That is the per-tool-call multiplier.

NOTE on steady state: when status-right is HEALTHY (contains 'tmux-claude-statusline'), the grep MATCHES and line 73 is SKIPPED — so in normal operation state.sh re-arms NOTHING (it only sets @ccstate, lines 76-80: `tmux set-option -pq -t $TMUX_PANE @ccstate ... refresh-client -S`). The regression is the interaction of the empty-status-right stopgap with the self-heal guard. Also note line 79 calls `refresh-client -S` on every hook, which forces a status redraw (re-runs all #() jobs) per tool call regardless of the re-arm.

FIX (per plan #3): state.sh must set ONLY @ccstate. Strip lines 72-73 (the self-heal source-file) entirely, OR make the heal a one-shot keyed off a sentinel option so it can never fire per-hook. Keep lines 76-80 but consider dropping `refresh-client -S` to `refresh-client -S` only on actual state change (it already only runs once per hook, but it triggers a full bar redraw).
```
### bar.sh format/interval points
```
hooks/tmux-claude-bar.sh is where status-format, #{T:status-right}, and the row-to-render wiring live (NOT tmux.conf — bar.sh owns the format strings; tmux.conf:129 just runs bar.sh):

- Line 14: R='~/.config/tmux-jw/hooks/tmux-claude-bar-render.sh' (the #() target).
- Line 17: A='#{client_width} #{session_name} #{window_index} #{client_pid}' — these baked-in expansions are what make tmux keep a SEPARATE persistent #() job per (client x window x row); client_pid keys per-client scroll.
- Line 25: L0="#($R 0 $A)"
- Line 26: L1="#($R 1 $A)#{T:status-right}"   <-- THE #{T:status-right} that drives continuum_save + statusline per redraw. PLAN #4: drop the `#{T:status-right}` suffix here.
- Line 27: L2="#($R 2 $A)"
- Lines 29-35 apply_3(): `set -g status 3`, `set -g status-format[0]=$L0`, `[1]=$L1`, `[2]=$L2`, `set -g @barmode 3`.
- Lines 37-41 apply_1(): sets status-format[0]=$L1 (note: 1-line mode ALSO carries #{T:status-right}), `status on`, @barmode 1.
- Line 54: `tmux refresh-client -S`.

status-interval is NOT in bar.sh — it is in tmux.conf:54 `set -g status-interval 5` AND tmux.conf:110 `set -g status-interval 5` (set TWICE). PLAN #5: change to 30 in BOTH tmux.conf lines (54 and 110). status-right itself is tmux.conf:112 `set -g status-right ' #(~/.config/tmux-jw/hooks/tmux-claude-statusline.sh) '`. continuum prepends #(continuum_save.sh) to that status-right at plugin init; @continuum-save-interval is tmux.conf:243 ('5', currently 0 live).
```
### cache inputs
```
Per 2026-06-spawn-storm-fix-plan.md #1, the cache is keyed/invalidated per client_pid with a hash over the render inputs. Exact inputs that change the rendered rows (from bar-render args + the two tmux reads):

ARGS (bar.sh line 17 / render line 25): row is NOT a hash input (all 3 rows share one cache build); client_pid (key, line 25 `client`), client_width (`width`), session_name (`session`), current window_index (`cur`).

WINDOW TABLE (render lines 47-52, `tmux list-windows -t $session`): for THIS session, the ordered list of `window_index` + effective name (`#{?#{@ccname},#{@ccname},#{window_name}}`) + `@ccstate` per window. Any add/remove/rename/state-change must bust the hash.

GLOBAL STATUS BOX (render lines 57-60, `tmux list-windows -a`): the multiset of `@ccstate` across ALL windows/sessions (counts g_w/g_q/g_n/g_d/g_s). Changes when any session's state changes anywhere.

VIEWPORT (render lines 77-78, vpfile `vp lastcur lastw`): the persisted scroll position `vp` for this client+session — render is viewport-dependent, so vp (and the manual-scroll file mtime) is effectively an input. Plan lists "vp" explicitly.

=> HASH = hash( session | cur | width | client_pid | (list-windows -t: idx+name+state, ordered) | (list-windows -a: state multiset) | vp ). Compute the two tmux list-windows reads ONCE in the BUILDER, hash them, compare to cached hash; the #() READER just cats row{0,1,2}_<pid> and, if mtime>INTERVAL or stored-hash != quick-recompute, kicks the locked builder. Cache files: ${TMPDIR:-/tmp}/tmux-claude-bar/cache/row{0,1,2}_<client_pid>; lock dir per pid.
```

## NEXT (do AFTER compaction, fresh context)
1. Resolve the 3 BLOCKING fixes above (patch tmux.conf: status-interval 30 ×2, status-right,
   @continuum-save-interval; neutralize continuum's auto re-prepend of continuum_save;
   pin the install ORDER so state.sh-staged lands FIRST).
2. Re-run the adversarial review (or a focused check) until GO.
3. Gated install on user's explicit OK, watching the signature:
   pgrep -fc tmux-claude-bar-render ≈0 idle · continuum_save ≈0 · procs<2s ≈5 not 45 · load flat under busy sessions.
4. ROLLBACK if it twitches: `printf '#!/bin/bash\nexit 0\n' > hooks/tmux-claude-bar-render.sh` + `tmux set -g status off` + `tmux set -gu status-format`.
