#!/bin/bash
# tmux-claude-restore.sh — bring back Claude Code sessions after a tmux/Claude crash.
#
# Reads the layout captured by tmux-claude-snapshot.sh
# (~/.cache/tmux-claude/last-layout.json) and, for every Claude session that is
# NOT currently running, brings it back by relaunching `claude --resume <id>`.
#
# IN-PLACE REUSE (added 2026-06-22): after a reboot, tmux-continuum restores your
# windows as BARE SHELLS (sometimes with the right name, sometimes stripped to
# "zsh"). Rather than create duplicate windows next to those, this matches each
# downed session onto an existing idle-shell window and relaunches claude THERE
# (via send-keys). Matching priority per session:
#     1. name   — an idle shell whose window-name == the session's name
#     2. cwd    — a GENERIC (zsh/bash/…) idle shell sitting in the session's cwd
#     3. fill   — any remaining GENERIC idle shell (renamed)
# Only if no shell is reusable do we create a fresh window. Human-named shells
# (e.g. "quick") are NEVER hijacked — only exact name-matches or generic shells
# are eligible, so your scratch windows are safe.
#
#   Triggers (all do the same thing):
#     · prefix + R          — the 1-key restore (bound in tmux.conf)
#     · on tmux start       — tmux-claude-autorestore.sh runs this with --auto
#     · cc-restore          — shell alias (the fallback if you miss the key/banner)
#     · this script, direct — ~/.config/tmux-jw/hooks/tmux-claude-restore.sh
#
#   Flags:
#     --target <session>    tmux session to restore INTO when a NEW window is
#                           needed (default: current). Reuse spans all sessions.
#     --auto                quiet mode for the on-start hook (silent when there is
#                           nothing to restore; one-line summary otherwise).
#     --all                 also recreate pure-shell windows (default: skip them —
#                           tmux-continuum already restores shells on reboot)
#     --dry-run             print the plan, change nothing
#
# SAFE BY DESIGN: never kills or closes a window (reuse is send-keys into an idle
# shell; worst case is an extra command at a prompt). Idempotent — skips any
# session already live, and each idle shell is claimed at most once.

exec python3 - "$@" <<'PY'
import json, os, subprocess, sys, glob, shlex

HOME      = os.path.expanduser("~")
REG_DIR   = os.path.join(HOME, ".claude", "sessions")
CACHE_DIR = os.path.join(HOME, ".cache", "tmux-claude")
# TMUX_CLAUDE_LAYOUT overrides the snapshot path (used by the test harness).
SNAP      = os.environ.get("TMUX_CLAUDE_LAYOUT") or os.path.join(CACHE_DIR, "last-layout.json")

# Window-names that mark a shell as "anonymous" (fair game for cwd-match / fill).
# A shell whose name is NOT one of these is treated as human-named and left alone.
SHELLS = {"zsh", "bash", "sh", "fish", "tcsh", "ksh", "dash", "-zsh", "-bash", "-sh"}

args    = sys.argv[1:]
dry     = "--dry-run" in args
do_all  = "--all" in args
auto    = "--auto" in args
target  = None
if "--target" in args:
    i = args.index("--target")
    if i + 1 < len(args):
        target = args[i + 1]

def tmux(*a):
    return subprocess.run(["tmux", *a], capture_output=True, text=True)

def tmux_out(*a):
    return tmux(*a).stdout.strip()

def say(msg):
    # In --auto we stay quiet unless there is something to report (handled by callers).
    print(msg)

# ── Load the snapshot ──────────────────────────────────────────────────────────
if not os.path.exists(SNAP):
    if not auto:
        print("⚠️  No layout snapshot yet (~/.cache/tmux-claude/last-layout.json).")
        print("    The watcher writes one every ~5s — give it a moment, then retry.")
    sys.exit(0)
try:
    snap = json.load(open(SNAP))
except Exception as e:
    if not auto:
        print("⚠️  Could not read snapshot: %s" % e)
    sys.exit(1)

