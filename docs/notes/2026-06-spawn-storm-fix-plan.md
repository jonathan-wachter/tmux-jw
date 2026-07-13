# tmux-jw spawn-storm — FIX PLAN  (owner: bar-render author session)

Durable spec so this survives context compaction. Pair with `2026-06-spawn-storm-handoff.md`
(firefighter's restore facts). **Storm is contained; load draining.** The job now
is to land the *real* fix, then carefully un-stub. DO NOT naked-un-stub.

## Current frozen state (from 2026-06-spawn-storm-handoff.md)
- 4 scripts STUBBED to `exit 0` (uncommitted, working-tree-only) + `.bak-stormfix-*` backups:
  - `hooks/tmux-claude-bar-render.sh`  (.bak-stormfix-20260626-141949)
  - `hooks/tmux-claude-statusline.sh`  (.bak-stormfix-20260626-142301)
  - `hooks/tmux-claude-reconcile.sh`   (.bak-stormfix-20260626-142301)
  - `~/.tmux/plugins/tmux-continuum/scripts/continuum_save.sh` (.bak-stormfix-20260626-142301)
- Live tmux opts changed on the live server: `status off`, `status-format` unset, `status-right ''`,
  `status-left ''`, `status-interval 60`, `@continuum-save-interval 0`.
- Pre-stub versions are in git (committed) AND in the `.bak-stormfix-*` files (identical).

## Root cause (settled — do NOT re-derive)
1. **Amplifier:** `bar-render.sh` does ALL work per `#()` call, NO cache, ~30 per-cell `$(…)`
   subshells/render × 3 rows × clients. My 13:11 tight-tabs/flexible-cell edit raised cell count →
   heavier renders → pileup under load.
2. **Multiplier:** `state.sh` (Claude-Code Pre/PostToolUse/Notification/Stop hook) re-arms the whole
   status machine on EVERY tool call across ~8 sessions → re-arms the `#()` job set (clients × windows × rows).
3. **Biggest load:** `#{T:status-right}` on row 1 → `#(continuum_save)` every redraw → tmux-resurrect
   `save.sh` (forks `ps`/pane) STACKING 5+ deep. This, not statusline, drove load to 302.

## The fix (5 parts)
1. **bar-render = stale-while-revalidate cache** (mirror `statusline.sh`'s pattern):
   - `#()` = fast READER: `cat` the per-client cached row; if stale (mtime > INTERVAL OR input-hash
     changed) kick the background BUILDER (mkdir-locked, per client_pid). Return cached row instantly.
   - BUILDER (background, detached): the heavy render (the 2 `tmux list-windows` calls + build all 3
     rows for this client_pid) → write 3 cache files atomically. Runs ≤ once/INTERVAL per client.
   - Cache: `${TMPDIR:-/tmp}/tmux-claude-bar/cache/row{0,1,2}_<pid>`; lock dir per pid.
   - Input-hash = hash(session, cur win, width, window-list+states, vp). Rebuild only on change.
   - NET: redraw rate + server load decoupled from render cost → cannot pile up.
2. **Kill per-cell subshells** in the builder: rewrite `dwidth`/`repeat`/`head_w`/`tail_w` to write a
   result var via `printf -v <name>` (nameref/arg), NOT `$(…)`. Builder should fork ≈0 beyond the 2 tmux reads.
3. **state.sh sets ONLY `@ccstate`** (per-pane). VERIFY it currently re-arms status-format/right/status/
   bar.sh and STRIP that. This kills the per-tool-call re-arm multiplier (the real regression condition).
4. **Decouple continuum + reconciler from the per-redraw path:**
   - Remove `#{T:status-right}` from `status-format[1]` (in `bar.sh`).
   - Reconciler kick + continuum-save run on ONE fixed-interval, mkdir-LOCKED path (≤once/INTERVAL),
     so resurrect `save.sh` can never stack. Simplest: fold both into the throttled bar-render BUILDER
     (it already runs ≤once/interval) with independent locks; OR a dedicated low-freq `set-hook`.
     Restore `@continuum-save-interval` to a sane value (e.g. 15) only if continuum's own timer is the driver.
5. **`status-interval 5 → 30`** in `bar.sh`/`tmux.conf` (free 6× cut).

## BUILD SAFELY — staged + isolated (never touch the live server or install)
- Write new versions to `hooks/<name>.sh.stormfix-staged` — do NOT overwrite the live stubbed `hooks/*.sh`.
- Test the staged bar-render in an ISOLATED server: `tmux -L stormtest` with mock windows. Verify:
  (a) 3 rows render identically to pre-storm; (b) after warm-up, idle = 0 background builders;
  (c) each `#()` reader forks ≈0 (just a cat); (d) builder runs ≤once/interval (lock + mtime gate).
- Adversarial storm-safety review: can it re-arm itself? cache races? does staged `state.sh` set ONLY
  `@ccstate`? is the resurrect-save stacking gone? GO/NO-GO verdict + residual risks.

## INSTALL — gated on user's EXPLICIT go; watch the signature
1. Confirm git has pre-stub versions (rollback source).
2. `mv` staged → live (bar-render; statusline/reconcile/state.sh if changed); patch `bar.sh`
   (drop `#{T:status-right}`, `status-interval 30`, continuum decouple); restore/replace `continuum_save.sh`.
3. Re-arm: `~/.config/tmux-jw/hooks/tmux-claude-bar.sh 3` (or reload tmux.conf); `status on`; set sane `@continuum-save-interval`.
4. WATCH (firefighter's signature): `pgrep -fc tmux-claude-bar-render` ≈ 0 idle; `continuum_save` ≈ 0;
   procs <2s old (`ps -axo etime|awk '$1~/^00:0[0-2]$/'|wc -l`) ≈ 5 not 45; load FLAT when sessions get busy.
5. ROLLBACK if it twitches: re-stub bar-render (`printf '#!/bin/bash\nexit 0\n' > …`) + `status off` +
   `status-format` unset. (Firefighter's circuit breaker.)

## Notes
- Repo auto-commits AND auto-pushes; `.stormfix-staged` files auto-commit (harmless, not installed).
- Live tmux = default socket. `~/.config/tmux-jw` → `~/projects/tmux-jw` (editing a hook = editing live).
- The dangerous step is ONLY the un-stub (#INSTALL). Everything before it is safe/isolated.
