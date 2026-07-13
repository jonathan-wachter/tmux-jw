#!/usr/bin/env bash
# tmux-pane-log.sh — always-on raw terminal logging for a tmux pane (crash forensics).
# Added 2026-06-21 after a Claude Code worker died with "[server exited unexpectedly]"
# and left NOTHING on disk to explain why (no macOS crash report, no debug log —
# debug logging was off). This is the TERMINAL-side half of the fix; the zsh
# `claude` wrapper's --debug-file is the APP-side half:
#   • --debug-file   → Claude's own internals/stack (the WHY)   ~/.claude/debug/cc-*.log
#   • this script    → the literal pane output (the WHAT you saw + exact timing,
#                      incl. the "[server exited unexpectedly]" banner). Captured by
#                      tmux — a SEPARATE process — so it survives even a crash so hard
#                      the worker never flushes its own debug file. Belt + suspenders.
#
# Invoked from the `pane-focus-in[10]` hook in tmux.conf (indexed so it stacks with
# the existing pane-focus-in at index 0 instead of clobbering it). Logging therefore
# starts the first time you touch a pane — before any future crash.
#
# ⚠️ NOTE: a full-screen TUI repaints constantly, so these logs are NOISY (lots of
# raw ANSI). That's expected — grep them for the crash marker when you need them:
#   grep -l 'server exited unexpectedly' ~/.claude/tmux-logs/*.log
# Files older than 7 days are auto-pruned each time a new pipe starts (cheap, keeps
# disk bounded since TUI panes can write MBs/day).
#
# Args (all passed by the hook as tmux format-expansions):
#   $1 pane_id (e.g. %12)  $2 session_name  $3 window_index  $4 pane_index  $5 pane_pipe
set -uo pipefail

pane_id="${1:?pane_id required}"
sess="${2:-unknown}"
win="${3:-0}"
pane="${4:-0}"
piped="${5:-0}"

# Idempotent: if tmux says this pane is already being piped, do nothing.
# (Explicit `if` — NOT `[ ] && exit` — so `set -e`-style early exit can't misfire.)
if [ "$piped" = "1" ]; then
  exit 0
fi

dir="$HOME/.claude/tmux-logs"
mkdir -p "$dir"
# Prune old logs (ignore errors — never let cleanup block logging from starting).
# -maxdepth 1 keeps the prune to top-level pane logs ONLY — it must NOT recurse into
# crash-*/ bundle subdirs (frozen by tmux-claude-crashcap.sh), which are kept forever.
find "$dir" -maxdepth 1 -type f -name '*.log' -mtime +7 -delete 2>/dev/null || true

# Sanitize the session name for use in a filename; strip the leading % from pane_id.
safe_sess="${sess//[^A-Za-z0-9._-]/_}"
f="$dir/$(date +%Y%m%d-%H%M%S)_${safe_sess}_w${win}p${pane}_${pane_id#%}.log"

# Start logging. `-O` captures any output already in the pane buffer too, so we don't
# miss lines printed in the instant before the pipe attaches.
tmux pipe-pane -t "$pane_id" "cat >> '$f'"
