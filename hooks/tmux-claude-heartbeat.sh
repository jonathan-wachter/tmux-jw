#!/bin/bash
# tmux-claude-heartbeat.sh — throttled driver for the state reconciler + continuum
# autosave, OFF the per-redraw render path. (STORM-FIX, 2026-06-26.)
#
# WHY THIS EXISTS: the storm's single biggest load source was continuum_save (→
# tmux-resurrect save.sh, which forks `ps` per pane) being driven by
# #{T:status-right} on a BAR ROW — i.e. on every redraw of every client of every
# row, stacking 5+ save.sh deep under load (docs/notes/2026-06-spawn-storm-handoff.md). The reconciler kick
# rode the same path. The bar rows no longer reference status-right at all; instead
# bar.sh wires THIS script as the default status-right (rendered ≤once per redraw
# per client, never per cell/row), and this script self-throttles so the heavy
# work fires AT MOST once per INTERVAL across the WHOLE server — save.sh can never
# stack again.
#
# It is a pure HEARTBEAT: it prints NOTHING (the bar rows already fill the line),
# returns in ~2ms (a stat + a mkdir attempt), and detaches all heavy work so tmux's
# #() capture returns immediately (the child does not hold tmux's stdout pipe open).
#
# bash 3.2 safe; macOS has no flock → atomic mkdir locks + mtime time-gates.

export LC_ALL=en_US.UTF-8

INTERVAL=30                                   # min seconds between heavy runs (server-global)
GATE_DIR="${TMPDIR:-/tmp}/tmux-claude-bar"
STAMP="${GATE_DIR}/heartbeat.stamp"           # mtime = last heavy run
LOCK="${GATE_DIR}/heartbeat.lock.d"           # atomic mkdir lock (overlap guard)

DIR=$(dirname "$0")
RECONCILE="${DIR}/tmux-claude-reconcile.sh"
RECONCILE_LOCK="$HOME/.cache/tmux-claude/reconcile.lock.d"
CONTINUUM="$HOME/.tmux/plugins/tmux-continuum/scripts/continuum_save.sh"

now=$(date +%s)

# ── Time-gate: only proceed if INTERVAL has elapsed since the last heavy run.
# This is the cheap fast-path most invocations take (one stat, then exit). The
# gate is server-global (single stamp file), so no matter how many clients/rows
# render status-right, the heavy work fires ≤once/INTERVAL.
if [ -r "$STAMP" ]; then
  last=$(stat -f %m "$STAMP" 2>/dev/null || echo 0)
  [ $(( now - last )) -lt "$INTERVAL" ] && exit 0
fi

# ── Detach EVERYTHING heavy. Redirecting the whole block to /dev/null means the
# backgrounded child does NOT hold tmux's stdout pipe open — tmux gets EOF the
# instant this script's foreground returns (which is right here, nothing printed).
{
  mkdir -p "$GATE_DIR" 2>/dev/null

  # Reap a wedged lock (crashed run) so the heartbeat can never stall forever.
  if [ -d "$LOCK" ]; then
    lage=$(( now - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
    [ "$lage" -gt 120 ] && rmdir "$LOCK" 2>/dev/null
  fi

  # Single-flight: only one heavy run at a time across the whole server.
  if mkdir "$LOCK" 2>/dev/null; then
    # Stamp FIRST so concurrent renders during this run all see a fresh gate and
    # skip — the run itself can take a few seconds and we don't want pile-up.
    : > "$STAMP" 2>/dev/null

    # (1) RECONCILER kick — same locked pattern the old statusline.sh used. Its
    # own lock (RECONCILE_LOCK) plus our outer gate means at most one reconcile
    # ever runs; a crashed reconcile can't wedge it (60s stale-lock reap).
    if [ -d "$RECONCILE_LOCK" ]; then
      rage=$(( $(date +%s) - $(stat -f %m "$RECONCILE_LOCK" 2>/dev/null || echo 0) ))
      [ "$rage" -gt 60 ] && rmdir "$RECONCILE_LOCK" 2>/dev/null
    fi
    if mkdir "$RECONCILE_LOCK" 2>/dev/null; then
      [ -x "$RECONCILE" ] && "$RECONCILE" --write
      rmdir "$RECONCILE_LOCK" 2>/dev/null
    fi

    # (2) CONTINUUM autosave — now driven on THIS throttled path only, not per
    # redraw. continuum_save.sh additionally self-gates on @continuum-save-interval
    # and self-locks, and the actual tmux-resurrect save it triggers is itself
    # detached — so even back-to-back heartbeats cannot stack save.sh. Only fires
    # if continuum is installed and autosave is enabled (interval > 0).
    [ -x "$CONTINUUM" ] && "$CONTINUUM"

    # (3) PRUNE departed-client cache/viewport files + reap stale builder locks.
    # Extracted to tmux-claude-prune.sh (2026-07-08, P5) — same helper-script
    # pattern as snapshot.sh/crashcap.sh below; see its header for the age-guard
    # rationale. Self-locating, fully guarded, inherits TMPDIR + PATH from here.
    "${DIR}/tmux-claude-prune.sh" >/dev/null 2>&1 || true

    rmdir "$LOCK" 2>/dev/null
  fi
} >/dev/null 2>&1 &

exit 0
