#!/usr/bin/env bash
# tmux-window-park.sh — the shared move engine behind BOTH the /tmux park|restore
# skill scripts AND the cockpit popup (prefix+o) park/restore action chips.
#
# Unlike the old skill scripts (which resolved "the current window" from
# $TMUX_PANE), this operates on an EXPLICIT window id (@N) passed in, so it can
# move ANY window — the one the cursor is on in the cockpit list, not just the
# caller's own pane. Decision 1A (2026-07-05): one tested implementation; the
# skill scripts become thin wrappers, the cockpit calls it directly.
#
# USAGE
#   tmux-window-park.sh park    <@win> [parking-name] [--porcelain]
#   tmux-window-park.sh restore <@win> [dest-session] [--follow] [--dry-run] [--porcelain]
#
# OPTIONS
#   --follow      after the move, bring the clients that were VIEWING the moved
#                 window to the destination and land them on it. This is the
#                 /tmux restore behavior (you follow your window home). Omit it
#                 (park, and the cockpit) to stay put: source-session clients
#                 land on a NEIGHBOR window instead, so a popup stays open.
#   --dry-run,-n  (restore) print the chosen destination and change nothing.
#   --porcelain   suppress the human summary; print one line "<dest>\t<index>"
#                 (the new location) for a caller to parse. The cockpit uses this.
#
# CLIENT SAFETY (why the pre-move dance): a tmux session's "current window" is
# shared by every client attached to it, and detach-on-destroy is on — so moving
# a session's LAST window destroys the session and DETACHES its clients. We
# therefore resettle any viewers BEFORE the move: to a neighbor (default) or to
# the destination (--follow, or when there's no neighbor). renumber-windows only
# auto-fires on window KILL, not on move-window (tmux 3.6b) — so we renumber the
# source by hand afterward, exactly as the skill scripts always did.
#
# TESTABILITY: honors $JW_TMUX (e.g. "tmux -L testsock") so a scratch server can
# be driven end-to-end; the cockpit's headless harness inherits it.
set -euo pipefail

TMUX_BIN=${JW_TMUX:-tmux}   # unquoted at call sites ON PURPOSE so "tmux -L sock" splits
die() { echo "ERROR: $*" >&2; exit 1; }

# Optional local config (repo root, git-ignored — see tmux-jw.config.example).
# NB: if-block, not `[ -r ] && .` — this script runs set -e, and a failed &&
# list here would abort it whenever the config file simply doesn't exist.
__cfg="${BASH_SOURCE[0]%/*}/../tmux-jw.config"
if [ -r "$__cfg" ]; then . "$__cfg"; fi

sub=${1:-}; shift 2>/dev/null || true
case "$sub" in park|restore) ;; *) die "usage: $0 park|restore <@win> [opts]";; esac

WID=${1:-}; shift 2>/dev/null || true
[ -n "$WID" ] || die "missing <@window-id>"
case "$WID" in @*[0-9]) ;; *) die "window id must look like @N (got '$WID')";; esac

FOLLOW=0; DRY=0; PORCELAIN=0; PARKING=${TMUXJW_PARKING:-cc-parking}; POS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --follow)     FOLLOW=1 ;;
    --dry-run|-n) DRY=1 ;;
    --porcelain)  PORCELAIN=1 ;;
    --parking)    PARKING="$2"; shift ;;   # park dest / restore MRU-exclusion lot
    --)           ;;
    -*)           die "unknown option: $1" ;;
    *)            POS="$1" ;;   # positional: parking-name (park) or dest-session (restore)
  esac
  shift
done

# ── resolve the source window ────────────────────────────────────────────────
$TMUX_BIN display-message -p -t "$WID" '#{window_id}' >/dev/null 2>&1 || die "window $WID not found"
src_session=$($TMUX_BIN display-message -p -t "$WID" '#{session_name}')
src_name=$($TMUX_BIN display-message -p -t "$WID" '#{window_name}')

# a session "has Claude" if any of its panes runs the CLI — its process comm is
# the version string (e.g. 2.1.199, the binary is installed versioned) or literal
# "claude". here-string (not a pipe) so grep -q can't SIGPIPE us under pipefail.
session_has_claude() {
  local out; out=$($TMUX_BIN list-panes -s -t "=$1" -F '#{pane_current_command}' 2>/dev/null || true)
  grep -qE '^(claude|[0-9]+(\.[0-9]+){1,3})$' <<<"$out"
}

# ── choose the destination ───────────────────────────────────────────────────
if [ "$sub" = park ]; then
  [ -n "$POS" ] && PARKING="$POS"
  DEST="$PARKING"; CREATE=1
else
  CREATE=0
  if [ -n "$POS" ]; then
    DEST="$POS"
    $TMUX_BIN has-session -t "=$DEST" 2>/dev/null || die "session '$DEST' not found."
  else
    # MRU: attached sessions first (in use NOW; ties by session_activity), then
    # detached by session_last_attached. Skip the source and the parking lot.
    now=$(date +%s)
    DEST=$($TMUX_BIN list-sessions \
             -F '#{session_attached}|#{session_last_attached}|#{session_activity}|#{session_name}' |
      while IFS='|' read -r attached last_att activity name; do
        [ "$name" = "$src_session" ] && continue
        [ "$name" = "$PARKING" ] && continue
        session_has_claude "$name" || continue
        if [ "${attached:-0}" -gt 0 ]; then key=$(( now + ${activity:-0} )); else key=${last_att:-0}; fi
        printf '%s\t%s\n' "$key" "$name"
      done | sort -rn | awk -F'\t' 'NR==1{print $2}')   # awk (not head) → no SIGPIPE race
    [ -n "$DEST" ] || die "no other session with Claude Code windows found."
  fi
