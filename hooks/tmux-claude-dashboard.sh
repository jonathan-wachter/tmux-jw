#!/bin/bash
# tmux-claude-dashboard.sh — multi-session "cockpit" popup (v2, 2026-07-02).
#
# Opened via prefix+o (through tmux-claude-dashboard-open.sh, which sizes the popup
# per device and passes the invoking client's context). v2 upgrades the v1
# single-session switcher into a cross-session cockpit:
#
#   HEADER  (2026-07-16) three zones: a `[ ➕ NEW ]` button in its own
#           │-separated section at the LEFT (tap or ⏎ on it → new window in the
#           VIEWED session — replaces the old "+ new window" bottom row), then
#           the session tabs — every CLAUDE-ACTIVE tmux session as a `❯ name ❮`
#           capsule (2026-07-08: sessions with no live Claude CLI and no
#           @ccstate/@ccname are hidden; the viewed/origin session always
#           shows), the VIEWED one inverted (BLUE when the bar itself has
#           focus) — and a `[ ❌ CLOSE ]` button at the top right (closes the
#           popup; replaces the old `[ X ]`). Reach the bar by pressing ↑ off
#           row 1; there ←/→ (or h/l, or tap) cycle NEW + the tabs — browsing
#           another session's windows WITHOUT switching — and ↓ drops back to
#           row 1.
#   BODY    (2026-07-08 redesign; restyled v3.1) one entry per window. The window
#           number, name, and status glyph are FLUSH-LEFT on the entry's divider
#           line (no ├─┤ T-bar frame), a dash rule running to the edge; the
#           SELECTED entry carries the CONTROL CHIPS right-aligned on that rule:
#          •8) 🤖 name ──❯ open ❮─❯ <sess> ❮…─❯ new ❮─❯ move ❮─❯ rename ❮─❯ close ❮──
#           Only the text between the ❯ ❮ brackets is highlighted. Below the
#           divider: Claude's own latest "※ recap" (harvested into @ccrecap by
#           tmux-claude-reconcile.sh), word-wrapped. • marks the active window.
#   FOOTER  full key hints + the current sort mode (or the inline rename/slot
#           editor when active).
#
# Input — TWO FOCUS ZONES (2026-07-05): the window LIST and the session BAR.
#   • ↑/↓ or k/j      → move the cursor in the list; ↑ off row 1 lifts focus to
#                       the session BAR; ↓ on the bar drops back to row 1
#   • ←/→ or h/l      → LIST: walk the selected entry's control chips —
#                       open · one chip per OTHER Claude-active session (move
#                       the window there; cc-parking always offered) · new
#                       (move it into a brand-new session named after it) ·
#                       move (teleport to an absolute slot in this session, à la
#                       prefix+.) · rename (inline-edit this window's name) ·
#                       close (RED; gracefully /exit Claude so its close hooks
#                       fire, then kill the window — Enter asks to CONFIRM).
#                       BAR: view the previous / next session (wraps around)
#   • Tab / Shift-Tab → switch session from anywhere and commit into the list on
#                       that session's active window (absorbs the old ←/→ switch)
#   • Enter           → run the ARMED chip. open switches this client across
#                       sessions if needed; moves keep the popup OPEN and
#                       refresh in place — a footer toast confirms. The move
#                       itself is hooks/tmux-window-park.sh, the same engine the
#                       /tmux park|restore skill scripts call. close needs a
#                       second Enter while the red chip shows `close?`.
#   • s               → cycle sort: index → attn (🔴💬🟠🤖✅ then idle) → name
#                       (sticky across opens via a state file)
#   • type its number → open that window in the viewed session. Single digits that
#                       are a prefix of a 2-digit index (e.g. "1" when 10-19 exist)
#                       wait for a 2nd digit; use 01-09 to disambiguate.
#   • space / f / b   → cursor to last / last / first window (list focus only)
#   • click           → header [ ➕ NEW ] = new window in the viewed session ·
#                       header tab = view that session · row = open that window ·
#                       [ ❌ CLOSE ] = close · wheel = scroll  (tap-to-park is
#                       v1-deferred)
#   • q or Esc        → close.  Unknown keys are no-ops (v1 closed on any key).
#
# Testability (added 2026-07-02): set JW_DASH_TEST=1 to run headless — geometry
# from JW_DASH_COLS/JW_DASH_ROWS, keys read from STDIN (raw bytes, so you can pipe
# real escape sequences), frames drawn to STDOUT, tmux invoked via $JW_TMUX (e.g.
# "tmux -L testsock") so a scratch server can be driven end-to-end. Actions also
# echo an "ACTION open <sess>:<win>" line for assertions.
#
# Sizing gotchas (verified 2026-06-11):
#  - bash does NOT set $COLUMNS inside display-popup (non-interactive shell)
#  - `$(tput cols)` ALWAYS returns 80 here (command-substitution pipe); read the
#    size via `stty size < /dev/tty` instead — it ioctls the real terminal.

BOLD=$'\033[1m'; DIM=$'\033[2m'; REV=$'\033[7m'; RESET=$'\033[0m'
# Explicit palette tones (ported color scheme) — cool fixed hues, NOT terminal-DIM
# of the fg. Use these so the render matches the shared scheme instead of a faded
# near-black. SLATE = structural rules/frame; MUTED = secondary text; SEPC = dashes.
SLATE=$'\033[38;2;57;69;83m'      # dark slate #394553 — header rule, frame edges
MUTED=$'\033[38;2;93;100;112m'    # mid-gray  #5d6470 — recaps, legend, hints, unfocused tabs
SEPC=$'\033[38;2;154;160;168m'    # light-gray #9aa0a8 — trailing/inter-chip separator dashes
# focused session-tab fill (slate) — distinguishes "the bar has focus" from the
# plain reverse-video "this is the viewed session" when focus is in the list
TABFOC=$'\033[48;2;57;69;83m\033[38;2;255;255;255m'
# armed CLOSE chip fill (red) — the destructive control announces itself; the
# same fill (bold) is used for the `close?` confirmation state
REDCH=$'\033[48;2;179;38;30m\033[38;2;255;255;255m'

# UTF-8 locale so ${#str} counts CHARACTERS (the ❯/❮ tab delimiters and · are
# multi-byte) — without this, header column math breaks under a C locale.
export LC_ALL=en_US.UTF-8

TMUX_BIN=${JW_TMUX:-tmux}   # unquoted at call sites ON PURPOSE so "tmux -L sock" splits

# Session + current window + client are passed by the launcher (reliable); fall
# back to resolving them here if run standalone. $3 (client_name) is what lets
# Enter switch THIS client to another session (switch-client -c).
SESSION=${1:-$($TMUX_BIN display-message -p '#{session_name}')}
CURWIN=${2:-$($TMUX_BIN display-message -p '#{window_index}')}
CLIENT=${3:-}

# ── control-chip action state (2026-07-08 redesign) ──────────────────────────
# Two focus zones: "body" (the window list) and "tabs" (the session bar). In the
# body, ←/→ walk the selected entry's CONTROL CHIPS, indexed by ACTION:
#   0                → open
#   1..#targets      → move the window to MOVE_TARGETS[ACTION-1] (each OTHER
#                      Claude-active session; cc-parking is always offered)
#   NACT-4           → new: move it into a brand-new session named after it
#   NACT-3           → move: teleport it to an ABSOLUTE slot number WITHIN this
#                      session (inline-edit the slot; same engine as prefix+.)
#   NACT-2           → rename: inline-edit this window's name (tmux rename-window)
#   NACT-1           → close: gracefully /exit the Claude session (so its close
#                      hooks fire) then kill the window. RED chip; Enter arms a
#                      `close?` CONFIRM state, a second Enter runs it, anything
#                      else cancels.
# ↑ off row 1 lifts focus to the bar; there ←/→ switch session and ↓ returns to
# row 1. The heavy lifting (moves) is the shared hook — see decision 1A.
FOCUS=body        # body | tabs
BARNEW=0          # 1 = the bar cursor sits on the [ ➕ NEW ] button (FOCUS=tabs)
ACTION=0          # chip index (see map above)
CONFIRM=0         # 1 = close armed and awaiting the confirming Enter
TOAST=""          # transient footer message after an action (cleared on next key)
MOVE_TARGETS=()   # session-name move destinations (rebuilt by load_sessions)
NACT=6            # total chips: open + #targets + new + move + rename + close
# ── inline text-entry state (2026-07-08 v3.1) ────────────────────────────────
# A tiny shared line editor drives the `rename` chip and the move-to-`slot` input.
# When INPUT_MODE is nonempty ("rename"|"slot") the main loop routes every key to
# handle_input_key() instead of the normal bindings: printable bytes append to
# INPUT_TEXT, backspace deletes, Enter commits, Esc cancels.
INPUT_MODE=""     # "" | rename | slot
INPUT_TEXT=""     # the buffer being edited
# Optional local config (repo root, git-ignored — see tmux-jw.config.example).
# Precedence: test-harness env (JW_DASH_*) → tmux-jw.config → hard default.
__cfg="${BASH_SOURCE[0]%/*}/../tmux-jw.config"
[ -r "$__cfg" ] && . "$__cfg"
PARKING_NAME=${JW_DASH_PARKING:-${TMUXJW_PARKING:-cc-parking}}
HOOK="${BASH_SOURCE[0]%/*}/tmux-window-park.sh"
TELEPORT="${BASH_SOURCE[0]%/*}/tmux-window-teleport.sh"   # the "move to slot" engine (prefix+.)
# ── global search state (R3, 2026-07-08): `.` opens a cross-session type-ahead.
# SEARCH_ON=1 makes build_model list windows from ALL Claude-active sessions that
# match SEARCH_Q (space-separated words, any-subset OR match, relevance-ranked),
# each shown with its session name appended. An EMPTY query lists every window.
# Printable keys edit the query; the selected result's chips act on ITS session
# (win_sess[]). Search mode PERSISTS until Esc — backspacing to empty stays in
# search (shows all); only Esc returns to the normal per-session view.
SEARCH_ON=0
SEARCH_Q=""
# ── tmux-help state (2026-07-09): `?` opens a full-screen reference of the tmux
# prefix (C-k) key bindings, generated live from `tmux list-keys -N -T prefix`
# so it always reflects the real bindings. Rendered in TWO columns; a type-ahead
# query filters by key OR description; Esc closes back to the list. 2026-07-16:
# the reference is RUNNABLE — ↑↓←→ (or a tap) move a selection over the grid
# (↑↓ = same column, ←→ = adjacent entry) and ⏎ replays `prefix + key` at the
# invoking client (send-keys -K) right after the popup closes, so the chosen
# binding runs exactly as if typed. HELP_M* = master arrays (loaded once);
# HELP_D*/HELP_N = current filtered view; HELP_SEL = selected entry index;
# HELP_OFF = scroll row; HELP_MAXK = key-column width for alignment.
HELP_ON=0
HELP_Q=""
HELP_OFF=0
HELP_SEL=0
HELP_LOADED=0
HELP_MAXK=0
HELP_N=0
HELP_PFX="C-k"    # actual tmux prefix (read live in help_load)
HELP_MDK=(); HELP_MDESC=(); HELP_MLC=()
HELP_DK=(); HELP_DESC=()
# process comm of a live Claude CLI pane: literal "claude" or a bare version
# string like 2.1.199 (the binary is installed versioned) — same rule as the
# park hook's session_has_claude().
CCRE='^(claude|[0-9]+(\.[0-9]+){1,3})$'

# ── terminal setup: real tty (normal) or stdin/stdout (JW_DASH_TEST, and
#    JW_DASH_MEASURE — the launcher's size-to-fit probe, which never draws) ────
if [ -n "$JW_DASH_TEST" ] || [ -n "$JW_DASH_MEASURE" ]; then
  TTY_IN=/dev/stdin; TTY_OUT=/dev/stdout
  cols=${JW_DASH_COLS:-100}; rows=${JW_DASH_ROWS:-30}
else
  TTY_IN=/dev/tty; TTY_OUT=/dev/tty
  size=$(stty size < /dev/tty 2>/dev/null)
  rows=${size%% *}; cols=${size##* }
  { [ -z "$cols" ] || [ "$cols" -le 0 ]; } 2>/dev/null && cols=${COLUMNS:-80}
  { [ -z "$rows" ] || [ "$rows" -le 0 ]; } 2>/dev/null && rows=${LINES:-24}

  # raw mode + mouse reporting (SGR 1006 + legacy X10 1000); always restored.
  # HIDE the terminal cursor (\033[?25l): draw() parks it at (rows,1) — right on
  # the footer's leading ↑ glyph — where its blink read as an always-"selected"
  # arrow in the bottom-left corner. This is a full-screen TUI; our own ▌ marks
  # the input caret in rename/slot, so the real cursor is pure noise here.
  saved_stty=$(stty -g < /dev/tty 2>/dev/null)
  stty -icanon -echo -icrnl < /dev/tty 2>/dev/null   # -icrnl: keep Enter as CR, not NL (else read -n1 eats it)
  # DISABLE auto-wrap (DECAWM, \033[?7l): the popup is a fixed rows×cols grid
  # drawn with explicit \n and absolute cursor moves — it never RELIES on wrap.
  # But a body line that measures wider than cols in THIS terminal (e.g. the
  # selected window's chip strip, whose ❯/❮ ornaments are 1 cell on the desktop
  # but 2 cells in iOS terminals) would soft-wrap to a second physical row,
  # overflowing the grid by a line and scrolling the whole frame up — which
  # clipped the pinned header. With wrap off the terminal truncates the over-long
  # line at the right margin instead, so frame height stays exactly `rows`.
  # Restored on exit alongside the mouse/cursor modes.
  printf '\033[?7l\033[?1000h\033[?1006h\033[?25l' > /dev/tty
  trap 'printf "\033[?7h\033[?1006l\033[?1000l\033[?25h" > /dev/tty; [ -n "$saved_stty" ] && stty "$saved_stty" < /dev/tty 2>/dev/null' EXIT
fi

# apply_dims — recompute every layout value that depends on cols/rows. Called
# once at startup AND on every SIGWINCH (2026-07-09: the popup pty IS resized by
# tmux when the client resizes — e.g. the iPhone keyboard sliding up shrinks the
# client — so re-deriving these + rebuilding the model reflows the whole view).
#   ind/hang : indent used by empty-state notices (recap lines are now flush-left)
#   wrap     : recap wrap width (build_model wraps to this → resize must rebuild)
#   RULE     : full-width divider string
#   view_h   : body height = rows minus header(2) + footer(2)
apply_dims() {
  # PHONE mode (2026-07-19): a narrow client is touch-first — the selected
  # window's chips leave the divider for a pinned ACTION BAR above the footer,
  # the header sheds to icon + one tab + < > arrows, the footer legend becomes
  # tap targets, and taps select-then-open (two-tap). Gate is width-only (a
  # narrow desktop split benefits too); JW_DASH_PHONE=0/1 forces it (tests).
  PHONE=0; [ "$cols" -lt 90 ] && PHONE=1   # <90 catches the iPhone BOTH ways (64 keyboard-up, ~85 full-screen)
  [ -n "$JW_DASH_PHONE" ] && PHONE=$JW_DASH_PHONE
  if [ "$cols" -lt 90 ]; then ind=" ";  hang=3; wrap=$(( cols - 4 ))
  else                        ind="  "; hang=4; wrap=$(( cols - 6 )); fi
  [ "$wrap" -lt 20 ] && wrap=20
  RULE=$(printf '─%.0s' $(seq 1 "$cols"))
  # phone: 1 row → action bar, 1 row → blank TOP SPACER (row 1) that pushes the
  # header's tap targets down, clear of Moshi's own chrome at the screen edge
  view_h=$(( rows - 4 - PHONE * 2 )); [ "$view_h" -lt 3 ] && view_h=3
}
apply_dims

# ── sort mode: sticky across opens via a tiny state file ──────────────────────
SORTFILE="${TMPDIR:-/tmp}/tmux-claude-bar/dash.sort"
sort_mode=index
[ -r "$SORTFILE" ] && read sort_mode < "$SORTFILE" 2>/dev/null
case "$sort_mode" in index|attn|name) ;; *) sort_mode=index;; esac

