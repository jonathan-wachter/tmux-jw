#!/bin/bash
# tmux-claude-bar-scroll.sh — scroll the dashboard bar's window list left/right by
# one window, for ONE client, WITHOUT changing the active window. Bound to a click
# on the << / >> buttons (range=user|bscrollL / bscrollR → MouseDown1Status).
#
# It just nudges the stored left-edge in that client's viewport state file; the
# render script (tmux-claude-bar-render.sh) sees the active window is UNCHANGED and
# therefore respects the new scroll position instead of snapping back to current.
# Over-scroll past the right end is capped by the render script's fill logic.
#
# Args:  <client_pid>  <session>  <range>   (range = "bscrollL" | "bscrollR")

client=${1:-0}
session=${2:-}
range=${3:-}

STATE_DIR="${TMPDIR:-/tmp}/tmux-claude-bar"
vpfile="${STATE_DIR}/vp_${client}_${session}"

vp=""; lastcur=""; lastw=""; [ -r "$vpfile" ] && read vp lastcur lastw <"$vpfile"
case "$vp" in ''|*[!0-9]*) exit 0 ;; esac      # no viewport yet → nothing to scroll

case "$range" in
  *L) vp=$(( vp - 1 )) ;;                       # << scroll left (show earlier windows)
  *R) vp=$(( vp + 1 )) ;;                       # >> scroll right (show later windows)
  *)  exit 0 ;;
esac
(( vp < 1 )) && vp=1                            # left bound; right bound is capped by render

# Preserve last_current AND last_width so render treats this as "unchanged" (neither
# a window switch nor a resize) → it respects the new manual scroll position.
mkdir -p "$STATE_DIR" 2>/dev/null
printf '%s %s %s\n' "$vp" "$lastcur" "$lastw" >"${vpfile}.$$" 2>/dev/null && mv -f "${vpfile}.$$" "$vpfile" 2>/dev/null
# Redraw so the scroll shows immediately. Refresh ALL clients: no-t resolution
# picks ONE "current" client, and although the tapping client is usually the
# most-recently-active (so usually wins), a concurrently-typing second client
# can steal that resolution and leave the tap looking dead for up to 30s.
# Non-tapping clients just re-cat their (unchanged, fresh) cache — trivial.
tmux list-clients -F 'refresh-client -S -t "#{client_name}"' 2>/dev/null \
  | tmux source-file - 2>/dev/null
