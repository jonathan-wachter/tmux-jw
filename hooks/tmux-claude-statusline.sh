#!/bin/bash
# tmux-claude-statusline.sh — SUPERSEDED 2026-06-26 by tmux-claude-heartbeat.sh.
#
# Its only remaining job (kick the background reconciler from the status bar) moved
# into tmux-claude-heartbeat.sh, which adds a 30s time-gate so the reconciler +
# continuum autosave fire <=once/INTERVAL instead of every redraw — the fix for the
# 2026-06-26 spawn storm (see docs/notes/2026-06-spawn-storm-fix-plan.md). status-right now runs the
# heartbeat; nothing references this file. Kept as a no-op tombstone so any stale
# reference fails safe. Pre-storm version: git history + the .bak-stormfix backup.
exit 0
