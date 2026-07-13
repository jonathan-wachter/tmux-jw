#!/bin/bash
# tmux-claude-jump.sh — jump to a Claude session by attention state.
#
# TWO MODES, chosen by the first argument:
#
#  (a) PRIORITY  — prefix+g (no args) or an explicit space-separated state list.
#      Jump to the single most-important match, scanning states in the given
#      priority order; first match wins. Default order:
#        🔴 needs_you > 💬 question > 🟠 stalled > ✅ done
#
#  (b) CYCLE     — a status-bar tap passes a j_* range id (from the #[range=…]
#      markup that tmux-claude-reconcile.sh wraps around each summary glyph).
#      Among ALL panes in that category, jump to the NEXT one after the pane
#      you're currently on, wrapping to the first. So repeated taps walk through
#      every working / needs-you session one at a time. Range → states:
#        j_attn  → needs_you question   (🔴 summary glyph)
#        j_work  → working              (🤖)
#        j_stall → stalled              (🟠)
#        j_done  → done                 (✅)
#
# Searches ALL tmux sessions; switches client + window + pane in one hop.
# DRYRUN=1 prints the target instead of switching (used for self-testing).

want_states=""
cycle=0
case "$1" in
  j_attn)  want_states="needs_you question"            ; cycle=1 ;;
  j_work)  want_states="working"                       ; cycle=1 ;;
  j_stall) want_states="stalled"                       ; cycle=1 ;;
  j_done)  want_states="done"                          ; cycle=1 ;;
  "")      want_states="needs_you question stalled done"; cycle=0 ;;  # prefix+g default
  *)       want_states="$*"                            ; cycle=0 ;;  # explicit list
esac

# Switch (or, under DRYRUN, just report). Args: session window pane_id
jump_to() {
  if [ -n "$DRYRUN" ]; then
    echo "would jump to: session=$1 window=$2 pane=$3"
  else
    tmux switch-client -t "$1" \; select-window -t "$1:$2" \; select-pane -t "$3"
  fi
}

# ── PRIORITY mode: first pane matching each wanted state, in order ───────────
if [ "$cycle" = "0" ]; then
  for want in $want_states; do
    hit=$(tmux list-panes -a \
      -F '#{@ccstate}|#{session_name}|#{window_index}|#{pane_id}' 2>/dev/null \
      | awk -F'|' -v w="$want" '$1 == w { print $2"|"$3"|"$4; exit }')
    if [ -n "$hit" ]; then
      IFS='|' read -r s wn p <<EOF
$hit
EOF
      jump_to "$s" "$wn" "$p"
      exit 0
    fi
  done
  tmux display-message "No Claude needs attention 🎉"
  exit 0
fi

# ── CYCLE mode: all matching panes in a stable order, jump to next-after-current
# ws is padded with spaces so a whole-word index() match can't hit a substring.
list=$(tmux list-panes -a \
  -F '#{@ccstate}|#{session_name}|#{window_index}|#{pane_id}' 2>/dev/null \
  | awk -F'|' -v ws=" $want_states " '$1 != "" && index(ws, " " $1 " ") { print $2"|"$3"|"$4 }')

if [ -z "$list" ]; then
  tmux display-message "No matching Claude session"
  exit 0
fi

# The pane you're looking at right now (the clicking client's active pane).
cur=$(tmux display-message -p '#{pane_id}' 2>/dev/null)

# Pick the entry AFTER the one whose pane == cur (wrapping); if cur isn't in the
# list (you're not currently on a matching pane), pick the first entry.
target=$(printf '%s\n' "$list" | awk -F'|' -v cur="$cur" '
  { rows[NR] = $0; pane[NR] = $3 }
  END {
    if (NR == 0) exit
    idx = 0
    for (i = 1; i <= NR; i++) if (pane[i] == cur) { idx = i; break }
    nxt = (idx == 0 ? 1 : (idx % NR) + 1)   # first if not on a match, else next (wrap)
    print rows[nxt]
  }')

IFS='|' read -r s wn p <<EOF
$target
EOF
jump_to "$s" "$wn" "$p"
