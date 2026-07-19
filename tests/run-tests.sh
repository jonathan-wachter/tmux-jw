#!/bin/bash
# tests/run-tests.sh — end-to-end regression tests for the cockpit dashboard and
# the boxbar renderer, driven against a SCRATCH tmux server (socket "jwdash") so
# nothing touches the real session. Safe to run any time:  bash tests/run-tests.sh
#
# How the harness works (the whole trick is dependency injection):
#   • dashboard: JW_DASH_TEST=1 makes tmux-claude-dashboard.sh read raw key bytes
#     from STDIN and draw frames to STDOUT (no /dev/tty, no stty), take geometry
#     from JW_DASH_COLS/ROWS, and call tmux via $JW_TMUX → we point it at the
#     scratch server and pipe it REAL escape sequences (arrows, SGR mouse, Enter).
#     Every open also prints "ACTION open <sess>:<win>" for assertions.
#   • bar renderer: it calls bare `tmux`, so we shim PATH with a tmux wrapper that
#     adds "-L jwdash", and isolate its cache with a private TMPDIR.
#
# Scratch layout built below:
#   cc-alpha : 1=alfa-one (idle) · 2=alfa-two (working 🤖 + recap) · 3=alfa-three (needs_you 🔴)
#   cc-beta  : 1=beta-one (idle)
#   cc-parked: 1=parked-one (done ✅)

set -u
cd "$(dirname "$0")/.."             # repo root, so hooks/ paths work
REPO=$PWD
SOCK=jwdash
# tmux binary under test: env override → local tmux-jw.config → first on PATH
[ -r "$REPO/tmux-jw.config" ] && . "$REPO/tmux-jw.config"
TMUXB=${JW_TEST_TMUX:-${TMUXJW_TMUX_BIN:-$(command -v tmux)}}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tmux-jw-tests.XXXXXX")
export TMUXJW_PROJ_MARKER=1   # pin the P? badge ON — machines without the assoc dir default it off
SHIM="$WORK/bin"; mkdir -p "$SHIM"
printf '#!/bin/bash\nexec %s -L %s "$@"\n' "$TMUXB" "$SOCK" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"

# we run INSIDE a real tmux session; unset TMUX so the scratch server can create
# sessions without the "nested sessions" guard kicking in.
unset TMUX

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ✅ %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  ❌ %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

