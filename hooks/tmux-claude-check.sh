#!/bin/bash
# tmux-claude-check.sh — how many snapshot Claude sessions are currently DOWN?
#
# "Down" = a Claude session present in the last layout snapshot
# (~/.cache/tmux-claude/last-layout.json) whose sessionId is NOT in the live
# registry (~/.claude/sessions/<pid>.json). After a crash, that's everything you
# had open; as tmux-claude-restore.sh brings sessions back, the count drops to 0.
#
#   no args     → print "<count>" (0 if none / no snapshot)
#   --list      → print "<count>" then one "  <name>  <sessionId>" line each
#   --notify    → if count > 0, flash a tmux banner pointing at the restore key.
#                 Wired to `set-hook -ga client-attached` so you're told the
#                 moment you reattach after a crash. Silent when count == 0.
#
# This is the "detect + notify" half of the watcher (the 1-key restore is the
# other half). Never errors out the hook: degrades to count 0 on any problem.

exec python3 - "$@" <<'PY'
import json, os, sys, glob, subprocess

HOME      = os.path.expanduser("~")
REG_DIR   = os.path.join(HOME, ".claude", "sessions")
# TMUX_CLAUDE_LAYOUT overrides the snapshot path (used by the test harness).
SNAP      = os.environ.get("TMUX_CLAUDE_LAYOUT") or os.path.join(HOME, ".cache", "tmux-claude", "last-layout.json")
args      = sys.argv[1:]

def live_sids():
    s = set()
    for f in glob.glob(os.path.join(REG_DIR, "*.json")):
        try:
            pid = int(os.path.basename(f)[:-5])
            os.kill(pid, 0)
            d = json.load(open(f))
            if d.get("kind") == "interactive" and d.get("sessionId"):
                s.add(d["sessionId"])
        except Exception:
            continue
    return s

down = []   # (name, sessionId)
try:
    snap = json.load(open(SNAP))
    live = live_sids()
    seen = set()
    for sess in snap.get("sessions", {}).values():
        for w in sess.get("windows", []):
            for p in w.get("panes", []):
                sid = p.get("sessionId")
                if p.get("type") == "claude" and sid and sid not in live and sid not in seen:
                    seen.add(sid)
                    down.append((p.get("name") or w.get("name") or sid[:8], sid))
except Exception:
    down = []

count = len(down)

if "--notify" in args:
    if count > 0:
        msg = ("⚠️  %d Claude session%s from your last layout %s down — "
               "prefix+R to restore (or run: cc-restore)" %
               (count, "" if count == 1 else "s", "is" if count == 1 else "are"))
        try:
            subprocess.run(["tmux", "display-message", "-d", "4000", msg])
        except Exception:
            pass
    sys.exit(0)

print(count)
if "--list" in args:
    for name, sid in down:
        print("  %-22s %s" % (name, sid))
PY
