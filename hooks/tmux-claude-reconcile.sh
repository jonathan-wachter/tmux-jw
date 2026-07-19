#!/bin/bash
# tmux-claude-reconcile.sh — truth-reconciler + status-bar summary
#
# Run by tmux's status-right "#(...)" every status-interval (5s, cached and
# throttled by tmux itself). Jobs:
#
#   1. RECONCILE: hooks miss Ctrl+C interrupts, crashes, and kills (Stop/
#      SessionEnd simply don't fire). Claude Code maintains a live registry at
#      ~/.claude/sessions/<pid>.json with status busy|waiting|idle — we map
#      each registry entry to its tmux pane via the process tree and correct
#      any @ccstate the hooks got wrong. Panes whose Claude died get cleared.
#   2. WATCHDOG: a session claiming "busy" whose pane hasn't painted ANYTHING
#      for 3+ min (tmux window_activity) is frozen — Claude Code's spinner
#      repaints continuously while genuinely working, even in background
#      windows. Marked 🟠 stalled. (Registry statusUpdatedAt is a transition
#      timestamp, NOT a heartbeat — verified 2026-06-10 — so it can't be used.)
#   3. NAME: publish each session's /rename name (registry .name) to the
#      pane's @ccname option — window tabs display it instead of the tmux
#      window name.
#   4. RECAP: harvest Claude Code's own "※ recap" text (system/away_summary
#      records in the transcript JSONL) into @ccrecap — shown in the prefix+r
#      dashboard popup. Zero extra AI calls.
#   5. SUMMARY: print a global attention summary for status-right, e.g.
#      "🤖 2 🔴 1 ✅ 1" — visible from every session, every device.
#
# NOTE: the registry and away_summary records are undocumented Claude Code
# internals (verified on v2.1.17x). If an update changes them, the hooks still
# work alone — this script degrades to "no reconciliation/names/recaps" but
# never breaks tmux.

REG_DIR="$HOME/.claude/sessions"
# `! assoc` writes the authoritative session→project mapping here (one file per
# sessionId, append-only slug history; LAST line = current). $HOME-relative so
# the test harness's fake-HOME trick covers it too.
ASSOC_DIR="$HOME/projects/session-wraps/state/assoc"
STALL_SECS=180   # busy + no pane output for this long = stalled
# Recap-harvest mtime stamps (P3, 2026-07-08): one file per sessionId recording
# the transcript mtime we last harvested, so an UNCHANGED transcript skips the
# tail+grep+jq scan. Env-overridable for the test harness.
RECAP_CACHE="${JW_RECAP_CACHE:-$HOME/.cache/tmux-claude}"

# ── Gather inputs (pipe-separated to survive empty fields) ──────────────────
panes=$(tmux list-panes -a -F '#{pane_id}|#{pane_pid}|#{@ccstate}|#{@ccname}|#{window_activity}|#{pane_title}|#{@ccbg}' 2>/dev/null)
[ -z "$panes" ] && exit 0

# One ps snapshot: child→parent map for the whole machine (cheap, ~5ms).
pstree=$(ps -ax -o pid=,ppid= | awk '{print $1"|"$2}')

# Registry: pid|kind|status|sessionId for every LIVE session. ALL kinds now:
# interactive sessions drive a pane's STATE, but ANY live claude (including
# kind=="bg" — the claude --bg fleet windows are bg yet ARE the main session of
# their pane) marks the pane as a Claude pane so it gets named from its title.
# Background SUB-agents share an interactive ancestor pane; harmless here because
# the name comes from the pane title (one per pane), not from the session name.
# ONE jq over the WHOLE registry (P2, 2026-07-08) instead of one jq fork per
# file (the old `for f … jq` loop cost N forks every 30s tick, N = live Claudes).
# input_filename tags each record with its path so the pid survives; the shell
# loop strips it back to the pid and applies the SAME kill -0 liveness filter.
# DEGRADATION NOTE: jq processes the file args in order and ABORTS on the first
# invalid-JSON file, so a registry file caught mid-write would truncate this
# tick's session list. That is transient (Claude Code writes the registry
# atomically; the next 30s tick re-reads cleanly) and self-healing — a missing
# session just isn't reconciled for one tick (its hook-set @ccstate stands).
sessions=""
if ls "$REG_DIR"/*.json >/dev/null 2>&1; then
  while IFS='|' read -r fn kind status sid name; do
    [ -n "$fn" ] || continue
    pid=${fn##*/}; pid=${pid%.json}
    case "$pid" in ''|*[!0-9]*) continue;; esac        # only numeric pid files
    kill -0 "$pid" 2>/dev/null || continue             # skip dead sessions
    sessions="${sessions}${pid}|${kind}|${status}|${sid}|${name}