cleanup() { "$TMUXB" -L "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

strip_ansi() { sed $'s/\x1b\\[[0-9;?<]*[a-zA-Z]//g'; }
# last frame only: frames start with ESC[H ESC[2J — keep text after the final one
last_frame() { awk 'BEGIN{RS="\033\\[H\033\\[2J"} {f=$0} END{print f}' | strip_ansi; }
# raw (ANSI-KEPT) last frame — for style assertions (V2 bracket highlight, V3
# header-focus blue) that the stripped frame is structurally blind to
last_frame_raw() { awk 'BEGIN{RS="\033\\[H\033\\[2J"} {f=$0} END{printf "%s", f}'; }
TABFOC_SEQ=$'\033[48;2;57;69;83m\033[38;2;255;255;255m'   # focused-tab slate fill (from dashboard.sh)
MUTED_SEQ=$'\033[38;2;93;100;112m'                        # idle-chip / summary-text mid-gray
REV_SEQ=$'\033[7m'; BOLD_SEQ=$'\033[1m'; RST_SEQ=$'\033[0m'

# dash <session> <curwin> <keys-printf-fmt> — run the dashboard headlessly
dash() {
  printf "$3" | JW_DASH_TEST=1 JW_DASH_COLS=110 JW_DASH_ROWS=24 \
    JW_TMUX="$TMUXB -L $SOCK" TMPDIR="$WORK" JW_DASH_PARKING=cc-parked \
    bash hooks/tmux-claude-dashboard.sh "$1" "$2" 2>>"$WORK/dash.err"
}

echo "── 0. syntax checks ──────────────────────────────────────────────"
check "dashboard.sh parses (bash -n)"      'bash -n hooks/tmux-claude-dashboard.sh'
check "bar-render.sh parses (bash -n)"     'bash -n hooks/tmux-claude-bar-render.sh'
check "dashboard-open.sh parses (bash -n)" 'bash -n hooks/tmux-claude-dashboard-open.sh'

echo "── scratch server ────────────────────────────────────────────────"
"$TMUXB" -L "$SOCK" kill-server 2>/dev/null
# minimal conf: match the real setup's 1-based window numbering (-f /dev/null
# would give base-index 0 and skew every index assertion below)
printf 'set -g base-index 1\n' > "$WORK/tmux.conf"
"$TMUXB" -L "$SOCK" -f "$WORK/tmux.conf" new-session -d -s cc-alpha -n alfa-one -x 200 -y 50 || { echo "FATAL: no scratch server"; exit 1; }
"$TMUXB" -L "$SOCK" new-window  -t cc-alpha -n alfa-two
"$TMUXB" -L "$SOCK" new-window  -t cc-alpha -n alfa-three
"$TMUXB" -L "$SOCK" new-session -d -s cc-beta   -n beta-one   -x 200 -y 50
"$TMUXB" -L "$SOCK" new-session -d -s cc-parked -n parked-one -x 200 -y 50
# cc-beta has no @ccstate — give it a @ccname so the dashboard's Claude-active
# session filter (live CLI OR @ccstate OR @ccname) keeps it visible in tests
"$TMUXB" -L "$SOCK" set-option -w -t cc-beta:1 @ccname beta-one
"$TMUXB" -L "$SOCK" set-option -w -t cc-alpha:2 @ccstate working
# alpha:2 gets a project association (pure emoji); alpha:3 stays
# unassociated (composite emoji·P? marker) — covers both renders
"$TMUXB" -L "$SOCK" set-option -w -t cc-alpha:2 @ccproj nannies
"$TMUXB" -L "$SOCK" set-option -w -t cc-alpha:2 @ccrecap 'We built the token tracker and it is live. Next action: get your go to build the value-ledger.'
"$TMUXB" -L "$SOCK" set-option -w -t cc-alpha:3 @ccstate needs_you
"$TMUXB" -L "$SOCK" set-option -w -t cc-parked:1 @ccstate done
"$TMUXB" -L "$SOCK" select-window -t cc-alpha:1
ok "scratch server up (3 sessions)"

echo "── 1. dashboard: first frame ─────────────────────────────────────"
f=$(dash cc-alpha 1 '' | last_frame)
check "session tabs show all 3 capsules"   '[[ "$f" == *"❯ cc-alpha ❮"* && "$f" == *"❯ cc-beta ❮"* && "$f" == *"❯ cc-parked ❮"* ]]'
check "window rows listed"                 '[[ "$f" == *"1) alfa-one"* && "$f" == *"alfa-two"* && "$f" == *"alfa-three"* ]]'
check "recap text rendered"                '[[ "$f" == *"Next action"* ]]'
check "glyph between number and name"      '[[ "$f" == *"2) 🤖 alfa-two"* && "$f" == *"3) 🔴 alfa-three"* ]]'
check "active window bullet on win 1"      '[[ "$f" == *"•"*"1) alfa-one"* ]]'
check "footer hints + sort mode"           '[[ "$f" == *"(t) sort:index"* && "$f" == *"⇥ session"* ]]'
check "footer shows accels + new items"    '[[ "$f" == *"(n)ew"* && "$f" == *"(m)ove"* && "$f" == *"(c)lose"* && "$f" == *"(.) search"* && "$f" == *"(s) new session"* ]]'
check "footer no longer offers / filter"   '[[ "$f" != *"(/) filter"* ]]'
check "header hints present, │-separated"  '[[ "$f" == *"│ ↑↓ move"* && "$f" == *"⇥ session"* ]]'
# dropdown chrome: one flush-left divider-title per entry (v3.1: no ├─┤ frame)
check "entry divider-titles drawn (3)"     '[ "$(printf "%s\n" "$f" | grep -cE "^•?[0-9]+\)")" = 3 ]'
check "selected entry shows chip strip"    '[[ "$f" == *"❯ open ❮"* && "$f" == *"❯ new session ❮"* && "$f" == *"❯ move ❮"* && "$f" == *"❯ rename ❮"* && "$f" == *"❯ close ❮"* ]]'
check "move chips = other CC sessions"     '[[ "$f" == *"❯ cc-beta ❮─❯ cc-parked ❮"* ]]'
# V1: divider titles are flush-left with no leading ├─ and no trailing ┤
check "divider is flush-left (no ├─)"      '[[ "$f" != *"├─"* && "$f" != *"┤"* ]]'
# V1: every divider line (selected w/ chips + unselected) fills EXACTLY cols (110)
dwline() { printf '%s' "$1" | python3 -c '
import sys
wide=set("🤖💬🔴✅🟠📚📺")
print(sum(2 if c in wide else 1 for c in sys.stdin.read()))'; }
selline=$(printf '%s\n' "$f" | grep -E "^•?[0-9]+\).*❯ open ❮" | head -1)
unsline=$(printf '%s\n' "$f" | grep -E "^•?[0-9]+\)" | grep -v "❯ open ❮" | head -1)
check "selected divider width == 110"      '[ "$(dwline "$selline")" = 110 ]'
check "unselected divider width == 110"    '[ "$(dwline "$unsline")" = 110 ]'

echo "── 1c. V2: highlight only INSIDE the ❯ ❮ brackets (raw frame) ─────"
# default frame: cursor on active window 1, so the OPEN chip is armed. Its inner
# ` open ` carries REV+BOLD while the ❯ ❮ brackets stay plain (ambient).
raw=$(dash cc-alpha 1 '' | last_frame_raw)
check "armed 'open' inner is reverse+bold" '[[ "$raw" == *"❯${RST_SEQ}${REV_SEQ}${BOLD_SEQ} open ${RST_SEQ}❮"* ]]'
# idle chips render whole (brackets + inner) in the summary-text mid-gray (MUTED)
check "idle chip is mid-gray, framed"      '[[ "$raw" == *"❯${RST_SEQ}${MUTED_SEQ} cc-beta ${RST_SEQ}${MUTED_SEQ}❮"* ]]'
# change #4: accelerator letter underlined (n of "new session" — idle → mid-gray)
UL_SEQ=$'\033[4m'; ULOFF_SEQ=$'\033[24m'
check "accelerator letter is underlined"   '[[ "$raw" == *"❯${RST_SEQ}${MUTED_SEQ} ${UL_SEQ}n${ULOFF_SEQ}ew session ${RST_SEQ}${MUTED_SEQ}❮"* ]]'
check "no style bleeds onto a bracket"     '[[ "$raw" != *"${REV_SEQ}❯"* && "$raw" != *"❮${REV_SEQ}"* ]]'
# the SELECTED row's window NAME is reverse-highlighted (window 1 = active here,
# so the • marker precedes the reversed title)
check "selected row title is reverse-video" '[[ "$raw" == *"•${REV_SEQ}${BOLD_SEQ}1) "* ]]'

echo "── 1d. V3: session-bar focus slate fill toggles with ↑/↓ (raw frame) ─"
raw=$(dash cc-alpha 1 '' | last_frame_raw)
check "list focus → NO slate fill on tab"  '[[ "$raw" != *"$TABFOC_SEQ"* ]]'
raw=$(dash cc-alpha 1 '\033[A' | last_frame_raw)   # ↑ lifts focus to the bar
check "↑ to bar → slate fill appears"      '[[ "$raw" == *"$TABFOC_SEQ"* ]]'
check "focused tab inner is slate, ❯ plain" '[[ "$raw" == *"❯${TABFOC_SEQ}${BOLD_SEQ} cc-alpha "* ]]'
raw=$(dash cc-alpha 1 '\033[A\033[B' | last_frame_raw)   # ↑ then ↓ back to list
check "↓ back to list → slate fill cleared" '[[ "$raw" != *"$TABFOC_SEQ"* ]]'

echo "── 1b. dashboard: measure mode (size-to-fit probe) ───────────────"
m=$(JW_DASH_MEASURE=1 JW_DASH_COLS=110 JW_TMUX="$TMUXB -L $SOCK" TMPDIR="$WORK" \
    bash hooks/tmux-claude-dashboard.sh cc-alpha 1 2>>"$WORK/dash.err")
# cc-alpha: 3 divider-title rows + ~1 recap line ≈ 4-8
check "measure returns sane line count"    '[ "$m" -ge 4 ] 2>/dev/null && [ "$m" -le 8 ]'

echo "── 1e. P1: JW_DASH_MEASURE=all = MAX over sessions in one process ─"
meas() { JW_DASH_MEASURE=$1 JW_DASH_COLS=110 JW_TMUX="$TMUXB -L $SOCK" TMPDIR="$WORK" \
         bash hooks/tmux-claude-dashboard.sh "$2" 1 2>>"$WORK/dash.err"; }
m_all=$(meas all cc-alpha)
m_a=$(meas 1 cc-alpha); m_b=$(meas 1 cc-beta); m_p=$(meas 1 cc-parked)
m_max=$m_a; [ "$m_b" -gt "$m_max" ] && m_max=$m_b; [ "$m_p" -gt "$m_max" ] && m_max=$m_p
check "measure=all equals max of per-session" '[ "$m_all" = "$m_max" ]'

echo "── 2. dashboard: ↓ + Enter opens window 2 ────────────────────────"
out=$(dash cc-alpha 1 '\033[B\r')
check "ACTION reports cc-alpha:2"          '[[ "$out" == *"ACTION open cc-alpha:2"* ]]'
aw=$("$TMUXB" -L "$SOCK" display-message -t cc-alpha -p '#{window_index}')
check "scratch server active window is 2"  '[ "$aw" = 2 ]'
"$TMUXB" -L "$SOCK" select-window -t cc-alpha:1

echo "── 3. dashboard: Tab switches session + commits, Enter opens across ─"
out=$(dash cc-alpha 1 '\t\r')              # Tab → commit to cc-beta (active win), Enter opens
check "Tab+Enter opens cc-beta:1"          '[[ "$out" == *"ACTION open cc-beta:1"* ]]'
out=$(dash cc-alpha 1 '\t')                # Tab then EOF: viewing beta, no open
f=$(printf '%s' "$out" | last_frame)
check "Tab views beta windows"             '[[ "$f" == *"1) beta-one"* ]]'
check "no ACTION on a mere Tab commit"     '[[ "$out" != *"ACTION"* ]]'

echo "── 2b. dashboard: selecting a recap row shows recap AND chips (no hide) ─"
out=$(dash cc-alpha 1 '\033[B')            # ↓ to row 2 (alfa-two, has a recap), EOF
f=$(printf '%s' "$out" | last_frame)
check "selected row keeps its recap text"  '[[ "$f" == *"token tracker"* ]]'
check "selected divider carries the chips" 'printf "%s\n" "$f" | grep "alfa-two" | grep -q "❯ open ❮"'

echo "── 3b. dashboard: ↑ to session BAR, ←/→ browse, ↓ back to row 1 ───"
out=$(dash cc-alpha 1 '\033[A\033[C')      # ↑ to bar, → next session (cc-beta), EOF
f=$(printf '%s' "$out" | last_frame)
check "bar → views next session"           '[[ "$f" == *"1) beta-one"* ]]'
check "bar focus footer shown"             '[[ "$f" == *"↓ into list"* ]]'
check "no ACTION browsing on the bar"      '[[ "$out" != *"ACTION"* ]]'
# ← off the first tab lands on the [ ➕ NEW ] stop first (2026-07-16), then
# wraps backward through the tabs — so cc-parked is now TWO ← away.
out=$(dash cc-alpha 1 '\033[A\033[D')      # ↑ to bar, ← onto the NEW stop
f=$(printf '%s' "$out" | last_frame)
check "bar ← lands on [ ➕ NEW ] stop"      '[[ "$f" == *"⏎ new window in "*"cc-alpha"* && "$out" != *"ACTION"* ]]'
out=$(dash cc-alpha 1 '\033[A\033[D\033[D') # ↑ to bar, ←← wraps past NEW to cc-parked
f=$(printf '%s' "$out" | last_frame)
check "bar ←← wraps to cc-parked"          '[[ "$f" == *"1) ✅ parked-one"* ]]'
out=$(dash cc-alpha 1 '\033[A\033[D\r')    # ↑, ← onto NEW, ⏎ → new window in cc-alpha
check "⏎ on NEW stop emits ACTION newwindow" '[[ "$out" == *"ACTION newwindow cc-alpha:"* ]]'
nwidx=$(printf '%s' "$out" | sed -n 's/.*ACTION newwindow cc-alpha:\([0-9]*\).*/\1/p')
[ -n "$nwidx" ] && "$TMUXB" -L "$SOCK" kill-window -t "cc-alpha:$nwidx" 2>/dev/null
out=$(dash cc-alpha 1 '\033[A\033[B\r')    # ↑ to bar, ↓ into list (row 1), Enter → open row 1
check "bar ↓ lands on row 1, Enter opens"  '[[ "$out" == *"ACTION open cc-alpha:1"* ]]'

echo "── 4. dashboard: typed digit opens that window ───────────────────"
out=$(dash cc-alpha 1 '3')
check "digit 3 → ACTION cc-alpha:3"        '[[ "$out" == *"ACTION open cc-alpha:3"* ]]'
"$TMUXB" -L "$SOCK" select-window -t cc-alpha:1

echo "── 5. dashboard: t cycles sort (attn puts 🔴 first) ──────────────"
out=$(dash cc-alpha 1 't')
f=$(printf '%s' "$out" | last_frame)
order=$(printf '%s\n' "$f" | grep -oE '^•?[0-9]+\)' | tr -dc '0-9\n' | tr '\n' ' ')
check "attn order is 3 2 1"                '[ "$order" = "3 2 1 " ]'
check "footer shows sort:attn"             '[[ "$f" == *"(t) sort:attn"* ]]'
out=$(dash cc-alpha 1 't')                 # sticky file → next open starts at attn, t → name
f=$(printf '%s' "$out" | last_frame)
check "sort mode sticky across opens"      '[[ "$f" == *"(t) sort:name"* ]]'
rm -f "$WORK/tmux-claude-bar/dash.sort"

echo "── 5a2. (s) new session: creates a blank cc-mmdd tmux session ─────"
mmdd=$(date +%m%d)
out=$(dash cc-alpha 1 's')
check "s emits ACTION newsession cc-mmdd"  '[[ "$out" == *"ACTION newsession cc-${mmdd}"* ]]'
# the session actually exists on the scratch server, with a plain shell window
newsess=$(printf '%s\n' "$out" | grep -oE 'ACTION newsession [^ ]+' | awk '{print $3}')
check "the new session exists"             '"$TMUXB" -L "$SOCK" has-session -t "=$newsess" 2>/dev/null'
check "new session is a blank single win"  '[ "$("$TMUXB" -L "$SOCK" list-windows -t "$newsess" -F x 2>/dev/null | wc -l | tr -d " ")" = 1 ]'
# a second (s) on a same-day collision suffixes -2, never fails
out=$(dash cc-alpha 1 's')
sess2=$(printf '%s\n' "$out" | grep -oE 'ACTION newsession [^ ]+' | awk '{print $3}')
check "same-day collision suffixes"        '[ "$sess2" != "$newsess" ] && [[ "$sess2" == *"cc-${mmdd}-"* ]]'
"$TMUXB" -L "$SOCK" kill-session -t "$newsess" 2>/dev/null
"$TMUXB" -L "$SOCK" kill-session -t "$sess2" 2>/dev/null

echo "── 5a3. (?) tmux help: 2-col bindings, type-ahead filter, Esc ─────"
# ? opens the live key-binding reference (from `tmux list-keys -N -T prefix`).
# The help derives the REAL prefix; this scratch server runs -f minimal.conf so
# its prefix is the tmux default (C-b), while production sources ~/.tmux.conf
# (C-k). Query it rather than hardcoding, exactly as the feature does.
pfx=$("$TMUXB" -L "$SOCK" show-options -gv prefix 2>/dev/null); [ -n "$pfx" ] || pfx=C-b
f=$(dash cc-alpha 1 '?' | last_frame)
check "help title shows the prefix"        '[[ "$f" == *"tmux key bindings — prefix ${pfx}"* ]]'
check "help lists a known binding"         '[[ "$f" == *"${pfx} c"*"Create a new window"* ]]'
check "help renders two columns on a row"  '[[ "$f" == *"${pfx} Space"*"${pfx} !"* ]]'
check "help footer shows count + hint"     '[[ "$f" == *"type to filter"* && "$f" == *"Esc close"* ]]'
# type-ahead: "window" narrows to only window-related bindings, drops the rest
f=$(dash cc-alpha 1 '?window' | last_frame)
check "help filter keeps matches"          '[[ "$f" == *"Create a new window"* ]]'
check "help filter drops non-matches"      '[[ "$f" != *"Select next layout"* ]]'
check "help filter is case-insensitive"    '[[ "$(dash cc-alpha 1 "?WINDOW" | last_frame)" == *"Create a new window"* ]]'
# zero matches → notice, no crash
f=$(dash cc-alpha 1 '?zzqq' | last_frame)
check "help no-match shows a notice"       '[[ "$f" == *'"'"'no binding matches "zzqq"'"'"'* ]]'
# backspace stays in help (empty query = all bindings); only Esc exits
f=$(dash cc-alpha 1 '?w\177' | last_frame)
check "help backspace-to-empty stays"      '[[ "$f" == *"tmux key bindings"* ]]'
f=$(dash cc-alpha 1 '?window\033' | last_frame)
check "help Esc returns to the list"       '[[ "$f" == *"❯ new session ❮"* && "$f" != *"tmux key bindings"* ]]'
# ↓ arrow scrolls when the list overflows a short popup
short() { printf "$1" | JW_DASH_TEST=1 JW_DASH_COLS=120 JW_DASH_ROWS=12 \
  JW_TMUX="$TMUXB -L $SOCK" TMPDIR="$WORK" JW_DASH_PARKING=cc-parked \
  bash hooks/tmux-claude-dashboard.sh cc-alpha 1 2>>"$WORK/dash.err" | last_frame; }
# ↓ moves the SELECTION (2026-07-16); the list scrolls once the selection
# passes the bottom of a short popup (view_h = 8 here → 10 ↓s force a scroll)
top0=$(short '?'            | sed -n '3p')
top10=$(short '?\033[B\033[B\033[B\033[B\033[B\033[B\033[B\033[B\033[B\033[B' | sed -n '3p')
check "help ↓ selection scrolls the list"  '[ "$top0" != "$top10" ] && [[ "$top0" == *"${pfx} Space"* ]]'
# the selection is reverse-video highlighted; ⏎ RUNS the selected binding
hraw=$(dash cc-alpha 1 '?' | last_frame_raw)
check "help selection is highlighted"      '[[ "$hraw" == *"${REV_SEQ}${pfx} "* ]]'
out=$(dash cc-alpha 1 '?\r')
check "help ⏎ emits ACTION helprun"        '[[ "$out" == *"ACTION helprun "* ]]'
out=$(dash cc-alpha 1 '?\033[B\r')
check "help ↓⏎ runs the third entry"       '[[ "$out" == *"ACTION helprun "* ]]'
# footer of the NORMAL view now advertises (?) tmux help (render wide so the
# full accelerator row fits without truncation)
f=$(printf '' | JW_DASH_TEST=1 JW_DASH_COLS=150 JW_DASH_ROWS=24 \
  JW_TMUX="$TMUXB -L $SOCK" TMPDIR="$WORK" JW_DASH_PARKING=cc-parked \
  bash hooks/tmux-claude-dashboard.sh cc-alpha 1 2>>"$WORK/dash.err" | last_frame)
check "footer advertises (?) tmux help"    '[[ "$f" == *"(?) tmux help"* ]]'

echo "── 5b. / no longer filters (command removed) ─────────────────────"
# `/` is a plain no-op now — send it ALONE (a trailing letter like 't' would hit
# the real keybindings, e.g. cycle_sort, and pollute the shared sort state file).
f=$(dash cc-alpha 1 '/' | last_frame)
check "'/' does not enter filter mode"     '[[ "$f" != *"filter: "* ]]'
check "'/' leaves the full list intact"    '[[ "$f" == *"alfa-one"* && "$f" == *"alfa-two"* && "$f" == *"alfa-three"* ]]'

echo "── 6. dashboard: mouse — tab click views, row click opens ────────"
# header: [ ➕ NEW ] zone cols 2-11, │ at 13, tabs from col 15 —
# "❯ cc-alpha ❮" = 15-26 + 2 sep → "❯ cc-beta ❮" starts col 29
out=$(dash cc-alpha 1 '\033[<0;30;1M')
f=$(printf '%s' "$out" | last_frame)
check "SGR click on beta tab views beta"   '[[ "$f" == *"1) beta-one"* && "$out" != *"ACTION"* ]]'
out=$(dash cc-alpha 1 '\033[<0;5;1M')      # tap inside the [ ➕ NEW ] zone
check "tap on [ ➕ NEW ] creates a window"  '[[ "$out" == *"ACTION newwindow cc-alpha:"* ]]'
nwidx=$(printf '%s' "$out" | sed -n 's/.*ACTION newwindow cc-alpha:\([0-9]*\).*/\1/p')
[ -n "$nwidx" ] && "$TMUXB" -L "$SOCK" kill-window -t "cc-alpha:$nwidx" 2>/dev/null
out=$(dash cc-alpha 1 '\033[<0;5;3M')      # row 3 = first content line = window 1
check "SGR click on row 1 opens win 1"     '[[ "$out" == *"ACTION open cc-alpha:1"* ]]'
out=$(dash cc-alpha 1 '\033[<0;5;2M')      # row 2 = header rule = inert chrome
check "click on header rule is a no-op"    '[[ "$out" != *"ACTION"* ]]'
out=$(dash cc-alpha 1 '\033[<0;109;1M')    # top-right [ ❌ CLOSE ] zone (col ≥ cols-12=98)
check "[ ❌ CLOSE ] click closes, no ACTION" '[[ "$out" != *"ACTION"* ]]'

echo "── 7. dashboard: q / Esc close, unknown key is a no-op ───────────"
out=$(dash cc-alpha 1 'q')
check "q closes cleanly"                   '[ $? = 0 ] && [[ "$out" != *"ACTION"* ]]'
out=$(dash cc-alpha 1 'zzz\033[B\r')       # unknown keys ignored, then ↓+Enter still works
check "unknown keys no-op (then ↓⏎ works)" '[[ "$out" == *"ACTION open cc-alpha:2"* ]]'
"$TMUXB" -L "$SOCK" select-window -t cc-alpha:1

echo "── 8. boxbar builder: alignment + capsules ───────────────────────"
BARW=100
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh --build "$BARW" cc-alpha 1 4242 "cc-alpha|1|${BARW}|4242" 2>>"$WORK/bar.err"
rowdir="$WORK/tmux-claude-bar/cache"
check "3 row caches written"               '[ -r "$rowdir/row0_4242" ] && [ -r "$rowdir/row1_4242" ] && [ -r "$rowdir/row2_4242" ]'
# display width: strip #[...] style/range tokens, count the 5 state emoji as 2 cells
dw() { sed 's/#\[[^]]*\]//g' "$1" | python3 -c '
import sys
s = sys.stdin.read()
wide = "🤖💬🔴✅🟠📚📺"
print(sum(2 if c in wide else 1 for c in s if c != "\n"))'; }
w0=$(dw "$rowdir/row0_4242"); w1=$(dw "$rowdir/row1_4242"); w2=$(dw "$rowdir/row2_4242")
check "row0 width == $BARW (got $w0)"      '[ "$w0" = "$BARW" ]'
check "row2 width == $BARW (got $w2)"      '[ "$w2" = "$BARW" ]'
check "row1 within width (got $w1)"        '[ "$w1" -le "$BARW" ]'
r0=$(sed 's/#\[[^]]*\]//g' "$rowdir/row0_4242")
r1=$(sed 's/#\[[^]]*\]//g' "$rowdir/row1_4242")
r2=$(sed 's/#\[[^]]*\]//g' "$rowdir/row2_4242")
# STACKED left block: name on row0, 📚sessions•📺windows info on row1, GLOBAL
# state counts on row2 (working alfa-two + needs_you alfa-three + done parked;
# 3 sessions on the scratch server, 3 windows in cc-alpha)
check "block row0 = session name"          '[[ "$r0" == *"cc-alpha"* && "$r0" != *"cc-alpha•"* ]]'
check "block row1 = 📚3•📺3 info"           '[[ "$r1" == *"📚3•📺3"* ]]'
check "block row2 = counts"                '[[ "$r2" == *"🤖1•🔴1•✅1"* ]]'
check "block is sessmenu target on 3 rows" 'grep -q "range=user|sessmenu" "$rowdir/row0_4242" && grep -q "range=user|sessmenu" "$rowdir/row1_4242" && grep -q "range=user|sessmenu" "$rowdir/row2_4242"'
check "no corner capsules remain"          '[[ "$r0" != *") cc-alpha ("* ]]'
# glyphs moved OUT of the tab cells into the bottom border, centered per tab
check "tabs are glyph-free (names only)"   '[[ "$r1" == *"alfa-two"* && "$r1" != *"•🤖"* ]]'
# numbers moved OUT of the tab cells too (2026-07-13): framed on the TOP border
check "row1 has no inline N• numbers"      '[[ "$r1" != *"2•alfa-two"* ]]'
check "plain window gets a bare ┤N├ badge" '[[ "$r2" == *"┤1├"* ]]'
check "number leads the framed badge"      '[[ "$r2" == *"┤2·🤖├"* ]]'
check "no-assoc window appends red ·P?"    '[[ "$r2" == *"3·🔴·P?"* ]]'
# with the block on the left, the table's own corners are all visible now
check "borders connect (┌ ┬ ┐ └ ┴ ┘)"      'grep -q "┌" "$rowdir/row0_4242" && grep -q "┬" "$rowdir/row0_4242" && grep -q "┐" "$rowdir/row0_4242" && grep -q "└" "$rowdir/row2_4242" && grep -q "┴" "$rowdir/row2_4242" && grep -q "┘" "$rowdir/row2_4242"'
# full-height tap slices: the border rows carry each window's click range too
# (3 windows in cc-alpha → exactly 3 window| ranges in each border row)
check "border rows are click targets"      '[ "$(grep -o "range=window|" "$rowdir/row0_4242" | wc -l | tr -d " ")" = 3 ] && [ "$(grep -o "range=window|" "$rowdir/row2_4242" | wc -l | tr -d " ")" = 3 ]'

echo "── 9. boxbar: dynamic tab widths (full → ellipsis → floor+scroll) ─"
"$TMUXB" -L "$SOCK" new-window -t cc-beta -n this-is-a-very-long-window-name
"$TMUXB" -L "$SOCK" new-window -t cc-beta -n medium-name-window
bar_beta() {  # <width> <pid> → echoes stripped row1
  PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh --build "$1" cc-beta 1 "$2" "cc-beta|1|$1|$2" 2>>"$WORK/bar.err"
  sed 's/#\[[^]]*\]//g' "$rowdir/row1_$2"
}
r=$(bar_beta 120 5001)
check "wide: full names, no ellipsis"      '[[ "$r" == *"this-is-a-very-long-window-name"* && "$r" != *"…"* ]]'
r=$(bar_beta 70 5002)
check "mid: names capped with ellipsis"    '[[ "$r" == *"…"* && "$r" != *"this-is-a-very-long-window-name"* ]]'
check "mid: all windows visible, no arrows" '[[ "$r" == *"beta-one"* && "$r" != *"◀"* && "$r" != *"▶"* ]]'
w5002=$(dw "$rowdir/row1_5002")
check "mid: row width == 70 (got $w5002)"  '[ "$w5002" = 70 ]'
r=$(bar_beta 44 5003)
check "floor: ellipsis + scroll chrome"    '[[ "$r" == *"…"* ]] && { [[ "$r" == *"◀"* ]] || [[ "$r" == *"▶"* ]]; }'
# standardized chrome: arrows are ALWAYS exactly 1 column (│▶│ / │◀│), the
# residual is absorbed as tab content instead of arrow padding
check "arrow chrome is exactly 1 column"   '[[ "$r" == *"│▶│" ]] && [[ "$r" != *" ▶"* ]] && [[ "$r" != *"▶ "* ]]'
w5003=$(dw "$rowdir/row1_5003")
check "floor: row width == 44 (got $w5003)" '[ "$w5003" = 44 ]'
# pixel-perfect fit: with the fill cell gone, the reclaimed columns let the
# long name render FULL at width 80 and the last tab's │ IS the right edge
r=$(bar_beta 74 5004)
check "tight: slack reaches the right edge" '[[ "$r" == *"this-is-a-very-long-window-name"* && "$r" != *"…"* && "$r" == *"medium-name-window│" ]]'
w5004=$(dw "$rowdir/row1_5004")
check "tight: row width == 74 (got $w5004)" '[ "$w5004" = 74 ]'

echo "── 9b. boxbar: SELECTED tab always shows its full name ────────────"
# window 2 (the 31-char name) is CURRENT at width 60 → its tab renders whole
# while the others shrink to the floor / scroll around it
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh --build 60 cc-beta 2 5005 "cc-beta|2|60|5005" 2>>"$WORK/bar.err"
r=$(sed 's/#\[[^]]*\]//g' "$rowdir/row1_5005")
check "current long name renders FULL"     '[[ "$r" == *"this-is-a-very-long-window-name"* ]]'
check "others still shrunk or scrolled"    '[[ "$r" == *"…"* ]] || [[ "$r" == *"◀"* ]] || [[ "$r" == *"▶"* ]]'
w5005=$(dw "$rowdir/row1_5005")
check "row width == 60 (got $w5005)"       '[ "$w5005" = 60 ]'

echo "── 9c. boxbar: numbers — top border (mode 3) vs inline (mode 1) ──"
# compact 1-line mode has no borders to hold the number, so the builder keeps
# the old N•name cells there; flipping back restores top-border numbers. The
# builder reads @barmode from the (shim-scoped) server; unset defaults to 3.
"$TMUXB" -L "$SOCK" set -g @barmode 1
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh --build 120 cc-beta 1 5006 "cc-beta|1|120|5006" 2>>"$WORK/bar.err"
r=$(sed 's/#\[[^]]*\]//g' "$rowdir/row1_5006")
check "compact mode keeps N• inline"       '[[ "$r" == *"1•beta-one"* ]]'
"$TMUXB" -L "$SOCK" set -g @barmode 3
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh --build 120 cc-beta 1 5007 "cc-beta|1|120|5007" 2>>"$WORK/bar.err"
r=$(sed 's/#\[[^]]*\]//g' "$rowdir/row1_5007")
r2c=$(sed 's/#\[[^]]*\]//g' "$rowdir/row2_5007")
check "mode 3: row1 names only"            '[[ "$r" == *"beta-one"* && "$r" != *"1•beta-one"* ]]'
check "mode 3: number badge on bottom border" '[[ "$r2c" == *"┤1├"* ]]'

echo "── 9c. P4: dirty hook + reader stale-rebuild on rename ────────────"
strip_fmt() { sed 's/#\[[^]]*\]//g' "$1" 2>/dev/null; }
# the dirty hook creates state.dirty (TMUX must be set to pass its in-tmux guard)
rm -f "$WORK/tmux-claude-bar/state.dirty"
TMUX=fake PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-dirty.sh
check "dirty hook creates state.dirty"     '[ -f "$WORK/tmux-claude-bar/state.dirty" ]'
# end-to-end: build a client's rows, rename a window, bump state.dirty, then run
# the READER (not --build) — it must detect staleness and kick a rebuild that
# picks up the new name (proves P4's rename→instant-refresh path)
"$TMUXB" -L "$SOCK" new-session -d -s cc-p4 -n p4-before -x 200 -y 50
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh --build 100 cc-p4 1 7007 "cc-p4|1|100|7007" 2>>"$WORK/bar.err"
check "p4 row built with the old name"     '[[ "$(strip_fmt "$rowdir/row1_7007")" == *"p4-before"* ]]'
sleep 1                                     # ensure state.dirty mtime > seendirty
"$TMUXB" -L "$SOCK" rename-window -t cc-p4:1 p4-after
: > "$WORK/tmux-claude-bar/state.dirty"
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh 1 100 cc-p4 1 7007 >/dev/null 2>>"$WORK/bar.err"
for i in $(seq 1 25); do                    # wait for the detached rebuild
  [[ "$(strip_fmt "$rowdir/row1_7007")" == *"p4-after"* ]] && break; sleep 0.2
done
check "reader rebuild picked up the rename" '[[ "$(strip_fmt "$rowdir/row1_7007")" == *"p4-after"* ]]'
"$TMUXB" -L "$SOCK" kill-session -t cc-p4 2>/dev/null
rm -f "$rowdir"/*_7007 "$WORK/tmux-claude-bar/vp_7007_cc-p4"

echo "── 9e. fractional-mtime gates: same-second dirty + scroll nudge ───"
# (1) @ccstate/dirty transition with NO sleep between build and touch. The old
# whole-second gate (`stat -f %m` + -gt) missed a touch landing in the SAME
# second as the build's snapshot, stranding the stale glyph for 30s; the %Fm
# string-inequality gate must catch it every time.
"$TMUXB" -L "$SOCK" new-session -d -s cc-fm -n fm-before -x 200 -y 50
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh --build 100 cc-fm 1 7107 "cc-fm|1|100|7107" 2>>"$WORK/bar.err"
check "fm row built with the old name"     '[[ "$(strip_fmt "$rowdir/row1_7107")" == *"fm-before"* ]]'
check "seendirty records dirty+vp mtimes"  '[ "$(awk "{print NF}" "$rowdir/seendirty_7107")" = 2 ]'
"$TMUXB" -L "$SOCK" rename-window -t cc-fm:1 fm-after
: > "$WORK/tmux-claude-bar/state.dirty"     # immediately — same second as the build
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh 1 100 cc-fm 1 7107 >/dev/null 2>>"$WORK/bar.err"
for i in $(seq 1 25); do                    # wait for the detached rebuild
  [[ "$(strip_fmt "$rowdir/row1_7107")" == *"fm-after"* ]] && break; sleep 0.2
done
check "same-second dirty touch rebuilds"   '[[ "$(strip_fmt "$rowdir/row1_7107")" == *"fm-after"* ]]'
# (2) external vp scroll nudge right after a rebuild — the old `vp -nt rowfile`
# whole-second test swallowed a tap landing in the rebuild's second (e.g. the
# 2nd of a rapid double-tap). Long names at width 60 force scroll mode.
for w in fm-second-window fm-third-window fm-fourth-window fm-fifth-window; do
  "$TMUXB" -L "$SOCK" new-window -t cc-fm -n "$w"
done
"$TMUXB" -L "$SOCK" select-window -t cc-fm:1
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh --build 60 cc-fm 1 7108 "cc-fm|1|60|7108" 2>>"$WORK/bar.err"
r=$(strip_fmt "$rowdir/row1_7108")
check "scroll fixture starts unscrolled"   '[[ "$r" != *"◀"* && "$r" == *"▶"* ]]'
printf '2 1 60\n' > "$WORK/tmux-claude-bar/vp_7108_cc-fm"   # external nudge, same second
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh 1 60 cc-fm 1 7108 >/dev/null 2>>"$WORK/bar.err"
for i in $(seq 1 25); do
  [[ "$(strip_fmt "$rowdir/row1_7108")" == *"◀"* ]] && break; sleep 0.2
done
check "same-second vp nudge rebuilds"      '[[ "$(strip_fmt "$rowdir/row1_7108")" == *"◀"* ]]'
"$TMUXB" -L "$SOCK" kill-session -t cc-fm 2>/dev/null
rm -f "$rowdir"/*_7107 "$rowdir"/*_7108 "$WORK/tmux-claude-bar"/vp_7107_cc-fm "$WORK/tmux-claude-bar"/vp_7108_cc-fm

echo "── 9d. P5: cache hygiene (prune departed + reap stale locks) ──────"
# stub `tmux list-clients` → one live pid (8888); everything else routes to the
# scratch server (the real prune calls bare tmux via PATH)
PSTUB="$WORK/bin-prune"; mkdir -p "$PSTUB"
printf '#!/bin/bash\nif [ "$1" = list-clients ]; then echo 8888; exit 0; fi\nexec %s -L %s "$@"\n' "$TMUXB" "$SOCK" > "$PSTUB/tmux"
chmod +x "$PSTUB/tmux"
mkdir -p "$rowdir"
OLD='202601010000'   # touch stamp well over PRUNE_AGE (1h) ago
: > "$rowdir/row1_9999";  touch -t "$OLD" "$rowdir/row1_9999"    # departed + old  → prune
: > "$rowdir/hash_9999";  touch -t "$OLD" "$rowdir/hash_9999"    # departed + old  → prune
: > "$rowdir/row1_8888";  touch -t "$OLD" "$rowdir/row1_8888"    # LIVE client     → keep
: > "$rowdir/row1_7777"                                          # departed + FRESH → keep (age guard)
mkdir -p "$rowdir/lock_5555.d"; touch -t "$OLD" "$rowdir/lock_5555.d"   # stale lock → reap
mkdir -p "$rowdir/lock_6666.d"                                          # fresh lock → keep
PATH="$PSTUB:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-prune.sh
check "departed+old file pruned"           '[ ! -e "$rowdir/row1_9999" ] && [ ! -e "$rowdir/hash_9999" ]'
check "live client's file kept"            '[ -e "$rowdir/row1_8888" ]'
check "departed+fresh file kept (age)"     '[ -e "$rowdir/row1_7777" ]'
check "stale lock dir reaped"              '[ ! -e "$rowdir/lock_5555.d" ]'
check "fresh lock dir kept"                '[ -e "$rowdir/lock_6666.d" ]'
# safety: with NO client list, nothing is pruned even if old
printf '#!/bin/bash\nif [ "$1" = list-clients ]; then exit 0; fi\nexec %s -L %s "$@"\n' "$TMUXB" "$SOCK" > "$PSTUB/tmux"
: > "$rowdir/row1_4444"; touch -t "$OLD" "$rowdir/row1_4444"
PATH="$PSTUB:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-prune.sh
check "empty client list prunes nothing"   '[ -e "$rowdir/row1_4444" ]'
rm -f "$rowdir"/*_8888 "$rowdir"/*_7777 "$rowdir"/*_4444; rm -rf "$rowdir/lock_6666.d"

echo "── 10. chip actions END-TO-END (mutating — runs last) ─────────────"
# chip order viewing cc-alpha: 0 open · 1 cc-beta · 2 cc-parked · 3 new · 4 close
# arm-only: → arms the first move chip, but nothing moves without Enter
"$TMUXB" -L "$SOCK" select-window -t cc-alpha:1
out=$(dash cc-alpha 1 '\033[C')            # → arm cc-beta chip, EOF (no run)
check "arming alone emits no ACTION"       '[[ "$out" != *"ACTION"* ]]'

# MOVE to the lot: ↓↓ to window 3, →→ arm cc-parked, Enter runs
out=$(dash cc-alpha 1 '\033[B\033[B\033[C\033[C\r')
check "move emits ACTION move → cc-parked" '[[ "$out" == *"ACTION move cc-alpha:3 cc-parked"* ]]'
f=$(printf '%s' "$out" | last_frame)
check "move toast shown (popup stayed open)" '[[ "$f" == *"moved"* && "$f" == *"alfa-three"* ]]'
moved=$("$TMUXB" -L "$SOCK" list-windows -t cc-parked -F '#{window_name}' | tr '\n' ' ')
check "alfa-three moved into the lot"      '[[ "$moved" == *"alfa-three"* ]]'
gap=$("$TMUXB" -L "$SOCK" list-windows -t cc-alpha -F '#{window_index}' | paste -sd, -)
check "cc-alpha renumbered gap-free (1,2)" '[ "$gap" = "1,2" ]'

# MOVE back out of the lot: viewing cc-parked, chips are 0 open · 1 cc-alpha ·
# 2 cc-beta · 3 new · 4 close → →→ arms cc-beta, Enter runs
li=$("$TMUXB" -L "$SOCK" list-windows -t cc-parked -F '#{window_index} #{window_name}' | awk '$2=="alfa-three"{print $1}')
out=$(dash cc-parked "$li" '\033[C\033[C\r')
check "lot move emits ACTION move → cc-beta" '[[ "$out" == *"ACTION move cc-parked:'"$li"' cc-beta"* ]]'
back=$("$TMUXB" -L "$SOCK" list-windows -t cc-beta -F '#{window_name}' | tr '\n' ' ')
check "alfa-three moved to cc-beta"        '[[ "$back" == *"alfa-three"* ]]'

echo "── 11. new-session chip ──────────────────────────────────────────"
# cc-beta now: 1 beta-one · 2 long-name · 3 medium · 4 alfa-three. Chips there:
# 0 open · 1 cc-alpha · 2 cc-parked · 3 new · 4 rename · 5 close. ↓↓↓ to
# alfa-three, →→→ arm new (index 3), Enter → new session named after the window.
out=$(dash cc-beta 1 '\033[B\033[B\033[B\033[C\033[C\033[C\r')
check "new emits ACTION new"               '[[ "$out" == *"ACTION new cc-beta:4 alfa-three"* ]]'
check "session alfa-three exists"          '"$TMUXB" -L "$SOCK" has-session -t =alfa-three 2>/dev/null'
nw=$("$TMUXB" -L "$SOCK" list-windows -t alfa-three -F '#{window_name}' | tr '\n' ' ')
check "window landed in the new session"   '[[ "$nw" == *"alfa-three"* ]]'

echo "── 12. close chip: red confirm, cancel, graceful close ────────────"
# viewing cc-beta: close is ALWAYS the last chip. 8× → overshoots and CLAMPS on
# it, robust to however many session/rename chips exist at this point in the run.
R8='\033[C\033[C\033[C\033[C\033[C\033[C\033[C\033[C'
out=$(dash cc-beta 1 "$R8")   # arm close, EOF
f=$(printf '%s' "$out" | last_frame)
check "close chip armed shows ❯ close ❮"  '[[ "$f" == *"❯ close ❮"* ]]'
check "arming close emits no ACTION"       '[[ "$out" != *"ACTION"* ]]'
out=$(dash cc-beta 1 "${R8}\r") # + Enter → CONFIRM state, EOF
f=$(printf '%s' "$out" | last_frame)
check "first ⏎ arms close? confirm"        '[[ "$f" == *"❯ close? ❮"* && "$out" != *"ACTION close"* ]]'
check "confirm footer explains"            '[[ "$f" == *"any other key cancels"* ]]'
out=$(dash cc-beta 1 "${R8}\rx") # + x → cancelled
check "other key cancels the confirm"      '[[ "$out" != *"ACTION close"* ]]'
check "beta-one still alive after cancel"  '[ -n "$("$TMUXB" -L "$SOCK" list-windows -t cc-beta -F "#{window_name}" | grep -x beta-one)" ]'
out=$(dash cc-beta 1 "${R8}\r\r") # ⏎⏎ → really close
check "close emits ACTION close cc-beta:1" '[[ "$out" == *"ACTION close cc-beta:1"* ]]'
gone=$("$TMUXB" -L "$SOCK" list-windows -t cc-beta -F '#{window_name}' | grep -cx beta-one)
check "beta-one window is gone"            '[ "$gone" = 0 ]'
f=$(printf '%s' "$out" | last_frame)
check "close toast shown (popup stayed open)" '[[ "$f" == *"closed"* && "$f" == *"beta-one"* ]]'

echo "── 13. P10: rename chip (inline editor, Esc cancel, commit) ───────"
# rename is ALWAYS second-to-last: reach it robustly via close (overshoot) then
# ONE ←. cc-alpha:1 is alfa-one (alfa-three was moved out in §10). Prefill =
# the current name; the footer editor shows it.
"$TMUXB" -L "$SOCK" select-window -t cc-alpha:1
f=$(dash cc-alpha 1 "${R8}\033[D\r" | last_frame)   # arm close→← rename, Enter → editor
check "rename editor prefills current name" '[[ "$f" == *"rename to: alfa-one"* ]]'
# prefill uses the DISPLAYED name (@ccname), not the raw window_name — set an
# @ccname on window 2 (whose window_name is 'alfa-two') and confirm it prefills it
"$TMUXB" -L "$SOCK" set-option -w -t cc-alpha:2 @ccname 'claude-recipes'
f=$(dash cc-alpha 2 "${R8}\033[D\r" | last_frame)
check "rename prefills @ccname, not win_name" '[[ "$f" == *"rename to: claude-recipes"* && "$f" != *"rename to: alfa-two"* ]]'
"$TMUXB" -L "$SOCK" set-option -w -t cc-alpha:2 -u @ccname
# Esc cancels — no mutation
out=$(dash cc-alpha 1 "${R8}\033[D\r\033")
check "Esc cancels rename (no ACTION)"     '[[ "$out" != *"ACTION rename"* ]]'
still=$("$TMUXB" -L "$SOCK" display-message -p -t cc-alpha:1 '#{window_name}')
check "window unchanged after cancel"      '[ "$still" = alfa-one ]'
# type a suffix + Enter → commit
out=$(dash cc-alpha 1 "${R8}\033[D\r-v2\r")
check "rename emits ACTION rename"         '[[ "$out" == *"ACTION rename cc-alpha:1 alfa-one-v2"* ]]'
newn=$("$TMUXB" -L "$SOCK" display-message -p -t cc-alpha:1 '#{window_name}')
check "window actually renamed"            '[ "$newn" = alfa-one-v2 ]'
f=$(printf '%s' "$out" | last_frame)
check "rename toast shown"                 '[[ "$f" == *"renamed"* && "$f" == *"alfa-one-v2"* ]]'

echo "── 13b. R4: chip accelerators n/m/r/c on the selected row ─────────"
"$TMUXB" -L "$SOCK" new-session -d -s cc-acc -n acc1 -x 200 -y 50
"$TMUXB" -L "$SOCK" new-window  -t cc-acc -n acc2
"$TMUXB" -L "$SOCK" set-option -w -t cc-acc:1 @ccname acc1
f=$(dash cc-acc 1 'r' | last_frame); check "r → rename editor"       '[[ "$f" == *"rename to:"* ]]'
f=$(dash cc-acc 1 'm' | last_frame); check "m → move-to-slot editor" '[[ "$f" == *"to slot:"* ]]'
f=$(dash cc-acc 1 'c' | last_frame); check "c → arms close confirm"  '[[ "$f" == *"❯ close? ❮"* ]]'
out=$(dash cc-acc 1 'cc');           check "c c → closes via accel"  '[[ "$out" == *"ACTION close cc-acc:1"* ]]'
# window 1 gone; n on the survivor spins it into a new session
out=$(dash cc-acc 1 'n');            check "n → new session"         '[[ "$out" == *"ACTION new cc-acc:"* ]]'
"$TMUXB" -L "$SOCK" kill-session -t cc-acc 2>/dev/null; "$TMUXB" -L "$SOCK" kill-session -t acc2 2>/dev/null

echo "── 13c. [ ➕ NEW ] header button creates a window in the session ──"
"$TMUXB" -L "$SOCK" new-session -d -s cc-nw -n nw1 -x 200 -y 50
"$TMUXB" -L "$SOCK" set-option -w -t cc-nw:1 @ccname nw1
f=$(dash cc-nw 1 '' | last_frame)
check "[ ➕ NEW ] button shown in header"   '[[ "$f" == *"[ ➕ NEW ]"* ]]'
check "'+ new window' bottom row is gone"  '[[ "$f" != *"+ new window"* ]]'
before=$("$TMUXB" -L "$SOCK" list-windows -t cc-nw -F x | wc -l | tr -d ' ')
out=$(dash cc-nw 1 '\033[<0;5;1M')  # tap the [ ➕ NEW ] zone → create
check "NEW tap emits ACTION newwindow"     '[[ "$out" == *"ACTION newwindow cc-nw:"* ]]'
after=$("$TMUXB" -L "$SOCK" list-windows -t cc-nw -F x | wc -l | tr -d ' ')
check "a window was actually created"      '[ "$after" -gt "$before" ]'
"$TMUXB" -L "$SOCK" kill-session -t cc-nw 2>/dev/null

echo "── 13c2. closing a session's LAST window switches the client out ──"
# killing the only window kills the session; the guard must first move the
# client to the most-recently-active OTHER session instead of dumping it out
# of tmux (test mode: emits the switch as an ACTION line, skips switch-client).
"$TMUXB" -L "$SOCK" new-session -d -s cc-solo -n solo1 -x 200 -y 50
"$TMUXB" -L "$SOCK" set-option -w -t cc-solo:1 @ccname solo1
out=$(dash cc-solo 1 'cc')          # (c)lose accel + confirming c on the ONLY window
check "last-win close emits lastwin-switch" '[[ "$out" == *"ACTION lastwin-switch "* ]]'
check "…and the close itself still runs"    '[[ "$out" == *"ACTION close cc-solo:1"* ]]'
check "…and the session is gone"            '! "$TMUXB" -L "$SOCK" has-session -t =cc-solo 2>/dev/null'

echo "── 13d. R3: '.' global cross-session type-ahead search ───────────"
"$TMUXB" -L "$SOCK" new-session -d -s cc-sa -n zebra-alpha -x 200 -y 50
"$TMUXB" -L "$SOCK" new-session -d -s cc-sb -n zebra-beta  -x 200 -y 50
"$TMUXB" -L "$SOCK" set-option -w -t cc-sa:1 @ccname zebra-alpha
"$TMUXB" -L "$SOCK" set-option -w -t cc-sb:1 @ccname zebra-beta
f=$(dash cc-sa 1 '.zebra' | last_frame)
check "search footer shows the query"      '[[ "$f" == *"search: zebra"* ]]'
check "search found 2 cross-session hits"  '[[ "$f" == *"2 results"* ]]'
# overflow guard: the selected chip line must fill EXACTLY cols (110), never wrap,
# even with many sessions (trailing session chips drop to fit)
selchip=$(printf '%s\n' "$f" | grep "❯ open ❮" | head -1)
check "selected chip line width == 110"    '[ "$(dwline "$selchip")" = 110 ]'
# non-selected result shows its full "name · session" suffix (the selected row's
# title may shrink to make room for the chip strip when many sessions exist)
check "result shows session suffix"        '[[ "$f" == *"zebra-beta · cc-sb"* ]]'
out=$(dash cc-sa 1 '.zebra-beta\r')        # narrow to the cross-session one, open it
check "search opens cross-session (cc-sb)" '[[ "$out" == *"ACTION open cc-sb:1"* ]]'
f=$(dash cc-sa 1 '.qqqzzz' | last_frame)
check "no-match shows a notice"            '[[ "$f" == *'"'"'no window matches "qqqzzz"'"'"'* ]]'
f=$(dash cc-sa 1 '.zebra\033' | last_frame)   # Esc leaves search → normal view (no · session suffix)
# (the selected row's title may truncate hard to fit the chip strip — by this
# point the run has ~6 sessions of move chips — so match a short prefix;
# "search:" absent = the search layer is gone)
check "Esc exits search to normal view"    '[[ "$f" == *"1) zebra-"* && "$f" != *"search:"* ]]'
# session-aware chips: the selected result's move targets EXCLUDE its own session.
# Render WIDE so no session chips are dropped-to-fit, and scope to the chip line
# (the header tab bar also lists every session).
f=$(printf '.zebra-beta' | JW_DASH_TEST=1 JW_DASH_COLS=200 JW_DASH_ROWS=24 \
      JW_TMUX="$TMUXB -L $SOCK" TMPDIR="$WORK" JW_DASH_PARKING=cc-parked \
      bash hooks/tmux-claude-dashboard.sh cc-sa 1 2>>"$WORK/dash.err" | last_frame)
chipline=$(printf '%s\n' "$f" | grep "❯ open ❮" | head -1)
check "search chips exclude result's session" '[[ "$chipline" == *"❯ cc-sa ❮"* && "$chipline" != *"❯ cc-sb ❮"* ]]'
"$TMUXB" -L "$SOCK" kill-session -t cc-sa 2>/dev/null; "$TMUXB" -L "$SOCK" kill-session -t cc-sb 2>/dev/null

echo "── 14. P2: reconciler single-jq registry extraction ──────────────"
# the ONE jq that replaced the per-file loop: tag each record with its path,
# default-empty the fields. Fixture: 2 well-formed registry files.
REGT="$WORK/reg"; mkdir -p "$REGT"
printf '{"kind":"interactive","status":"busy","sessionId":"aaaa-1111"}' > "$REGT/12345.json"
printf '{"kind":"bg","status":"idle","sessionId":"bbbb-2222"}'          > "$REGT/67890.json"
jqout=$(jq -r '[input_filename, .kind // "", .status // "", .sessionId // ""] | join("|")' "$REGT"/*.json 2>/dev/null)
check "jq tags path|kind|status|sid"       '[[ "$jqout" == *"/12345.json|interactive|busy|aaaa-1111"* && "$jqout" == *"/67890.json|bg|idle|bbbb-2222"* ]]'
# the shell-side pid recovery + numeric guard (mirrors reconcile.sh)
recov=""; while IFS='|' read -r fn kind status sid; do
  [ -n "$fn" ] || continue; p=${fn##*/}; p=${p%.json}
  case "$p" in ''|*[!0-9]*) continue;; esac
  recov="${recov}${p}|${kind}|${status}|${sid};"
done <<< "$jqout"
check "pid recovered from input_filename"  '[[ "$recov" == *"12345|interactive|busy|aaaa-1111;"* && "$recov" == *"67890|bg|idle|bbbb-2222;"* ]]'
# a non-numeric-named file is dropped by the guard
printf '{"kind":"x","status":"y","sessionId":"z"}' > "$REGT/notapid.json"
jqout=$(jq -r '[input_filename, .kind // "", .status // "", .sessionId // ""] | join("|")' "$REGT"/*.json 2>/dev/null)
kept=""; while IFS='|' read -r fn kind status sid; do
  p=${fn##*/}; p=${p%.json}; case "$p" in ''|*[!0-9]*) continue;; esac; kept="${kept}${p};"