# ── Which Claude sessions are ALREADY live? (so we never duplicate one) ─────────
live_sids = set()
for f in glob.glob(os.path.join(REG_DIR, "*.json")):
    try:
        pid = int(os.path.basename(f)[:-5])
        os.kill(pid, 0)
        d = json.load(open(f))
        if d.get("kind") == "interactive" and d.get("sessionId"):
            live_sids.add(d["sessionId"])
    except Exception:
        continue

# ── Resolve the target tmux session (only used when a NEW window is needed) ─────
if not target:
    target = tmux_out("display-message", "-p", "#{session_name}")
if not target:
    target = next(iter(snap.get("sessions", {})), "cc")
existing = set(tmux_out("list-sessions", "-F", "#{session_name}").splitlines())
if target not in existing:
    if dry:
        print("would create missing target session '%s'" % target)
    else:
        tmux("new-session", "-d", "-s", target)

# ── Gather reusable idle-shell windows across ALL sessions ──────────────────────
# Single-pane windows whose (active) pane is sitting at an idle login shell.
reusable = []   # {sess, win_id, name, cwd}
fmt = "#{session_name}\t#{window_id}\t#{window_name}\t#{window_panes}\t#{pane_current_command}\t#{pane_current_path}"
for line in tmux_out("list-windows", "-a", "-F", fmt).splitlines():
    parts = line.split("\t")
    if len(parts) < 6:
        continue
    sess, win_id, name, npanes, cmd, path = parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]
    if npanes != "1" or cmd not in SHELLS:
        continue
    reusable.append({"sess": sess, "win_id": win_id, "name": name, "cwd": path})

claimed = set()
def claim_window(label, cwd):
    """Find an idle shell to relaunch this session into. None → must create new."""
    ncwd = os.path.normpath(os.path.expanduser(cwd)) if cwd else None
    preds = [
        lambda c: c["name"] == label,                                              # 1. exact name
        lambda c: c["name"] in SHELLS and ncwd and os.path.normpath(c["cwd"]) == ncwd,  # 2. generic in cwd
        lambda c: c["name"] in SHELLS,                                             # 3. generic fill
    ]
    for pred in preds:
        for c in reusable:
            if c["win_id"] in claimed:
                continue
            if pred(c):
                claimed.add(c["win_id"])
                return c
    return None

# ── Build the restore plan ─────────────────────────────────────────────────────
plan          = []   # windows to bring back: {name, layout, panes, active}
skipped_live  = 0
skipped_shell = 0
present_names = {c["name"] for c in reusable}

planned = set()
for sess in snap.get("sessions", {}).values():
    for w in sess.get("windows", []):
        cpanes = [p for p in w["panes"] if p["type"] == "claude" and p.get("sessionId")]
        if not cpanes:
            if do_all and w["name"] not in present_names:
                plan.append(w)
                present_names.add(w["name"])
            else:
                skipped_shell += 1
            continue
        down = [p for p in cpanes if p["sessionId"] not in live_sids]
        skipped_live += len(cpanes) - len(down)
        down = [p for p in down if p["sessionId"] not in planned]
        if not down:
            continue
        if len(down) == len(cpanes):
            plan.append(w)
            for p in cpanes:
                planned.add(p["sessionId"])
        else:
            for p in down:
                plan.append({"index": w["index"], "name": p.get("name") or w["name"],
                             "active": True, "layout": "", "panes": [dict(p, index=1, active=True)]})
                planned.add(p["sessionId"])

# ── Report header ──────────────────────────────────────────────────────────────
n_sessions = sum(1 for w in plan for p in w["panes"] if p["type"] == "claude" and p.get("sessionId"))
if not plan:
    if not auto:
        msg = "✅ Nothing to restore — all %d snapshot Claude session(s) are already live." % skipped_live
        if skipped_shell and not do_all:
            msg += " (%d shell-only window(s) skipped; use --all to include.)" % skipped_shell
        print(msg)
    sys.exit(0)

if not auto:
    print("%s %d Claude session(s)%s" % (
        "Would restore" if dry else "Restoring", n_sessions,
        "  [DRY RUN]" if dry else ""))
    if skipped_live:
        print("  · skipping %d already-live session(s)" % skipped_live)
    if skipped_shell and not do_all:
        print("  · skipping %d shell-only window(s) (use --all to include)" % skipped_shell)

