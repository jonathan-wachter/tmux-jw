#!/bin/bash
# tmux-claude-bar-render.sh — STALE-WHILE-REVALIDATE render of the connected-table
# dashboard ribbon (STORM-FIX rewrite, 2026-06-26).
#
# WHY THE REWRITE: the previous version did ALL work on EVERY #() call (no cache),
# forking ~30 per-cell $(dwidth|repeat|head_w|tail_w|…) subshells × 3 rows ×
# (clients × windows). Under load those renders piled up and drove the spawn storm
# (see docs/notes/2026-06-spawn-storm-*.md). This version splits into:
#
#   READER  (the #() entrypoint): a FAST path. It just `cat`s the per-client cached
#           row for the requested row number and returns INSTANTLY (one stat + one
#           cat, zero per-cell forks). If the cache is stale (mtime older than
#           INTERVAL OR the input-hash file no longer matches the live inputs) it
#           kicks ONE detached, mkdir-locked BUILDER per client_pid and STILL returns
#           the cached row immediately (classic stale-while-revalidate).
#
#   BUILDER (background, invoked as `… --build <width> <session> <cur> <client_pid>`):
#           the heavy render. Runs the 2 `tmux list-windows` calls ONCE and builds
#           ALL 3 rows for this client_pid in a single pass, then writes them
#           atomically to the cache. Runs ≤ once/INTERVAL per client (lock + mtime
#           gate), so redraw rate is fully decoupled from render cost — it cannot
#           pile up. Every $(dwidth|repeat|head_w|tail_w|glyph|blanks|border) was
#           rewritten to assign a result var via `printf -v` (an out-var arg) so the
#           builder forks ≈0 beyond the 2 tmux reads.
#
# VISUAL OUTPUT (2026-07-02 layout): a FULL-HEIGHT STACKED slate block on the
# left — session name on the top row, a rule across the middle, global counts
# on the bottom row (`cc-0624-0 / ─────── / 🤖1•✅2`), light-on-dark, entirely
# tappable (sessmenu → cockpit dropdown) — then the 3-row connected window
# table (tight tabs, single bold ◀/▶ scroll glyphs, current tab inverted,
# window|N + user|bscrollL/R click ranges). The old row-0 corner capsules and
# per-glyph link_* ranges are gone; the block replaces both.
#
# READER args:  <row 0|1|2>  <client_width>  <session_name>  <cur_window_index>  <client_pid>
# BUILDER args: --build      <client_width>  <session_name>  <cur_window_index>  <client_pid>
#
# bash 3.2 safe: no associative arrays, no namerefs; out-vars passed by name and set
# with `printf -v "$name"` / `eval`. LC_ALL forced for emoji width math.

export LC_ALL=en_US.UTF-8