# ── sessions ──────────────────────────────────────────────────────────────────
SESS_LIST=(); nsess=0
VSESS=$SESSION            # the session whose windows are being VIEWED
load_sessions() {
  SESS_LIST=(); local s found=0 sn cmd st nm active="|"
  # CLAUDE-ACTIVE FILTER (2026-07-08): one pass over every pane on the server.
  # A session qualifies when any pane runs the CLI (comm matches CCRE) OR still
  # carries hook/reconciler state (@ccstate/@ccname) — the latter keeps
  # sessions whose Claude just crashed (attention pending) visible, and lets
  # the headless test harness mark sessions active without a real CLI.
  while IFS='|' read -r sn cmd st nm; do
    [ -z "$sn" ] && continue
    case "$active" in *"|${sn}|"*) continue;; esac
    if [[ "$cmd" =~ $CCRE ]] || [ -n "$st" ] || [ -n "$nm" ]; then
      active="${active}${sn}|"
    fi
  done < <($TMUX_BIN list-panes -a -F '#{session_name}|#{pane_current_command}|#{@ccstate}|#{@ccname}' 2>/dev/null)
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    # only Claude-active sessions — plus the viewed and origin sessions, so
    # the popup can never orphan itself out of its own view
    case "$active" in
      *"|${s}|"*) ;;
      *) [ "$s" = "$VSESS" ] || [ "$s" = "$SESSION" ] || continue ;;
    esac
    SESS_LIST+=("$s"); [ "$s" = "$VSESS" ] && found=1
  done < <($TMUX_BIN list-sessions -F '#{session_name}' 2>/dev/null)
  nsess=${#SESS_LIST[@]}
  # viewed session vanished (killed while popup open) → fall back sanely
  if [ "$found" = 0 ] && [ "$nsess" -gt 0 ]; then VSESS=${SESS_LIST[0]}; fi
  build_targets
}

# move-chip destinations: every listed session EXCEPT $1 (the session the
# selected window is in — VSESS in normal view, the result's session in search),
# plus the parking lot even when it doesn't exist yet (the park hook creates it).
build_targets() {
  local exclude=${1:-$VSESS}
  MOVE_TARGETS=(); local i lot=0
  for (( i=0; i<nsess; i++ )); do
    [ "${SESS_LIST[i]}" = "$exclude" ] && continue
    MOVE_TARGETS+=("${SESS_LIST[i]}")
    [ "${SESS_LIST[i]}" = "$PARKING_NAME" ] && lot=1
  done
  [ "$lot" = 0 ] && [ "$exclude" != "$PARKING_NAME" ] && MOVE_TARGETS+=("$PARKING_NAME")
  NACT=$(( 1 + ${#MOVE_TARGETS[@]} + 4 ))   # open · targets… · new · move · rename · close
}
sview() {  # → index of VSESS in SESS_LIST (echo-free: sets __sv)
  local i; __sv=0
  for (( i=0; i<nsess; i++ )); do [ "${SESS_LIST[i]}" = "$VSESS" ] && { __sv=$i; return; }; done
}

# greedy word-wrap with a wider FIRST line (room after "N) name — ") and a
# narrower hanging CONTINUATION width. bash 3.2 safe.
wrap2() {
  local text=$1 fw=$2 cw=$3 line="" word width
  # NB: width MUST be assigned in its OWN statement — in `local a=$1 b=$a`,
  # bash expands $a BEFORE the local assignments run, so b lands empty. This
  # exact bug made the first wrapped line always break after one word.
  width=$fw
  for word in $text; do
    if   [ -z "$line" ]; then line=$word
    elif [ $(( ${#line} + 1 + ${#word} )) -le "$width" ]; then line="$line $word"
    else printf '%s\n' "$line"; line=$word; width=$cw; fi
  done
  [ -n "$line" ] && printf '%s\n' "$line"
}

# ── per-line display model for the VIEWED session ─────────────────────────────
# Built with NO styling baked in — the selection highlight is applied at DRAW
# time so the cursor can move freely. Per display line:
#   line_win  = owning window index (tap-to-jump target)
#   line_kind = h (the entry's DIVIDER-TITLE line: "N) name" rendered inside
#               ├───┤, plus the control chips when selected) | c (recap line)
#   line_a    = header title "N) name"  OR  the recap text
#   line_b    = unused (kept for slot symmetry)
# win_order[] / whead[] index the windows in display order, for the cursor.
# line_sess[] parallels line_win (owning session per display line, for clicks);
# win_sess[] parallels win_order (owning session per entry, for the cursor). In
# normal mode every entry's session is VSESS; in global search each carries its
# own. add_line takes the session as $6.
line_win=(); line_kind=(); line_a=(); line_b=(); line_g=(); line_sess=(); valid=""
win_order=(); win_sess=(); whead=(); nwin=0; total=0; active_win=""
add_line() { line_win+=("$1"); line_kind+=("$2"); line_a+=("$3"); line_b+=("$4"); line_g+=("$5"); line_sess+=("$6"); }

build_model() {
  line_win=(); line_kind=(); line_a=(); line_b=(); line_g=(); line_sess=(); valid=""
  win_order=(); win_sess=(); whead=(); active_win=""
  # R3: global cross-session search replaces the normal per-session list
  if [ "$SEARCH_ON" = 1 ]; then build_model_search; return; fi
  local raw sorted win active name state recap nm g gw pfxw fw cw title rest ci ordn=0

  raw=$($TMUX_BIN list-windows -t "$VSESS" \
    -F '#{window_index}|#{window_active}|#{?#{@ccname},#{@ccname},#{window_name}}|#{@ccstate}|#{@ccrecap}' 2>/dev/null)

  # sort: decorate (prio|zero-padded-idx|line) → sort → strip the 2 decorations.
  # cut -f3- keeps the ORIGINAL line intact even if a recap contains more '|'s.
  case "$sort_mode" in
    attn) sorted=$(printf '%s\n' "$raw" | awk -F'|' '{
            p=5
            if      ($4=="needs_you") p=0
            else if ($4=="question")  p=1
            else if ($4=="stalled")   p=2
            else if ($4=="working")   p=3
            else if ($4=="done")      p=4
            printf "%d|%05d|%s\n", p, $1, $0
          }' | sort -t'|' -k1,1n -k2,2 | cut -d'|' -f3-) ;;
    name) sorted=$(printf '%s\n' "$raw" | awk -F'|' '{ printf "%s|%05d|%s\n", tolower($3), $1, $0 }' \
            | sort -t'|' -k1,1 -k2,2 | cut -d'|' -f3-) ;;
    *)    sorted=$raw ;;
  esac

  cw=$(( wrap )); [ "$cw" -lt 10 ] && cw=10   # recap is flush-left now → full wrap width
  while IFS='|' read -r win active name state recap; do
    [ -z "$win" ] && continue
    valid="${valid} ${win}"
    nm=${name:-?}
    [ "$active" = 1 ] && active_win=$win
    # @ccstate → status glyph (same set the ribbon shows)
    case "$state" in
      working)   g='🤖';; question)  g='💬';; needs_you) g='🔴';;
      done)      g='✅';; stalled)   g='🟠';; *) g='';;
    esac
    # glyph sits BETWEEN the number and the name (matches the work cockpit).
    # The title renders INSIDE the entry's divider line (2026-07-08) — the old
    # separate title row + inline " — recap" tail are gone; the recap starts on
    # its own full-width line below the divider.
    if [ -n "$g" ]; then title="${win}) ${g} ${nm}"; else title="${win}) ${nm}"; fi
    win_order[ordn]="$win"; win_sess[ordn]="$VSESS"; whead[ordn]=${#line_win[@]}
    add_line "$win" h "$title" "" "$g" "$VSESS"   # line_g carries the glyph → width math
    if [ -n "$recap" ]; then
      while IFS= read -r cl; do add_line "$win" c "$cl" "" "" "$VSESS"; done < <(wrap2 "$recap" "$cw" "$cw")
    fi
    ordn=$((ordn+1))
  done <<EOF
$sorted
EOF
  # (2026-07-16: the synthetic "+ new window" bottom row is gone — new-window
  # now lives in the header's [ ➕ NEW ] button.)
  nwin=$ordn
  total=${#line_win[@]}
}

# ── R3 global search: windows from ALL Claude-active sessions matching SEARCH_Q ─
# Matching = space-separated words, ANY-subset (OR): a window is included if it
# contains AT LEAST ONE typed word (case-insensitive substring of "name
# session"); results are RELEVANCE-RANKED by how many words hit (desc), then by
# session, then window index. Each entry shows its session appended after the
# name; win_sess[]/line_sess[] carry the owning session so chips act on it.
build_model_search() {
  local q toks n_tok haystack mc allwins line sess win active name state recap
  local nm g title cw ordn=0
  q=$(printf '%s' "$SEARCH_Q" | tr '[:upper:]' '[:lower:]')
  toks=$q; n_tok=0; for _t in $toks; do n_tok=$((n_tok+1)); done
  cw=$(( wrap )); [ "$cw" -lt 10 ] && cw=10   # recap is flush-left now → full wrap width

  # one pass over every window on the server; keep only Claude-active sessions
  # (SESS_LIST) and score against the query. Decorate with matchcount for the
  # sort, then strip. `cut -f5-` keeps recap intact even with embedded '|'.
  allwins=$($TMUX_BIN list-windows -a \
    -F '#{session_name}|#{window_index}|#{window_active}|#{?#{@ccname},#{@ccname},#{window_name}}|#{@ccstate}|#{@ccrecap}' 2>/dev/null)

  local scored=""
  while IFS='|' read -r sess win active name state recap; do
    [ -z "$sess" ] && continue
    case " ${SESS_LIST[*]} " in *" $sess "*) ;; *) continue;; esac   # Claude-active only
    haystack=$(printf '%s' "$name $sess" | tr '[:upper:]' '[:lower:]')
    mc=0
    if [ "$n_tok" -eq 0 ]; then mc=1; else
      for _t in $toks; do case "$haystack" in *"$_t"*) mc=$((mc+1));; esac; done
    fi
    [ "$mc" -gt 0 ] || continue
    # rank key: (99-mc) so higher match counts sort FIRST; then session; then idx
    scored="${scored}$(printf '%02d' $(( 99 - mc )))|${sess}|$(printf '%05d' "$win" 2>/dev/null || echo 00000)|${sess}|${win}|${active}|${name}|${state}|${recap}
"
  done <<EOF
$allwins
EOF

  local sorted
  sorted=$(printf '%s' "$scored" | sort -t'|' -k1,1 -k2,2 -k3,3n | cut -d'|' -f4-)

  while IFS='|' read -r sess win active name state recap; do
    [ -z "$sess" ] && continue
    valid="${valid} ${win}"
    nm=${name:-?}
    case "$state" in
      working) g='🤖';; question) g='💬';; needs_you) g='🔴';;
      done) g='✅';; stalled) g='🟠';; *) g='';;
    esac
    # session name appended after the window name (change #3)
    if [ -n "$g" ]; then title="${win}) ${g} ${nm} · ${sess}"; else title="${win}) ${nm} · ${sess}"; fi
    win_order[ordn]="$win"; win_sess[ordn]="$sess"; whead[ordn]=${#line_win[@]}
    add_line "$win" h "$title" "" "$g" "$sess"
    if [ -n "$recap" ]; then
      while IFS= read -r cl; do add_line "$win" c "$cl" "" "" "$sess"; done < <(wrap2 "$recap" "$cw" "$cw")
    fi
    ordn=$((ordn+1))
  done <<EOF
$sorted
EOF
  nwin=$ordn
  total=${#line_win[@]}
}

# position of window $1 in the current display order → __wp (0 if absent)
win_pos() {
  local i; __wp=0
  for (( i=0; i<nwin; i++ )); do [ "${win_order[i]}" = "$1" ] && { __wp=$i; return; }; done
}

# ── geometry: header (row 1) + header rule (row 2) + body (rows 3..rows-2) +
#    footer rule (row rows-1) + footer (row rows). view_h/RULE/ind/hang/wrap are
#    all set by apply_dims() above (also re-run on SIGWINCH). ──────────────────
max_off=0; offset=0; sel=0

recalc_scroll() { max_off=$(( total - view_h )); [ "$max_off" -lt 0 ] && max_off=0; }

is_valid() { case " $valid " in *" $1 "*) return 0;; *) return 1;; esac; }
# is $1 a strict prefix of some valid 2+digit window index?
ambiguous() { local w; for w in $valid; do case "$w" in "$1"?*) return 0;; esac; done; return 1; }

