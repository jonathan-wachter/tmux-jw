#!/bin/bash
# tmux-claude-crashcap.sh — freeze crash forensics the moment a Claude session dies.
#
# WHY (2026-06-21): we added two always-on crash logs — app-side
# ~/.claude/debug/cc-*.log (the claude() --debug-file wrapper) and terminal-side
# ~/.claude/tmux-logs/*.log (the tmux pane-focus-in[10] pipe-pane hook) — but both
# self-prune after 7 days and the terminal logs grow fast. This bundles the relevant
# logs for a crashed session into a durable, prune-exempt folder the instant the
# crash is detected, with a manifest, so /debug-jw can surface it cleanly later.
#
# HOW IT FITS THE EXISTING SYSTEM (no new detector, no new daemon):
#   • detection = the SAME "down = in last-layout.json snapshot but sessionId not in
#     the live ~/.claude/sessions registry" rule used by tmux-claude-check.sh.
#   • it rides the reconciler heartbeat — tmux-claude-reconcile.sh calls this right
#     after tmux-claude-snapshot.sh on its ~5s --write run (already a locked bg job).
#   • it reads the snapshot's sessionId→name/cwd/tmux-pane map to locate the logs.
#
# CRASH vs CLEAN-QUIT: a normally-closed session is also "down". We only bundle when
# a candidate log actually contains a CRASH signature (server exited / heap OOM /
# fatal / signal) — so closing sessions never spams bundles. One bundle per crash
# episode (a per-sessionId marker, cleared when the session comes back live).
#
# Never breaks the heartbeat: every error → watcher.log, exit 0.

exec python3 - "$@" <<'PY'
import json, os, re, glob, time, shutil, subprocess, traceback

HOME      = os.path.expanduser("~")
REG_DIR   = os.path.join(HOME, ".claude", "sessions")
CACHE_DIR = os.path.join(HOME, ".cache", "tmux-claude")
SNAP      = os.environ.get("TMUX_CLAUDE_LAYOUT") or os.path.join(CACHE_DIR, "last-layout.json")
DEBUG_DIR = os.path.join(HOME, ".claude", "debug")
TMUX_DIR  = os.path.join(HOME, ".claude", "tmux-logs")
CAP_DIR   = os.path.join(CACHE_DIR, "captured")     # per-sessionId capture markers
LOG       = os.path.join(CACHE_DIR, "watcher.log")

# Only files modified within this window are considered candidate logs (cheap + avoids
# matching an old reused sessionId). Crashes are detected within ~5s, so this is ample.
RECENT_SECS = 12 * 3600
# A bundle is created ONLY if a candidate log matches this (a real crash, not a clean quit).
CRASH_RE = re.compile(r"server exited unexpectedly|JavaScript heap out of memory|"
                      r"Reached heap limit|FATAL ERROR|uncaughtException|unhandledRejection|"
                      r"SIGKILL|SIGSEGV|SIGABRT|Killed: 9", re.I)

