#!/bin/bash
# tmux-pipelines-ticker.sh — ensure a detached 'wraps' session is running the
# session-pipelines lifecycle ticker (`pipelines trace -f`), so the journal of
# hook → enqueue → run → notify is always one cockpit hop (prefix+o) or
# `tmux attach -t wraps` away.
#
# Idempotent: exits instantly if the session exists. Fired from tmux.conf at
# server start AND from client-attached[52], so a ticker that died (jq crash,
# manual kill) is resurrected on the next attach. If the ticker process exits,
# the pane/session dies with it — that's the signal to this script to rebuild.
#
# PATH: run-shell/launchd environments carry a minimal PATH (/usr/bin:/bin).
# The CLI needs jq (Homebrew), so the session command sets PATH explicitly —
# without it the ticker dies instantly and the session evaporates with it
# (exactly what happened on first deploy, 2026-07-15).

SESSION="wraps"
PIPELINES="$HOME/projects/session-pipelines/bin/pipelines"

[ -x "$PIPELINES" ] || exit 0                       # facility not installed → no-op
tmux has-session -t "=$SESSION" 2>/dev/null && exit 0

tmux new-session -d -s "$SESSION" -n trace \
  "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin exec '$PIPELINES' trace -f"