# ── Execute the plan ───────────────────────────────────────────────────────────
def pane_cmd(p):
    """Command for a NEW-window pane (Claude resumes; shells stay open)."""
    if p["type"] == "claude" and p.get("sessionId"):
        return "claude --resume %s; exec zsh" % p["sessionId"]
    return None

def send_resume(win_id, sid, want_cwd, have_cwd):
    """Relaunch claude in an existing idle shell via send-keys."""
    cmd = "claude --resume %s" % sid
    if want_cwd and os.path.normpath(os.path.expanduser(want_cwd)) != os.path.normpath(have_cwd or ""):
        cmd = "cd %s && %s" % (shlex.quote(os.path.expanduser(want_cwd)), cmd)
    tmux("send-keys", "-t", win_id, "C-u")
    tmux("send-keys", "-t", win_id, cmd, "Enter")

reused = created = 0
for w in plan:
    ppanes = w["panes"]
    if not ppanes:
        continue
    first = ppanes[0]
    label = (first.get("name") if first["type"] == "claude" else None) or w["name"]
    sid   = first.get("sessionId")
    single_claude = len(ppanes) == 1 and first["type"] == "claude" and sid

    # ── Try in-place reuse first (single-pane Claude windows only) ──────────────
    reuse = claim_window(label, first.get("cwd")) if single_claude else None
    if reuse:
        if dry:
            how = ("name" if reuse["name"] == label
                   else "cwd" if reuse["name"] in SHELLS and
                        os.path.normpath(reuse["cwd"]) == os.path.normpath(os.path.expanduser(first.get("cwd") or ""))
                        else "fill")
            print("  • reuse %s:%s '%s' (%s-match) ← claude:%s" %
                  (reuse["sess"], reuse["win_id"], reuse["name"], how, sid[:8]))
        else:
            # Always rename — this also turns OFF automatic-rename for the window,
            # so claude's process title ("2.1.186") can't clobber the session name
            # (the box has `automatic-rename on` globally).
            tmux("rename-window", "-t", reuse["win_id"], label)
            send_resume(reuse["win_id"], sid, first.get("cwd"), reuse["cwd"])
        reused += 1
        continue

    # ── Otherwise create a fresh window (full layout for multi-pane) ────────────
    tag = "claude:%s" % sid[:8] if first["type"] == "claude" else "shell"
    if dry:
        print("  • create '%s' (%d pane%s) — pane1=%s" %
              (label, len(ppanes), "" if len(ppanes) == 1 else "s", tag))
        for p in ppanes[1:]:
            t = "claude:%s" % p["sessionId"][:8] if p["type"] == "claude" else "shell"
            print("        + pane %s in %s" % (t, p["cwd"]))
        created += 1
        continue

    new_args = ["new-window", "-d", "-P", "-F", "#{window_id}",
                "-t", target, "-n", label, "-c", first["cwd"]]
    cmd = pane_cmd(first)
    if cmd:
        new_args.append(cmd)
    win_id = tmux(*new_args).stdout.strip()
    if not win_id:
        print("  ⚠️  failed to create window '%s' — skipping" % label)
        continue
    for p in ppanes[1:]:
        sp = ["split-window", "-d", "-t", win_id, "-c", p["cwd"]]
        cmd = pane_cmd(p)
        if cmd:
            sp.append(cmd)
        tmux(*sp)
    if w.get("layout") and len(ppanes) > 1:
        tmux("select-layout", "-t", win_id, w["layout"])
    for pos, p in enumerate(ppanes):
        if p.get("active"):
            tmux("select-pane", "-t", "%s.%d" % (win_id, pos + 1))
            break
    created += 1

# ── Final summary ──────────────────────────────────────────────────────────────
if dry:
    sys.exit(0)
summary = "✅ Restored %d session(s): %d reused in place, %d new window(s)." % (
    reused + created, reused, created)
if auto:
    print(summary)
else:
    print(summary)
    print("   Big sessions pause at the resume prompt — switch in and press Enter")
    print("   (summary) or ↓ Enter (full transcript) to wake each one.")
PY