done <<< "$jqout"
check "non-numeric registry file skipped"  '[[ "$kept" != *"notapid"* ]]'
rm -rf "$REGT"

echo "── 15. P3: recap harvest mtime gate (harvest→skip→harvest) ────────"
# drive the REAL reconciler against a HOME-isolated registry+transcript fixture.
# A scratch pane's pane_pid IS the registry pid, so it maps directly (no ps walk).
"$TMUXB" -L "$SOCK" new-session -d -s cc-p3 -n p3win -x 200 -y 50
p3pid=$("$TMUXB" -L "$SOCK" list-panes -t cc-p3 -F '#{pane_pid}' | head -1)
H3="$WORK/p3home"; mkdir -p "$H3/.claude/sessions" "$H3/.claude/projects/proj"
printf '{"kind":"interactive","status":"idle","sessionId":"testsid3"}' > "$H3/.claude/sessions/$p3pid.json"
printf '%s\n' '{"type":"system","subtype":"away_summary","content":"P3 recap payload."}' > "$H3/.claude/projects/proj/testsid3.jsonl"
run_rec() { HOME="$H3" JW_RECONCILE_TRACE=1 PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-reconcile.sh 2>&1 >/dev/null; }
t1=$(run_rec)
check "1st pass harvests the transcript"    '[[ "$t1" == *"harvest testsid3"* ]]'
rc=$("$TMUXB" -L "$SOCK" show-option -pqv -t cc-p3 @ccrecap 2>/dev/null)
check "recap published to @ccrecap"         '[[ "$rc" == *"P3 recap payload"* ]]'
t2=$(run_rec)
check "2nd pass SKIPS (transcript unchanged)" '[[ "$t2" == *"skip testsid3"* && "$t2" != *"harvest testsid3"* ]]'
sleep 1; touch "$H3/.claude/projects/proj/testsid3.jsonl"
t3=$(run_rec)
check "touch → 3rd pass harvests again"      '[[ "$t3" == *"harvest testsid3"* ]]'
check "mtime stamp file created"             '[ -f "$H3/.cache/tmux-claude/recap_seen_testsid3" ]'
"$TMUXB" -L "$SOCK" kill-session -t cc-p3 2>/dev/null

