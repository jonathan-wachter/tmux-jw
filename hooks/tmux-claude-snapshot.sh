#!/bin/bash
# tmux-claude-snapshot.sh — record the live Claude-in-tmux layout for crash recovery.
#
# WHY THIS EXISTS (2026-06-19): twice in one day a tmux/Claude crash left ~10
# Claude Code sessions needing to be rebuilt BY HAND (find each session id on
# disk, figure out its cwd + name, relaunch `claude --resume <id>` in the right
# window). The transcripts never die — they live at
# ~/.claude/projects/<proj>/<sessionId>.jsonl — so recovery is always POSSIBLE;
# it was just ad hoc. This snapshotter + tmux-claude-restore.sh make it one key.
#
# WHAT IT CAPTURES → ~/.cache/tmux-claude/last-layout.json:
#   - every tmux session → its windows → each window's PANE LAYOUT string
#   - for every pane: its cwd, the command running, and (if it's a Claude pane)
#     the exact sessionId + /rename name, resolved via the SAME registry +
#     process-tree walk the reconciler uses (~/.claude/sessions/<pid>.json).
#   - non-Claude panes are captured too, tagged type="shell" (handled
#     gracefully on restore — recreated as plain shells in their cwd).
#
# HOW IT RUNS: piggybacks the reconciler heartbeat — tmux-claude-reconcile.sh
# calls this at the end of its --write run (every ~5s, already in a locked
# background job off the render path), so there is NO new daemon to babysit.
#
# CRASH-SAFE WRITE GUARD: after a crash + tmux restart, this script would run
# again while Claude is NOT yet restored and try to overwrite the good layout
# with an empty/partial one. The guard refuses to clobber a richer recent
# snapshot: it skips the write if the new capture has FEWER Claude sessions than
# the stored one AND (the stored one is < 15 min old, OR the new count is 0).
# A genuine "I closed some sessions" shrink is recorded once things settle.
#
# Never breaks tmux: any error is logged to ~/.cache/tmux-claude/watcher.log and
# the script exits 0 (a background hook that aborts tmux redraws is worse than a
# missed snapshot).

exec python3 - "$@" <<'PY'
import json, os, subprocess, sys, time, glob, traceback

HOME      = os.path.expanduser("~")
REG_DIR   = os.path.join(HOME, ".claude", "sessions")
CACHE_DIR = os.path.join(HOME, ".cache", "tmux-claude")
# TMUX_CLAUDE_LAYOUT overrides the snapshot path (used by the test harness).
OUT       = os.environ.get("TMUX_CLAUDE_LAYOUT") or os.path.join(CACHE_DIR, "last-layout.json")
LOG       = os.path.join(CACHE_DIR, "watcher.log")
GUARD_SECS = 900   # don't let a shrink clobber a snapshot younger than this
BOOT_GUARD_SECS = 3600   # after a server (re)start, block shrink-writes this long

