#!/bin/bash
# tmux-claude-dirty.sh — mark the boxbar cache stale and force ONE redraw.
# (2026-07-08, P4)
#
# WHY: the boxbar reader (tmux-claude-bar-render.sh) rebuilds a cached row early
# only when the global `state.dirty` marker moves (an @ccstate transition) —
# otherwise it waits out the INTERVAL (30s) mtime gate. That left three common
# events lagging up to 30s: a window RENAME, a NEW window, and a CLOSED window.
# This tiny hook bumps `state.dirty` and forces a status redraw so those show
# in ~200ms, exactly like an @ccstate change does.
#
# Wired from tmux.conf as indexed hooks (window-renamed/linked/unlinked[52]) so
# re-sourcing the conf overwrites — never stacks — this entry. Also called by
# tmux-claude-reconcile.sh after it publishes an @ccname (a rename the tmux
# window-renamed hook doesn't see, since it's a tmux OPTION change not a name).
#
# STORM-SAFE: the work is one `:>` (truncate) + one `refresh-client -S`. The
# refresh re-reads CACHED rows (the builder still runs ≤once/INTERVAL behind its
# mkdir lock), so even if window-renamed fires on every shell auto-rename this
# cannot pile up. Mirrors the touch-then-refresh pattern in tmux-claude-state.sh.

[ -z "$TMUX" ] && exit 0            # not inside tmux (nothing to redraw)

d="${TMPDIR:-/tmp}/tmux-claude-bar"
[ -d "$d" ] || mkdir -p "$d" 2>/dev/null
: > "$d/state.dirty" 2>/dev/null || true
# Refresh EVERY client, not just the one tmux resolves as "current" — with
# multiple clients attached the others otherwise sit on the stale cached row
# until their next status-interval tick (up to 30s). Same fix as state.sh.
tmux list-clients -F 'refresh-client -S -t "#{client_name}"' 2>/dev/null \
  | tmux source-file - 2>/dev/null
exit 0
