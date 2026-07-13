#!/usr/bin/env bash
# tmux-window-teleport.sh <target-slot> <window-id> <session-name>
# ─────────────────────────────────────────────────────────────────────────────
# Teleport a window to an ABSOLUTE slot number: it lands AT the number you
# typed, everything from that slot rightward shifts over one, the vacated slot
# is closed up, and the session ends gap-free. Bound to prefix+. in tmux.conf.
#
# WHY A SCRIPT (the bugs this fixes over plain `move-window -b -t N`):
#   1. move-window NEVER triggers the renumber-windows option — that option
#      only fires when a window is CLOSED (man tmux: "when a window is closed
#      in a session"). So every teleport used to leave a gap at the old slot.
#   2. Gaps make index numbers diverge from visible bar position: after an
#      upward move you'd be INDEX 8 but only the 7th tab on the ribbon — the
#      "off-by-one shortfall" that compounds with every subsequent move.
#      Fix: renumber BEFORE (heal inherited gaps so typed numbers mean what
#      the bar shows) and AFTER (close the gap this move just made).
#   3. Insert direction matters. In ORDER terms, "insert before window N"
#      lands you one short when moving UP (your own vacated slot collapses
#      beneath you). So: moving UP -> -a (insert AFTER target); moving DOWN
#      -> -b (insert BEFORE target). Either way you land exactly at N.
#
# ROBUSTNESS (learned the hard way):
#   • Takes the window id (@N, immutable) + session name explicitly from the
#     binding — never guesses "the current window" from client context.
#   • Every tmux call is session-qualified; window ids stay valid even for
#     windows linked into multiple sessions (the ribbon link helper does this).
#   • No head/tail pipes (a `tmux ... | head` under pipefail can die on a
#     SIGPIPE race and silently no-op the whole script).
#   • Self-verifies the landing slot and reports it via display-message —
#     never trusts "no error" as success.
#
# ARGS: $1 = target slot (what the user typed at the prompt)
#       $2 = window id   (#{window_id}, expanded by run-shell in the binding)
#       $3 = session name (#{session_name}, ditto)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# TMUX_BIN honors $JW_TMUX (e.g. "tmux -L testsock") so a scratch server can be
# driven end-to-end — same convention as tmux-window-park.sh. Unquoted at call
# sites ON PURPOSE so the "-L sock" splits. prefix+. passes no JW_TMUX → `tmux`.
TMUX_BIN=${JW_TMUX:-tmux}
# QUIET (JW_TELEPORT_QUIET=1): the cockpit "move" chip drives this headlessly —
# suppress the user-facing tmux display-message chatter AND the focus-stealing
# final select-window (the popup verifies + toasts the landing itself).
QUIET=${JW_TELEPORT_QUIET:-0}
say() { [ "$QUIET" = 1 ] || $TMUX_BIN display-message "$1"; }
trap '[ "$QUIET" = 1 ] || $TMUX_BIN display-message "teleport: FAILED at line $LINENO" || true' ERR

target="${1:?usage: tmux-window-teleport.sh <target-slot> <window-id> <session>}"
win="${2:?usage: tmux-window-teleport.sh <target-slot> <window-id> <session>}"
sess="${3:?usage: tmux-window-teleport.sh <target-slot> <window-id> <session>}"

# Reject non-numeric input loudly rather than dying on a shell arithmetic error.
case "$target" in
  ''|*[!0-9]*)
    say "teleport: '$target' is not a slot number"
    exit 0
    ;;
esac

# 1) Heal any pre-existing gaps FIRST, so the number the user typed refers to
#    the same thing the status bar shows (index == position). No-op when clean.
$TMUX_BIN move-window -r -t "$sess"

# 2) Locate ourselves + the index bounds. while-read consumes ALL lines (no
#    early-exit pipe -> no SIGPIPE); if-statements (not `[ ] && x`) so a false
#    test can't trip `set -e` on the last loop iteration.
cur="" first="" last=""
while read -r idx id; do
  if [ -z "$first" ]; then first="$idx"; fi
  last="$idx"
  if [ "$id" = "$win" ]; then cur="$idx"; fi
done < <($TMUX_BIN list-windows -t "$sess" -F '#{window_index} #{window_id}')

if [ -z "$cur" ]; then
  say "teleport: window $win not found in session '$sess'"
  exit 0
fi

# Clamp out-of-range targets to the ends (type 99 -> go to the last slot)
# instead of erroring with "can't find window".
if [ "$target" -lt "$first" ]; then target="$first"; fi
if [ "$target" -gt "$last"  ]; then target="$last";  fi

if [ "$target" -eq "$cur" ]; then
  say "teleport: already in slot $cur"
  exit 0
fi

# 3) Direction-aware insert (see header: UP needs -a, DOWN needs -b).
if [ "$target" -gt "$cur" ]; then
  $TMUX_BIN move-window -s "$sess:$cur" -a -t "$sess:$target"
else
  $TMUX_BIN move-window -s "$sess:$cur" -b -t "$sess:$target"
fi

# 4) Close the gap we just left behind (move-window won't do it for us).
$TMUX_BIN move-window -r -t "$sess"

# 5) Verify where we ACTUALLY landed (by window id), keep focus there, and
#    report — loudly flagging any mismatch instead of failing silently.
final=""
while read -r idx id; do
  if [ "$id" = "$win" ]; then final="$idx"; fi
done < <($TMUX_BIN list-windows -t "$sess" -F '#{window_index} #{window_id}')

[ "$QUIET" = 1 ] || $TMUX_BIN select-window -t "$sess:$final"
if [ "$final" -eq "$target" ]; then
  say "teleported → slot $final"
else
  say "teleport: landed at $final but asked for $target — please report"
fi