def log(msg):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(LOG, "a") as fh:
            fh.write("[%s] snapshot: %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except Exception:
        pass

def tmux(*args):
    try:
        r = subprocess.run(["tmux", *args], capture_output=True, text=True, timeout=5)
        return r.stdout
    except Exception as e:
        log("tmux %s failed: %s" % (args, e))
        return ""

def claude_count(snap):
    n = 0
    for s in snap.get("sessions", {}).values():
        for w in s.get("windows", []):
            for p in w.get("panes", []):
                if p.get("type") == "claude" and p.get("sessionId"):
                    n += 1
    return n

try:
    TAB = "\t"
    # ── Gather tmux windows (with their exact pane-geometry layout string) ──────
    win_raw = tmux("list-windows", "-a", "-F", TAB.join(
        ["#{session_name}", "#{window_index}", "#{window_name}",
         "#{window_active}", "#{window_layout}"]))
    if not win_raw.strip():
        sys.exit(0)   # tmux not running / no windows → nothing to snapshot

    pane_raw = tmux("list-panes", "-a", "-F", TAB.join(
        ["#{session_name}", "#{window_index}", "#{pane_index}", "#{pane_active}",
         "#{pane_pid}", "#{pane_current_path}", "#{pane_current_command}"]))

    # ── Process tree (child pid → parent pid), one cheap ps snapshot ───────────
    parent = {}
    try:
        ps = subprocess.run(["ps", "-ax", "-o", "pid=,ppid="],
                            capture_output=True, text=True, timeout=5).stdout
        for line in ps.splitlines():
            f = line.split()
            if len(f) == 2:
                parent[int(f[0])] = int(f[1])
    except Exception as e:
        log("ps failed: %s" % e)

    # ── Registry: live, interactive Claude sessions → pid:{sessionId,name,cwd} ──
    reg = {}
    for f in glob.glob(os.path.join(REG_DIR, "*.json")):
        try:
            pid = int(os.path.basename(f)[:-5])
        except ValueError:
            continue
        try:
            os.kill(pid, 0)          # alive?
        except OSError:
            continue
        try:
            d = json.load(open(f))
        except Exception:
            continue
        if d.get("kind") != "interactive":
            continue                 # exclude bg/workflow subagents (share an ancestor pane)
        sid = d.get("sessionId")
        if not sid:
            continue
        cwd = d.get("cwd", "") or ""
        name = d.get("name") or (cwd.rstrip("/").split("/")[-1] if cwd else "")
        reg[pid] = {"sessionId": sid, "name": name, "cwd": cwd}

    # ── Index panes by their shell pid so we can map a Claude pid → its pane ────
    pane_by_pid = {}
    panes = {}   # (session, window_index, pane_index) → pane dict
    for line in pane_raw.splitlines():
        p = line.split(TAB)
        if len(p) < 7:
            continue
        sess, win, pane, active, pid, cwd, cmd = p[:7]
        try:
            pid = int(pid)
        except ValueError:
            continue
        key = (sess, win, pane)
        panes[key] = {"index": int(pane), "active": active == "1", "cwd": cwd,
                      "cmd": cmd, "type": "shell", "sessionId": None, "name": None}
        pane_by_pid[pid] = key

    # Walk UP from each Claude pid to the first pid that owns a pane (same method
    # as the reconciler — Claude runs as a child of the pane's shell).
    def find_pane(pid):
        p, hops = pid, 0
        while p and p > 1 and hops < 20:
            if p in pane_by_pid:
                return pane_by_pid[p]
            p = parent.get(p)
            hops += 1
        return None

    for pid, info in reg.items():
        key = find_pane(pid)
        if key in panes:
            panes[key].update(type="claude", sessionId=info["sessionId"], name=info["name"])

    # ── Assemble session → windows → panes ─────────────────────────────────────
    sessions = {}
    for line in win_raw.splitlines():
        w = line.split(TAB)
        if len(w) < 5:
            continue
        sess, win, wname, wactive, layout = w[:5]
        wp = sorted((panes[k] for k in panes if k[0] == sess and k[1] == win),
                    key=lambda x: x["index"])
        sessions.setdefault(sess, {"windows": []})["windows"].append({
            "index": int(win), "name": wname, "active": wactive == "1",
            "layout": layout,
            "panes": [{k: pane[k] for k in
                       ("index", "active", "cwd", "cmd", "type", "sessionId", "name")}
                      for pane in wp],
        })

    snapshot = {"savedAt": int(time.time()), "sessions": sessions}
    new_count = claude_count(snapshot)

    # ── Crash-safe write guard ─────────────────────────────────────────────────
    if os.path.exists(OUT):
        try:
            old = json.load(open(OUT))
            old_count = claude_count(old)
            now = time.time()
            age = now - old.get("savedAt", 0)
            if new_count < old_count and (age < GUARD_SECS or new_count == 0):
                # Keep the richer, recent snapshot (almost certainly a crash/restart).
                sys.exit(0)
            # BOOT GUARD (added 2026-07-02): the rule above has a hole — a slow
            # reboot (>15 min gap) plus ONE manually-resumed session makes
            # new_count nonzero and age stale, so a shrink-write clobbered the
            # only record of the pre-reboot sessions. If the stored snapshot
            # predates this tmux server's start, it is BY DEFINITION the
            # pre-crash/pre-reboot record — block shrink-writes for the first
            # hour of server life so restore gets its chance. Growth (or equal
            # count) writes flow through immediately, ending the freeze early.
            if new_count < old_count:
                try:
                    srv_start = int(tmux("display-message", "-p", "#{start_time}").strip() or 0)
                except (ValueError, AttributeError):
                    srv_start = 0
                if srv_start and old.get("savedAt", 0) < srv_start \
                        and now - srv_start < BOOT_GUARD_SECS:
                    log("boot guard: pre-boot snapshot (%d claude) kept; blocked shrink to %d"
                        % (old_count, new_count))
                    sys.exit(0)
        except Exception:
            pass   # unreadable old snapshot → just overwrite it

    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = "%s.tmp.%d" % (OUT, os.getpid())
    with open(tmp, "w") as fh:
        json.dump(snapshot, fh)
    os.replace(tmp, OUT)   # atomic

except SystemExit:
    raise
except Exception:
    log("unhandled:\n" + traceback.format_exc())
    sys.exit(0)   # never break the tmux heartbeat
PY