"
  done < <(jq -r '[input_filename, .kind // "", .status // "", .sessionId // "", .name // ""] | join("|")' \
             "$REG_DIR"/*.json 2>/dev/null)
fi

# ── Map registry pids → panes, decide corrections, tally summary ────────────
# Datasets stream through stdin with a record-type prefix because macOS awk
# forbids newlines in -v variable values.
actions=$({
  printf '%s\n' "$panes"    | sed 's/^/P|/'
  printf '%s\n' "$pstree"   | sed 's/^/T|/'
  printf '%s'   "$sessions" | sed 's/^/S|/'
} | awk -F'|' -v now="$(date +%s)" -v stall="$STALL_SECS" -v host="$(hostname)" -v hostshort="$(hostname -s)" '
$1 == "P" && $2 != "" {
  pane_by_pid[$3] = $2          # shell pid → pane id
  state[$2] = $4                # current @ccstate
  name[$2]  = $5                # current @ccname
  act[$2]   = $6                # window last-output time (epoch secs)
  ptitle[$2] = $7               # pane title — Claude shows "<spinner> <session name>"
  ccbg[$2]   = $8               # current @ccbg flag (bg work drives this pane)
  is_pane[$2] = 1
  next
}
$1 == "T" { parent[$2] = $3; next }
$1 == "S" && $2 != "" {
  # Walk up the process tree from the claude pid until we hit a pane pid.
  p = $2; hops = 0
  while (p > 1 && hops < 15 && !(p in pane_by_pid)) { p = parent[p]; hops++ }
  if (p in pane_by_pid) {
    pane = pane_by_pid[p]
    has_claude[pane] = 1                    # any kind → this is a Claude pane
    if ($3 == "interactive") {              # interactive drives STATE + recaps
      reg_status[pane] = $4
      reg_sid[pane]    = $5
    }
    # An ACTIVE kind==bg session whose process lives IN the pane (claude --bg
    # fleet window) marks the pane actively working too (BG-BUSY, 2026-07-09).
    # Active = anything but idle/waiting/empty: observed live values include
    # "busy" AND "shell" (mid tool-exec); a bg session exists to work, so
    # unknown future statuses default to ACTIVE, not ignored.
    if ($3 == "bg" && $4 != "idle" && $4 != "waiting" && $4 != "") bg_busy[pane] = 1
  } else if ($3 == "bg" && $4 != "idle" && $4 != "waiting" && $4 != "" && $6 != "") {
    # BG-BUSY BY NAME (2026-07-09): background agents/tasks spawned by an
    # interactive session run under the detached --bg-pty supervisor (parent =
    # launchd), so the tree walk can NEVER reach a pane. But the registry gives
    # them the SPAWNING sessions name, and we already derive each panes name
    # from its title — so map the orphan by name in the END block. Without
    # this, a pane whose interactive session idles while its background agent
    # works showed NO glyph at all: the hooks state (Stop keeps "working" when
    # background_tasks run) was actively CLEARED by the r==idle rule below.
    # Verified live on cc-main:10 sight-words-champion, 2026-07-09.
    bgbusy_name[$6] = 1
  }
  next
}
END {
  for (pane in is_pane) {
    s = state[pane]; r = reg_status[pane]

    # ── NAME — straight from the live pane TITLE, which Claude Code sets to the
    # session name (with a leading status spinner when interactive; bg-fleet windows
    # set a bare name with no spinner). Strip a leading spinner. A non-empty
    # title = a Claude session is here; a truly empty title (a plain shell pane, like
    # an idle zsh) clears the name. Title-only ON PURPOSE: the registry/process-tree
    # mapping was BOTH flaky (missed windows) AND bg-excluding, which is why version
    # names (2.1.195) kept leaking through.
    # PUBLISH THE FULL NAME (2026-07-02; was substr(dn,1,18), which silently
    # pre-cut every consumer — the bar sizes names dynamically now and the
    # dashboard wraps, so clipping belongs to each consumer). 60 = sanity cap.
    # NB: this comment lives INSIDE a single-quoted awk string — no apostrophes!
    dn = ptitle[pane]; sub(/^[^a-zA-Z0-9]+/, "", dn); dn = substr(dn, 1, 60)
    # HOSTNAME = NO TITLE (2026-07-16): tmux defaults pane_title to #{host},
    # so a pane whose program never sets a title (e.g. the email-triage TUI)
    # would publish the HOSTNAME as its @ccname and hijack the tab away from
    # the real window_name. Treat the default as empty.
    if (dn == host || dn == hostshort) dn = ""
    if (dn != name[pane]) print pane "|name|" (dn == "" ? "clear" : dn)

    # BG-BUSY BY NAME (2026-07-09): an unmappable busy bg session whose
    # registry name equals this panes title-derived name is attributed here.
    # (Two panes with identical names would both light up — acceptable soft
    # failure; names are the window identity everywhere else in this system.)
    if (dn != "" && (dn in bgbusy_name)) bg_busy[pane] = 1

    # Publish the bg-driven flag as @ccbg so renderers can style the name
    # differently (boxbar shows the tab name in ITALICS — JW belt-and-
    # suspenders request 2026-07-09). Written only on change, like @ccstate.
    want_bg = bg_busy[pane] ? "1" : ""
    if (want_bg != ccbg[pane]) print pane "|bgflag|" (want_bg == "" ? "clear" : want_bg)

    # ── STATE + recaps — interactive sessions drive state; a busy bg session
    # in/for the pane counts as work too (BG-BUSY, 2026-07-09). For a bg-only
    # pane with NO bg activity, leave the hook-set @ccstate alone; only clear
    # state when there is no Claude in the pane at all.
    if (r == "") {
      if (bg_busy[pane]) {
        if (s != "question" && s != "needs_you") {
          new = (now - act[pane] > stall) ? "stalled" : "working"
          if (new != s) print pane "|state|" new
        }
      }
      else if (!has_claude[pane] && s != "") print pane "|state|clear"
      continue
    }
    print pane "|sid|" reg_sid[pane]      # recap harvesting happens in bash

    # Reconciliation rules — hooks win on specificity, registry on truth:
    #   busy    → active state; but silent pane for 3+ min = stalled 🟠
    #   waiting → must show an attention state (missed permission event)
    #   idle    → active/attention states are stale (Ctrl+C, Esc); keep "done"
    #             — UNLESS a bg session is busy for this pane: the interactive
    #             turn ended but delegated work is still running, so show it
    #             working (this also overrides a premature "done").
    new = s
    if (r == "busy" || (r == "idle" && bg_busy[pane])) {
      if (s != "question" && s != "needs_you")
        new = (now - act[pane] > stall) ? "stalled" : "working"
    }
    else if (r == "waiting" && s != "needs_you" && s != "question") {
      # WAITING can mean a permission prompt OR a pending AskUserQuestion —
      # the hooks catch the former instantly (PermissionRequest → needs_you)
      # but NOT the latter (PreToolUse never fires for AskUserQuestion,
      # verified live 2026-07-09). The registry cannot tell them apart, but
      # the transcript can: bash peeks the last assistant tool call and sets
      # question (💬) vs needs_you (🔴). Emit a waitq action carrying the sid.
      new = "needs_you"; wait_peek[pane] = 1
    }
    else if (r == "idle" && (s == "working" || s == "question" || s == "needs_you" || s == "stalled")) new = "clear"
    if (new != s) {
      if (wait_peek[pane]) print pane "|waitq|" reg_sid[pane]
      else print pane "|state|" new
    }

    final = (new == "clear" ? "" : new)
    if      (final == "working")                          n_work++
    else if (final == "needs_you" || final == "question") n_attn++
    else if (final == "stalled")                          n_stall++
    else if (final == "done")                             n_done++
  }
  # Each glyph group is wrapped in a tmux user range (#[range=user|ID]…
  # #[norange]) so a status-bar tap on it can be routed to tmux-claude-jump.sh
  # by the MouseDown1Status binding in tmux.conf. format_draw honors #[…] markup
  # even when it arrives via a #() job stdout (only #{}/#() are not re-run).
  # NOTE: keep this awk block free of apostrophes — it is bash single-quoted.
  out = ""
  if (n_work  > 0) out = out "#[range=user|j_work]🤖 "  n_work  " #[norange]"
  if (n_attn  > 0) out = out "#[range=user|j_attn]🔴 "  n_attn  " #[norange]"
  if (n_stall > 0) out = out "#[range=user|j_stall]🟠 " n_stall " #[norange]"
  if (n_done  > 0) out = out "#[range=user|j_done]✅ "  n_done  " #[norange]"
  print "SUMMARY|" out
}')

# ── Apply corrections, harvest recaps, print the summary ────────────────────
# Pull the SUMMARY line out FIRST: it now carries #[range=user|…] markup whose
# '|' chars would be mangled by the IFS='|' field split in the loop below.
summary=$(printf '%s\n' "$actions" | sed -n 's/^SUMMARY|//p')

# P4 (2026-07-08): the boxbar reader ignores @ccstate/@ccname between rebuilds
# except when the global state.dirty marker moves — so a NAME correction (or a
# reconciler-only state fix) published here otherwise shows only after the 30s
# INTERVAL. Track whether we wrote any state/name change and bump state.dirty
# ONCE at the end (below) if so. Reconcile runs ≤once/INTERVAL, so this can't
# storm; recap-only writes do NOT set it (recaps aren't on the bar).
dirty_changed=0

while IFS='|' read -r pane kind value; do
  [ "$pane" = "SUMMARY" ] && continue
  case "$kind" in
    state)
      if [ "$value" = "clear" ]; then
        tmux set-option -pq -t "$pane" -u @ccstate 2>/dev/null
      else
        tmux set-option -pq -t "$pane" @ccstate "$value" 2>/dev/null
      fi
      dirty_changed=1
      ;;
    name)
      if [ "$value" = "clear" ]; then
        tmux set-option -pq -t "$pane" -u @ccname 2>/dev/null
      else
        tmux set-option -pq -t "$pane" @ccname "$value" 2>/dev/null
      fi
      dirty_changed=1
      ;;
    bgflag)
      if [ "$value" = "clear" ]; then
        tmux set-option -pq -t "$pane" -u @ccbg 2>/dev/null
      else
        tmux set-option -pq -t "$pane" @ccbg 1 2>/dev/null
      fi
      dirty_changed=1     # italic styling lives on the bar → rebuild + repaint
      ;;
    waitq)
      # value = sessionId of a session in registry status "waiting". Decide
      # 💬 vs 🔴 by peeking the transcript: the last assistant record's last
      # tool_use name is AskUserQuestion for a pending question, else it is
      # the permission-blocked tool. Falls back to needs_you when the
      # transcript is missing/unreadable — never worse than the old rule.
      # Cost: one tail+grep per pane ENTERING waiting (the awk only emits
      # this when a correction is needed), not per tick.
      wstate=needs_you
      tf=$(ls "$HOME/.claude/projects/"*/"$value".jsonl 2>/dev/null | head -1)
      if [ -n "$tf" ]; then
        last_tool=$(tail -c 131072 "$tf" | grep '"type":"assistant"' | tail -1 \
                    | grep -o '"name":"[A-Za-z_]*"' | tail -1)
        case "$last_tool" in *AskUserQuestion*) wstate=question;; esac
      fi
      tmux set-option -pq -t "$pane" @ccstate "$wstate" 2>/dev/null
      dirty_changed=1
      ;;
    sid)
      # ASSOC → @ccproj (2026-07-13, JW): `assoc` sets the pane option ONCE,
      # but a SessionStart clear (compaction/resume) wipes it and nothing
      # republished it — a stale red P? that no amount of assoc-ing dismissed
      # (and the mirror bug: assoc --clear left a stale slug). Re-derive from
      # the authoritative assoc file for the pane's LIVE sessionId every tick:
      # self-heals both directions. show-option is a read (no redraw); we
      # write only on change and bump dirty so P? flips on the next redraw.
      want_proj=$(tail -1 "$ASSOC_DIR/$value" 2>/dev/null)
      cur_proj=$(tmux show-option -pqv -t "$pane" @ccproj 2>/dev/null)
      if [ "$want_proj" != "$cur_proj" ]; then
        if [ -z "$want_proj" ]; then tmux set-option -pq -t "$pane" -u @ccproj 2>/dev/null
        else tmux set-option -pq -t "$pane" @ccproj "$want_proj" 2>/dev/null; fi
        dirty_changed=1
      fi
      # Latest "※ recap" from the transcript (newest away_summary record in
      # the last 256KB — recaps are sparse; tail keeps this cheap on big files)
      tf=$(ls "$HOME/.claude/projects/"*/"$value".jsonl 2>/dev/null | head -1)
      if [ -n "$tf" ]; then
        # MTIME GATE (P3, 2026-07-08): skip the tail+grep+jq scan when the
        # transcript hasn't changed since we last harvested it. Steady state (N
        # idle Claudes) drops from N×(tail+grep+jq) per tick to N×(stat+show).
        # We still re-harvest if @ccrecap is currently EMPTY (a crash-restored
        # pane reuses the sessionId+transcript but starts with no @ccrecap), so
        # the gate never strands a blank recap.
        tf_mtime=$(stat -f %m "$tf" 2>/dev/null || echo 0)
        stamp="${RECAP_CACHE}/recap_seen_${value}"
        seen_mtime=0; [ -r "$stamp" ] && read seen_mtime < "$stamp" 2>/dev/null
        cur_recap=$(tmux show-option -pqv -t "$pane" @ccrecap 2>/dev/null)
        if [ "$tf_mtime" != 0 ] && [ "$tf_mtime" = "$seen_mtime" ] && [ -n "$cur_recap" ]; then
          [ -n "$JW_RECONCILE_TRACE" ] && echo "skip $value" >&2
        else
          [ -n "$JW_RECONCILE_TRACE" ] && echo "harvest $value" >&2
          recap=$(tail -c 262144 "$tf" | grep '"away_summary"' | tail -1 \
                  | jq -r '.content // empty' 2>/dev/null \
                  | sed 's/ (disable recaps in \/config)//')
          # IDEMPOTENT (2026-06-17): only write when the value actually CHANGED.
          # show-option is a READ (no redraw); set-option triggers a status
          # redraw. The old unconditional set fired once PER active session EVERY
          # run (~10 redraws/tick with 10 Claudes) — the main cause of the
          # constant cursor flicker over mosh. Steady state is now zero writes.
          if [ -n "$recap" ]; then
            new_recap="${recap:0:300}"
            [ "$cur_recap" != "$new_recap" ] && tmux set-option -pq -t "$pane" @ccrecap "$new_recap" 2>/dev/null
          fi
          # Record the mtime we harvested against — even when no recap was found
          # (the file is current; a re-scan next tick would find nothing new).
          mkdir -p "$RECAP_CACHE" 2>/dev/null
          printf '%s\n' "$tf_mtime" > "${stamp}.tmp.$$" 2>/dev/null && mv -f "${stamp}.tmp.$$" "$stamp" 2>/dev/null
        fi
      fi
      ;;
  esac