fi

if [ "$src_session" = "$DEST" ]; then
  if [ "$PORCELAIN" = 1 ]; then printf '%s\t%s\n' "$DEST" "$($TMUX_BIN display-message -p -t "$WID" '#{window_index}')"
  else echo "Window '$src_name' ($WID) is already in '$DEST' — nothing to do."; fi
  exit 0
fi

if [ "$DRY" = 1 ]; then
  echo "Would move '$src_name' ($WID): '$src_session' → '$DEST' (dry run, nothing changed)."
  exit 0
fi

# ── pre-move client resettlement (see header: CLIENT SAFETY) ─────────────────
win_count=$($TMUX_BIN list-windows -t "=$src_session" -F x | wc -l | tr -d ' ')
is_current=0
[ "$($TMUX_BIN display-message -p -t "=$src_session:" '#{window_id}')" = "$WID" ] && is_current=1
viewers=""
if [ "$is_current" = 1 ]; then
  viewers=$($TMUX_BIN list-clients -F '#{client_name} #{session_name}' |
            awk -v s="$src_session" '$2==s{print $1}')
fi

if [ "$FOLLOW" = 1 ] && [ "$is_current" = 1 ]; then
  # /tmux restore: take the viewers to DEST first (also avoids a last-window detach)
  for c in $viewers; do $TMUX_BIN switch-client -c "$c" -t "=$DEST:" 2>/dev/null || true; done
elif [ "$is_current" = 1 ] && [ "$win_count" -gt 1 ]; then
  # park / cockpit: shift source clients LEFT to a neighbor (next-by-index, else
  # previous) so they stay in the source session — matches /tmux park's landing.
  src_index=$($TMUX_BIN display-message -p -t "$WID" '#{window_index}')
  landing=$($TMUX_BIN list-windows -t "=$src_session" -F '#{window_index} #{window_id}' |
            awk -v cur="$src_index" '$1 > cur { print $2; exit }')
  [ -n "$landing" ] || landing=$($TMUX_BIN list-windows -t "=$src_session" -F '#{window_index} #{window_id}' |
            awk -v cur="$src_index" '$1 < cur { id = $2 } END { print id }')
  [ -n "$landing" ] && $TMUX_BIN select-window -t "$landing"
elif [ "$is_current" = 1 ]; then
  # no neighbor (last window) and not following: don't detach — park the viewers
  # on DEST so any open popup survives the source session's destruction.
  for c in $viewers; do $TMUX_BIN switch-client -c "$c" -t "=$DEST:" 2>/dev/null || true; done
fi

# ── the move ─────────────────────────────────────────────────────────────────
if [ "$CREATE" = 1 ] && ! $TMUX_BIN has-session -t "=$DEST" 2>/dev/null; then
  # No parking session yet: new-session forces a placeholder window, so make it
  # detached & sized like the source (avoid an 80x24 reflow), then replace the
  # placeholder with our window (-k kills the target placeholder).
  src_w=$($TMUX_BIN display-message -p -t "$WID" '#{window_width}')
  src_h=$($TMUX_BIN display-message -p -t "$WID" '#{window_height}')
  $TMUX_BIN new-session -d -s "$DEST" -x "$src_w" -y "$src_h"
  $TMUX_BIN move-window -k -s "$WID" -t "=$DEST:"'{start}'
else
  # -d: don't select it at the destination — never yank a client browsing DEST.
  $TMUX_BIN move-window -d -a -s "$WID" -t "=$DEST:"'{end}'
fi

# ── verify (never trust silence) ─────────────────────────────────────────────
now_in=$($TMUX_BIN display-message -p -t "$WID" '#{session_name}')
[ "$now_in" = "$DEST" ] || die "window $WID ('$src_name') ended up in '$now_in', not '$DEST'."

# followers land ON the moved window in DEST
if [ "$FOLLOW" = 1 ] && [ -n "$viewers" ]; then
  $TMUX_BIN select-window -t "$WID" 2>/dev/null || true
fi

# close the index gap in the source (if it survived) — renumber-windows honored by hand
if [ "$win_count" -gt 1 ] && $TMUX_BIN has-session -t "=$src_session" 2>/dev/null &&
   [ "$($TMUX_BIN display-message -p -t "=$src_session:" '#{renumber-windows}')" = "1" ]; then
  $TMUX_BIN move-window -r -t "=$src_session"
fi

dest_idx=$($TMUX_BIN display-message -p -t "$WID" '#{window_index}')

# ── report ───────────────────────────────────────────────────────────────────
if [ "$PORCELAIN" = 1 ]; then
  printf '%s\t%s\n' "$DEST" "$dest_idx"
  exit 0
fi

verb=Parked; [ "$sub" = restore ] && verb=Restored
echo "$verb window '$src_name' ($WID) → $DEST:$dest_idx"
echo "Now in '$DEST':"
if [ "$FOLLOW" = 1 ] && [ -n "$viewers" ]; then mk=' ← you are here'; else mk=' *'; fi
$TMUX_BIN list-windows -t "=$DEST" -F "  #{window_index}: #{window_name}#{?window_active,$mk,}"
if [ "$win_count" -gt 1 ] && $TMUX_BIN has-session -t "=$src_session" 2>/dev/null; then
  echo "Back in '$src_session':"
  if [ "$FOLLOW" = 1 ]; then bk=' *'; else bk=' ← you are here'; fi
  $TMUX_BIN list-windows -t "=$src_session" -F "  #{window_index}: #{window_name}#{?window_active,$bk,}"
else
  echo "NOTE: '$src_session' had only that one window — the session itself is now gone."
fi