# ── shared config / paths ─────────────────────────────────────────────────────
STATE_DIR="${TMPDIR:-/tmp}/tmux-claude-bar"   # viewport files (shared with pre-storm)
CACHE_DIR="${STATE_DIR}/cache"                # row{0,1,2}_<pid> + hash + locks live here
INTERVAL=30                                   # max cache age (s) before a rebuild kicks
SELF="$0"

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ READER  — the #() entrypoint. Fast: cat cached row, maybe kick a builder. ║
# ╚══════════════════════════════════════════════════════════════════════════╝
if [ "$1" != "--build" ]; then
  row=${1:-1}; width=${2:-120}; session=${3:-}; cur=${4:-0}; client=${5:-0}

  rowfile="${CACHE_DIR}/row${row}_${client}"
  hashfile="${CACHE_DIR}/hash_${client}"

  # Quick, fork-light staleness probe. We deliberately do NOT run the 2 tmux
  # list-windows reads here (that's the builder's job) — staleness is judged on
  # (a) cache age and (b) a CHEAP input hash over ONLY the args we already have:
  # session, current window, width, client. These are exactly the inputs that
  # re-anchor the viewport / change which cells are highlighted, so a change here
  # must rebuild immediately. Everything else the build depends on (the window
  # table, names, per-window @ccstate, the global state counts, and manual scroll
  # position) is NOT in this cheap key — those are covered by the INTERVAL mtime
  # gate (rebuild within 30s). We intentionally do NOT key on the viewport file's
  # mtime: the builder itself rewrites that file, which would make the key flap on
  # every build and force a rebuild on every single read (defeating the cache).
  cheap_key="${session}|${cur}|${width}|${client}"

  stale=0
  if [ ! -r "$rowfile" ]; then
    stale=1
  else
    age=$(( $(date +%s) - $(stat -f %m "$rowfile" 2>/dev/null || echo 0) ))
    [ "$age" -ge "$INTERVAL" ] && stale=1
    if [ "$stale" = 0 ] && [ -r "$hashfile" ]; then
      read stored_cheap _ < "$hashfile" 2>/dev/null
      [ "$stored_cheap" != "$cheap_key" ] && stale=1
    fi
    # (c) a window's @ccstate changed since this row was built → rebuild NOW so the
    # glyph/counts repaint near-instantly instead of waiting out the INTERVAL gate.
    # state.sh touches state.dirty ONLY on a real transition (not every hook), and
    # the builder records the dirty mtime it built against in seendirty_<pid>, so
    # this fires once per actual change — never on same-state hook spam (no storm).
    # Race-free: a transition during a build bumps state.dirty past the build's
    # recorded mtime, so the next read rebuilds again (never a missed change).
    # FRACTIONAL MTIME (2026-07-09): %Fm (nanoseconds on APFS), compared as a
    # STRING with != — the old whole-second `%m -gt` missed any transition that
    # landed in the SAME second as the build's snapshot (a real race: hooks fire
    # within ms of the rebuild they themselves triggered), stranding the stale
    # glyph until the 30s INTERVAL. Inequality is enough: mtimes only move
    # forward, so "changed since the build" == "differs from the snapshot".
    # seendirty_<pid> now holds TWO fields: "<dirty %Fm> <vp %Fm>" (see (d)).
    seen_dirty=0; seen_vp=0
    if [ "$stale" = 0 ]; then
      [ -r "${CACHE_DIR}/seendirty_${client}" ] && read seen_dirty seen_vp < "${CACHE_DIR}/seendirty_${client}"
      cur_dirty=$(stat -f %Fm "${STATE_DIR}/state.dirty" 2>/dev/null || echo 0)
      [ "$cur_dirty" != "${seen_dirty:-0}" ] && stale=1
    fi
    # (d) viewport scrolled externally (bar-scroll.sh nudged vp via the ◀/▶ chrome)
    # → rebuild so the manual scroll actually shows. vp is NOT in cheap_key, so
    # without this a scroll never invalidates the cache. Compared the same %Fm-
    # string way as (c) against the vp mtime the builder recorded (2026-07-09;
    # the old `vp -nt rowfile` test was whole-second too, so a scroll tap in the
    # same second as a rebuild was silently swallowed — e.g. rapid double-taps).
    # The builder snapshots vp's mtime AFTER its own conditional write and
    # BEFORE writing the rowfiles, so its own writes never self-trigger a flap;
    # only an external nudge changes the mtime afterwards.
    if [ "$stale" = 0 ]; then
      cur_vp=$(stat -f %Fm "${STATE_DIR}/vp_${client}_${session}" 2>/dev/null || echo 0)
      [ "$cur_vp" != "${seen_vp:-0}" ] && stale=1
    fi
  fi

  if [ "$stale" = 1 ]; then
    # Kick ONE builder per client_pid, fully detached so this #() capture returns
    # NOW. mkdir lock = atomic overlap guard (macOS has no flock); a crashed
    # builder can't wedge it forever (stale-lock reap below). Redirecting the whole
    # block to /dev/null means the child does NOT hold tmux's stdout pipe open —
    # tmux gets EOF the instant the `cat` at the bottom of the reader exits.
    lockdir="${CACHE_DIR}/lock_${client}.d"
    {
      mkdir -p "$CACHE_DIR" 2>/dev/null
      if [ -d "$lockdir" ]; then
        lage=$(( $(date +%s) - $(stat -f %m "$lockdir" 2>/dev/null || echo 0) ))
        [ "$lage" -gt 60 ] && rmdir "$lockdir" 2>/dev/null
      fi
      if mkdir "$lockdir" 2>/dev/null; then
        # Invoke via `bash "$SELF"` (not exec) so the kick works even if the
        # file's +x bit isn't set yet (e.g. freshly `mv`d from .stormfix-staged
        # before chmod). tmux's own #() runs us through a shell too.
        bash "$SELF" --build "$width" "$session" "$cur" "$client" "$cheap_key"
        rmdir "$lockdir" 2>/dev/null
      fi
    } >/dev/null 2>&1 &
  fi

  # Return the cached row INSTANTLY (stale-while-revalidate). On a cold cache
  # (first ever render for this client) emit the bare grid background so the bar
  # is never blank; the builder fills it within INTERVAL.
  if [ -r "$rowfile" ]; then
    cat "$rowfile" 2>/dev/null
  else
    printf '%s' '#[fg=#1a1a1a,bg=#b5bcc8,nobold]'
  fi
  exit 0
fi

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ BUILDER — heavy render, runs ≤once/INTERVAL per client. Builds all 3 rows.║
# ╚══════════════════════════════════════════════════════════════════════════╝
shift   # drop --build
width=${1:-120}; session=${2:-}; cur=${3:-0}; client=${4:-0}; cheap_key=${5:-}

# After writing fresh cache, PUSH it to the screen. Stale-while-revalidate only
# REVALIDATES the cache here; without a redraw the new render (e.g. the current-tab
# highlight after a window switch) isn't shown until the NEXT redraw event —
# status-interval (up to 30s), a scroll, or a Claude hook's refresh. That gap is the
# "highlight doesn't update after a swipe" bug. redisplay() forces a status redraw of
# THIS client (mapped from client_pid) so the highlight/glyphs update within one
# builder cycle (~200ms). Targeted, so other clients don't cascade-refresh — each
# client's own builder refreshes itself. The redraw re-runs the readers, which now
# find the cache fresh (cheap_key/dirty/age all match) → plain cat, no rebuild → no
# loop. Called from BOTH cache-write paths (empty-session + main) just before exit.
redisplay() {
  local cname
  cname=$(tmux list-clients -F '#{client_pid} #{client_name}' 2>/dev/null | awk -v p="$client" '$1==p{print $2; exit}')
  [ -n "$cname" ] && tmux refresh-client -S -t "$cname" 2>/dev/null
}

NW=40            # HARD ceiling on a window name (sanity cap for the L-search)
NFLOOR=9         # name floor: below this we stop shrinking and start scrolling
MARGIN=2         # scrolloff context windows

GRID='#[fg=#1a1a1a,bg=#b5bcc8,nobold]'   # near-black on blue-gray (tabs, << >>, gridlines)
SLATE='#[fg=#ffffff,bg=#394553,bold]'    # white/bold on slate (session name + current tab)