done <<EOF
$actions
EOF

# P3: prune recap mtime-stamps for long-dead sessions (>7d since last harvest)
# so the stamp dir can't grow unbounded. One find; runs on the throttled tick.
find "$RECAP_CACHE" -name 'recap_seen_*' -mtime +7 -delete 2>/dev/null || true

# P4: if any @ccstate/@ccname changed, mark the boxbar cache stale so the reader
# rebuilds on the next redraw instead of waiting out the INTERVAL. One truncate.
# 2026-07-09: ALSO push a status redraw to every client — without it, a
# reconciler-only correction (crash cleanup, 🟠 stalled, missed needs_you) sat
# invisible until each client's own status-interval tick, stacking a second
# ≤30s of lag on top of the ≤30s heartbeat cadence. Reconcile runs ≤once per
# INTERVAL, so 2 extra forks here cannot storm.
if [ "$dirty_changed" = 1 ]; then
  d="${TMPDIR:-/tmp}/tmux-claude-bar"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null
  : > "$d/state.dirty" 2>/dev/null || true
  tmux list-clients -F 'refresh-client -S -t "#{client_name}"' 2>/dev/null \
    | tmux source-file - 2>/dev/null
fi

# ── Emit / persist the summary ──────────────────────────────────────────────
# --write (used by tmux-claude-statusline.sh): persist to the cache file that
# the status bar reads, written ATOMICALLY (temp + mv) so the bar never cats a
# half-written file mid-update. Without --write (manual runs / debugging) it
# still prints to stdout exactly as before, so nothing else that calls this
# script directly is affected.
if [ "${1:-}" = "--write" ]; then
  CACHE_DIR="$HOME/.cache/tmux-claude"
  mkdir -p "$CACHE_DIR" 2>/dev/null
  tmp="$CACHE_DIR/.summary.$$"
  printf '%s' "$summary" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CACHE_DIR/summary" 2>/dev/null

  # CRASH-RECOVERY WATCHER (2026-06-19): snapshot the live Claude-in-tmux layout
  # so it can be one-key-restored after a crash. Rides this same 5s heartbeat —
  # no extra daemon. Self-locating, fully guarded, can never break the heartbeat.
  "$(dirname "$0")/tmux-claude-snapshot.sh" >/dev/null 2>&1 || true

  # CRASH FORENSICS CAPTURE (2026-06-21): right after the snapshot refreshes, freeze
  # the logs of any Claude session that just left the live registry WITH a crash
  # signature (server exited / heap OOM / fatal / signal) into a durable, prune-exempt
  # ~/.claude/tmux-logs/crash-<ts>_<name>/ bundle. Reuses the snapshot's session→pane
  # map and the same "down" rule as tmux-claude-check.sh — no new detector, no new
  # daemon. Clean quits don't bundle (no crash signature). /debug-jw surfaces these.
  "$(dirname "$0")/tmux-claude-crashcap.sh" >/dev/null 2>&1 || true
else
  printf '%s' "$summary"
fi
exit 0