echo "── 16. move chip: teleport window to an absolute slot ─────────────"
# fresh 5-window session; @ccname makes it Claude-active so the popup views it
"$TMUXB" -L "$SOCK" new-session -d -s cc-tele -n t1 -x 200 -y 50
for n in 2 3 4 5; do "$TMUXB" -L "$SOCK" new-window -t cc-tele -n "t$n"; done
"$TMUXB" -L "$SOCK" set-option -w -t cc-tele:1 @ccname t1
# arm the move chip (close overshoot then ←←: close→rename→move), type 4, ⏎.
# cursor starts on window 2 (t2); move it to slot 4.
out=$(dash cc-tele 2 "${R8}\033[D\033[D\r4\r")
check "move emits ACTION teleport …:2 → 4"  '[[ "$out" == *"ACTION teleport cc-tele:2 4"* ]]'
order=$("$TMUXB" -L "$SOCK" list-windows -t cc-tele -F '#{window_index}:#{window_name}' | tr '\n' ' ')
# t2 lands at slot 4; t3→2, t4→3 (the slots it passed shift up by one)
check "t2 landed at slot 4"                 '[[ "$order" == *"4:t2"* ]]'
check "displaced windows shifted up"        '[[ "$order" == *"2:t3"* && "$order" == *"3:t4"* ]]'
check "session stays gap-free 1..5"         '[ "$order" = "1:t1 2:t3 3:t4 4:t2 5:t5 " ]'
f=$(printf '%s' "$out" | last_frame)
check "move toast shows the landing slot"   '[[ "$f" == *"moved"* && "$f" == *"slot 4"* ]]'
# the move-chip editor prompt: arm move (close overshoot ←←), Enter → editor
f=$(dash cc-tele 2 "${R8}\033[D\033[D\r" | last_frame)
check "move editor prompts for a slot"      '[[ "$f" == *"to slot:"* ]]'
"$TMUXB" -L "$SOCK" kill-session -t cc-tele 2>/dev/null

