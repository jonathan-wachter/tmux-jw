#!/bin/bash
# tmux-claude-bar.sh — install the dashboard bar mode and point status-format at
# the render script. Runs ONCE at config load and ONCE per toggle (never per
# redraw), so it can't cause the mosh cursor flicker the old inline reconciler did.
# (STORM-FIX rewrite, 2026-06-26 — see docs/notes/2026-06-spawn-storm-fix-plan.md #4 and #5.)
#
# The actual table is drawn by tmux-claude-bar-render.sh (now stale-while-
# revalidate: the #() readers are pure cats; a throttled background builder does
# the heavy render ≤once/INTERVAL per client). This script wires the 3 status rows
# to it, flips 3-line ⇆ 1-line, and installs the throttled heartbeat that keeps
# continuum-save + the state reconciler ticking OFF the per-redraw path.
#
#   prefix + b  →  toggle 3-line table ⇆ 1-line table (same colors)
#
# Usage: tmux-claude-bar.sh [3|1|toggle]   (default: 3)

R='~/.config/tmux-jw/hooks/tmux-claude-bar-render.sh'
HB='~/.config/tmux-jw/hooks/tmux-claude-heartbeat.sh'
# tmux expands these per client. client_pid keys the per-client scroll position so
# a wide Mac and a narrow phone keep independent (stable) viewports.
A='#{client_width} #{session_name} #{window_index} #{client_pid}'

# ── STORM FIX #5 cut redraw frequency 5s → 30s when redraws were expensive.
#    2026-07-09: relaxed to 10s — a redraw is now 3 cat-readers + a stat-and-exit
#    heartbeat per client (SWR cache), and the heavy builder is gated by its own
#    INTERVAL=30 + dirty markers, so redraw rate no longer drives build rate.
#    10s is purely the FALLBACK lag cap for any push the refresh-all misses.
#    Also set in tmux.conf; keep BOTH in sync so a bare conf reload that does
#    NOT re-run this script can't diverge.
tmux set -g status-interval 10

# ── STORM FIX #4: status-right's PAYLOAD changes, not its wiring. Row 1 MUST keep
# #{T:status-right} — that suffix is the ONLY thing that makes tmux evaluate
# status-right at all. With a custom status-format that omits it on every row,
# status-right is never drawn, so the heartbeat never fires: no reconciler, no
# autosave, glyphs/recaps silently freeze. (Verified empirically 2026-06-26 with a
# pty-attached client: 0 heartbeat fires without the suffix, fires with it.)
# What actually changed is the CONTENT of status-right. It used to be
# #(continuum_save.sh) #(statusline.sh) — continuum's save fired on EVERY redraw of
# EVERY client, stacking tmux-resurrect save.sh 5+ deep under load (the single
# biggest storm source, per docs/notes/2026-06-spawn-storm-handoff.md). Now status-right is a SINGLE
# self-throttling, mkdir-locked heartbeat: cheap stat+exit per render, heavy
# reconcile + continuum work gated to ≤once/INTERVAL server-wide, so save.sh can
# never stack. continuum's own auto-prepend of #(continuum_save.sh) onto
# status-right at tpm init is stripped by a post-tpm re-assert in tmux.conf.
L0="#($R 0 $A)"
L1="#($R 1 $A)#{T:status-right}"
L2="#($R 2 $A)"

apply_3() {
  tmux set -g status 3
  tmux set -g 'status-format[0]' "$L0"
  tmux set -g 'status-format[1]' "$L1"
  tmux set -g 'status-format[2]' "$L2"
  tmux set -g @barmode 3
}

apply_1() {
  tmux set -g 'status-format[0]' "$L1"
  tmux set -g status on   # tmux's `status` takes on|off|2..5 — "on" IS the 1-line value
  tmux set -g @barmode 1
}

# ── Throttled heartbeat (drives reconciler + continuum-save off the render path).
# status-right is rendered once per row-1 redraw per client (NOT per cell), and the
# heartbeat script is itself mkdir-locked + time-gated to fire its heavy work
# ≤once/INTERVAL across the whole server. It prints nothing visible (zero-width),
# so the bar rows already fill the line and this never shows.
# IMPORTANT: tmux-continuum PREPENDS its OWN #(continuum_save.sh) onto status-right
# at tpm init (continuum.tmux:add_resurrect_save_interpolation), which would make
# continuum_save a SIBLING that fires on every redraw — NOT gated by this heartbeat
# (it's a separate #() job). That sibling is the storm's biggest contributor, so it
# is STRIPPED at install by a post-tpm re-assert of status-right in tmux.conf (which
# runs AFTER tpm and wins). After that, continuum_save runs ONLY via this heartbeat.
install_heartbeat() {
  tmux set -g status-right-length 60
  tmux set -g status-right " #(${HB}) "
}

arg="${1:-3}"
if [ "$arg" = "toggle" ]; then
  cur=$(tmux show -gv @barmode 2>/dev/null || echo 3)
  if [ "$cur" = "3" ]; then arg=1; else arg=3; fi
fi

case "$arg" in
  1) apply_1 ;;
  *) apply_3 ;;
esac

install_heartbeat

# Mode flip changes what the BUILDER emits (numbers inline vs on the top
# border), so poke state.dirty — else every client serves the OTHER mode's
# cached rows until the 30s mtime gate. Refresh EVERY client (same multi-client
# fix as state.sh); runs once per toggle/config-load, cannot storm.
d="${TMPDIR:-/tmp}/tmux-claude-bar"
[ -d "$d" ] || mkdir -p "$d" 2>/dev/null
: > "$d/state.dirty" 2>/dev/null || true
tmux list-clients -F 'refresh-client -S -t "#{client_name}"' 2>/dev/null \
  | tmux source-file - 2>/dev/null || true
