#!/bin/bash
# tmux-claude-autorestore.sh — automatically bring Claude sessions back when a
# fresh tmux server comes up (after a Mac reboot, a tmux/Claude crash, or a
# Moshi reconnect that spawns a new server).
#
# THE GAP THIS CLOSES: tmux-continuum restores your WINDOWS on server start, but
# only as BARE SHELLS — the `claude` processes inside them are gone. Until now you
# had to notice the banner and press prefix+R. This runs the restore for you.
#
#   Wired to:  set-hook -g client-attached[51]   (beside the [50] notify hook)
#   Toggle:    tmux option  @claude-autorestore   ('on' = restore; else notify-only)
#   Guard:     a lock keyed to the tmux SERVER PID → fires ONCE per server, not on
#              every reattach. A new server (new PID) gets a fresh lock and runs again.
#   Timing:    waits for continuum to FINISH restoring windows (window count goes
#              quiet) before restoring, so we reuse those shells in place instead of
#              racing continuum and creating duplicate windows.
#
# Delegates to tmux-claude-restore.sh --auto (in-place reuse, never kills). Never
# errors the hook — always exits 0.

HOOKS="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
LOG="$HOME/.claude/tmux-logs/autorestore.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

# ── Toggle (default on) ─────────────────────────────────────────────────────────
toggle="$(tmux show-options -gv @claude-autorestore 2>/dev/null)"
[ -z "$toggle" ] && toggle="on"
if [ "$toggle" != "on" ]; then
    log "skip: @claude-autorestore='$toggle' (notify-only)"
    exit 0
fi

# ── Once per server: atomic lock keyed to the server PID ────────────────────────
spid="$(tmux display-message -p '#{pid}' 2>/dev/null)"
[ -n "$spid" ] || exit 0
lock="${TMPDIR:-/tmp}/cc-autorestore-${spid}.lock"
# mkdir is atomic — only the first attach of this server wins; the rest no-op.
mkdir "$lock" 2>/dev/null || exit 0
# Best-effort sweep of stale locks from previous servers (PIDs no longer alive).
for d in "${TMPDIR:-/tmp}"/cc-autorestore-*.lock; do
    [ -e "$d" ] || continue
    p="${d##*/cc-autorestore-}"; p="${p%.lock}"
    kill -0 "$p" 2>/dev/null || rmdir "$d" 2>/dev/null
done

# ── Boot stash: freeze the layout as of server start (added 2026-07-02) ─────────
# The reconciler heartbeat keeps rewriting last-layout.json; on a slow reboot it
# can capture the post-boot bare-shell state before restore reads it (the 07-02
# clobber: 41-min reboot gap + one manually-resumed session slipped through the
# snapshot guard). Freeze a copy the moment we win the boot lock; check.sh and
# restore.sh both honor TMUX_CLAUDE_LAYOUT, so every read below uses the frozen
# pre-boot layout no matter what the snapshotter does to the live file meanwhile.
SNAP="$HOME/.cache/tmux-claude/last-layout.json"
STASH="$HOME/.cache/tmux-claude/boot-layout.json"
if cp "$SNAP" "$STASH" 2>/dev/null; then
    export TMUX_CLAUDE_LAYOUT="$STASH"
    log "server $spid: stashed layout → $STASH"
else
    log "server $spid: WARN no $SNAP to stash — reading live file"
fi

# ── Wait for continuum to finish restoring windows (count goes quiet) ───────────
# Without this we'd run while continuum is mid-restore, find no shells to reuse,
# and create duplicate windows — the exact mess this whole thing avoids.
prev=-1; stable=0
for _ in $(seq 1 14); do
    sleep 1
    cur="$(tmux list-windows -a 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$cur" = "$prev" ] && [ "${cur:-0}" -gt 0 ]; then
        stable=$((stable + 1))
        [ "$stable" -ge 2 ] && break   # unchanged for 2 consecutive ticks → settled
    else
        stable=0
    fi
    prev="$cur"
done

# ── Anything actually down? (cheap count from check.sh) ─────────────────────────
down="$("$HOOKS/tmux-claude-check.sh" 2>/dev/null | head -1)"
case "$down" in
    ''|0) log "server $spid up; nothing down — no action"; exit 0 ;;
esac

# ── Restore ─────────────────────────────────────────────────────────────────────
# At config-load time (boot trigger) there may be no client yet, so session_name
# can come back empty — omit --target then (restore reuses windows by name/cwd
# across ALL sessions anyway; --target only picks where NEW windows go).
sess="$(tmux display-message -p '#{session_name}' 2>/dev/null)"
log "server $spid up; $down session(s) down → restoring into '${sess:-<no client>}'"
if [ -n "$sess" ]; then
    out="$("$HOOKS/tmux-claude-restore.sh" --auto --target "$sess" 2>&1)"
else
    out="$("$HOOKS/tmux-claude-restore.sh" --auto 2>&1)"
fi
log "restore → $out"

tmux display-message -d 5000 \
    "♻️  Auto-restored $down Claude session(s) — switch in and press Enter to wake each." 2>/dev/null
exit 0