echo "── 17. BG-BUSY: orphan bg session drives 🤖 + @ccbg + italics ─────"
# The sight-words case (2026-07-09): the pane's interactive Claude reports
# "idle" in the registry, while a busy kind=bg session — running under the
# detached --bg-pty supervisor (parent=launchd, so the process-tree walk can
# NEVER map it) — carries the same registry NAME. The reconciler must match it
# to the pane by title-derived name, set @ccstate=working (not clear it!),
# publish @ccbg=1, and the boxbar must render that tab's name in italics.
"$TMUXB" -L "$SOCK" new-session -d -s cc-bg -n bgwin -x 200 -y 50 'sleep 300'
"$TMUXB" -L "$SOCK" select-pane -t cc-bg:1 -T 'bgwork-champion'
bgpanepid=$("$TMUXB" -L "$SOCK" list-panes -t cc-bg -F '#{pane_pid}' | head -1)
sleep 300 & ORPHAN=$!                       # live pid NOT under any scratch pane
H4="$WORK/bghome"; mkdir -p "$H4/.claude/sessions"
printf '{"kind":"interactive","status":"idle","sessionId":"bgsid-int"}' > "$H4/.claude/sessions/$bgpanepid.json"
printf '{"kind":"bg","status":"busy","sessionId":"bgsid-bg","name":"bgwork-champion"}' > "$H4/.claude/sessions/$ORPHAN.json"
# pre-set working (as the Stop hook leaves it when bg tasks run): the OLD
# r==idle rule cleared this — the fix must PRESERVE it
"$TMUXB" -L "$SOCK" set-option -pq -t cc-bg:1 @ccstate working
HOME="$H4" PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-reconcile.sh >/dev/null 2>&1
st=$("$TMUXB" -L "$SOCK" show-option -pqv -t cc-bg:1 @ccstate)
bgf=$("$TMUXB" -L "$SOCK" show-option -pqv -t cc-bg:1 @ccbg)
check "idle+bg-busy keeps working (not cleared)" '[ "$st" = working ]'
check "@ccbg published"                     '[ "$bgf" = 1 ]'
# boxbar renders the bg-busy tab in italics (and still shows the 🤖 glyph)
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh --build 100 cc-bg 1 7209 "cc-bg|1|100|7209" 2>>"$WORK/bar.err"
check "bg tab renders in italics"           'grep -q "#\[italics\]" "$rowdir/row1_7209"'
check "bg tab still shows 🤖 on the border" 'grep -q "🤖" "$rowdir/row2_7209"'
# status "shell" (observed live 2026-07-09: bg session mid tool-exec) must count
# as active too — the busy-only version of this rule missed it on cc-main:10
printf '{"kind":"bg","status":"shell","sessionId":"bgsid-bg","name":"bgwork-champion"}' > "$H4/.claude/sessions/$ORPHAN.json"
HOME="$H4" PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-reconcile.sh >/dev/null 2>&1
st=$("$TMUXB" -L "$SOCK" show-option -pqv -t cc-bg:1 @ccstate)
check "bg status=shell also counts active"  '[ "$st" = working ]'
# bg session gone (answer arrived / job done) → next pass clears both
rm -f "$H4/.claude/sessions/$ORPHAN.json"
HOME="$H4" PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-reconcile.sh >/dev/null 2>&1
st=$("$TMUXB" -L "$SOCK" show-option -pqv -t cc-bg:1 @ccstate)
bgf=$("$TMUXB" -L "$SOCK" show-option -pqv -t cc-bg:1 @ccbg)
check "bg done → state cleared by idle rule" '[ -z "$st" ]'
check "bg done → @ccbg cleared"             '[ -z "$bgf" ]'
kill "$ORPHAN" 2>/dev/null; wait "$ORPHAN" 2>/dev/null   # wait reaps → no "Terminated" noise
"$TMUXB" -L "$SOCK" kill-session -t cc-bg 2>/dev/null
rm -f "$rowdir"/*_7209 "$WORK/tmux-claude-bar/vp_7209_cc-bg"

echo "── 18. waitq: registry waiting → 💬 question vs 🔴 needs_you ──────"
# PreToolUse never fires for AskUserQuestion (verified live 2026-07-09), so the
# reconciler disambiguates a "waiting" session by peeking the transcript's last
# assistant tool call: AskUserQuestion → question, anything else → needs_you.
"$TMUXB" -L "$SOCK" new-session -d -s cc-wq -n wq1 -x 200 -y 50 'sleep 300'
wqpid=$("$TMUXB" -L "$SOCK" list-panes -t cc-wq -F '#{pane_pid}' | head -1)
H5="$WORK/wqhome"; mkdir -p "$H5/.claude/sessions" "$H5/.claude/projects/proj"
printf '{"kind":"interactive","status":"waiting","sessionId":"wqsid"}' > "$H5/.claude/sessions/$wqpid.json"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{}}]}}' > "$H5/.claude/projects/proj/wqsid.jsonl"
HOME="$H5" PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-reconcile.sh >/dev/null 2>&1
st=$("$TMUXB" -L "$SOCK" show-option -pqv -t cc-wq:1 @ccstate)
check "pending AskUserQuestion → question 💬" '[ "$st" = question ]'
# permission-style wait: last assistant tool is Bash → needs_you
"$TMUXB" -L "$SOCK" set-option -pq -t cc-wq:1 -u @ccstate
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}' > "$H5/.claude/projects/proj/wqsid.jsonl"
HOME="$H5" PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-reconcile.sh >/dev/null 2>&1
st=$("$TMUXB" -L "$SOCK" show-option -pqv -t cc-wq:1 @ccstate)
check "permission wait → needs_you 🔴"       '[ "$st" = needs_you ]'
# missing transcript falls back to needs_you (never worse than the old rule)
"$TMUXB" -L "$SOCK" set-option -pq -t cc-wq:1 -u @ccstate
rm -f "$H5/.claude/projects/proj/wqsid.jsonl"
HOME="$H5" PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-reconcile.sh >/dev/null 2>&1
st=$("$TMUXB" -L "$SOCK" show-option -pqv -t cc-wq:1 @ccstate)
check "no transcript → needs_you fallback"   '[ "$st" = needs_you ]'
"$TMUXB" -L "$SOCK" kill-session -t cc-wq 2>/dev/null


echo "── 19. P?: persistent on idle Claude windows, dismissed by assoc ──"
# a pane whose ACTIVE process is literally named "claude" (fake binary) with no
# @ccstate and no @ccproj must show a standalone ┤P?├ on the bottom border —
# the marker no longer rides the state emoji (JW 2026-07-13). Setting @ccproj
# dismisses it on the next build.
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
# needs a real Mach-O named "claude": a shebang script reports comm=bash, and
# copies of SYSTEM binaries (/bin/sleep, /usr/bin/jq) are trust-cache-signed +
# launch-constrained — SIGKILLed when run from any other path. Compile a
# 3-line idler instead (CLT clang; the linker ad-hoc-signs it).
printf '#include <unistd.h>\nint main(void){pause();return 0;}\n' > "$FAKEBIN/idle.c"
/usr/bin/clang -o "$FAKEBIN/claude" "$FAKEBIN/idle.c" 2>>"$WORK/bar.err"
"$TMUXB" -L "$SOCK" new-session -d -s cc-pq -n pq-window-x -x 200 -y 50 "$FAKEBIN/claude"
sleep 1   # let the pane exec so pane_current_command settles on "claude"
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh --build 100 cc-pq 1 7301 "cc-pq|1|100|7301" 2>>"$WORK/bar.err"
r2p=$(sed 's/#\[[^]]*\]//g' "$rowdir/row2_7301")
check "idle claude, no assoc → ┤1·P?├"     '[[ "$r2p" == *"┤1·P?├"* ]]'
"$TMUXB" -L "$SOCK" set-option -pq -t cc-pq:1 @ccproj tmux
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh --build 100 cc-pq 1 7302 "cc-pq|1|100|7302" 2>>"$WORK/bar.err"
r2p=$(sed 's/#\[[^]]*\]//g' "$rowdir/row2_7302")
check "assoc set → P? dismissed, N stays"  '[[ "$r2p" != *"P?"* && "$r2p" == *"┤1├"* ]]'
# a plain SHELL window (comm != claude) must never grow a P?
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh --build 100 cc-beta 1 7303 "cc-beta|1|100|7303" 2>>"$WORK/bar.err"
r2s=$(sed 's/#\[[^]]*\]//g' "$rowdir/row2_7303")
check "plain shell windows stay P?-free"   '[[ "$r2s" != *"P?"* ]]'
# working state + no assoc still renders the composite (existing behavior)
"$TMUXB" -L "$SOCK" set-option -pq -t cc-pq:1 -u @ccproj
"$TMUXB" -L "$SOCK" set-option -pq -t cc-pq:1 @ccstate working
PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-bar-render.sh --build 100 cc-pq 1 7304 "cc-pq|1|100|7304" 2>>"$WORK/bar.err"
r2p=$(sed 's/#\[[^]]*\]//g' "$rowdir/row2_7304")
check "working + no assoc → ┤1·🤖·P?├"      '[[ "$r2p" == *"┤1·🤖·P?├"* ]]'

echo "── 20. reconciler republishes @ccproj from the assoc file ─────────"
# assoc sets the pane option once; SessionStart clears wipe it. The reconciler
# must re-derive it every tick from state/assoc/<sessionId> (tail -1 = current)
# — and clear it when the file goes away (assoc --clear).
prpid=$("$TMUXB" -L "$SOCK" list-panes -t cc-pq -F '#{pane_pid}' | head -1)
H6="$WORK/prhome"; mkdir -p "$H6/.claude/sessions" "$H6/projects/session-pipelines/state/assoc"
printf '{"kind":"interactive","status":"busy","sessionId":"prsid"}' > "$H6/.claude/sessions/$prpid.json"
printf 'life-os\ntmux\n' > "$H6/projects/session-pipelines/state/assoc/prsid"
"$TMUXB" -L "$SOCK" set-option -pq -t cc-pq:1 -u @ccproj
HOME="$H6" PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-reconcile.sh >/dev/null 2>&1
pj=$("$TMUXB" -L "$SOCK" show-option -pqv -t cc-pq:1 @ccproj)
check "wiped @ccproj re-published (tail -1)" '[ "$pj" = tmux ]'
rm -f "$H6/projects/session-pipelines/state/assoc/prsid"
HOME="$H6" PATH="$SHIM:$PATH" TMPDIR="$WORK" bash hooks/tmux-claude-reconcile.sh >/dev/null 2>&1
pj=$("$TMUXB" -L "$SOCK" show-option -pqv -t cc-pq:1 @ccproj)
check "assoc file gone → @ccproj cleared"   '[ -z "$pj" ]'
"$TMUXB" -L "$SOCK" kill-session -t cc-pq 2>/dev/null

echo "── 21. PHONE mode: narrow-client touch layout ─────────────────────"
# cols<72 → PHONE=1: chips leave the divider for a pinned action bar, header
# sheds to [ ➕ ] + one tab + < > arrows, footer becomes tap targets, taps
# select-then-open (two-tap). Self-contained sessions (@ccstate marks active).
"$TMUXB" -L "$SOCK" new-session -d -s cc-ph1 -n ph-one -x 200 -y 50
"$TMUXB" -L "$SOCK" new-window  -t cc-ph1 -n ph-two
"$TMUXB" -L "$SOCK" set-option -w -t cc-ph1:1 @ccstate idle
"$TMUXB" -L "$SOCK" set-option -w -t cc-ph1:2 @ccstate working
"$TMUXB" -L "$SOCK" set-option -w -t cc-ph1:1 @ccrecap "a recap line for the phone tests"
"$TMUXB" -L "$SOCK" new-session -d -s cc-ph2 -n ph-solo -x 200 -y 50
"$TMUXB" -L "$SOCK" set-option -w -t cc-ph2:1 @ccstate idle
phone() { printf "$2" | JW_DASH_TEST=1 JW_DASH_COLS=64 JW_DASH_ROWS=24 \
  JW_TMUX="$TMUXB -L $SOCK" TMPDIR="$WORK" JW_DASH_PARKING=cc-parked \
  bash hooks/tmux-claude-dashboard.sh "$1" 1 2>>"$WORK/dash.err"; }
f=$(phone cc-ph1 'q' | last_frame)
check "phone header: icon-only [ ➕ ]"       'printf "%s\n" "$f" | head -1 | grep -q "\[ ➕ \]"'
check "phone header: no [ ➕ NEW ]"          '! printf "%s\n" "$f" | grep -q "➕ NEW"'
check "phone header: < name > arrows"        'printf "%s\n" "$f" | head -1 | grep -q "< *cc-ph1 *>"'
check "phone divider: no inline chips"       '! printf "%s\n" "$f" | grep -q "❯ open ❮"'
check "phone action bar: open + close"       'printf "%s\n" "$f" | grep -q "\[ open \].*\[ close \]"'
check "phone footer: tap targets"            'printf "%s\n" "$f" | grep -q "\[ search \].*\[ + session \]"'
fr=$(phone cc-ph1 'q' | last_frame_raw)
check "phone selected title = REV cursor"    '[[ "$fr" == *"${REV_SEQ}${BOLD_SEQ}"*"ph-one"* ]]'
# two-tap: window 2's header row (win1 header row3 + 1 recap line → row 5);
# first tap only SELECTS (no ACTION open), the second tap on the same row opens
out=$(phone cc-ph1 '\033[<0;5;5Mq')
check "phone tap 1: selects, no open"        '! printf "%s" "$out" | grep -aq "ACTION open"'
check "phone tap 1: cursor moved to ph-two"  '[[ "$(printf "%s" "$out" | last_frame_raw)" == *"${REV_SEQ}${BOLD_SEQ}"*"ph-two"* ]]'
out=$(phone cc-ph1 '\033[<0;5;5M\033[<0;5;5M')
check "phone tap 2: same row opens"          'printf "%s" "$out" | grep -aq "ACTION open cc-ph1:2"'
# action bar: ↑-arm walk skips hidden session-move indices (open→new→move…),
# and a tap on the bar's [ open ] span opens the selected window
fr=$(phone cc-ph1 '\033[C\033[Cq' | last_frame_raw)
check "phone ←/→ walk: 2×→ arms [ move ]"    '[[ "$fr" == *"${REV_SEQ}${BOLD_SEQ}[ move ]"* ]]'
ocol=$(phone cc-ph1 'q' | last_frame | grep -n "\[ open \]" | head -1 | awk -F: '{print index($2 ":" $3, "[ open ]")}')
check "phone abar tap on [ open ] opens"     'printf "%s" "$(phone cc-ph1 "\033[<0;$(( ocol + 2 ));22M")" | grep -aq "ACTION open cc-ph1:1"'
# horizontal wheel (SGR btn 67) → next session; header line 1 changes
h1=$(phone cc-ph1 'q' | last_frame | head -1)
h2=$(phone cc-ph1 '\033[<67;5;10Mq' | last_frame | head -1)
check "phone wheel-right → other session"    '[ "$h1" != "$h2" ]'
# wide mode untouched: same session at 110 cols still renders inline chips
fw=$(dash cc-ph1 1 'q' | last_frame)
check "wide mode keeps divider chips"        'printf "%s\n" "$fw" | grep -q "❯ open ❮"'
check "wide mode keeps [ ➕ NEW ]"           'printf "%s\n" "$fw" | grep -q "➕ NEW"'
"$TMUXB" -L "$SOCK" kill-session -t cc-ph1 2>/dev/null
"$TMUXB" -L "$SOCK" kill-session -t cc-ph2 2>/dev/null

echo "──────────────────────────────────────────────────────────────────"
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