LBTN="◀"; RBTN="▶"                        # scroll buttons: single bold glyph, tight
lbw=${#LBTN}; rbw=${#RBTN}

# ── helpers (ALL fork-free: result written into a caller-named out-var) ────────
# Each takes its output variable NAME as the LAST positional arg and assigns it
# with `printf -v` / `eval`, so callers never need $(...) command substitution.

# dwidth <string> <outvar> — display width in cells (each 2-wide emoji counts 1
# extra over its byte-length-naive char count, matching the original).
# 📚/📺 (the block's sessions/windows badges) are Emoji_Presentation codepoints —
# reliably 2 cells, unlike e.g. 🗂/🖥 which render 1-or-2 depending on terminal.
dwidth() {
  local s=$1 total=${#1} g t before
  for g in 🤖 💬 🔴 ✅ 🟠 📚 📺; do
    before=${#s}; t=${s//"$g"/}; total=$((total + before - ${#t})); s=$t
  done
  printf -v "$2" '%s' "$total"
}

# repeat <n> <char> <outvar> — <char> repeated n times.
repeat() {
  local n=$1 ch=$2 out
  (( n < 0 )) && n=0
  printf -v out '%*s' "$n" ''
  printf -v "$3" '%s' "${out// /$ch}"
}

# head_w <string> <width> <outvar> — left-truncate <string> to fit <width> cells,
# right-padded with spaces to EXACTLY <width> (preserves original alignment).
head_w() {
  local s=$1 w=$2 out="" c ch __dw __pad
  for ((c=0; c<${#s}; c++)); do
    ch=${s:c:1}; dwidth "$out$ch" __dw; (( __dw > w )) && break; out="$out$ch"
  done
  dwidth "$out" __dw; __pad=$(( w - __dw )); (( __pad < 0 )) && __pad=0
  printf -v "$3" '%s%*s' "$out" "$__pad" ''
}

# tail_w <string> <width> <outvar> — right-truncate (keep tail) to <width> cells,
# left-padded with spaces to EXACTLY <width>.
tail_w() {
  local s=$1 w=$2 out="" c ch __dw __pad
  for ((c=${#s}-1; c>=0; c--)); do
    ch=${s:c:1}; dwidth "$ch$out" __dw; (( __dw > w )) && break; out="$ch$out"
  done
  dwidth "$out" __dw; __pad=$(( w - __dw )); (( __pad < 0 )) && __pad=0
  printf -v "$3" '%*s%s' "$__pad" '' "$out"
}

# glyph <state> <outvar> — emoji for a @ccstate.
# NOTE: the internal var is __g (NOT g): a caller passes `g` AS the out-var name
# (`glyph "$ws" g`), so a `local g` here would SHADOW the caller's g and the
# `printf -v "$2"` write would land on the doomed local instead — dropping the
# glyph entirely. Use a name no caller will ever pass as an out-var.
glyph() {
  local __g
  case "$1" in
    working)   __g='🤖';;
    question)  __g='💬';;
    needs_you) __g='🔴';;
    done)      __g='✅';;
    stalled)   __g='🟠';;
    *)         __g='';;
  esac
  printf -v "$2" '%s' "$__g"
}

# blanks <n> <outvar> — n spaces.
blanks() { printf -v "$2" '%*s' "$1" ''; }

# center <string> <width> <outvar> — centered, space-padded to EXACTLY <width>.
center() {
  local s=$1 w=$2 __dw lp rp
  dwidth "$s" __dw
  lp=$(( (w - __dw) / 2 )); (( lp < 0 )) && lp=0
  rp=$(( w - __dw - lp ));  (( rp < 0 )) && rp=0
  printf -v "$3" '%*s%s%*s' "$lp" '' "$s" "$rp" ''
}

# Snapshot state.dirty's mtime BEFORE reading @ccstate below, so seendirty records
# "the state as of this build" (see the reader's dirty check). Captured before the
# reads = any later transition bumps state.dirty past this → reader rebuilds again.
# %Fm (fractional, ns on APFS) since 2026-07-09 — compared by string (in)equality
# in the reader, closing the same-second race the whole-second %m had.
dirty_at_build=$(stat -f %Fm "${STATE_DIR}/state.dirty" 2>/dev/null || echo 0)
# vp path is needed by BOTH exit paths now (the empty-session early-exit writes a
# vp mtime snapshot too), so name it here rather than down in the viewport logic.
vpfile="${STATE_DIR}/vp_${client}_${session}"

# Optional local config (repo root, git-ignored — see tmux-jw.config.example).
# Env wins for TMUXJW_PROJ_MARKER so the test harness can pin it.
__env_pm="${TMUXJW_PROJ_MARKER:-}"
__cfg="${BASH_SOURCE[0]%/*}/../tmux-jw.config"
[ -r "$__cfg" ] && . "$__cfg"
[ -n "$__env_pm" ] && TMUXJW_PROJ_MARKER="$__env_pm"
# P? MARKER GATE: the red P? badge flags Claude windows with no `! assoc`
# project association — meaningless without the session-pipelines assoc
# workflow, where it would brand EVERY window forever. auto (default) = on
# only when the assoc state dir exists; force with 1/0.
case "${TMUXJW_PROJ_MARKER:-auto}" in
  1|on)  PMARK=1;;
  0|off) PMARK=0;;
  *)     if [ -d "$HOME/projects/session-pipelines/state/assoc" ]; then PMARK=1; else PMARK=0; fi;;
esac