def log(msg):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(LOG, "a") as fh:
            fh.write("[%s] crashcap: %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except Exception:
        pass

def live_sids():
    s = set()
    for f in glob.glob(os.path.join(REG_DIR, "*.json")):
        try:
            pid = int(os.path.basename(f)[:-5])
            os.kill(pid, 0)                       # alive?
            d = json.load(open(f))
            if d.get("kind") == "interactive" and d.get("sessionId"):
                s.add(d["sessionId"])
        except Exception:
            continue
    return s

def recent(paths):
    cut = time.time() - RECENT_SECS
    out = []
    for p in paths:
        try:
            if os.path.getmtime(p) >= cut:
                out.append(p)
        except OSError:
            pass
    return sorted(out, key=os.path.getmtime, reverse=True)

def file_has_crash(p):
    # grep is far cheaper than reading multi-MB TUI logs into python.
    try:
        return subprocess.run(["grep", "-aqiE", CRASH_RE.pattern, p], timeout=10).returncode == 0
    except Exception:
        try:
            with open(p, "r", errors="ignore") as fh:
                return bool(CRASH_RE.search(fh.read()))
        except Exception:
            return False

def transcript_for(sid):
    m = glob.glob(os.path.join(HOME, ".claude", "projects", "*", sid + ".jsonl"))
    return m[0] if m else ""

try:
    try:
        snap = json.load(open(SNAP))
    except Exception:
        raise SystemExit(0)                       # no snapshot yet → nothing to do

    live = live_sids()

    # Collect down Claude panes from the snapshot.
    down = []   # dicts: sid,name,cwd,sess,win,pane
    for sess_name, s in snap.get("sessions", {}).items():
        for w in s.get("windows", []):
            for p in w.get("panes", []):
                sid = p.get("sessionId")
                if p.get("type") == "claude" and sid and sid not in live:
                    down.append({"sid": sid, "name": p.get("name") or "",
                                 "cwd": p.get("cwd") or "",
                                 "sess": sess_name, "win": w.get("index"),
                                 "pane": p.get("index")})
    down_sids = {d["sid"] for d in down}

    os.makedirs(CAP_DIR, exist_ok=True)
    # Reset markers for sessions that are live again → a FUTURE crash re-captures.
    for mk in glob.glob(os.path.join(CAP_DIR, "*")):
        if os.path.basename(mk) in live:
            try: os.remove(mk)
            except OSError: pass

    recent_dbg = recent(glob.glob(os.path.join(DEBUG_DIR, "cc-*.log")))

    for d in down:
        sid = d["sid"]
        marker = os.path.join(CAP_DIR, sid)
        if os.path.exists(marker):
            continue                              # already captured this episode

        # ── locate candidate logs ───────────────────────────────────────────
        # terminal log: structural match on session/window/pane (newest)
        tmux_matches = recent(glob.glob(os.path.join(
            TMUX_DIR, "*_%s_w%sp%s_*.log" % (d["sess"], d["win"], d["pane"]))))
        # app-debug log: precise content match on the sessionId
        dbg_matches = []
        if recent_dbg:
            try:
                r = subprocess.run(["grep", "-lF", "--", sid] + recent_dbg,
                                   capture_output=True, text=True, timeout=15)
                dbg_matches = [x for x in r.stdout.splitlines() if x]
            except Exception:
                pass

        candidates = (tmux_matches[:1] + dbg_matches)
        # ── gate: only bundle a CONFIRMED crash (else it's a clean quit) ─────
        if not any(file_has_crash(c) for c in candidates):
            # Mark it so we don't re-scan every 5s; cleared when it returns live.
            try: open(marker, "w").close()
            except OSError: pass
            continue

        # ── build the bundle ────────────────────────────────────────────────
        ts = time.strftime("%Y%m%d-%H%M%S")
        safe = re.sub(r"[^A-Za-z0-9._-]", "_", d["name"] or sid[:8])
        bundle = os.path.join(TMUX_DIR, "crash-%s_%s" % (ts, safe))
        os.makedirs(bundle, exist_ok=True)
        copied = []
        for src in (tmux_matches[:1] + dbg_matches):
            try:
                shutil.copy2(src, os.path.join(bundle, os.path.basename(src)))
                copied.append(os.path.basename(src))
            except Exception as e:
                log("copy %s failed: %s" % (src, e))

        tr = transcript_for(sid)
        manifest = [
            "Claude Code crash bundle",
            "detected:   " + time.strftime("%Y-%m-%d %H:%M:%S"),
            "sessionId:  " + sid,
            "name:       " + (d["name"] or "(unnamed)"),
            "cwd:        " + (d["cwd"] or "(unknown)"),
            "tmux:       session=%s window=%s pane=%s" % (d["sess"], d["win"], d["pane"]),
            "transcript: " + (tr or "(not found)") + "   (persists ~cleanupPeriodDays)",
            "resume:     cd %s && claude --resume %s" % (d["cwd"] or "~", sid),
            "captured:   " + (", ".join(copied) if copied else "(no logs found — may predate logging setup)"),
            "",
            "Frozen by tmux-claude-crashcap.sh on the heartbeat after this session left",
            "the live registry AND a log showed a crash signature. App-debug = cc-*.log;",
            "terminal = *_wNpN_*.log. Inspect with /debug-jw.",
        ]
        try:
            with open(os.path.join(bundle, "manifest.txt"), "w") as fh:
                fh.write("\n".join(manifest) + "\n")
        except Exception as e:
            log("manifest write failed: %s" % e)

        try: open(marker, "w").close()
        except OSError: pass
        log("captured %s for %s (%s) — %d file(s)" % (bundle, sid, d["name"] or "?", len(copied)))

except SystemExit:
    raise
except Exception:
    log("unhandled:\n" + traceback.format_exc())
finally:
    os._exit(0)   # never break the heartbeat, whatever happened
PY
