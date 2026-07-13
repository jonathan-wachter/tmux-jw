#!/bin/bash
# tmux-claude-dashboard-open.sh — size-aware launcher for the dashboard popup
#
# Bound to prefix+o (and the bar's left-block tap). display-popup geometry is
# fixed at invocation, so this
# launcher checks the invoking client's width and picks:
#   narrow (<110 cols, iPhone/iPad-portrait in Moshi) → borderless full screen
#   wide   (Mac/iPad-landscape)                       → 85% x 70% with border
#
# run-shell from a key binding carries the pressing client's context, so
# #{client_width} resolves to the right device.

DASH="$(dirname "$0")/tmux-claude-dashboard.sh"   # sibling script (self-locating)

# Capture the invoking client's context HERE (reliable) and pass it to the popup,
# which can't always resolve "current session" from inside display-popup. The
# client_name lets the popup's Enter switch THIS client to another session
# (switch-client -c) — the cross-session "open" added in dashboard v2.
w=$(tmux display-message -p '#{client_width}' 2>/dev/null)
ses=$(tmux display-message -p '#{session_name}' 2>/dev/null)
cw=$(tmux display-message -p '#{window_index}' 2>/dev/null)
cl=$(tmux display-message -p '#{client_name}' 2>/dev/null)

# DROPDOWN look (2026-07-02): the popup hangs off the boxbar like a menu.
#   -y S     = anchor to the status line (status is at top → popup sits flush
#              beneath the bar, whatever its current height, 3-line or 1-line)
#   -x C     + -w 96% = near-full width with slim symmetric margins
#   -h       = NEAR-FULL HEIGHT (2026-07-03, was 58%): client height minus the
#              bar minus a GAP-row reveal at the bottom, so the Claude Code
#              text-entry area stays visible under the dropdown and the window
#              list doesn't scroll until it truly runs out of screen.
#   -s / -S  = fill + border in the bar's own scheme (slate border on blue-gray)
PSTYLE='bg=#b5bcc8,fg=#1a1a1a'
PBORDER='fg=#394553,bg=#b5bcc8'
GAP=5
ht=$(tmux display-message -p '#{client_height}' 2>/dev/null)
sl=$(tmux show-option -gv status 2>/dev/null)
case "$sl" in [1-5]) ;; *) sl=1;; esac        # "on"/"off"/junk → treat as 1 line
ph=$(( ${ht:-40} - sl - GAP ))
[ "$ph" -lt 10 ] && ph=10

# SIZE TO FIT v3 (2026-07-08, P1): the height above is the MAX. Measure the
# LARGEST session's content (measure mode builds the real model — wrapped
# recaps — at the popup's inner width) and size to it, because the popup CANNOT
# be resized after launch (display-popup ignores -w/-h when re-run inside an
# existing popup) and ←/→ browses other sessions — sizing only the opening
# session left bigger sessions scrolling in a too-small box (the "parked windows
# are missing" bug, 2026-07-03).
#
# PERF (P1): this used to re-exec the whole dashboard script ONCE PER SESSION in
# a serial loop — a fork storm that dominated prefix+o latency. JW_DASH_MEASURE=all
# does the max in ONE process (and only over Claude-active sessions, the ones the
# popup can actually show). Shrink to content + 4 chrome rows + 2 border rows.
iw=$(( ${w:-100} * 96 / 100 - 2 )); [ "$iw" -lt 20 ] && iw=20
content=$(JW_DASH_MEASURE=all JW_DASH_COLS="$iw" bash "$DASH" "$ses" 1 2>/dev/null)
case "$content" in ''|*[!0-9]*) content=9999 ;; esac   # probe failed → force max height
fit=$(( content + 4 + 2 ))
[ "$fit" -lt 10 ] && fit=10
[ "$fit" -lt "$ph" ] && ph=$fit
if [ -n "$w" ] && [ "$w" -lt 110 ]; then
  # narrow (iPhone): keep borderless full-screen, just adopt the scheme
  tmux display-popup -B -s "$PSTYLE" -w 100% -h 100% -E "$DASH $ses $cw $cl"
else
  tmux display-popup -x C -y S -w 96% -h "$ph" -s "$PSTYLE" -S "$PBORDER" -E "$DASH $ses $cw $cl"
fi