# ── gather THIS session's windows (RAW — cells are built later, once the
#    dynamic name cap L is known; see DYNAMIC TAB WIDTH below) ─────────────────
idx=(); rname=(); rg=(); rbg=(); rfg=(); text=(); slot=(); n=0
# \x1f (unit separator) as delimiter, NOT tab: tab is IFS whitespace, so
# consecutive tabs COLLAPSE on read — an empty @ccbg would shift @ccproj
# into wb (latent for years with trailing-empty fields; exposed 2026-07-13
# when a non-empty field landed after an empty one). \x1f never collapses.
while IFS=$'\x1f' read -r wi wn ws wb wp wf wcc; do
  [ -z "$wi" ] && continue
  wn=${wn:0:$NW}; glyph "$ws" g
  # NO-PROJECT MARKER (2026-07-13, PERSISTENT per JW): a Claude window with no
  # `! assoc` association shows a red P? on the bottom border ALWAYS — appended
  # to the state emoji when one is up ("🤖·P?"), standalone ("P?") when the
  # window is idle. "Is a Claude window" = active pane comm is claude or a bare
  # version string (same rule as the dashboard/park CCRE); comm is the LAST
  # gather field on purpose — it is never empty, so it cannot collapse.
  if [ "$PMARK" = 1 ] && [ -z "$wp" ]; then
    if [ -n "$g" ]; then g="${g}·P?"
    elif [[ "$wcc" =~ ^(claude|[0-9]+(\.[0-9]+){1,3})$ ]]; then g="P?"; fi
  fi
  # BOTTOM-BORDER BADGE (2026-07-13, revised per JW: "numbers above look
  # silly"): the window NUMBER leads the badge on EVERY window — ┤7├ bare,
  # ┤7·🤖├ working, ┤7·✅·P?├ done + unassociated — replacing the old inline
  # "7•name" cell prefix in the 3-row mode. border() degrades right-to-left
  # (·P? first, then the emoji) so the number survives the narrowest cells.
  g="${wi}${g:+·${g}}"
  n=$((n+1)); idx[n]=$wi; rname[n]=$wn; rg[n]=$g; rbg[n]=$wb; rfg[n]=$wf
done < <(tmux list-windows -t "$session" -F $'#{window_index}\x1f#{?#{@ccname},#{@ccname},#{window_name}}\x1f#{@ccstate}\x1f#{@ccbg}\x1f#{@ccproj}\x1f#{@ccfg}\x1f#{pane_current_command}' 2>/dev/null)

# ── status box: GLOBAL state counts across ALL tmux windows (every session),
#    plus the tmux session count (ns) for the block's info row — one pass, no
#    extra tmux call (unique session names tracked in a |-delimited seen-list,
#    bash-3.2-safe stand-in for an associative set) ─────────────────────────────
g_w=0; g_q=0; g_n=0; g_d=0; g_s=0
ns=0; seen_s="|"
while IFS=$'\t' read -r sn ws; do
  case "$seen_s" in *"|${sn}|"*) ;; *) seen_s="${seen_s}${sn}|"; ns=$((ns+1));; esac
  case "$ws" in
    working)   g_w=$((g_w+1));;
    question)  g_q=$((g_q+1));;
    needs_you) g_n=$((g_n+1));;
    done)      g_d=$((g_d+1));;
    stalled)   g_s=$((g_s+1));;
  esac
done < <(tmux list-windows -a -F '#{session_name}	#{@ccstate}' 2>/dev/null)

# FULL input hash: the cheap key (args + vp mtime) PLUS the window table and the
# global-state multiset. Stored alongside the rows so a future reader could match
# it; the reader only checks the cheap subset, the mtime gate covers the rest.
win_sig=""
for ((k=1;k<=n;k++)); do win_sig="${win_sig}${idx[k]}:${rname[k]}${rg[k]}${rbg[k]}${rfg[k]};"; done
# BARMODE (2026-07-13): mode 3 moves window numbers OUT of the tab cells onto
# the TOP border (┤2├, mirroring the bottom-border glyphs); the 1-line compact
# mode has no borders, so it keeps them INLINE ("2•name"). One show per BUILD
# (not per render); the toggle in bar.sh pokes state.dirty so a mode flip
# rebuilds immediately instead of serving the other mode's cached row.
bm=$(tmux show -gqv @barmode 2>/dev/null); [ "$bm" = 1 ] || bm=3
NPFX=""; [ "$bm" = 1 ] && NPFX=1
full_hash="${cheap_key}#W=${win_sig}#G=${g_w},${g_q},${g_n},${g_d},${g_s},${ns}#M=${bm}"

# Empty session (no windows): write a bare-grid row to all 3 cache files and stop.
mkdir -p "$CACHE_DIR" 2>/dev/null
if [ "$n" -eq 0 ]; then
  for r in 0 1 2; do
    tmp="${CACHE_DIR}/.row${r}_${client}.$$"
    printf '%s' "$GRID" > "$tmp" 2>/dev/null && mv -f "$tmp" "${CACHE_DIR}/row${r}_${client}" 2>/dev/null
  done
  printf '%s %s\n' "$cheap_key" "$full_hash" > "${CACHE_DIR}/.hash_${client}.$$" 2>/dev/null \
    && mv -f "${CACHE_DIR}/.hash_${client}.$$" "${CACHE_DIR}/hash_${client}" 2>/dev/null
  vp_at_build=$(stat -f %Fm "$vpfile" 2>/dev/null || echo 0)
  printf '%s %s\n' "$dirty_at_build" "$vp_at_build" > "${CACHE_DIR}/.seendirty_${client}.$$" 2>/dev/null \
    && mv -f "${CACHE_DIR}/.seendirty_${client}.$$" "${CACHE_DIR}/seendirty_${client}" 2>/dev/null
  redisplay
  exit 0
fi

curpos=1; for ((k=1;k<=n;k++)); do [ "${idx[k]}" = "$cur" ] && { curpos=$k; break; }; done

