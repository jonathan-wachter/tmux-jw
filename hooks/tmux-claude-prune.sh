#!/bin/bash
# tmux-claude-prune.sh — boxbar cache/viewport hygiene. (P5, 2026-07-08)
#
# Called from the throttled heartbeat (≤once/INTERVAL), so it never touches a
# hot path. Two jobs:
#
#   (a) REAP STALE BUILDER LOCKS. The reader creates cache/lock_<pid>.d, kicks a
#       builder, and rmdir's it in the SAME invocation (lifetime: milliseconds).
#       A lock dir older than LOCK_AGE is therefore a crashed builder — reap it
#       (belt over the reader's own 60s reap; also covers the heartbeat lock).
#
#   (b) PRUNE DEPARTED-CLIENT FILES. bar-render writes a permanent per-client set
#       — cache/row{0,1,2}_<pid>, hash_<pid>, seendirty_<pid>, lock_<pid>.d and
#       vp_<pid>_<session> — and every mosh reconnect / Jump re-attach mints a
#       NEW client_pid, so nothing ever removes the old set (pure inode growth
#       until reboot). Drop the files of any pid that is no longer an attached
#       client AND whose mtime is older than PRUNE_AGE.
#
# WHY THE AGE GUARD: a live client's files are rewritten continuously (mtime
# fresh), so requiring >PRUNE_AGE means a transient `tmux list-clients` hiccup —
# or a client mid-reconnect briefly absent from the list — can't nuke a live
# cache (which would only self-heal on the next render anyway). Departed pids
# don't reappear, so their files simply age out.
#
# bash 3.2 safe; honors $TMPDIR (test isolation) and bare `tmux` via PATH.

export LC_ALL=en_US.UTF-8

GATE_DIR="${TMPDIR:-/tmp}/tmux-claude-bar"
CACHE="${GATE_DIR}/cache"
PRUNE_AGE=3600     # departed-client files must be this old before removal
LOCK_AGE=600       # a builder lock older than this = a crashed builder → reap
now=$(date +%s)

# (a) reap stale locks regardless of client liveness (a healthy lock lives ms)
for d in "$CACHE"/lock_*.d "$GATE_DIR"/heartbeat.lock.d; do
  [ -d "$d" ] || continue
  age=$(( now - $(stat -f %m "$d" 2>/dev/null || echo "$now") ))
  [ "$age" -gt "$LOCK_AGE" ] && rmdir "$d" 2>/dev/null
done

# (b) prune departed-client files. SAFETY: bail if we got no client list at all
# (a transient empty list must not nuke every live cache).
live=" $(tmux list-clients -F '#{client_pid}' 2>/dev/null | tr '\n' ' ') "
[ -n "${live// /}" ] || exit 0

for f in "$CACHE"/row[012]_* "$CACHE"/hash_* "$CACHE"/seendirty_* "$CACHE"/lock_*.d "$GATE_DIR"/vp_*; do
  [ -e "$f" ] || continue                    # unmatched glob stays literal → skip
  base=${f##*/}
  pid=${base#row[012]_}; pid=${pid#hash_}; pid=${pid#seendirty_}; pid=${pid#lock_}; pid=${pid#vp_}
  pid=${pid%%[!0-9]*}                         # leading digits = the client_pid
  [ -n "$pid" ] || continue
  case " $live " in *" $pid "*) continue ;; esac    # still attached → keep
  age=$(( now - $(stat -f %m "$f" 2>/dev/null || echo "$now") ))
  [ "$age" -gt "$PRUNE_AGE" ] && rm -rf "$f" 2>/dev/null   # departed + stale → remove
done
exit 0
