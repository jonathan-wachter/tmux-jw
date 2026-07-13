#!/bin/bash
# tmux-claude-bar-link.sh — click a status-box glyph (🤖/💬/🔴/🟠/✅) in the ribbon
# to reach a window of that state ANYWHERE in tmux. If a matching window is already
# in the current session, select it; otherwise LINK it into this session (it stays
# linked in its origin session too — link-window, not move-window) and focus it.
#
# Bound via MouseDown1Status: range=user|link_<state> → run-shell '… <session> <range>'.
#
# Args:  <current_session>  <range>   (range = "link_working" | "link_needs_you" | …)

session=${1:-}
state=${2#link_}
[ -z "$state" ] && exit 0

here=""            # window indices of matching windows already in THIS session
src=""; src_id=""  # first matching window found in ANOTHER session
while IFS='|' read -r sess widx wid ws; do
  [ "$ws" = "$state" ] || continue
  if [ "$sess" = "$session" ]; then
    here="${here}${here:+ }${widx}"
  elif [ -z "$src" ]; then
    src="${sess}:${widx}"; src_id="$wid"
  fi
done < <(tmux list-windows -a -F '#{session_name}|#{window_index}|#{window_id}|#{@ccstate}' 2>/dev/null)

if [ -n "$here" ]; then
  # already here → focus the first match (could cycle later)
  set -- $here
  tmux select-window -t "${session}:$1"
elif [ -n "$src" ]; then
  # pull it in: link (keeps it in its origin session) then focus the linked window
  tmux link-window -s "$src" -t "${session}:" 2>/dev/null && tmux select-window -t "$src_id" 2>/dev/null
fi
tmux refresh-client -S 2>/dev/null