# ── LEFT BLOCK: session name + global counts, full-height slate (2026-07-02) ──
# `cc-0624-0•🤖1•✅2` — light text on dark slate, spanning ALL 3 bar rows on the
# left; the ENTIRE block (all three rows) is one sessmenu tap target that opens
# the cockpit dropdown. This replaces the old row-0 `) name (` / `) counts (`
# corner capsules AND the per-glyph link_* click ranges (bar-link.sh no longer
# has a bar affordance; prefix+g still jumps by attention).
sp=""
addstat() {   # <emoji> <count>
  [ "$2" -gt 0 ] || return
  [ -n "$sp" ] && sp="${sp}•"
  sp="${sp}${1}${2}"
}
addstat 🤖 "$g_w"; addstat 💬 "$g_q"; addstat 🔴 "$g_n"
addstat 🟠 "$g_s"; addstat ✅ "$g_d"
# STACKED layout (JW's sketch, 2026-07-02): the block uses its full 3-row height
# as a mini-panel — name level with the tabs' top border, counts level with the
# bottom border, and an INFO row between (📚 tmux sessions • 🪟 windows in THIS
# session — the middle row was a plain rule at first, upgraded same day):
#      cc-0624-0
#      📚3•📺5
#      🤖1•✅2
# width = the widest of the three rows (+1 cell padding each side), capped at
# 2/5 of the client so the window tabs always keep the floor space.
bmax=$(( width * 2 / 5 )); [ "$bmax" -lt 10 ] && bmax=10
avail=$(( bmax - 2 ))
blk_top="$session"; blk_mid="📚${ns}•📺${n}"; blk_bot="$sp"
dwidth "$blk_top" __btw; [ "$__btw" -gt "$avail" ] && { head_w "$blk_top" "$avail" blk_top; __btw=$avail; }
dwidth "$blk_mid" __bmw; [ "$__bmw" -gt "$avail" ] && { head_w "$blk_mid" "$avail" blk_mid; __bmw=$avail; }
dwidth "$blk_bot" __bbw; [ "$__bbw" -gt "$avail" ] && { head_w "$blk_bot" "$avail" blk_bot; __bbw=$avail; }
btw=$__btw
[ "$__bmw" -gt "$btw" ] && btw=$__bmw
[ "$__bbw" -gt "$btw" ] && btw=$__bbw
block_w=$(( btw + 2 ))                     # 1 space padding each side
tw=$(( width - block_w ))                  # table width: everything right of the block

# ── viewport budget B = room for the WINDOW cells ─────────────────────────────
B=$(( tw - lbw - rbw - 3 )); [ "$B" -lt 4 ] && B=4
# Fit-mode budget: when everything fits there are NO ◀/▶ arrows and NO fill
# cell either — the last tab's │ IS the table's right edge — so the only
# reserved column is the left border. (The tail below skips the fill cell when
# the cells land exactly on the edge, and absorbs a single stray column as one
# space inside the last tab.)
BF=$(( tw - 1 )); [ "$BF" -lt 4 ] && BF=4