# OPEN a window: select it in its session; if that session isn't the one this
# client is attached to, switch the client there too (that's the "open" in the
# footer — full jump, not just a peek). Test mode: report + select only.
# jump_win <window-index> [session] — session defaults to VSESS (normal view);
# search results / clicks pass the entry's own session so open works cross-session.
jump_win() {
  local idx=$1 ses=${2:-$VSESS}
  is_valid "$idx" || return 1
  [ -n "$JW_DASH_TEST" ] && printf 'ACTION open %s:%s\n' "$ses" "$idx"
  $TMUX_BIN select-window -t "${ses}:$idx" 2>/dev/null
  if [ -z "$JW_DASH_TEST" ] && [ "$ses" != "$SESSION" ]; then
    if [ -n "$CLIENT" ]; then $TMUX_BIN switch-client -c "$CLIENT" -t "$ses" 2>/dev/null
    else                      $TMUX_BIN switch-client -t "$ses" 2>/dev/null; fi
  fi
  exit 0
}

# ── header: session tabs as `❯ name ❮` capsules + hints; click ranges recorded ─
# (❯/❮ = U+276F/U+276E: single-cell-width everywhere, unlike 〉〈 U+3009/3008
#  which are East-Asian-Wide → 2 cells and font-ambiguous over mosh)
tab_lo=(); tab_hi=(); tab_of=()   # column span of each RENDERED tab → session index
hdr_out=""; hdr_bound=0           # column of the TAB zone's right edge │ (0 = none)
hdr_bound0=0                      # column of the NEW zone's right edge │ (0 = none)
new_lo=0; new_hi=0                # click span of the [ ➕ NEW ] button
# Session-tab zone shading: flattened to the popup fill (ported scheme has no
# distinct tab band) — the tabs read as their own region via the │ emitted below,
# the header rule's ┴ junction at hdr_bound, and the popup's own border.
SHADE=$'\033[48;2;181;188;200m'
# PHONE header (2026-07-19): ` [ ➕ ] │ < ❮sess❯ > i/n │` — icon-only NEW, ONLY
# the viewed session's tab, ASCII `<`/`>` arrows as prev/next-session tap
# targets (recorded in tab_lo/hi with SENTINEL tab_of values −1/−2; the name
# span is −3 = drop into the list), and an i/n count when there are ≥2 sessions.
# Keyboard hints are dropped — chrome this small is for touch. ASCII arrows on
# purpose: ‹›❯❮ are ambiguous-width (2 cells in iOS terminals — the header-clip
# bug), so phone chrome avoids them; tap columns must be exact.
build_header_phone() {
  local sv nst tst name cnt="" maxn col styled i lab need
  local budget=$(( cols - 8 ))    # keep the [ ❌ ] zone clear
  sview; sv=$__sv
  nst="$BOLD"; [ "$FOCUS" = tabs ] && [ "$BARNEW" = 1 ] && nst="${TABFOC}${BOLD}"
  styled="${SHADE} ${nst}[ ➕ ]${RESET}${SHADE} ${RESET}${SLATE}│${RESET}${SHADE} "
  new_lo=2; new_hi=7              # "[ ➕ ]" = 6 cells (➕ is 2), cols 2-7
  hdr_bound0=9
  col=11                          # first cell after "│ "
  # ALL-TABS mode (2026-07-19): when every session fits as its own [ name ]
  # chip, render them ALL as direct finger-sized tap targets — one tap
  # switches, no cycling. The leftover header width IS the tap padding.
  need=0
  for (( i=0; i<nsess; i++ )); do need=$(( need + ${#SESS_LIST[i]} + 6 )); done
  need=$(( need - 2 ))            # last chip has no 2-cell gap
  if [ $(( col + need )) -le "$budget" ]; then
    for (( i=0; i<nsess; i++ )); do
      lab="[ ${SESS_LIST[i]} ]"
      if [ "$i" = "$sv" ]; then
        if [ "$FOCUS" = tabs ] && [ "$BARNEW" = 0 ]; then tst="${TABFOC}${BOLD}"
        else                                              tst="${REV}${BOLD}"; fi
      else                                                tst="$BOLD"; fi
      tab_lo+=("$col"); tab_hi+=($(( col + ${#lab} - 1 ))); tab_of+=("$i")
      styled="${styled}${tst}${lab}${RESET}${SHADE}"
      col=$(( col + ${#lab} ))
      [ $(( i + 1 )) -lt "$nsess" ] && { styled="${styled}  "; col=$(( col + 2 )); }
    done
    styled="${styled} ${RESET}${SLATE}│${RESET}"
    hdr_bound=$(( col + 1 ))
    hdr_out=$styled
    return
  fi
  # overflow fallback: chunky [ < ] name [ > ] cycle buttons + i/n count
  [ "$nsess" -gt 1 ] && cnt="$(( sv + 1 ))/${nsess}"
  name=${SESS_LIST[sv]}
  maxn=$(( budget - col - ${#cnt} - 15 ))   # 2×"[ < ]"(5) + pads
  [ "$maxn" -lt 4 ] && maxn=4
  [ ${#name} -gt "$maxn" ] && name="${name:0:$(( maxn - 1 ))}…"
  if [ "$FOCUS" = tabs ] && [ "$BARNEW" = 0 ]; then tst="${TABFOC}${BOLD}"
  else                                              tst="${REV}${BOLD}"; fi
  tab_lo=("$col");           tab_hi=($(( col + 4 )));               tab_of=(-1)   # [ < ] prev
  styled="${styled}${BOLD}[ < ]${RESET}${SHADE} "
  col=$(( col + 6 ))
  tab_lo+=("$col");          tab_hi+=($(( col + ${#name} + 1 )));   tab_of+=(-3)  # name → list
  styled="${styled}${tst} ${name} ${RESET}${SHADE} "
  col=$(( col + ${#name} + 3 ))
  tab_lo+=("$col");          tab_hi+=($(( col + 4 )));              tab_of+=(-2)  # [ > ] next
  styled="${styled}${BOLD}[ > ]${RESET}${SHADE}"
  col=$(( col + 5 ))
  [ -n "$cnt" ] && { styled="${styled} ${MUTED}${cnt}${RESET}${SHADE}"; col=$(( col + ${#cnt} + 1 )); }
  styled="${styled} ${RESET}${SLATE}│${RESET}"
  hdr_bound=$(( col + 1 ))
  hdr_out=$styled
}

build_header() {
  tab_lo=(); tab_hi=(); tab_of=(); hdr_out=""; hdr_bound=0
  [ "$PHONE" = 1 ] && { build_header_phone; return; }
  local budget=$(( cols - 14 ))   # keep the top-right [ ❌ CLOSE ] zone clear (12 cells + margin)
  local i lab lw col start=0 sv plain="" styled="${SHADE} "
  sview; sv=$__sv

  # [ ➕ NEW ] button (2026-07-16): its own │-separated zone at the LEFT of the
  # bar, before the tabs — tap or ⏎ (when the bar cursor is on it) creates a
  # window in the VIEWED session. TABFOC fill marks the bar cursor; fixed
  # geometry: label = 9 chars / 10 cells (➕ is 2 cells), cols 2-11, │ at 13.
  local nst="$BOLD"
  [ "$FOCUS" = tabs ] && [ "$BARNEW" = 1 ] && nst="${TABFOC}${BOLD}"
  styled="${styled}${nst}[ ➕ NEW ]${RESET}${SHADE} ${RESET}${SLATE}│${RESET}${SHADE} "
  new_lo=2; new_hi=11
  hdr_bound0=13
  col=15                          # first tab column (after "│ ")

  # choose the first rendered tab so the VIEWED one always fits inside budget
  while :; do
    local used=$col fits=0 j
    for (( j=start; j<nsess; j++ )); do
      lab="❯ ${SESS_LIST[j]} ❮"; lw=$(( ${#lab} + 2 ))
      used=$(( used + lw ))
      [ "$j" = "$sv" ] && { [ "$used" -le "$budget" ] && fits=1; break; }
    done
    [ "$fits" = 1 ] || [ "$start" -ge "$sv" ] && break
    start=$(( start + 1 ))
  done

  # NB: every RESET kills the shade too, so re-open ${SHADE} after each styled run
  [ "$start" -gt 0 ] && { plain="… "; styled="${styled}${MUTED}… ${RESET}${SHADE}"; col=$(( col + 2 )); }
  for (( i=start; i<nsess; i++ )); do
    lab="❯ ${SESS_LIST[i]} ❮"
    if [ $(( col + ${#lab} )) -gt "$budget" ]; then
      styled="${styled}${MUTED}…${RESET}${SHADE}"; plain="${plain}…"; col=$(( col + 1 ))
      break
    fi
    tab_lo+=("$col"); tab_hi+=($(( col + ${#lab} - 1 ))); tab_of+=("$i")
    # HIGHLIGHT rule (v3.1): style only the ` name ` BETWEEN the ❯ ❮ brackets;
    # the brackets stay plain-on-shade. Every RESET kills the shade, so re-open
    # ${SHADE} before the closing ❮ (and it carries through to the separator).
    local inner=" ${SESS_LIST[i]} " tst
    if [ "$i" = "$sv" ]; then
      # viewed tab: blue when the BAR itself has focus (and the bar cursor is
      # not parked on [ ➕ NEW ]), plain reverse otherwise
      if [ "$FOCUS" = tabs ] && [ "$BARNEW" = 0 ]; then tst="${TABFOC}${BOLD}"
      else                        tst="${REV}${BOLD}"; fi
    else                          tst="${BOLD}"; fi
    styled="${styled}❯${tst}${inner}${RESET}${SHADE}❮"
    plain="${plain}${lab}"
    col=$(( col + ${#lab} ))
    if [ $(( i + 1 )) -lt "$nsess" ]; then styled="${styled}  "; plain="${plain}  "; col=$(( col + 2 )); fi
  done
  # close the shaded zone: trailing pad, then the boxed right edge │; remember
  # its column so draw() can place the matching ┴ in the rule below
  styled="${styled} ${RESET}${SLATE}│${RESET}"
  hdr_bound=$(( col + 1 ))
  # short hints in the leftover header room (full set lives in the footer);
  # focus-dependent so the bar tells you what ←/→ does right now. 2026-07-16:
  # fitted SEGMENT-WISE (drop trailing ` · seg` pieces that overflow) — the NEW
  # zone + wider [ ❌ CLOSE ] leave less room, and a partial hint beats none.
  local segs rest seg cand hint=""
  if [ "$FOCUS" = tabs ]; then segs='←→ session|↓ list|⇥ commit|Esc/q'
  else                         segs='↑↓ move|←→ controls|⇥ session|⏎|Esc/q'; fi
  rest=$segs
  while [ -n "$rest" ]; do
    seg=${rest%%|*}
    case "$rest" in *'|'*) rest=${rest#*|};; *) rest="";; esac
    if [ -z "$hint" ]; then cand=" $seg"; else cand="$hint · $seg"; fi
    [ $(( hdr_bound + ${#cand} )) -le "$budget" ] || break
    hint=$cand
  done
  [ -n "$hint" ] && styled="${styled}${MUTED}${hint}${RESET}"
  hdr_out=$styled
}

# ── entry divider-title line (2026-07-08 redesign; restyled v3.1) ─────────────
# One line per window entry: `•N) 🤖 name ─────…─────`. The title is FLUSH-LEFT
# (no leading ├─), one space, then a dash rule to the right edge (no trailing
# ┤ — the T-bar frame was dropped 2026-07-08). On the SELECTED entry the control
# chips render right-aligned inside the rule, with a short `──` tail:
#   •8) 🤖 name ────❯ open ❮─❯ <sess> ❮…─❯ new ❮─❯ rename ❮─❯ close ❮──
# HIGHLIGHT rule (v3.1): an IDLE chip renders whole in the summary text's mid-gray
# (MUTED) — brackets included — so it reads as one unit at the recap-text weight; an
# ARMED chip keeps PLAIN brackets with a reverse/red inner → ❯[ open ]❮ inverted.
# The close chip is red (fg when idle, bg when armed, bold-bg `close?` while
# confirming). Chip column spans (incl. brackets) are recorded in chip_lo/chip_hi
# (+ selrow_scr, the screen row) so a tap can arm-and-run one.
REDFG=$'\033[38;2;197;52;42m'
ULINE=$'\033[4m'; ULOFF=$'\033[24m'   # accelerator-letter underline (change #4)
chip_lo=(); chip_hi=(); selrow_scr=0
draw_entry_rule() {
  local j=$1 w=$2 title=$3 gph=$4 mk tw gx sel_here=0 fillw fill styled
  local labels=() acc=() aidx=() lw=() i inner lbl tot seg st maxs col keep
  local ntarg shown k t closelbl a
  # sel_here by LINE POSITION (this header line == the selected entry's header
  # line), NOT by window-index value — indices collide across sessions in global
  # search, so a value compare would light up every "window 1" at once.
  [ "$FOCUS" = body ] && [ "$j" = "${whead[sel]}" ] && sel_here=1
  mk=""; [ "$w" = "$active_win" ] && mk="•"
  gx=0; [ -n "$gph" ] && gx=1                     # status emoji = 2 cells, 1 char
  tw=$(( ${#mk} + ${#title} + gx ))
  if [ "$sel_here" = 0 ] || [ "$PHONE" = 1 ]; then
    # layout: TITLE + ' ' + dashes-to-edge  (total == cols). PHONE mode renders
    # the SELECTED entry this way too — REV title marks the cursor, and its
    # actions live in the pinned action bar (draw_abar), not divider chips.
    local tst="$BOLD"; [ "$sel_here" = 1 ] && tst="${REV}${BOLD}"
    fillw=$(( cols - tw - 1 ))
    if [ "$fillw" -lt 0 ]; then
      keep=$(( ${#title} + fillw - 1 )); [ "$keep" -lt 4 ] && keep=4
      title="${title:0:$keep}…"; tw=$(( ${#mk} + ${#title} + gx ))
      fillw=$(( cols - tw - 1 )); [ "$fillw" -lt 0 ] && fillw=0
    fi
    printf -v fill '%*s' "$fillw" ''; fill=${fill// /─}
    printf '%s%s%s%s %s%s%s\n' "$mk" "$tst" "$title" "$RESET" "$SEPC" "$fill" "$RESET"
    return
  fi
  # SELECTED: build the chip strip — open · move-to-session targets · new
  # session · move · rename · close. Each displayed chip carries its LOGICAL
  # action index aidx[] (open=0 · session k=k · new=NACT-4 · move=NACT-3 ·
  # rename=NACT-2 · close=NACT-1) so arming/click/accelerators stay correct even
  # when trailing SESSION chips are DROPPED to fit a narrow bar (the 4 action
  # chips are always shown and are also n/m/r/c accelerator-reachable). acc[]
  # marks the accelerator (first-letter-underlined) chips.
  maxs=14; [ "$cols" -lt 90 ] && maxs=8
  ntarg=${#MOVE_TARGETS[@]}
  local sess_lbls=()
  for (( k=0; k<ntarg; k++ )); do
    t=${MOVE_TARGETS[k]}; [ ${#t} -gt "$maxs" ] && t="${t:0:$((maxs-1))}…"
    sess_lbls[k]=$t
  done
  closelbl=close; [ "$CONFIRM" = 1 ] && closelbl="close?"
  # strip width for a given number of shown session chips (open + sessions + 4
  # action chips, each subsequent chip costs 1 separator + label+4).
  stripw() { local ns=$1 kk ww=$(( 4 + 4 )) x
    for (( kk=0; kk<ns; kk++ )); do ww=$(( ww + 1 + ${#sess_lbls[kk]} + 4 )); done
    for x in "new session" move rename "$closelbl"; do ww=$(( ww + 1 + ${#x} + 4 )); done
    printf '%s' "$ww"; }
  # drop trailing session chips until the strip leaves ≥8 cols for the title
  shown=$ntarg
  while (( shown > 0 )); do
    tot=$(stripw "$shown"); (( cols - tot - 3 >= 8 )) && break; shown=$(( shown - 1 ))
  done
  tot=$(stripw "$shown")
  labels=("open");        acc=(0); aidx=(0)
  for (( k=0; k<shown; k++ )); do labels+=("${sess_lbls[k]}"); acc+=(0); aidx+=("$(( k + 1 ))"); done
  labels+=("new session"); acc+=(1); aidx+=("$(( NACT - 4 ))")
  labels+=("move");        acc+=(1); aidx+=("$(( NACT - 3 ))")
  labels+=("rename");      acc+=(1); aidx+=("$(( NACT - 2 ))")
  labels+=("$closelbl");   acc+=(1); aidx+=("$(( NACT - 1 ))")
  for i in "${!labels[@]}"; do lw[i]=$(( ${#labels[i]} + 4 )); done
  # layout: TITLE + ' ' + dashes + CHIPS + '──'  (total == cols); shrink the
  # TITLE before the chips when it doesn't fit (chips already fit per above).
  fillw=$(( cols - tw - tot - 3 ))               # 3 = 1 space + 2 tail dashes
  if [ "$fillw" -lt 1 ]; then
    keep=$(( tw + fillw - 1 )); [ "$keep" -lt 6 ] && keep=6
    title="${title:0:$(( keep - 1 - gx ))}…"; tw=$(( ${#mk} + ${#title} + gx ))
    fillw=$(( cols - tw - tot - 3 )); [ "$fillw" -lt 0 ] && fillw=0
  fi
  printf -v fill '%*s' "$fillw" ''; fill=${fill// /─}
  # the SELECTED row's title is reverse-video highlighted (marks the cursor row);
  # the • active marker stays plain, like the chip brackets.
  styled="${mk}${REV}${BOLD}${title}${RESET} ${SEPC}${fill}${RESET}"
  chip_lo=(); chip_hi=(); selrow_scr=$(( 3 + PHONE + j - offset ))
  col=$(( tw + fillw + 2 ))                       # 1-based column of the first chip
  for i in "${!labels[@]}"; do
    lbl=${labels[i]}; a=${aidx[i]}                 # a = LOGICAL action index
    # underline the accelerator (first) letter on chips that have one
    if [ "${acc[i]}" = 1 ]; then inner=" ${ULINE}${lbl:0:1}${ULOFF}${lbl:1} "
    else                          inner=" ${lbl} "; fi
    chip_lo[a]=$col; chip_hi[a]=$(( col + lw[i] - 1 ))   # indexed by LOGICAL action
    # bracket color: idle chips frame in the summary text's mid-gray (MUTED) so the
    # whole chip reads as one unit at the same weight as the recap text; an ARMED
    # chip keeps PLAIN brackets so the inverted ❯[ label ]❮ pops against the fill.
    bkt="$MUTED"; [ "$a" = "$ACTION" ] && bkt=""
    if [ "$a" = "$ACTION" ]; then
      if [ "$a" = $(( NACT - 1 )) ]; then st="${REDCH}${BOLD}"   # armed close
      else                                st="${REV}${BOLD}"; fi  # armed other
    elif [ "$a" = $(( NACT - 1 )) ]; then st="${REDFG}"           # idle close (red label, mid-gray frame)
    else                                  st="${MUTED}"; fi        # idle chip: mid-gray, matches the summary text
    seg="${bkt}❯${RESET}${st}${inner}${RESET}${bkt}❮${RESET}"
    styled="${styled}${seg}"
    col=$(( col + lw[i] ))
    if [ "$i" -lt $(( ${#labels[@]} - 1 )) ]; then styled="${styled}${SEPC}─${RESET}"; col=$(( col + 1 )); fi
  done
  styled="${styled}${SEPC}──${RESET}"
  printf '%s\n' "$styled"
}

# ── PHONE action bar (2026-07-19) ────────────────────────────────────────────
# One full-width row above the footer rule with the SELECTED window's actions as
# big tap targets: [ open ] [ new ] [ move ] [ ren ] [ close ], evenly spread so
# each target is finger-sized. Same LOGICAL action indices as the divider chips
# (open=0 · new=NACT−4 · move=NACT−3 · rename=NACT−2 · close=NACT−1); the
# session-move chips don't fit here — that verb stays on keyboard/wide mode
# (and `move` still reaches any slot). Spans → abar_lo/abar_hi (keyed by
# logical index) + abar_row for press(). ASCII [ ] frames on purpose (no ❯❮ —
# ambiguous-width, 2 cells in iOS terminals; tap columns must be exact).
abar_lo=(); abar_hi=(); abar_row=0
MVP_ACT=()   # movepick picker: abar span i → MOVE_TARGETS index (−1 slot · −2 cancel)
# draw_abar_movepick — the [ move ] DESTINATION PICKER (2026-07-19): tapping
# [ move ] on the phone swaps the bar for one chip per other Claude session
# (same MOVE_TARGETS as the wide-mode chips), plus [ slot # ] (the old
# within-session slot prompt) and [ x ] (cancel). Trailing session chips are
# dropped when they don't fit — slot #/x always stay. Runs as INPUT_MODE=
# movepick, so stray keys are swallowed and a tap anywhere else cancels.
draw_abar_movepick() {
  local n=${#MOVE_TARGETS[@]} shown t i lbl st col used styled="" pad
  local lbls=()
  while :; do
    shown=$n; used=$(( 10 + 5 ))                    # "[ slot # ]" + "[ x ]"
    for (( i=0; i<shown; i++ )); do
      t=${MOVE_TARGETS[i]}; [ ${#t} -gt 8 ] && t="${t:0:7}…"
      lbls[i]=$t; used=$(( used + ${#t} + 5 ))      # "[ t ]" + 1 gap
    done
    [ "$used" -le "$cols" ] || { n=$(( n - 1 )); [ "$n" -lt 0 ] && break; continue; }
    break
  done
  col=1
  for (( i=0; i<shown; i++ )); do
    lbl=${lbls[i]}
    abar_lo+=("$col"); abar_hi+=($(( col + ${#lbl} + 3 ))); MVP_ACT+=("$i")
    styled="${styled}${MUTED}[ ${lbl} ]${RESET} "
    col=$(( col + ${#lbl} + 5 ))
  done
  abar_lo+=("$col"); abar_hi+=($(( col + 9 ))); MVP_ACT+=(-1)
  styled="${styled}${MUTED}[ slot # ]${RESET} "
  col=$(( col + 11 ))
  abar_lo+=("$col"); abar_hi+=($(( col + 4 ))); MVP_ACT+=(-2)
  styled="${styled}${REDFG}[ x ]${RESET}"
  printf '%s\n' "$styled"
}
draw_abar() {
  abar_lo=(); abar_hi=(); MVP_ACT=(); abar_row=$(( rows - 2 ))
  [ "$nwin" -le 0 ] && { printf '\n'; return; }    # nothing selected → keep geometry
  if [ "$INPUT_MODE" = movepick ]; then draw_abar_movepick; return; fi
  local labels=(open new move ren close)
  local aidx=(0 $(( NACT - 4 )) $(( NACT - 3 )) $(( NACT - 2 )) $(( NACT - 1 )))
  local i lbl a st col lead gap used=0 pad styled=""
  [ "$CONFIRM" = 1 ] && labels[4]="close?"
  for i in 0 1 2 3 4; do used=$(( used + ${#labels[i]} + 4 )); done   # each "[ lbl ]"
  gap=$(( (cols - used) / 6 )); [ "$gap" -lt 0 ] && gap=0
  lead=$(( (cols - used - gap * 4) / 2 )); [ "$lead" -lt 0 ] && lead=0
  printf -v styled '%*s' "$lead" ''; col=$(( lead + 1 ))
  for i in 0 1 2 3 4; do
    lbl=${labels[i]}; a=${aidx[i]}
    if [ "$a" = "$ACTION" ] && [ "$FOCUS" = body ]; then
      if [ "$i" = 4 ]; then st="${REDCH}${BOLD}"; else st="${REV}${BOLD}"; fi
    elif [ "$i" = 4 ]; then st="$REDFG"
    else                    st="$MUTED"; fi
    abar_lo[a]=$col; abar_hi[a]=$(( col + ${#lbl} + 3 ))
    styled="${styled}${st}[ ${lbl} ]${RESET}"
    col=$(( col + ${#lbl} + 4 ))
    if [ "$i" -lt 4 ]; then printf -v pad '%*s' "$gap" ''; styled="${styled}${pad}"; col=$(( col + gap )); fi
  done
  printf '%s\n' "$styled"
}

# PHONE footer tap targets (registered only when the DEFAULT footer renders;
# input/toast/confirm footers leave the arrays empty → taps there are inert)
foot_lo=(); foot_hi=(); foot_verb=()

draw() {
  if [ "$HELP_ON" = 1 ]; then draw_help; return; fi
  {
    printf '\033[H\033[2J'
    [ "$PHONE" = 1 ] && printf '\n'    # phone: blank spacer row 1 (see apply_dims)
    chip_lo=(); chip_hi=(); selrow_scr=0
    # V3 (2026-07-08): rebuild the header EVERY frame so focus transitions (↑ to
    # the tab bar, ↓/⏎ back to the list) restyle the viewed tab immediately.
    # It was a cached string before, so ↑ left the blue-focus fill stale until
    # the next view_session() rebuilt it. build_header is pure string assembly
    # over the loaded SESS_LIST (no tmux calls) — negligible per-frame cost.
    build_header
    printf '%s\n' "$hdr_out"
    # rule under the header, with a ┴ closing each header zone's right edge │
    # (the [ ➕ NEW ] zone at hdr_bound0, the tab zone at hdr_bound)
    local hr=$RULE
    if [ "$hdr_bound" -ge 1 ] && [ "$hdr_bound" -le "$cols" ]; then
      hr="${RULE:0:$(( hdr_bound - 1 ))}┴${RULE:$hdr_bound}"
    fi
    if [ "$hdr_bound0" -ge 1 ] && [ "$hdr_bound0" -le "$cols" ]; then
      hr="${hr:0:$(( hdr_bound0 - 1 ))}┴${hr:$hdr_bound0}"
    fi
    printf '%s%s%s\n' "$SLATE" "$hr" "$RESET"
    local end=$(( offset + view_h )) j w kind a b mk selwin shown=0
    selwin=${win_order[sel]}
    # zero windows visible (a search matched nothing) → a dim notice so
    # the body is never a silent blank
    if [ "$total" -eq 0 ] && [ "$SEARCH_ON" = 1 ]; then
      printf '%s%*sno window matches "%s"  (Esc clears)%s\n' "$MUTED" "$hang" '' "$SEARCH_Q" "$RESET"
      shown=$((shown+1))
    fi
    for (( j = offset; j < end && j < total; j++ )); do
      w=${line_win[j]}; kind=${line_kind[j]}; a=${line_a[j]}; b=${line_b[j]}; gph=${line_g[j]}
      if [ "$kind" = h ]; then
        draw_entry_rule "$j" "$w" "$a" "$gph"     # divider-title (+ chips if selected)
      else
        printf '%s%s%s\n' "$MUTED" "$a" "$RESET"   # recap flush-left, aligned under the entry's number
      fi
      shown=$((shown+1))
    done
    for (( j = shown; j < view_h; j++ )); do printf '\n'; done     # pad so the footer sits at the bottom
    [ "$PHONE" = 1 ] && draw_abar                     # phone: pinned action bar row
    printf '%s%s%s\n' "$SLATE" "$RULE" "$RESET"       # rule above the footer
    # footer: input-mode prompt (highest priority) · then a transient TOAST ·
    # then focus/confirm-aware hints (wide) or tap targets (phone)
    local foot fseg fcol fi
    foot_lo=(); foot_hi=(); foot_verb=()
    if [ "$SEARCH_ON" = 1 ]; then foot="search: ${SEARCH_Q}▌  (${nwin} results across all sessions · ↑↓ pick · ⏎ open · Esc close search)"
    elif [ "$INPUT_MODE" = rename ]; then foot="rename to: ${INPUT_TEXT}▌  (⏎ save · Esc cancel)"
    elif [ "$INPUT_MODE" = slot ]; then foot="move window ${win_order[sel]} to slot: ${INPUT_TEXT}▌  (⏎ go · Esc cancel)"
    elif [ "$INPUT_MODE" = movepick ]; then foot="move window ${win_order[sel]} where? tap a destination · [ x ]/Esc cancel"
    elif [ -n "$TOAST" ]; then foot="$TOAST"
    elif [ "$CONFIRM" = 1 ]; then foot="⏎ again = gracefully close window ${win_order[sel]} · any other key cancels"
    elif [ "$FOCUS" = tabs ] && [ "$BARNEW" = 1 ]; then foot="⏎ new window in '${VSESS}' · ←/→ session · ↓ into list · Esc/q close"
    elif [ "$FOCUS" = tabs ]; then foot="←/→ switch session · ↓ into list · ⇥ commit · Esc/q close"
    elif [ "$PHONE" = 1 ]; then
      # phone default footer: tappable verbs (the keyboard legend is useless on
      # touch and never fit anyway); spans registered for press()
      local fsegs=("search" "sort:${sort_mode}" "+ session" "?")
      local fverbs=(search sort newsess help)
      foot=""; fcol=1
      for fi in 0 1 2 3; do
        fseg="[ ${fsegs[fi]} ]"
        foot_lo+=("$fcol"); foot_hi+=($(( fcol + ${#fseg} - 1 ))); foot_verb+=("${fverbs[fi]}")
        foot="${foot}${fseg} "
        fcol=$(( fcol + ${#fseg} + 1 ))
      done
    else foot="(n)ew · (m)ove · (r)ename · (c)lose · (.) search · (t) sort:${sort_mode} · (s) new session · (?) tmux help · Esc/q"; fi
    [ ${#foot} -gt "$cols" ] && foot=${foot:0:$cols}
    printf '%s%s%s' "$MUTED" "$foot" "$RESET"
    # tappable close button, top-right corner ([ ❌ ] = 6 cells on the phone,
    # [ ❌ CLOSE ] = 12 wide); then park the cursor at the bottom
    if [ "$PHONE" = 1 ]; then printf '\033[2;%dH%s[ ❌ ]%s\033[%d;1H' $(( cols - 6 )) "$BOLD" "$RESET" "$rows"   # row 2: header sits under the spacer
    else printf '\033[1;%dH%s[ ❌ CLOSE ]%s\033[%d;1H' $(( cols - 12 )) "$BOLD" "$RESET" "$rows"; fi
  } > "$TTY_OUT"
}

scroll() { offset=$(( offset + $1 )); [ "$offset" -gt "$max_off" ] && offset=$max_off; [ "$offset" -lt 0 ] && offset=0; }

# move the selection cursor by N windows (clamped), and scroll the viewport just
# enough to keep the selected window's header line on-screen.
move_sel() {
  [ "$nwin" -le 0 ] && { sel=0; offset=0; return; }   # nothing to select (search matched 0)
  sel=$(( sel + $1 ))
  (( sel < 0 )) && sel=0
  (( sel >= nwin )) && sel=$(( nwin - 1 ))
  (( sel < 0 )) && sel=0
  # in global search each result may live in a different session → recompute the
  # move-to-session chips (and NACT) for the newly-selected result's session.
  [ "$SEARCH_ON" = 1 ] && build_targets "${win_sess[sel]:-$VSESS}"
  local h=${whead[sel]}
  (( h < offset )) && offset=$h
  (( h >= offset + view_h )) && offset=$(( h - view_h + 1 ))
  (( offset > max_off )) && offset=$max_off
  (( offset < 0 )) && offset=0
}

# view another session: delta ±1 (wraps) or =N (absolute index)
view_session() {
  load_sessions
  [ "$nsess" -eq 0 ] && exit 0
  local sv; sview; sv=$__sv
  case "$1" in
    =*) sv=${1#=} ;;
    *)  sv=$(( (sv + $1 + nsess) % nsess )) ;;
  esac
  (( sv < 0 )) && sv=0; (( sv >= nsess )) && sv=$(( nsess - 1 ))
  VSESS=${SESS_LIST[sv]}
  ACTION=0; CONFIRM=0                # new session → re-arm the default (open)
  build_targets                      # move chips exclude the newly-viewed session
  build_model; recalc_scroll         # header is rebuilt by draw() (V3)
  offset=0
  win_pos "$active_win"; sel=$__wp   # cursor lands on the viewed session's active window
  move_sel 0
}

# ── R3 global search mode (entered with `.`) ──────────────────────────────────
search_rebuild() { build_model; recalc_scroll; sel=0; move_sel 0; }
search_enter() { SEARCH_ON=1; SEARCH_Q=""; ACTION=0; CONFIRM=0; FOCUS=body; TOAST=""; search_rebuild; }
search_exit() {                       # back to the normal viewed-session list
  SEARCH_ON=0; SEARCH_Q=""; ACTION=0; CONFIRM=0
  build_targets; build_model; recalc_scroll
  win_pos "$CURWIN"; sel=$__wp; move_sel 0
}

# ── tmux-help mode (entered with `?`, 2026-07-09) ─────────────────────────────
# A live, filterable, two-column reference of the C-k prefix bindings. Data comes
# straight from `tmux list-keys -N -T prefix` (native order matches the classic
# `?` help: Space, !, ", #, …), so it never drifts from the real config.
help_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }   # bash 3.2 has no ${x,,}

help_load() {
  HELP_MDK=(); HELP_MDESC=(); HELP_MLC=(); HELP_MAXK=0
  local key rest dk
  # Prefix the real bound key (C-k here) so the display matches what you press;
  # read it live rather than hardcoding, so it stays correct if the prefix changes.
  HELP_PFX=$($TMUX_BIN show-options -gv prefix 2>/dev/null); [ -n "$HELP_PFX" ] || HELP_PFX="C-k"
  # read splits: key = first field, rest = remainder (leading ws trimmed). Every
  # tmux key name is a single token (Space, M-Right, C-Up, PPage…), so this is safe.
  while read -r key rest; do
    [ -z "$key" ] && continue
    dk="$HELP_PFX $key"
    HELP_MDK+=("$dk"); HELP_MDESC+=("$rest")
    HELP_MLC+=("$(help_lc "$dk $rest")")     # pre-lowered haystack (once) → fork-free filter
    [ ${#dk} -gt "$HELP_MAXK" ] && HELP_MAXK=${#dk}
  done < <($TMUX_BIN list-keys -N -T prefix 2>/dev/null)
  HELP_LOADED=1
}

# rebuild the filtered view from HELP_Q (case-insensitive substring over key+desc)
help_filter() {
  HELP_DK=(); HELP_DESC=(); HELP_N=0
  local q i
  q=$(help_lc "$HELP_Q")
  for (( i=0; i<${#HELP_MDK[@]}; i++ )); do
    if [ -z "$q" ]; then
      HELP_DK+=("${HELP_MDK[i]}"); HELP_DESC+=("${HELP_MDESC[i]}")
    else
      case "${HELP_MLC[i]}" in *"$q"*) HELP_DK+=("${HELP_MDK[i]}"); HELP_DESC+=("${HELP_MDESC[i]}") ;; esac
    fi
  done
  HELP_N=${#HELP_DK[@]}
  HELP_SEL=0
}

help_scroll() {
  HELP_OFF=$(( HELP_OFF + $1 ))
  local rows_total=$(( (HELP_N + 1) / 2 )) maxoff
  maxoff=$(( rows_total - view_h )); (( maxoff < 0 )) && maxoff=0
  (( HELP_OFF > maxoff )) && HELP_OFF=$maxoff
  (( HELP_OFF < 0 )) && HELP_OFF=0
}

# move the help selection by $1 entries (row-major grid: ±2 = same column, ±1 =
# adjacent entry) and scroll just enough to keep it on-screen.
help_move() {
  [ "$HELP_N" -gt 0 ] || return
  HELP_SEL=$(( HELP_SEL + $1 ))
  (( HELP_SEL < 0 )) && HELP_SEL=0
  (( HELP_SEL >= HELP_N )) && HELP_SEL=$(( HELP_N - 1 ))
  local r=$(( HELP_SEL / 2 ))
  (( r < HELP_OFF )) && HELP_OFF=$r
  (( r >= HELP_OFF + view_h )) && HELP_OFF=$(( r - view_h + 1 ))
  (( HELP_OFF < 0 )) && HELP_OFF=0
}

# run the SELECTED binding: replay `prefix + key` AT THE CLIENT (send-keys -K,
# looked up in the client's key table) a beat after this popup tears down —
# same defer pattern as do_newwindow — so the binding runs exactly as if typed.
help_run() {
  [ "$HELP_N" -gt 0 ] || return
  local dk key ekey epfx tgt=""
  dk=${HELP_DK[HELP_SEL]}
  key=${dk#"$HELP_PFX "}
  if [ -n "$JW_DASH_TEST" ]; then printf 'ACTION helprun %s\n' "$key"; exit 0; fi
  # key names can BE quote characters (" and ') → escape for the '…' embedding
  ekey=$(printf '%s' "$key" | sed "s/'/'\\\\''/g")
  epfx=$(printf '%s' "$HELP_PFX" | sed "s/'/'\\\\''/g")
  [ -n "$CLIENT" ] && tgt=" -c '$CLIENT'"
  $TMUX_BIN run-shell -b "sleep 0.2; tmux send-keys -K${tgt} '$epfx' '$ekey'" 2>/dev/null
  exit 0
}

# tap in help: an entry runs it; header/footer chrome dismisses the help layer.
help_press() {
  local y=$1 x=$2 r idx colw gap=2
  { [ "$y" -ge 3 ] && [ "$y" -lt $(( rows - 1 )) ]; } 2>/dev/null || { help_exit; return; }
  colw=$(( (cols - gap - 1) / 2 )); (( colw < 10 )) && colw=10
  r=$(( HELP_OFF + y - 3 ))
  idx=$(( r * 2 )); [ "$x" -gt $(( 1 + colw + gap )) ] && idx=$(( idx + 1 ))
  if [ "$idx" -ge 0 ] && [ "$idx" -lt "$HELP_N" ]; then HELP_SEL=$idx; help_run; fi
}

help_enter() {
  [ "$HELP_LOADED" = 1 ] || help_load
  HELP_ON=1; HELP_Q=""; HELP_OFF=0; HELP_SEL=0; CONFIRM=0; TOAST=""; help_filter
}
help_exit() { HELP_ON=0; HELP_Q=""; HELP_OFF=0; HELP_SEL=0; }

# two-column render of the filtered bindings + type-ahead footer. All content is
# ASCII, so ${#s} == display width (no emoji math needed here).
draw_help() {
  {
    printf '\033[H\033[2J'
    printf '%s tmux key bindings — prefix %s %s\n' "$BOLD" "$HELP_PFX" "$RESET"
    printf '%s%s%s\n' "$SLATE" "$RULE" "$RESET"
    local n=$HELP_N gap=2 colw rows_total maxoff shown=0 r li ri lentry rentry
    colw=$(( (cols - gap - 1) / 2 )); (( colw < 10 )) && colw=10
    rows_total=$(( (n + 1) / 2 ))
    maxoff=$(( rows_total - view_h )); (( maxoff < 0 )) && maxoff=0
    (( HELP_OFF > maxoff )) && HELP_OFF=$maxoff
    (( HELP_OFF < 0 )) && HELP_OFF=0
    if [ "$n" -eq 0 ]; then
      printf '%s%*sno binding matches "%s"  (Esc closes)%s\n' "$MUTED" "$hang" '' "$HELP_Q" "$RESET"
      shown=1
    fi
    # row-major: row r shows entries 2r (left) and 2r+1 (right); scrolls by row.
    # Pad each entry to colw FIRST, then wrap the SELECTED one in reverse video
    # (styling after padding — ANSI bytes would break the %-*s width math).
    for (( r = HELP_OFF; r < HELP_OFF + view_h && r < rows_total; r++ )); do
      li=$(( r * 2 )); ri=$(( r * 2 + 1 ))
      printf -v lentry '%-*s %s' "$HELP_MAXK" "${HELP_DK[li]}" "${HELP_DESC[li]}"
      lentry=${lentry:0:colw}
      printf -v lentry '%-*s' "$colw" "$lentry"
      [ "$li" = "$HELP_SEL" ] && lentry="${REV}${lentry}${RESET}"
      if [ "$ri" -lt "$n" ]; then
        printf -v rentry '%-*s %s' "$HELP_MAXK" "${HELP_DK[ri]}" "${HELP_DESC[ri]}"
        rentry=${rentry:0:colw}
        [ "$ri" = "$HELP_SEL" ] && rentry="${REV}${rentry}${RESET}"
      else rentry=""; fi
      printf ' %s%*s%s\n' "$lentry" "$gap" '' "$rentry"
      shown=$((shown+1))
    done
    for (( r = shown; r < view_h; r++ )); do printf '\n'; done
    printf '%s%s%s\n' "$SLATE" "$RULE" "$RESET"
    local foot="help: ${HELP_Q}▌  (${n} of ${#HELP_MDK[@]} · type to filter · ↑↓←→ select · ⏎ run · Esc close)"
    [ ${#foot} -gt "$cols" ] && foot=${foot:0:$cols}
    printf '%s%s%s' "$MUTED" "$foot" "$RESET"
    printf '\033[1;%dH%s[ ❌ CLOSE ]%s\033[%d;1H' $(( cols - 12 )) "$BOLD" "$RESET" "$rows"
  } > "$TTY_OUT"
}

# ── focus-aware key handlers (2026-07-05) ─────────────────────────────────────
# ↑/↓ move within the LIST; ↑ off row 1 lifts focus to the session BAR, where
# ←/→ switch session and ↓ drops back to row 1. ←/→ in the list arm the action.
k_up() {
  if [ "$FOCUS" = tabs ]; then return; fi          # already at the top
  CONFIRM=0
  # ↑ off row 1 lifts focus to the session bar — but NOT during global search
  # (there's no "viewed session" to browse there; stay in the results).
  if [ "$sel" -le 0 ]; then [ "$SEARCH_ON" = 1 ] || { FOCUS=tabs; BARNEW=0; ACTION=0; }; return; fi
  move_sel -1; ACTION=0                             # 3A: vertical motion re-arms open
}
k_down() {
  CONFIRM=0
  if [ "$FOCUS" = tabs ]; then FOCUS=body; BARNEW=0; ACTION=0; sel=0; move_sel 0; return; fi
  move_sel 1; ACTION=0
}
# bar_move — ←/→ on the bar cycle a cursor over [ ➕ NEW ] + the session tabs
# (wraps). Landing on a tab VIEWS that session (as before); landing on NEW
# keeps the current view — ⏎ there creates a window in the VIEWED session.
bar_move() {
  local p; sview
  if [ "$BARNEW" = 1 ]; then p=0; else p=$(( __sv + 1 )); fi
  p=$(( (p + $1 + nsess + 1) % (nsess + 1) ))
  if [ "$p" -eq 0 ]; then BARNEW=1
  else BARNEW=0; view_session "=$(( p - 1 ))"; fi
}
# arm_step: ←/→ walk the armed action. PHONE shows only the 5 bar verbs, so the
# walk hops open → new → move → rename → close, skipping the (hidden)
# session-move indices; wide mode keeps the plain ±1 walk over every chip.
arm_step() {
  if [ "$PHONE" != 1 ]; then
    if [ "$1" -gt 0 ]; then [ "$ACTION" -lt $(( NACT - 1 )) ] && ACTION=$(( ACTION + 1 ))
    else                    [ "$ACTION" -gt 0 ] && ACTION=$(( ACTION - 1 )); fi
    return
  fi
  local seq=(0 $(( NACT - 4 )) $(( NACT - 3 )) $(( NACT - 2 )) $(( NACT - 1 ))) i p=0
  for i in 0 1 2 3 4; do [ "${seq[i]}" -le "$ACTION" ] && p=$i; done
  p=$(( p + $1 )); (( p < 0 )) && p=0; (( p > 4 )) && p=4
  ACTION=${seq[p]}
}
k_left()  { if [ "$FOCUS" = tabs ]; then bar_move -1; else CONFIRM=0; arm_step -1; fi; }
k_right() { if [ "$FOCUS" = tabs ]; then bar_move  1; else CONFIRM=0; arm_step  1; fi; }
# Tab / Shift-Tab: switch session from anywhere and COMMIT into the list on the
# active window (keeps the pre-existing ⇥ behavior; absorbs the old ←/→ switch).
k_tab()   { view_session "$1"; FOCUS=body; BARNEW=0; ACTION=0; CONFIRM=0; }
# Enter: on the bar, run [ ➕ NEW ] if the cursor is on it, else drop into the
# list; in the list, run the armed chip.
k_enter() {
  if [ "$FOCUS" = tabs ]; then
    [ "$BARNEW" = 1 ] && { CONFIRM=0; do_newwindow; return; }
    FOCUS=body; ACTION=0; CONFIRM=0; sel=0; move_sel 0; return
  fi
  run_action
}

# ── the chip engine (2026-07-08) ──────────────────────────────────────────────
# run_action dispatches the ARMED chip: 0 = open · 1..#targets = move-to-session
# · NACT-4 = new session · NACT-3 = move-to-slot · NACT-2 = rename · NACT-1 = close.
run_action() {
  [ "$nwin" -le 0 ] && return                      # no window selected (search matched 0)
  if [ "$ACTION" -eq 0 ]; then CONFIRM=0; jump_win "${win_order[sel]}" "${win_sess[sel]:-$VSESS}"; return; fi
  if [ "$ACTION" -eq $(( NACT - 1 )) ]; then       # close: two-step confirm
    if [ "$CONFIRM" = 1 ]; then CONFIRM=0; do_close; else CONFIRM=1; fi
    return
  fi
  CONFIRM=0
  if   [ "$ACTION" -eq $(( NACT - 2 )) ]; then input_start rename
  elif [ "$ACTION" -eq $(( NACT - 3 )) ]; then input_start slot
  elif [ "$ACTION" -eq $(( NACT - 4 )) ]; then do_new
  else do_move "${MOVE_TARGETS[$(( ACTION - 1 ))]}"; fi
}

# accelerator (change #4): fire a specific chip on the selected row by its letter
# — (n)ew session · (m)ove · (r)ename · (c)lose. Body focus + a real window only
# (the tab bar has no accelerators).
accel() {
  [ "$FOCUS" = body ] || return
  [ "$nwin" -le 0 ] && return
  ACTION=$1; run_action
}

# resolve the selected window → __w (index) / __wid (@id) / __wname (raw tmux
# window name, "" if gone) / __wdisp (the DISPLAYED name — @ccname when a Claude
# pane set one, else window_name — matches what the list shows and is what the
# rename editor prefills, so the user edits the real name, not the "2.1.199"
# version comm tmux auto-named the window)
sel_resolve() {
  local pair
  # __wsess = the SELECTED entry's owning session (VSESS in normal view, the
  # result's own session in global search) — all mutations act on it, not VSESS.
  __w=${win_order[sel]}; __wname=""; __wdisp=""; __wsess=${win_sess[sel]:-$VSESS}
  __wid=$($TMUX_BIN list-windows -t "$__wsess" -F '#{window_index} #{window_id}' 2>/dev/null \
          | awk -v x="$__w" '$1==x{print $2}')
  if [ -n "$__wid" ]; then
    # window_name | displayed-name (@ccname-or-window_name) in one call; split on |
    pair=$($TMUX_BIN display-message -p -t "$__wid" '#{window_name}|#{?#{@ccname},#{@ccname},#{window_name}}' 2>/dev/null)
    __wname=${pair%%|*}; __wdisp=${pair#*|}
  fi
}

# after any mutation: the window left VSESS (or VSESS/other sessions died) —
# rebuild everything and keep the cursor in range. Exits if nothing is left.
refresh_after_action() {
  load_sessions; build_model; recalc_scroll    # header is rebuilt by draw() (V3)
  [ "$nsess" -eq 0 ] && exit 0
  (( sel >= nwin )) && sel=$(( nwin - 1 )); (( sel < 0 )) && sel=0
  ACTION=0; CONFIRM=0; move_sel 0
}

# do_move <dest-session> — move the SELECTED window via the shared hook. Never
# trusts silence: reads the hook's porcelain result and toasts it, or toasts a
# failure. The parking lot goes through the `park` verb (creates the lot on
# demand); existing sessions through `restore <dest>` (validates existence).
do_move() {
  local dest=$1 verb out ds di rc
  sel_resolve
  [ -n "$__wid" ] || { TOAST="move: window $__w not found"; return; }
  verb=restore; [ "$dest" = "$PARKING_NAME" ] && verb=park
  [ -n "$JW_DASH_TEST" ] && printf 'ACTION move %s:%s %s\n' "$__wsess" "$__w" "$dest"
  out=$("$HOOK" "$verb" "$__wid" "$dest" --parking "$PARKING_NAME" --porcelain 2>/dev/null); rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    ds=${out%%$'\t'*}; di=${out##*$'\t'}
    TOAST="moved '$__wname' → $ds:$di"
  else
    TOAST="move FAILED for '$__wname' — check the terminal"
  fi
  refresh_after_action
}

# do_new — move the SELECTED window into a BRAND-NEW session named after it
# (sanitized, -2/-3… suffixed on collision). The park verb creates the session
# sized like the source window, so no 80x24 reflow.
do_new() {
  local base newname n2 out ds di rc
  sel_resolve
  [ -n "$__wid" ] || { TOAST="new: window $__w not found"; return; }
  base=$(printf '%s' "$__wname" | tr -c 'a-zA-Z0-9_.-' '-' | sed 's/^-*//; s/-*$//')
  [ -n "$base" ] || base=cc-new
  newname=$base; n2=2
  while $TMUX_BIN has-session -t "=$newname" 2>/dev/null; do
    newname="${base}-${n2}"; n2=$(( n2 + 1 ))
  done
  [ -n "$JW_DASH_TEST" ] && printf 'ACTION new %s:%s %s\n' "$__wsess" "$__w" "$newname"
  out=$("$HOOK" park "$__wid" "$newname" --porcelain 2>/dev/null); rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    ds=${out%%$'\t'*}; di=${out##*$'\t'}
    TOAST="new session '$ds' ← '$__wname' (window $di)"
  else
    TOAST="new-session move FAILED for '$__wname' — check the terminal"
  fi
  refresh_after_action
}

# do_newwindow — create a fresh window in the VIEWED session and OPEN it
# (same landing as jump_win: select it, switch this client across sessions if
# needed, then close the popup). Triggered by the header's [ ➕ NEW ] button
# (tap, or ⏎ with the bar cursor on it).
do_newwindow() {
  local idx
  # TEST path: create synchronously so the harness can observe the new window
  # and read its index from the ACTION line.
  if [ -n "$JW_DASH_TEST" ]; then
    idx=$($TMUX_BIN new-window -t "$VSESS" -P -F '#{window_index}' 2>/dev/null)
    if [ -z "$idx" ]; then TOAST="new window FAILED in '$VSESS'"; refresh_after_action; return; fi
    printf 'ACTION newwindow %s:%s\n' "$VSESS" "$idx"
    exit 0
  fi
  # REAL path: DEFER creation until AFTER this popup tears down (which happens
  # the instant we exit). A window created from INSIDE the popup draws its shell
  # prompt while the popup still covers the screen, and tmux does NOT repaint the
  # freshly-switched window when the popup closes — so the prompt sits in the
  # grid unseen until a ZLE event forces a redraw (the "no command prompt until I
  # hit Ctrl-C" bug). Creating it a beat after we exit replicates a plain
  # `tmux new-window` typed at the prompt, which paints cleanly. new-window
  # auto-selects the new window in its session; switch-client is only needed when
  # the VIEWED session isn't this client's own session. run-shell -b queues a
  # server-side job that survives the popup close; the short sleep lets the
  # teardown win the race so the create lands in the real client, not the overlay.
  local defer="tmux new-window -t '$VSESS'"
  if [ "$VSESS" != "$SESSION" ]; then
    if [ -n "$CLIENT" ]; then defer="$defer && tmux switch-client -c '$CLIENT' -t '$VSESS'"
    else                      defer="$defer && tmux switch-client -t '$VSESS'"; fi
  fi
  $TMUX_BIN run-shell -b "sleep 0.2; $defer" 2>/dev/null
  exit 0
}

# do_newsession (2026-07-09) — create a BRAND-NEW blank tmux session named
# cc-mmdd (today's date, e.g. cc-0709) and switch this client into it. This is
# NOT the "new session" chip (do_new, which MOVES the selected window into a new
# session named after it) — this makes a fresh empty session with a plain shell.
# Bound to the (s) footer key. On a same-day collision it suffixes -2, -3, … so
# it never fails and you can spin up several blank sessions in a day.
do_newsession() {
  local base name n2 cw ch sz defer
  base="${TMUXJW_SESSION_PREFIX:-cc-}$(date +%m%d)"
  name=$base; n2=2
  while $TMUX_BIN has-session -t "=$name" 2>/dev/null; do
    name="${base}-${n2}"; n2=$(( n2 + 1 ))
  done
  # TEST path: create synchronously so the harness can observe the session and
  # read its name from the ACTION line.
  if [ -n "$JW_DASH_TEST" ]; then
    $TMUX_BIN new-session -d -s "$name" 2>/dev/null
    printf 'ACTION newsession %s\n' "$name"
    exit 0
  fi
  # Size the new session to THIS client so the blank terminal opens without an
  # 80x24 reflow. Query the real client (captured at launch), not the popup.
  if [ -n "$CLIENT" ]; then
    cw=$($TMUX_BIN display-message -p -t "$CLIENT" '#{client_width}' 2>/dev/null)
    ch=$($TMUX_BIN display-message -p -t "$CLIENT" '#{client_height}' 2>/dev/null)
  else
    cw=$($TMUX_BIN display-message -p '#{client_width}' 2>/dev/null)
    ch=$($TMUX_BIN display-message -p '#{client_height}' 2>/dev/null)
  fi
  sz=""
  case "$cw" in ''|*[!0-9]*) ;; *) case "$ch" in ''|*[!0-9]*) ;; *) sz=" -x $cw -y $ch";; esac;; esac
  # DEFER the create+switch to a run-shell job that fires just after this popup
  # tears down — a session made from INSIDE the popup draws its blank shell's
  # prompt behind the overlay and tmux won't repaint it on close (the "no prompt
  # until Ctrl-C" bug; same fix as do_newwindow). new-session -d makes it without
  # stealing focus; switch-client then lands this client in it.
  defer="tmux new-session -d -s '$name'$sz"
  if [ -n "$CLIENT" ]; then defer="$defer && tmux switch-client -c '$CLIENT' -t '$name'"
  else                      defer="$defer && tmux switch-client -t '$name'"; fi
  $TMUX_BIN run-shell -b "sleep 0.2; $defer" 2>/dev/null
  exit 0
}

# do_close — GRACEFUL close: if a Claude CLI runs in the window, send `/exit`
# (C-u first to clear any half-typed input) so Claude Code's SessionEnd/close
# hooks fire, wait for the process to leave (≤8s), THEN kill the window. If
# Claude refuses to exit (mid-turn, permission prompt), NOTHING is killed — a
# toast says so. Windows with no Claude are killed directly.
do_close() {
  local pane cmd i wc csess other
  sel_resolve
  [ -n "$__wid" ] || { TOAST="close: window $__w not found"; return; }
  [ -n "$JW_DASH_TEST" ] && printf 'ACTION close %s:%s\n' "$__wsess" "$__w"
  pane=""
  while read -r pid pcmd; do
    [[ "$pcmd" =~ $CCRE ]] && { pane=$pid; break; }
  done < <($TMUX_BIN list-panes -t "$__wid" -F '#{pane_id} #{pane_current_command}' 2>/dev/null)
  if [ -n "$pane" ]; then
    TOAST="closing '$__wname' gracefully…"; draw
    $TMUX_BIN send-keys -t "$pane" C-u 2>/dev/null
    $TMUX_BIN send-keys -t "$pane" '/exit' Enter 2>/dev/null
    cmd=""
    for (( i=0; i<32; i++ )); do                   # ≤8s for hooks to run
      sleep 0.25
      cmd=$($TMUX_BIN display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null) || { cmd=""; break; }
      [[ "$cmd" =~ $CCRE ]] || break
    done
    if [ -n "$cmd" ] && [[ "$cmd" =~ $CCRE ]]; then
      TOAST="'$__wname' did not exit after /exit — NOT closed (it may be mid-turn)"
      refresh_after_action; return
    fi
  fi
  # LAST-WINDOW GUARD (2026-07-16): killing a session's only window kills the
  # session, and if THIS client is attached to it, tmux dumps the client back
  # to the shell. Land it in the most-recently-active OTHER session first (its
  # current window = its MRU window), so closing the last window never kicks
  # you out of tmux.
  wc=$($TMUX_BIN list-windows -t "$__wsess" -F x 2>/dev/null | wc -l | tr -d ' ')
  if [ "$wc" -le 1 ]; then
    csess=$SESSION
    if [ -n "$CLIENT" ]; then
      csess=$($TMUX_BIN display-message -p -t "$CLIENT" '#{client_session}' 2>/dev/null)
      [ -n "$csess" ] || csess=$SESSION
    fi
    if [ "$csess" = "$__wsess" ]; then
      other=$($TMUX_BIN list-sessions -F '#{session_activity} #{session_name}' 2>/dev/null \
              | awk -v s="$__wsess" '$2!=s' | sort -rn | head -1 | cut -d' ' -f2-)
      if [ -n "$other" ]; then
        [ -n "$JW_DASH_TEST" ] && printf 'ACTION lastwin-switch %s\n' "$other"
        if [ -n "$CLIENT" ]; then $TMUX_BIN switch-client -c "$CLIENT" -t "$other" 2>/dev/null
        elif [ -z "$JW_DASH_TEST" ]; then $TMUX_BIN switch-client -t "$other" 2>/dev/null; fi
      fi
    fi
  fi
  $TMUX_BIN kill-window -t "$__wid" 2>/dev/null
  TOAST="closed '$__wname'"
  refresh_after_action
}

# do_teleport <slot> — move the SELECTED window to an ABSOLUTE slot number
# WITHIN its session, via the shared teleport engine (the same one prefix+.
# uses): heal gaps → direction-aware insert → renumber, so moving win 3 → 10
# makes 10 become 9, and moving 14 → 12 makes 12 become 13. We drive it in QUIET
# mode and VERIFY independently by the window id's new index (never trust
# silence), then keep the cursor on the moved window.
do_teleport() {
  local target=$1 after
  sel_resolve
  [ -n "$__wid" ] || { TOAST="move: window $__w not found"; return; }
  case "$target" in ''|*[!0-9]*) TOAST="move: '$target' is not a slot number"; return;; esac
  [ -n "$JW_DASH_TEST" ] && printf 'ACTION teleport %s:%s %s\n' "$__wsess" "$__w" "$target"
  JW_TELEPORT_QUIET=1 JW_TMUX="$TMUX_BIN" "$TELEPORT" "$target" "$__wid" "$__wsess" >/dev/null 2>&1
  after=$($TMUX_BIN list-windows -t "$__wsess" -F '#{window_index} #{window_id}' 2>/dev/null \
          | awk -v id="$__wid" '$2==id{print $1}')
  if [ -n "$after" ]; then TOAST="moved '$__wdisp' → slot $after"
  else TOAST="move FAILED for '$__wname' — check the terminal"; fi
  # the window's index changed and the whole session renumbered → rebuild and
  # keep the cursor on the moved window (now at index $after).
  build_model; recalc_scroll
  [ -n "$after" ] && { win_pos "$after"; sel=$__wp; }
  ACTION=0; CONFIRM=0; move_sel 0
}

# ── inline line editor (2026-07-08 v3.1) — shared by rename + slot ──
# input_start enters a mode; handle_input_key (called from the main loop while
# INPUT_MODE is set) edits INPUT_TEXT; commit/cancel leave the mode.
input_start() {
  INPUT_MODE=$1; CONFIRM=0; TOAST=""
  case "$1" in
    rename)   sel_resolve; INPUT_TEXT=${__wdisp} ;;   # prefill the DISPLAYED name
    slot)     INPUT_TEXT="" ;;                          # empty → type the target slot
    movepick) INPUT_TEXT="" ;;                          # phone [ move ] destination picker
  esac
}

# movepick_press — a tap while the [ move ] destination picker is open (routed
# here from handle_input_key's SGR case). On the bar: session chip = move
# there · [ slot # ] = the classic within-session slot prompt · [ x ] = cancel.
# Anywhere else = cancel (same contract as taps during rename/slot input).
movepick_press() {
  local y=$1 x=$2 i a
  INPUT_MODE=""
  [ "$y" = "$abar_row" ] || return 0
  for i in "${!abar_lo[@]}"; do
    if [ "$x" -ge "${abar_lo[i]}" ] && [ "$x" -le "${abar_hi[i]}" ]; then
      a=${MVP_ACT[i]}
      case "$a" in
        -2) return 0 ;;                                # [ x ] cancel
        -1) input_start slot; return 0 ;;              # [ slot # ]
        *)  do_move "${MOVE_TARGETS[a]}"; return 0 ;;  # session destination
      esac
    fi
  done
  return 0
}

input_commit() {
  local mode=$INPUT_MODE; INPUT_MODE=""
  case "$mode" in
    rename)
      local newname=$INPUT_TEXT
      [ -n "$newname" ] || { TOAST="rename cancelled (empty name)"; return; }
      sel_resolve
      [ -n "$__wid" ] || { TOAST="rename: window $__w not found"; return; }
      [ -n "$JW_DASH_TEST" ] && printf 'ACTION rename %s:%s %s\n' "$VSESS" "$__w" "$newname"
      # automatic-rename off so the shell doesn't overwrite it. NOTE: a live
      # Claude pane publishes @ccname via the reconciler, which the bar/cockpit
      # DISPLAY over the tmux window name — so renaming a Claude window changes
      # the tmux name but the shown name stays @ccname until Claude's own
      # /rename. Accepted for v1.
      $TMUX_BIN set-option -w -t "$__wid" automatic-rename off 2>/dev/null
      $TMUX_BIN rename-window -t "$__wid" "$newname" 2>/dev/null
      TOAST="renamed window $__w → '$newname'"
      build_model; recalc_scroll; win_pos "$__w"; sel=$__wp; move_sel 0
      ;;
    slot)
      [ -n "$INPUT_TEXT" ] || { TOAST="move cancelled (no slot)"; return; }
      do_teleport "$INPUT_TEXT"
      ;;
  esac
}

input_cancel() {
  INPUT_MODE=""       # Esc simply leaves the input mode (rename/slot discard the buffer)
}

# handle_input_key — one key while an input mode is active. Printable bytes
# append, backspace deletes, Enter commits, Esc cancels; arrow/CSI sequences are
# swallowed (no-ops) so a stray arrow can't corrupt the buffer.
handle_input_key() {
  local key=$1 b2 cc seqi j1 j2 j3
  case "$key" in
    $'\x1b')
      # NB: integer -t only — bash 3.2 (the live /bin/bash) rejects fractional
      # timeouts with an ERROR, so `-t 0.4` returned instantly and the rest of
      # the escape sequence leaked into the main loop, where a mouse event's
      # payload digits (`0;30;22M`) fired the digit-jump path and CLOSED the
      # popup. Same leak on newer bash: the old swallow only drained `[0-9]…`
      # sequences, never SGR mouse (`<…M`). Swallow EVERY CSI to its final byte.
      IFS= read -rsn1 -t 1 b2 < "$TTY_IN" || b2=""
      if [ "$b2" = "[" ]; then
        seqi=""
        while IFS= read -rsn1 -t 1 cc < "$TTY_IN"; do
          case "$cc" in [A-Za-z~]) break ;; *) seqi="$seqi$cc" ;; esac
        done
        # legacy X10 mouse (\e[M + 3 raw payload bytes) → drain the payload
        if [ "$cc" = M ] && [ -z "$seqi" ]; then
          IFS= read -rsn1 -t 1 j1 < "$TTY_IN"; IFS= read -rsn1 -t 1 j2 < "$TTY_IN"; IFS= read -rsn1 -t 1 j3 < "$TTY_IN"
          input_cancel; return
        fi
        # a tap (SGR press) while typing = CANCEL the input — touch users have
        # no reachable Esc; wheel/release/arrows are swallowed silently. In the
        # movepick picker the tap is the SELECTION, so it routes to hit-testing.
        case "${seqi}${cc}" in
          '<0;'*M)
            if [ "$INPUT_MODE" = movepick ]; then
              j1=${seqi#<0;}; movepick_press "${j1##*;}" "${j1%%;*}"
            else input_cancel; fi ;;
        esac
        return
      fi
      input_cancel ;;                             # bare Esc → cancel
    $'\r'|$'\n'|'') input_commit ;;
    $'\x7f'|$'\x08') INPUT_TEXT="${INPUT_TEXT%?}" ;;   # backspace
    *)
      if [ "$INPUT_MODE" = slot ]; then
        case "$key" in [0-9]) INPUT_TEXT="${INPUT_TEXT}${key}" ;; esac   # slot: digits only
      elif [ "$INPUT_MODE" = movepick ]; then
        :                                                # picker: keys swallowed (Esc/⏎/tap act)
      else
        case "$key" in [[:print:]]) INPUT_TEXT="${INPUT_TEXT}${key}" ;; esac
      fi ;;
  esac
}

# re-sort in place, keeping the cursor on the same window
cycle_sort() {
  local keep=${win_order[sel]}
  case "$sort_mode" in
    index) sort_mode=attn ;;
    attn)  sort_mode=name ;;
    *)     sort_mode=index ;;
  esac
  mkdir -p "${SORTFILE%/*}" 2>/dev/null
  printf '%s\n' "$sort_mode" > "$SORTFILE" 2>/dev/null
  build_model; recalc_scroll
  win_pos "$keep"; sel=$__wp
  move_sel 0
}

# unified mouse press at screen row $1 / col $2:
#   row 1 = chrome (session tabs or [ X ]) · row 2 = header rule (inert) ·
#   rows 3..rows-2 = window rows (dividers tap through to their window) ·
#   rows-1/rows = footer chrome (inert)
press() {
  local y=$1 x=$2 i idx cw p
  [ "$y" -ge 1 ] 2>/dev/null || return
  # phone: row 1 is the blank top spacer — DELIBERATELY inert (it exists to
  # keep header taps clear of Moshi's own chrome at the screen edge), and the
  # header lives on row 2
  if [ "$PHONE" = 1 ] && [ "$y" -le 1 ]; then return; fi
  if [ "$y" -le $(( 1 + PHONE )) ]; then
    cw=12; [ "$PHONE" = 1 ] && cw=6
    [ "$x" -ge $(( cols - cw )) ] 2>/dev/null && exit 0           # [ ❌ CLOSE ] / [ ❌ ]
    if [ "$x" -ge "$new_lo" ] 2>/dev/null && [ "$x" -le "$new_hi" ]; then
      do_newwindow; return                                        # [ ➕ NEW ] / [ ➕ ]
    fi
    for (( i=0; i<${#tab_lo[@]}; i++ )); do
      if [ "$x" -ge "${tab_lo[i]}" ] && [ "$x" -le "${tab_hi[i]}" ]; then
        case "${tab_of[i]}" in
          -1) view_session -1 ;;                # phone: < = previous session
          -2) view_session  1 ;;                # phone: > = next session
          -3) FOCUS=body; ACTION=0; CONFIRM=0 ;;   # phone: name tap = into the list
          *)  view_session "=${tab_of[i]}" ;;
        esac
        return
      fi
    done
    return
  fi
  # phone: the pinned action bar (row rows-2) — tap arms + runs (close taps
  # twice through the red confirm, exactly like the wide-mode chips)
  if [ "$PHONE" = 1 ] && [ "$y" = "$abar_row" ]; then
    for i in "${!abar_lo[@]}"; do
      if [ "$x" -ge "${abar_lo[i]}" ] && [ "$x" -le "${abar_hi[i]}" ]; then
        # [ move ] opens the DESTINATION PICKER instead of the bare slot
        # prompt — sessions are tap targets there, slot # still reachable
        if [ "$i" = $(( NACT - 3 )) ]; then CONFIRM=0; FOCUS=body; input_start movepick; return; fi
        [ "$i" != "$ACTION" ] && CONFIRM=0
        FOCUS=body; ACTION=$i; run_action; return
      fi
    done
    return
  fi
  if [ "$y" -ge $(( rows - 1 )) ]; then
    # footer: inert in wide mode; on the phone the DEFAULT footer row carries
    # tap targets (arrays are empty whenever another footer variant rendered)
    if [ "$y" = "$rows" ]; then
      for i in "${!foot_lo[@]}"; do
        if [ "$x" -ge "${foot_lo[i]}" ] && [ "$x" -le "${foot_hi[i]}" ]; then
          case "${foot_verb[i]}" in
            search)  CONFIRM=0; search_enter ;;
            sort)    CONFIRM=0; cycle_sort ;;
            newsess) CONFIRM=0; do_newsession ;;
            help)    CONFIRM=0; help_enter ;;
          esac
          return
        fi
      done
    fi
    return
  fi
  # the selected entry's control chips are directly tappable (arm + run; a tap
  # on close arms the red `close?` confirm, a second tap runs it)
  if [ "$FOCUS" = body ] && [ "$y" = "$selrow_scr" ] && [ "${#chip_lo[@]}" -gt 0 ]; then
    # chip_lo/chip_hi are keyed by LOGICAL action index (may have gaps when
    # session chips are dropped to fit) → iterate set indices, not 0..count.
    for i in "${!chip_lo[@]}"; do
      if [ "$x" -ge "${chip_lo[i]}" ] && [ "$x" -le "${chip_hi[i]}" ]; then
        [ "$i" != "$ACTION" ] && CONFIRM=0
        ACTION=$i; run_action; return
      fi
    done
  fi
  idx=$(( offset + y - 3 - PHONE ))    # phone: body starts a row lower (spacer)
  if [ "$idx" -ge 0 ] && [ "$idx" -lt "$total" ]; then
    if [ "$PHONE" = 1 ]; then
      # two-tap (phone): the first tap SELECTS the entry under the finger (the
      # action bar retargets); a second tap on the already-selected entry opens
      # it. Kills accidental jumps while thumb-scrolling.
      for (( p=0; p<nwin; p++ )); do
        if [ "$idx" -ge "${whead[p]}" ] && \
           [ "$idx" -le $(( p + 1 < nwin ? whead[p+1] - 1 : total - 1 )) ]; then
          if [ "$p" = "$sel" ] && [ "$FOCUS" = body ]; then
            jump_win "${line_win[$idx]}" "${line_sess[$idx]:-$VSESS}"
          else
            FOCUS=body; CONFIRM=0; ACTION=0; sel=$p; move_sel 0
          fi
          return
        fi
      done
      return
    fi
    jump_win "${line_win[$idx]}" "${line_sess[$idx]:-$VSESS}"
  fi
}

# resolve a typed digit (with 01-09 / prefix logic) → open
digit() {
  local d=$1 d2 win
  if [ "$d" = 0 ] || ambiguous "$d"; then
    IFS= read -rsn1 -t 3 d2 < "$TTY_IN" || return
    case "$d2" in [0-9]) win=$((10#${d}${d2}));; *) return;; esac
  else
    win=$d
  fi
  jump_win "$win"
}

# ── init: sessions + first model, cursor on the invoking window ───────────────
load_sessions
if [ "$nsess" -eq 0 ]; then
  printf '\n%sNo tmux sessions found.%s\n' "$ind" "$RESET" > "$TTY_OUT"
  [ -z "$JW_DASH_TEST" ] && read -rsn1 < /dev/tty
  exit 0
fi
build_model; recalc_scroll   # header is rebuilt by draw() (V3)
# MEASURE mode: print the content line count (window rows + recap lines) for the
# launcher's size-to-fit height, then exit. Two variants:
#   =1  (default) — just THIS session's model. Kept for back-compat + tests.
#   =all (P1, 2026-07-08) — the MAX across every Claude-active session, computed
#         in ONE process. The launcher used to re-exec this whole script once per
#         session (serial fork storm on prefix+o); now it calls us once.
if [ -n "$JW_DASH_MEASURE" ]; then
  if [ "$JW_DASH_MEASURE" = all ]; then
    __mx=$total; __save=$VSESS
    for (( __i=0; __i<nsess; __i++ )); do
      VSESS=${SESS_LIST[__i]}; build_model
      [ "$total" -gt "$__mx" ] && __mx=$total
    done
    VSESS=$__save
    printf '%s\n' "$__mx"
  else
    printf '%s\n' "$total"
  fi
  exit 0
fi
if [ "$nwin" -eq 0 ]; then
  printf '\n%sNo windows found in this session.%s\n' "$ind" "$RESET" > "$TTY_OUT"
  [ -z "$JW_DASH_TEST" ] && read -rsn1 < /dev/tty
  exit 0
fi
win_pos "$CURWIN"; sel=$__wp
move_sel 0   # position the viewport on the initial selection

# ── LIVE RESIZE (2026-07-09) ─────────────────────────────────────────────────
# tmux 3.6 resizes the popup's pty when the client resizes (verified: the iPhone
# keyboard sliding up shrinks the client → the popup pty gets SIGWINCH). bash's
# blocking `read` does NOT return on that signal (and bash 3.2 has no fractional
# `read -t` to poll cheaply), BUT a WINCH trap DOES run immediately, even while
# read is blocked (verified). So we reflow straight from the trap: re-read the
# size, re-derive the layout, rebuild the model (recaps re-wrap to the new
# width), and redraw — no timeout, no loop restructure. Interactive tty only
# (test/measure modes never resize and draw to stdout).
refresh_size() {
  local size r c
  size=$(stty size < /dev/tty 2>/dev/null)
  r=${size%% *}; c=${size##* }
  { [ -n "$c" ] && [ "$c" -gt 0 ]; } 2>/dev/null && cols=$c
  { [ -n "$r" ] && [ "$r" -gt 0 ]; } 2>/dev/null && rows=$r
  apply_dims
  build_model; recalc_scroll; move_sel 0
  draw
}
[ -z "$JW_DASH_TEST" ] && [ -z "$JW_DASH_MEASURE" ] && trap 'refresh_size' WINCH

# ── input debug logger (2026-07-19) ──────────────────────────────────────────
# `touch ~/.config/tmux-jw/dashboard-debug` (or JW_DASH_DEBUG=1) → every raw
# key byte / CSI sequence / mouse event appends to /tmp/tmux-jw-dash-debug.log,
# for discovering what a terminal actually sends (e.g. does a Moshi horizontal
# swipe emit wheel-left/right, SGR btn 66/67?). Delete the flag file to stop.
DBGF=""
{ [ -n "$JW_DASH_DEBUG" ] || [ -e "$HOME/.config/tmux-jw/dashboard-debug" ]; } && DBGF=/tmp/tmux-jw-dash-debug.log
dbg() { [ -n "$DBGF" ] || return 0; printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >> "$DBGF"; }
dbg "── open cols=$cols rows=$rows phone=${PHONE:-0} term=$TERM"

while :; do
  draw
  IFS= read -rsn1 key < "$TTY_IN" || break
  dbg "key $(printf '%q' "$key")"
  # inline text entry (rename / slot) swallows ALL keys until it commits/cancels
  if [ -n "$INPUT_MODE" ]; then handle_input_key "$key"; continue; fi
  TOAST=""                          # a pending action toast lives exactly one keypress
  if [ "$key" = $'\x1b' ]; then
    IFS= read -rsn1 -t 1 b2 < "$TTY_IN" || b2=""        # EOF/timeout → treat as bare Esc
    # bare Esc: leave tmux-help / global search if active, else close the popup
    [ "$b2" != "[" ] && { [ "$HELP_ON" = 1 ] && { help_exit; continue; }; [ "$SEARCH_ON" = 1 ] && { search_exit; continue; }; exit 0; }
    IFS= read -rsn1 -t 1 b3 < "$TTY_IN" || continue
    # tmux-help mode: ↑↓←→ move the SELECTION over the 2-col grid (↑↓ = same
    # column, ←→ = adjacent entry; scrolls to follow), PgUp/PgDn page, CSI-u
    # Enter runs the selected binding. Mouse (M / <) falls through to the
    # shared block below, which routes the wheel to help_scroll and a tap to
    # help_press (entry = run it, chrome = dismiss).
    if [ "$HELP_ON" = 1 ]; then
      case "$b3" in
        A) help_move -2; continue ;;
        B) help_move  2; continue ;;
        C) help_move  1; continue ;;
        D) help_move -1; continue ;;
        [0-9]) seq="$b3"
               while IFS= read -rsn1 -t 1 cc < "$TTY_IN"; do seq="$seq$cc"; case "$cc" in [A-Za-z~]) break ;; esac; done
               case "$seq" in
                 13u|10u|13\;*u|10\;*u) help_run ;;
                 5~) help_move "-$(( view_h * 2 ))" ;; 6~) help_move "$(( view_h * 2 ))" ;;
               esac
               continue ;;
        M|'<') : ;;                    # mouse → shared block below
        *) continue ;;
      esac
    fi
    case "$b3" in
      A) k_up;     continue ;;      # ↑ (list: up / off row 1 → bar)
      B) k_down;   continue ;;      # ↓ (bar → row 1)
      C) k_right;  continue ;;      # → (list: arm action · bar: next session)
      D) k_left;   continue ;;      # ← (list: arm action · bar: prev session)
      Z) k_tab -1; continue ;;      # Shift-Tab (CSI Z) → prev session, commit
      M)   # legacy X10 mouse: \e[M <btn+32> <x+32> <y+32>  (3 raw bytes)
        IFS= read -rsn1 -t 1 cb < "$TTY_IN"; IFS= read -rsn1 -t 1 cx < "$TTY_IN"; IFS= read -rsn1 -t 1 cy < "$TTY_IN"
        printf -v b '%d' "'$cb"; printf -v x '%d' "'$cx"; printf -v y '%d' "'$cy"
        btn=$(( (b - 32) & 3 ))
        dbg "x10 b=$b btn=$btn x=$(( x - 32 )) y=$(( y - 32 ))"
        case "$(( (b - 32) & 64 ))" in
          64) if [ "$HELP_ON" = 1 ]; then [ "$btn" = 0 ] && help_scroll -3 || help_scroll 3
              else case "$btn" in
                     0) scroll -3 ;; 1) scroll 3 ;;
                     2) view_session -1 ;; 3) view_session 1 ;;   # horizontal wheel ←/→
                   esac; fi; continue ;;
        esac
        [ "$HELP_ON" = 1 ] && { [ "$btn" = 0 ] && help_press "$(( y - 32 ))" "$(( x - 32 ))"; continue; }
        [ "$btn" = 0 ] && press "$(( y - 32 ))" "$(( x - 32 ))"
        continue ;;
      '<') # SGR mouse: \e[<btn;x;yM  (press) / m (release)
        seq=""
        while IFS= read -rsn1 -t 1 c < "$TTY_IN"; do case "$c" in M|m) break ;; *) seq="$seq$c" ;; esac; done
        btn=${seq%%;*}; rest=${seq#*;}; mx=${rest%%;*}; my=${rest##*;}
        dbg "sgr btn=$btn x=$mx y=$my ${c}"
        if [ "$HELP_ON" = 1 ]; then      # in help: wheel scrolls, a tap runs/dismisses
          case "$btn" in
            64) help_scroll -3 ;; 65) help_scroll 3 ;;
            0)  [ "$c" = "M" ] && help_press "$my" "$mx" ;;
          esac; continue
        fi
        case "$btn" in
          64) scroll -3; continue ;;
          65) scroll  3; continue ;;
          66) view_session -1; continue ;;   # horizontal wheel ← → prev session
          67) view_session  1; continue ;;   # horizontal wheel → → next session
          0)  [ "$c" = "M" ] && press "$my" "$mx"; continue ;;
          *)  continue ;;
        esac ;;
      [0-9]) # CSI sequence with numeric params: a CSI-u key (e.g. Enter = 13u when
             # extended-keys is on) or a modified arrow (e.g. \e[1;5A). Read through
             # the final letter, then map.
        seq="$b3"
        while IFS= read -rsn1 -t 1 cc < "$TTY_IN"; do seq="$seq$cc"; case "$cc" in [A-Za-z~]) break ;; esac; done
        dbg "csi $seq"
        case "$seq" in
          13u|10u|13\;*u|10\;*u) k_enter ;;   # CSI-u Enter → run armed action
          *A) k_up ;;
          *B) k_down ;;
          *C) k_right ;;
          *D) k_left ;;
          *) : ;;
        esac
        continue ;;
      *) continue ;;
    esac
  fi
  # ── R3 global search: printable keys edit the query; arrows/Enter (handled in
  # the CSI block above) still navigate results / open. Letters do NOT act as
  # accelerators while searching. ──
  if [ "$SEARCH_ON" = 1 ]; then
    case "$key" in
      $'\r'|$'\n'|'') k_enter ;;                       # open the selected result
      # backspace edits the query but STAYS in search (empty query = all windows);
      # only Esc leaves search mode (handled in the Esc block above).
      $'\x7f'|$'\x08') SEARCH_Q="${SEARCH_Q%?}"; search_rebuild ;;
      $'\t') : ;;                                       # Tab is inert in search
      [[:print:]]) SEARCH_Q="${SEARCH_Q}${key}"; search_rebuild ;;
      *) : ;;
    esac
    continue
  fi
  # ── tmux-help: printable keys edit the filter query; ↑↓←→/wheel move+scroll
  # (handled in the CSI/mouse blocks above); ⏎ RUNS the selected binding; Esc
  # closes (bare-Esc block above). PERSISTS until Esc, like search —
  # backspacing to empty just shows all bindings. ──
  if [ "$HELP_ON" = 1 ]; then
    case "$key" in
      $'\x7f'|$'\x08') HELP_Q="${HELP_Q%?}"; HELP_OFF=0; help_filter ;;
      $'\r'|$'\n'|'') help_run ;;                       # ⏎ = run the selected binding
      $'\t') : ;;                                        # Tab inert
      [[:print:]]) HELP_Q="${HELP_Q}${key}"; HELP_OFF=0; help_filter ;;
      *) : ;;
    esac
    continue
  fi
  case "$key" in
    $'\r'|$'\n'|'') k_enter ;;        # Enter → run armed action (open / park|restore)
    $'\t') k_tab 1 ;;                 # Tab → next session, commit into the list
    j) k_down ;;
    k) k_up ;;
    l) k_right ;;                     # contextual (list: action · bar: session)
    h) k_left ;;
    t) CONFIRM=0; cycle_sort ;;       # (t) cycle sort mode (was s; freed s for new session)
    s) CONFIRM=0; do_newsession ;;    # (s) create a brand-new blank tmux session cc-mmdd
    n) accel $(( NACT - 4 )) ;;       # (n)ew session accelerator
    m) accel $(( NACT - 3 )) ;;       # (m)ove to slot accelerator
    r) accel $(( NACT - 2 )) ;;       # (r)ename accelerator
    c) accel $(( NACT - 1 )) ;;       # (c)lose accelerator (two-step confirm)
    .) CONFIRM=0; search_enter ;;     # global cross-session type-ahead search
    '?') CONFIRM=0; help_enter ;;     # (?) tmux key-binding help (filterable, 2-col)
    ' '|f) CONFIRM=0; [ "$FOCUS" = body ] && { move_sel "$total"; ACTION=0; } ;;    # → last window
    b)     CONFIRM=0; [ "$FOCUS" = body ] && { move_sel "-$total"; ACTION=0; } ;;   # → first window
    [0-9]) CONFIRM=0; digit "$key" ;;
    q) exit 0 ;;
    *) CONFIRM=0 ;;                   # unknown keys: no-op (and cancel a pending close?)
  esac
done
exit 0
