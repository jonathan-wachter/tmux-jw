#!/bin/bash
# tmux-claude-state.sh — Claude Code hook → per-pane tmux state
# (STORM-FIX rewrite, 2026-06-26)
#
# Called from settings.json hooks with ONE arg, the state to record:
#   working | question | needs_you | done | clear
#
# Writes the state to this pane's @ccstate tmux user option, which
# ~/.tmux.conf renders as emoji in window tabs and pane borders:
#   🤖 working · 💬 question (AskUserQuestion) · 🔴 needs you · ✅ done (unseen)
#
# ⚠️ STORM FIX — WHAT CHANGED AND WHY (see docs/notes/2026-06-spawn-storm-fix-plan.md #3):
# The old version re-armed the ENTIRE status machine on EVERY hook event via a
# self-heal guard:
#     tmux show-options -gv status-right | grep -q 'tmux-claude-statusline' \
#       || tmux source-file ~/.tmux.conf
# That grep MISSED on every event whenever status-right was empty (e.g. the storm
# stopgap `set -g status-right ''`), so `source-file ~/.tmux.conf` ran on EVERY
# Pre/PostToolUse/Notification/Stop hook across ~8 sessions. Sourcing the conf
# re-executes `tmux-claude-bar.sh 3`, which re-sets status-format[0/1/2] +
# status-right — i.e. it re-armed the whole #() fork machine PER TOOL CALL. That
# was the per-tool-call multiplier behind the spawn storm.
#
# This script now sets ONLY @ccstate (per pane). It NEVER re-arms status-format,
# status-right, status, or runs bar.sh / source-file. The bar is armed exactly
# once at config load (tmux.conf → tmux-claude-bar.sh) and stays armed; if a
# manual experiment ever wipes status-right, re-arm deliberately with
# `~/.config/tmux-jw/hooks/tmux-claude-bar.sh 3` (or reload tmux.conf) — not from
# this hot path.
#
# Design notes (research 2026-06-10):
# - Hooks give INSTANT transitions but miss crashes/Ctrl+C/kills — the
#   companion tmux-claude-reconcile.sh (run off the bar's throttled path) is the
#   safety net that fixes stale state within ~INTERVAL.
# - $TMUX_PANE is inherited from the Claude Code process environment.
# - Per-pane user options die with the pane = free garbage collection.

STATE="$1"

# Hooks MUST consume stdin (Claude Code pipes JSON; not draining it can
# surface broken-pipe errors). We also need it for the Stop payload below.
INPUT=$(cat)

# Not inside tmux (Ghostty bare window, web session, etc.) — nothing to do.
[ -z "$TMUX" ] && exit 0
[ -z "$TMUX_PANE" ] && exit 0

# ── SELF-HEAL (safe): the heartbeat that drives the reconciler (window naming,
# recaps, stale-state cleanup) AND continuum autosave rides status-right. If
# status-right ever loses it — a stray `set status-right ''`, a partial conf
# reload, a server restart that didn't re-arm — all of that silently freezes (it
# did, for 3.4h, on 2026-06-28). Restore it here with a SINGLE direct `set` when
# the sentinel is missing. This is NOT the old self-heal that did
# `source-file ~/.tmux.conf` (a full re-arm that caused the 2026-06-26 spawn
# storm) — just one idempotent option set, so it can't storm even if it fired
# every hook. Cost when healthy: one `tmux show`.
case "$(tmux show -gv status-right 2>/dev/null)" in
  *tmux-claude-heartbeat*) : ;;   # healthy — heartbeat is wired
  *) tmux set -g status-right ' #(~/.config/tmux-jw/hooks/tmux-claude-heartbeat.sh) ' 2>/dev/null ;;
esac

# Is this pane currently on-screen in an attached client? (pane is active in
# its window AND that window is current AND the session has a client attached)
# Fetch visibility AND the current @ccstate in ONE tmux call — the @ccstate read is
# free here (folded into the existing display-message), so the transition check at
# the bottom costs no extra fork. `|` splits cleanly even when @ccstate is empty.
info=$(tmux display-message -p -t "$TMUX_PANE" \
  '#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}|#{@ccstate}' 2>/dev/null)
visible=${info%%|*}; old_ccstate=${info#*|}

case "$STATE" in
  done)
    # Stop fired — but if background tasks are still running, the session is
    # really still working (Stop fires at turn end even with bg work alive).
    if command -v jq >/dev/null 2>&1; then
      running=$(printf '%s' "$INPUT" \
        | jq -r '[.background_tasks[]? | select(.status=="running")] | length' 2>/dev/null)
      [ "${running:-0}" -gt 0 ] 2>/dev/null && STATE="working"
    fi
    # "done" means "finished while you weren't looking" — if you're already
    # looking at this pane, skip straight to idle (no stale ✅ to clear).
    if [ "$STATE" = "done" ] && [ "$visible" = "1" ]; then
      STATE="clear"
    fi
    ;;
  question|needs_you)
    # Ring the terminal bell ONLY when the pane isn't on-screen: Ghostty
    # badges/notifies natively, and tmux sets its bell flag as a fallback.
    # /dev/tty is required — hook stdout never reaches the terminal.
    if [ "$visible" != "1" ]; then
      { printf '\a' > /dev/tty; } 2>/dev/null || true
    fi
    ;;
esac

# Write @ccstate for this pane, then request a status redraw. This is the ONLY
# tmux state this hook touches — no status-format/right/status re-arm.
newval="$STATE"; [ "$STATE" = "clear" ] && newval=""

# (1) Set @ccstate FIRST, so any rebuild kicked by the dirty touch below reads the
#     already-updated value.
if [ "$STATE" = "clear" ]; then
  tmux set-option -pq -t "$TMUX_PANE" -u @ccstate 2>/dev/null
  # new/cleared session ⇒ any project association belongs to the OLD
  # session id — drop the pane marker so the bar shows P? again (the
  # authoritative assoc file is keyed by session id and unaffected)
  tmux set-option -pq -t "$TMUX_PANE" -u @ccproj 2>/dev/null
else
  tmux set-option -pq -t "$TMUX_PANE" @ccstate "$STATE" 2>/dev/null
fi

# (2) Near-instant glyphs: touch the global dirty marker ONLY on an ACTUAL
#     transition (old != new). bar-render's cached reader deliberately ignores
#     @ccstate between rebuilds (that decoupling is what tamed the spawn storm),
#     so without this signal a glyph could lag up to INTERVAL (30s). Touching ONLY
#     on a real change is what keeps this OFF the storm path: same-state hook spam
#     (working→working on every tool call) does nothing. Must sit AFTER the set
#     above and BEFORE the refresh below so the forced redraw sees both the fresh
#     marker and the new @ccstate.
if [ "$old_ccstate" != "$newval" ]; then
  d="${TMPDIR:-/tmp}/tmux-claude-bar"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null
  : > "$d/state.dirty" 2>/dev/null || true
fi

# (3) Force the status redraw so the change shows immediately — on EVERY client.
#     `refresh-client -S` with no -t resolves "current client" = ONE client (the
#     most-recently-active one), so with several clients attached (Ghostty + Jump
#     + Moshi is a typical multi-device setup) the other clients kept the STALE cached
#     row until their next status-interval tick — up to 30s of "the emoji didn't
#     update" (proven live 2026-07-09: 1 of 3 clients rebuilt). Emitting one
#     refresh-client per client via `source-file -` keeps it at 2 forks total,
#     and this only runs on a real transition, so it cannot storm.
tmux list-clients -F 'refresh-client -S -t "#{client_name}"' 2>/dev/null \
  | tmux source-file - 2>/dev/null

exit 0