# ── DYNAMIC TAB WIDTH (2026-07-02): grow names to fit, shrink before scrolling.
# Full names whenever they all fit; otherwise binary-search the LARGEST per-name
# cap L (≥ NFLOOR) at which every window still fits inside B — names longer than
# L get an ellipsis, shorter ones always render whole. Only when even L=NFLOOR
# overflows does the ◀/▶ viewport machinery below kick in. Fork-free (≤ ~7
# total_at probes), so the storm-safe builder budget is untouched.
# NOTE: the status glyph is NOT in the cell anymore — it renders on the BOTTOM
# BORDER, centered under its tab (JW 2026-07-02), saving 3 cells per busy tab.
total_at() {   # <L> <outvar> — total width of all tabs at name-cap L (cells + │ seps)
  local L=$1 t=0 k nm __cw
  for ((k=1;k<=n;k++)); do
    nm=${rname[k]}
    # FULL-NAME CURRENT TAB (2026-07-08): the SELECTED window is exempt from the
    # cap — it always counts (and later renders) at its full name, so the L
    # search and the fit/scroll decision are made with that exemption baked in.
    if (( k != curpos )) && [ ${#nm} -gt "$L" ]; then nm="${nm:0:L}…"; fi
    dwidth "${NPFX:+${idx[k]}•}${nm}" __cw
    t=$(( t + __cw + 1 ))
  done
  printf -v "$2" '%s' "$t"
}
Lmax=$NFLOOR
for ((k=1;k<=n;k++)); do (( ${#rname[k]} > Lmax )) && Lmax=${#rname[k]}; done
total_at "$NFLOOR" __tf
if (( __tf > BF )); then
  L=$NFLOOR        # floor reached → scrolling handles the overflow
else
  lo=$NFLOOR; hi=$Lmax; L=$NFLOOR
  while (( lo <= hi )); do
    mid=$(( (lo + hi) / 2 ))
    total_at "$mid" __tm
    if (( __tm <= BF )); then L=$mid; lo=$(( mid + 1 )); else hi=$(( mid - 1 )); fi
  done
fi

# ── SLACK DISTRIBUTION (2026-07-03): the uniform cap L quantizes — bumping it
# costs +1 on EVERY cut name at once, so a few leftover cells used to strand as
# blank fill. Spend them one at a time instead: per-window caps start at L and
# still-cut names get +1 char round-robin (left to right) until the leftover is
# gone or everything is full. Only in fit mode — scroll mode keeps the floor.
cap=()
for ((k=1;k<=n;k++)); do cap[k]=$L; done
# FULL-NAME CURRENT TAB (2026-07-08): the selected window's tab shows its whole
# name; only the OTHER tabs shrink/scroll around it. total_at() already counted
# it at full width, so in fit mode this always fits. In scroll mode the full
# name is CLAMPED so the current cell can never exceed the viewport budget —
# otherwise fit_forward could fit nothing and the viewport math would wedge.
# The push direction falls out of the existing anchoring: at the right end the
# viewport is packed right-anchored (expansion pushes neighbors LEFT), at the
# left end it grows rightward, and mid-list the margin logic re-centers.
cbudget=$B; (( __tf <= BF )) && cbudget=$BF
ccap=${#rname[curpos]}
while (( ccap > L )); do
  nmt=${rname[curpos]:0:ccap}
  [ "$ccap" -lt "${#rname[curpos]}" ] && nmt="${nmt}…"
  dwidth "${NPFX:+${idx[curpos]}•}${nmt}" __ccw
  (( __ccw + 1 <= cbudget )) && break
  ccap=$(( ccap - 1 ))
done
(( ccap > cap[curpos] )) && cap[curpos]=$ccap
if (( __tf <= BF )); then
  B=$BF   # fit mode: the viewport must clip against the SAME no-chrome budget
          # the sizer used, or it re-clips the approved layout and ▶ reappears
  total_at "$L" __tl
  leftover=$(( BF - __tl ))
  while (( leftover > 0 )); do
    spent=0
    for ((k=1; k<=n && leftover>0; k++)); do
      if (( ${#rname[k]} > cap[k] + 1 )); then
        cap[k]=$(( cap[k] + 1 )); leftover=$(( leftover - 1 )); spent=1
      fi
    done
    (( spent )) || break
  done
fi
# build the final cells (tight: no padding spaces inside the cell).
# A name exactly 1 char over its cap renders FULL — the ellipsis would occupy
# the same cell its last character needs, so cutting there is pure loss.
for ((k=1;k<=n;k++)); do
  nm=${rname[k]}
  if [ ${#nm} -gt $(( cap[k] + 1 )) ]; then ck=${cap[k]}; nm="${nm:0:ck}…"; fi
  text[k]="${NPFX:+${idx[k]}•}${nm}"
  dwidth "${text[k]}" __tw; slot[k]=$(( __tw + 1 ))   # cell + trailing │
done

fit_forward()  { local st=$1 u=0 k last=$1; for ((k=st;k<=n;k++)); do (( u+slot[k]<=B )) && { u=$((u+slot[k])); last=$k; } || break; done; __ff=$last; }
fit_backward() { local en=$1 u=0 k first=$1; for ((k=en;k>=1;k--)); do (( u+slot[k]<=B )) && { u=$((u+slot[k])); first=$k; } || break; done; __fb=$first; }

vp=""; lastcur=""; lastw=""; [ -r "$vpfile" ] && read vp lastcur lastw <"$vpfile"
case "$vp" in
  ''|*[!0-9]*)
    te=$(( curpos+MARGIN>n ? n : curpos+MARGIN )); fit_backward "$te"; vp=$__fb; lastcur="";;
esac
(( vp<1 )) && vp=1; (( vp>n )) && vp=n

# Re-anchor on a window switch OR a width change (resize); else respect manual scroll.
if [ "$lastcur" != "$cur" ] || [ "$lastw" != "$width" ]; then
  fit_forward "$vp"; vend=$__ff; vis=$(( vend - vp + 1 ))
  if (( vis > 2*MARGIN )); then
    if (( curpos - vp < MARGIN && vp > 1 )); then vp=$(( curpos-MARGIN<1 ? 1 : curpos-MARGIN ))
    elif (( vend - curpos < MARGIN && vend < n )); then te=$(( curpos+MARGIN>n ? n : curpos+MARGIN )); fit_backward "$te"; vp=$__fb; fi
  else
    (( curpos < vp ))  && vp=$curpos
    (( curpos > vend )) && { fit_backward "$curpos"; vp=$__fb; }
  fi
  (( vp<1 )) && vp=1; fit_forward "$vp"; vend=$__ff
  if (( vend == n )); then fit_backward "$n"; nb=$__fb; (( nb <= curpos )) && { vp=$nb; vend=$n; }; fi
  (( curpos > vend )) && { fit_backward "$curpos"; vp=$__fb; fit_forward "$vp"; vend=$__ff; }
  (( curpos < vp ))   && { vp=$curpos; fit_forward "$vp"; vend=$__ff; }
else
  fit_forward "$vp"; vend=$__ff
  if (( vend == n )); then fit_backward "$n"; vp=$__fb; vend=$n; fi
fi
s=$vp; e=$vend
# Persist viewport only when it actually changed. We compare against the vp/
# lastcur/lastw we already read above — NO extra `cat` subshell.
new="$vp $cur $width"; old="$vp $lastcur $lastw"
if [ "$new" != "$old" ]; then
  printf '%s\n' "$new" >"${vpfile}.$$" 2>/dev/null && mv -f "${vpfile}.$$" "$vpfile" 2>/dev/null
fi
# Snapshot vp's mtime NOW — after our own (conditional) write above, before the
# rowfiles below. The reader compares the live vp mtime against this recorded
# value (string !=), so our own write is "seen" (no self-trigger flap) while any
# EXTERNAL scroll nudge landing after this line differs → next read rebuilds.
vp_at_build=$(stat -f %Fm "$vpfile" 2>/dev/null || echo 0)

# ── leftover → partial so the window strip fills (no gap) ──────────────────────
sumslot=0; for ((k=s;k<=e;k++)); do sumslot=$(( sumslot + slot[k] )); done
leftover=$(( B - sumslot )); (( leftover<0 )) && leftover=0
pmode=none; pp=0; Lp=0
if   (( e<n && leftover>=4 )); then pmode=right; pp=$(( e+1 )); Lp=$(( leftover-1 ))
elif (( s>1 && leftover>=4 )); then pmode=left;  pp=$(( s-1 )); Lp=$(( leftover-1 ))
fi

# cells: [<<] (+left partial) windows (+right partial); 4th arg = the window's
# status glyph, rendered by border() centered in the cell's BOTTOM border run;
# 5th arg = @ccbg — BG-BUSY windows render their tab text in ITALICS (JW 2026-
# 07-09: work is being done by a background session, not the interactive one)
ctext=(); crange=(); cinv=(); cglyph=(); cital=(); ccol=()
add_cell() { local i=${#ctext[@]}; ctext[i]="$1"; crange[i]="$2"; cinv[i]="$3"; cglyph[i]="$4"; cital[i]="${5:-}"; ccol[i]="${6:-}"; }
# ◀ only when there's left overflow (earlier windows scrolled off). If everything
# fits (s==1, e==n) neither arrow shows — the windows just start at the left border.
if (( s > 1 )); then add_cell "$LBTN" "user|bscrollL" 2 "" ""; fi
if [ "$pmode" = left ]; then tail_w "${text[pp]}" "$Lp" __pt; add_cell "$__pt" "window|${idx[pp]}" 0 "${rg[pp]}" "${rbg[pp]}" "${rfg[pp]}"; fi   # partial tab → SELECTS its window (not scroll)
for ((k=s;k<=e;k++)); do
  if [ "$k" = "$curpos" ]; then ci=1; else ci=0; fi
  add_cell "${text[k]}" "window|${idx[k]}" "$ci" "${rg[k]}" "${rbg[k]}" "${rfg[k]}"
done
if [ "$pmode" = right ]; then head_w "${text[pp]}" "$Lp" __pt; add_cell "$__pt" "window|${idx[pp]}" 0 "${rg[pp]}" "${rbg[pp]}" "${rfg[pp]}"; fi   # partial tab → SELECTS its window (not scroll)

# final cell: width fills the table to `tw` exactly (gapless).
pre_w=1; for ((i=0;i<${#ctext[@]};i++)); do dwidth "${ctext[i]}" __cw; pre_w=$(( pre_w + __cw + 1 )); done
rbf=$(( tw - pre_w - 1 ))
if (( e < n )); then
  # Right overflow exists → show the ▶ scroll button. STANDARDIZED 2026-07-03:
  # ▶ (like ◀) is ALWAYS exactly 1 column — it used to be the flexible cell
  # that absorbed the residual as padding, rendering 1-3+ wide depending on
  # whether ◀/a partial happened to exist. The residual now becomes CONTENT:
  # widen the partial tab if one exists, else give the last visible tab a
  # higher name cap (trailing spaces only when its name runs out anyway).
  extra=$(( rbf - rbw )); (( extra < 0 )) && extra=0
  if (( extra > 0 )); then
    if [ "$pmode" = right ]; then
      li=$(( ${#ctext[@]} - 1 ))
      head_w "${text[pp]}" $(( Lp + extra )) __pt; ctext[li]=$__pt
    elif [ "$pmode" = left ]; then
      tail_w "${text[pp]}" $(( Lp + extra )) __pt; ctext[1]=$__pt   # ◀ is cell 0, the partial is cell 1
    else
      li=$(( ${#ctext[@]} - 1 ))
      ck2=$(( cap[e] + extra ))
      nm=${rname[e]}
      if [ ${#nm} -gt $(( ck2 + 1 )) ]; then nm="${nm:0:ck2}…"; fi
      __nc="${NPFX:+${idx[e]}•}${nm}"
      dwidth "${ctext[li]}" __ow; dwidth "$__nc" __nw2
      xp=$(( __ow + extra - __nw2 )); (( xp < 0 )) && xp=0
      blanks "$xp" __xpad
      ctext[li]="${__nc}${__xpad}"
    fi
  fi
  add_cell "$RBTN" "user|bscrollR" 2 ""
elif (( rbf >= 1 )); then
  # all fit, residual room remains (nothing left to widen) → plain blank fill
  # cell (no ▶ glyph, no click range).
  blanks "$rbf" __blank
  add_cell "$__blank" "" 3 ""
elif (( rbf == 0 )); then
  # exactly ONE stray column: a 0-wide fill would draw `││`, so absorb it as a
  # single space inside the last tab instead (invisible, keeps the edge exact).
  li=$(( ${#ctext[@]} - 1 ))
  ctext[li]="${ctext[li]} "
fi
# rbf == -1: the cells end exactly at the right edge — the last tab's │ is the
# table's closing border; no fill cell at all (pixel-perfect fit mode).
nc=${#ctext[@]}

# border <0|2> <outvar> — full top/bottom border across every cell (fork-free).
# On the BOTTOM border (row 2), a cell's status glyph is embedded centered in
# its dash run, framed by box-drawing TEES from the same set as the borders —
# so the joins are pixel-exact by design (tried ▶◀ = too heavy, →← = arrowheads
# did not meet the line in this font):
#   └──┤7·🤖├──┴
# ┤/├ (U+2524/251C) are true box-drawing chars: guaranteed 1 cell, guaranteed
# to connect with ─. Emoji = 2 cells, so a framed glyph replaces 4 dashes and
# the row width stays exact. Cells too narrow for the frame (cw 4-5) get the
# bare centered glyph; below 4, plain dashes.
# FULL-HEIGHT TAP SLICES (2026-07-03): each cell's border segment carries the
# SAME click range as the cell itself, so the entire vertical slice of the bar
# — top border, tab, bottom border — selects that window (and the ◀/▶ columns
# scroll). Junction chars (┬/┴) between cells stay neutral. Range markup adds
# no display width.
border() {
  local oc cc jc i out seg cw g2 gw2 lft rgt s1 s2 styled cand
  if [ "$1" = 0 ]; then oc='┌'; cc='┐'; jc='┬'; else oc='└'; cc='┘'; jc='┴'; fi
  out="$oc"
  for ((i=0;i<nc;i++)); do
    dwidth "${ctext[i]}" cw
    g2=""; [ "$1" = 2 ] && g2="${cglyph[i]}"
    if [ -n "$g2" ]; then
      # BADGE LADDER (2026-07-13): the slot holds "N[·emoji][·P?]" ("7·✅·P?"
      # = 7 cells), N always first. Degrade RIGHT-TO-LEFT until it fits: full
      # badge → drop ·P? → bare number — the number is the window identity
      # (row 1 no longer shows it inline), so it survives the narrowest cell.
      # Per candidate: framed ┤X├ inside the dash run when there is room for
      # at least one dash each side, bare centered X when only the text fits;
      # dwidth measures plain text — the red P? styling is substituted at emit
      # time only (format codes add no width, GRID re-asserts border style).
      seg=""
      for cand in "$g2" "${g2%·P?}" "${g2%%·*}"; do
        [ -n "$cand" ] || continue
        dwidth "$cand" gw2
        styled=${cand/P?/#[fg=#b00000,bold]P?${GRID}}
        if (( cw >= gw2 + 4 )); then
          lft=$(( (cw - gw2 - 2) / 2 )); rgt=$(( cw - gw2 - 2 - lft ))
          repeat "$lft" '─' s1; repeat "$rgt" '─' s2
          seg="${s1}┤${styled}├${s2}"; break
        elif (( cw >= gw2 + 2 )); then
          lft=$(( (cw - gw2) / 2 )); rgt=$(( cw - gw2 - lft ))
          repeat "$lft" '─' s1; repeat "$rgt" '─' s2
          seg="${s1}${styled}${s2}"; break
        fi
      done
      [ -n "$seg" ] || repeat "$cw" '─' seg
    else
      repeat "$cw" '─' seg
    fi
    if [ -n "${crange[i]}" ]; then
      out="${out}#[range=${crange[i]}]${seg}#[norange]"
    else
      out="${out}${seg}"
    fi
    if (( i<nc-1 )); then out="${out}${jc}"; else out="${out}${cc}"; fi
  done
  printf -v "$2" '%s' "$out"
}

# ── render all 3 rows into row_out[0..2], then write the cache atomically ──────
row_out=()

# left-block segments (stacked): centered name / sessions•windows info /
# centered state counts; all three rows carry the sessmenu tap range so the
# WHOLE block is the dropdown's tap target.
center "$blk_top" "$block_w" __btop
center "$blk_mid" "$block_w" __bmid
center "$blk_bot" "$block_w" __bbot
BLK_TOP="#[range=user|sessmenu]${SLATE}${__btop}#[norange]"
BLK_MID="#[range=user|sessmenu]${SLATE}${__bmid}#[norange]"
BLK_BOT="#[range=user|sessmenu]${SLATE}${__bbot}#[norange]"

# row 1 (middle): the block's info row + the cells themselves. BG-BUSY tabs
# (cital) wrap their text in italics — style attrs add no display width, so
# all the cell/width math above is untouched.
m="${GRID}│"
for ((i=0;i<nc;i++)); do
  it=""; itoff=""
  if [ "${cital[i]}" = 1 ]; then it='#[italics]'; itoff='#[noitalics]'; fi
  # @ccfg per-window tab color (2026-07-16, JW: "email" window in #6566FF).
  # fg-only override; the trailing GRID re-assert keeps the │ gridline clean.
  cf=""; cfoff=""
  if [ -n "${ccol[i]}" ]; then cf="#[fg=${ccol[i]}]"; cfoff="$GRID"; fi
  if   [ "${cinv[i]}" = 1 ]; then m="${m}${SLATE}${it}${cf}${ctext[i]}${itoff}${GRID}│"
  elif [ "${cinv[i]}" = 3 ]; then m="${m}${ctext[i]}│"   # blank fill: grid bg, no range, no glyph
  elif [ "${cinv[i]}" = 2 ]; then m="${m}#[range=${crange[i]}]#[bold]${ctext[i]}#[nobold]#[norange]│"
  else m="${m}#[range=${crange[i]}]${it}${cf}${ctext[i]}${itoff}${cfoff}#[norange]│"; fi
done
row_out[1]="${BLK_MID}${m}"

# row 0 (top): block name row + the full top border
border 0 b0
row_out[0]="${BLK_TOP}${GRID}${b0}"

# row 2 (bottom): block counts row + the closing border
border 2 b2
row_out[2]="${BLK_BOT}${GRID}${b2}"

# Atomic write of all 3 rows + the hash. Each row goes to a temp then mv (so a
# reader never cats a half-written file). Write the hash LAST so the rows are
# already in place when a reader next compares.
for r in 0 1 2; do
  tmp="${CACHE_DIR}/.row${r}_${client}.$$"
  printf '%s' "${row_out[r]}" > "$tmp" 2>/dev/null && mv -f "$tmp" "${CACHE_DIR}/row${r}_${client}" 2>/dev/null
done
printf '%s %s\n' "$cheap_key" "$full_hash" > "${CACHE_DIR}/.hash_${client}.$$" 2>/dev/null \
  && mv -f "${CACHE_DIR}/.hash_${client}.$$" "${CACHE_DIR}/hash_${client}" 2>/dev/null
printf '%s %s\n' "$dirty_at_build" "$vp_at_build" > "${CACHE_DIR}/.seendirty_${client}.$$" 2>/dev/null \
  && mv -f "${CACHE_DIR}/.seendirty_${client}.$$" "${CACHE_DIR}/seendirty_${client}" 2>/dev/null

redisplay
exit 0
