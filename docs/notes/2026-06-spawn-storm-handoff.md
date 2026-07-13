# tmux-jw spawn-storm — handoff from the firefight session

You (the bar-render author session) own the fix. This is the **delta** on top of your
own root-cause writeup — the parts my investigation surfaced that yours understates or
misses — plus the **exact changeset I applied** so you can restore from a known state.

Your analysis is correct (uncached per-cell-subshell renders + a redraw loop). Agreed.
Don't re-derive it. Just fold in the two items below before you implement the cache.

---

## Delta #1 — the heaviest single load source isn't bar-render, it's continuum → tmux-resurrect `save.sh` STACKING

`status-right` = `#(continuum_save.sh) #(statusline.sh)`, and `status-format[1]` expands
`#{T:status-right}`, so continuum_save runs on **every redraw**. continuum_save triggers
**tmux-resurrect `save.sh`**, which forks **`ps` per pane**. Under load each save takes
>5s, so saves don't finish before the next fires → I caught **5+ concurrent `save.sh`
instances stacked** (ages 43s/42s/41s/3s/2s) at peak. This is an independent heavy forker
beyond bar-render and the statusline→reconciler loop.

→ Your fix #3 (move continuum off the per-redraw `#{T:status-right}` path) is exactly
right — just know that the resurrect-save stacking, not statusline, was the biggest
contributor to the 300 load. Put continuum on a single locked fixed-interval timer
(or disable auto-save). I already set `@continuum-save-interval 0` live as a stopgap.

## Delta #2 — `#()` job multiplication: clients × windows × rows, re-armed every tool call

The `#()` strings bake in `#{client_pid} #{window_index} #{client_width}`, so tmux keeps a
**separate persistent job per (client × window × row)**. With 16+ windows × several
attached clients (2 mosh + Jump) × 3 rows = **dozens of distinct jobs**, each re-run every
`status-interval` (was **5s**). And `state.sh` (Claude-Code PreToolUse/PostToolUse/
Notification/Stop hook) **re-installs the whole status machine on every tool call across
all ~8 sessions** — so the job set kept getting re-armed at tool-call frequency.

→ Your fix #4 (state.sh sets only `@ccstate`, never re-arms the bar) is the key structural
fix — it breaks the re-arm-on-every-tool-call multiplier. When you cache bar-render, key
the cache per `client_pid` and consider collapsing rows so you don't keep 3× the jobs.
Also bump `status-interval` (5 → 30) regardless; it's a free 6× cut.

---

## Exact changeset I applied (so you can restore cleanly)

### Scripts stubbed to `exit 0` (originals backed up next to them):
| stubbed file | backup |
|---|---|
| `~/.config/tmux-jw/hooks/tmux-claude-bar-render.sh` | `.bak-stormfix-20260626-141949` |
| `~/.config/tmux-jw/hooks/tmux-claude-statusline.sh` | `.bak-stormfix-20260626-142301` |
| `~/.config/tmux-jw/hooks/tmux-claude-reconcile.sh` | `.bak-stormfix-20260626-142301` |
| `~/.tmux/plugins/tmux-continuum/scripts/continuum_save.sh` | `.bak-stormfix-20260626-142301` |

Stubs were written via shell `printf` (NOT the Edit/Write tool), so **auto-commit did not
fire** — they're working-tree-only, uncommitted. `git stash`/checkout of the hooks dir
would restore the committed (pre-stub) versions; the `.bak-stormfix-*` files are identical
to those and safe to delete once you've re-installed your real fix.

### Live tmux options I changed on server `cc-0624` (PID 5283):
```
status off
status-format            # unset (set -gu) — reverted to tmux default
status-right             ''
status-left              ''
status-interval          60
@continuum-save-interval 0
```
These get re-armed by `state.sh`/`bar.sh` on the next tool call / config reload, but
that's harmless while the scripts are stubbed. After your fix: re-install the bar via
`~/.config/tmux-jw/hooks/tmux-claude-bar.sh 3` (or reload tmux.conf) and re-enable
continuum if you want it.

### ⚠️ Do NOT naked-un-stub
Un-stubbing without your cache fix + `state.sh` decoupling brings the storm straight back —
state.sh re-arms the same `#()` fork machine. Land the fix first, then un-stub.

---

## Verification target
Storm signature to watch while testing (these were the tells):
- `pgrep -fc tmux-claude-bar-render` and `continuum_save` should stay ~0 at idle
- procs <2s old (`ps -axo etime | awk '$1 ~ /^00:0[0-2]$/' | wc -l`) ~5, not 45+
- `load` should not climb when sessions get busy (busy sessions = more state.sh hooks =
  the original amplifier — that's the real regression test)

Peak was load 302, ~700 procs/sec. Baseline now ~45 and draining.
