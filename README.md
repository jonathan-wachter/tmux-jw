# tmux-jw

A **live [Claude Code](https://claude.com/claude-code) session dashboard for tmux**, plus the tmux tuning that makes Claude Code pleasant to drive **remotely over [mosh](https://mosh.org/)** (e.g. from an iPad or phone).

Every tmux window tab shows what its Claude Code session is doing right now — working, asking you a question, blocked on a permission, or finished while you were away — and a global summary in the status bar lets you **tap to jump** straight to whichever session needs you. The status bar is **flicker-free over mosh**, where naive `status-right` scripts make the cursor strobe.

```
 cc-0624-0 ┌──────────┬──────────┬───────────┬─────────┬───┐
  📚3•📺4  │life-os   │triage    │dotfiles   │notes    │ ▶ │
  🤖2•💬1  └─┤1·🤖├──┴─┤2·💬├──┴──┤3·✅├───┴──┤4├────┴───┘
 └ session · 📚 sessions • 📺 windows here · global state counts
   (the whole block is the tap target → cockpit dropdown)
```

Tab titles size **dynamically**: full window names whenever they fit, then a shared cap with `…` on the names actually cut, down to a 9-char floor — only then do the ◀/▶ scroll arrows appear. Each tab carries a **badge framed on the bottom border**, centered under it: the window number plus the status glyph (`─┤7·🤖├─`), degrading right-to-left in narrow cells so the number always survives. The title row stays pure name.

| Glyph | Meaning |
|:---:|---|
| 🤖 | Claude is **working** (generating / running tools) |
| 💬 | Claude has a **question** for you (AskUserQuestion) |
| 🔴 | Claude **needs you** — permission prompt or error |
| 🟠 | **Stalled** — claims busy but the pane hasn't painted in 3+ min (watchdog) |
| ✅ | **Done** while you were away (auto-clears when you focus the pane) |
| _(none)_ | idle |
| `P?` (red) | Window's Claude session has **no project association** — persistent until you `assoc` a project. Off by default unless the [session-wraps](https://github.com/jonathan-wachter) assoc workflow is installed (`TMUXJW_PROJ_MARKER`). |

## Features

- **Per-window live state** in the tab list and pane borders, driven by Claude Code hooks (instant) and a reconciler (catches crashes / `Ctrl-C` / kills that hooks miss).
- **Global attention summary** in the bar's full-height left block — session name / `📚N•📺N` (tmux sessions • windows here) / global state counts, light-on-slate; the whole block is the tap target that drops the cockpit down from the bar.
- **Tap-to-jump** (`MouseDown1Status`) and **`prefix + g`** — jump to the session that needs you most (🔴 > 💬 > 🟠 > ✅). Works over mosh on a touchscreen.
- **`prefix + o` (or `prefix + m`) cockpit** — a popup with **every tmux session as a `❯ name ❮` tab** (`←/→` browses another session's windows *without switching to it*; tap a tab on touch) and the viewed session's windows below, each with its status glyph and latest Claude Code "※ recap". `↑/↓` + `Enter` (or a typed number, or a tap) **opens** a window — switching sessions too if it lives elsewhere. `s` cycles sort (index → attention → name, sticky across opens). Recaps are harvested from Claude Code's own transcript — **no extra AI calls**. Renders as a **dropdown hanging off the boxbar** (96% wide, near-full height — it stops 5 rows short of the bottom so the Claude Code entry area stays visible; bar-matching colors); also opens by tapping the bar's left block. **Phone mode** (client < 90 cols): touch-first layout — a pinned `[ open ] [ new ] [ move ] [ ren ] [ close ]` action bar replaces the divider chips, taps select-then-open, [ move ] opens a destination picker (session chips + slot + cancel), the header shows every session as a full-size tap-to-switch tab (chunky [ < ] [ > ] cycle buttons on overflow), the footer sheds to tap targets, and a horizontal wheel (sideways swipe) cycles sessions.
- **Session names in tabs** — publishes each session's `/rename` name to its window tab.
- **Crash recovery** — a snapshotter records the live Claude-in-tmux layout (session ids + cwds + pane layouts) every heartbeat; after a tmux/Claude crash, **`prefix + R`** (or `cc-restore`) relaunches `claude --resume <id>` for every session that isn't running, rebuilding their windows. On reattach you get a banner if any are down. Additive + idempotent — it only creates windows and skips anything already live. See [Crash recovery](#crash-recovery).
- **Flicker-free status bar over mosh** — the status reader returns in ~2 ms from a cache and refreshes in the background (stale-while-revalidate), so the cursor never strobes. See [`hooks/tmux-claude-statusline.sh`](hooks/tmux-claude-statusline.sh) for the why.
- **Claude-Code-over-mosh tmux tuning** — fast `escape-time` (so `Esc` interrupts Claude reliably), unconditional extended keys (so `Shift+Enter` works inside tmux), 24-bit color, and an OSC 52 clipboard override mosh actually accepts. Each line is commented with *why*.

## How it works

```
Claude Code hooks ──(instant)──▶ @ccstate / @ccname per tmux pane ──▶ window tabs + borders
        │                                   ▲
        │ (every status-interval, in bg)    │ corrects missed events, runs watchdog,
        ▼                                   │ publishes names, harvests recaps
  tmux-claude-statusline.sh ──kicks──▶ tmux-claude-reconcile.sh ──writes──▶ ~/.cache/tmux-claude/summary
        │                                                                          │
        └────────────────── reads cache instantly (status-right) ◀────────────────┘
```

- **`tmux-claude-state.sh <state>`** — wired to Claude Code hook events (`Notification`, `Stop`, `PreToolUse`, …); writes the pane's `@ccstate` instantly.
- **`tmux-claude-reconcile.sh`** — the truth-reconciler + summarizer. Maps Claude Code's session registry to tmux panes, fixes states the hooks missed, runs a stall watchdog, and writes the global summary to a cache file.
- **`tmux-claude-statusline.sh`** — what `status-right` actually calls: prints the cached summary instantly and kicks the reconciler in the background.
- **`tmux-claude-jump.sh`** — cycles to the next session in a given attention category.
- **`tmux-claude-dashboard.sh` / `-open.sh`** — the `prefix + o` / `prefix + m` multi-session cockpit popup (size-aware: full-screen on a phone, bordered window on a Mac). Headless-testable: `JW_DASH_TEST=1` reads keys from stdin and draws to stdout, `JW_TMUX` redirects it at a scratch server (see `tests/run-tests.sh`).
- **`tmux-claude-snapshot.sh`** — records the live layout to `~/.cache/tmux-claude/last-layout.json` (rides the reconciler heartbeat). Crash-safe write guard: won't clobber a richer recent snapshot.
- **`tmux-claude-restore.sh`** — rebuilds windows for every Claude session in the snapshot that isn't currently running. Reproduces pane layouts; non-Claude panes come back as plain shells.
- **`tmux-claude-check.sh`** — counts how many snapshot sessions are down; `--notify` flashes the reattach banner (wired to `client-attached`).

## Crash recovery

tmux-continuum restores tmux *windows* after a reboot, but the Claude processes inside them are gone. This closes that gap — and recovers from any crash that kills your Claude sessions while their transcripts (`~/.claude/projects/<proj>/<sessionId>.jsonl`) live on.

```
every ~5s (reconciler heartbeat) ──▶ tmux-claude-snapshot.sh
    reads ~/.claude/sessions/<pid>.json (live, interactive) + tmux pane/layout
    └─▶ ~/.cache/tmux-claude/last-layout.json   [{sessionId, name, cwd, layout, panes}]

after a crash:
    prefix + R  /  cc-restore  ──▶ tmux-claude-restore.sh
        diff snapshot vs live registry ──▶ claude --resume <id> for each downed session
    on reattach ──▶ tmux-claude-check.sh --notify ──▶ "⚠️ N down — prefix+R to restore"
```

| Trigger | What it does |
|---|---|
| `prefix + R` | Restore all downed Claude sessions (the 1-key) |
| reattach banner | Tells you N sessions are down, points at the key |
| `cc-restore` | Shell-alias fallback (in `~/.zshrc`) if you miss the key/banner |
| `cc-down` | List which snapshot sessions are currently down |

Flags: `--dry-run` (print the plan, change nothing), `--all` (also recreate pure-shell windows, deduped by name — off by default since continuum handles shells), `--target <session>` (restore into a specific session; defaults to the current one). The snapshot path can be overridden with `TMUX_CLAUDE_LAYOUT` (used by the tests). Restore is **additive and idempotent**: it only ever creates windows, never kills, and skips any session already live — always safe to press again. Big sessions pause at Claude's own "resume from summary / full" prompt.

## Requirements

- **tmux ≥ 3.5a** (needs `extended-keys-format csi-u`)
- **[Claude Code](https://claude.com/claude-code)** (the dashboard reads its session registry + transcripts)
- **`jq`** and **bash**
- Optional: **mosh** for remote use; **[TPM](https://github.com/tmux-plugins/tpm)** + `tmux-resurrect` + `tmux-continuum` for the reboot-survival lines at the bottom of `tmux.conf`

## Install

```sh
git clone https://github.com/jonathan-wachter/tmux-jw ~/.config/tmux-jw
~/.config/tmux-jw/install.sh
```

The installer:
1. Checks for `tmux` (and version), `jq`, `bash`.
2. Makes the hooks executable and ensures they're reachable at `~/.config/tmux-jw/hooks/` (the path `tmux.conf` references).
3. Symlinks `~/.tmux.conf` → this repo's `tmux.conf` **only if you don't already have one** (otherwise it prints a `source-file` line to add).
4. Prints the Claude Code hook wiring to add to your `settings.json`.

Then:

```sh
tmux source-file ~/.tmux.conf        # reload tmux
# install TPM plugins (optional): prefix + I
```

### Wire up the Claude Code hooks

The dashboard needs Claude Code to call `tmux-claude-state.sh` on its lifecycle events. Merge the contents of [`hooks.example.json`](hooks.example.json) into the `"hooks"` block of `~/.claude/settings.json` (it's plain JSON — strip any comments). Summary of the mapping:

| Claude Code event | State written |
|---|---|
| `UserPromptSubmit`, `PostToolUse` | `working` 🤖 |
| `PreToolUse` (AskUserQuestion) | `question` 💬 |
| `Notification`, `StopFailure` | `needs_you` 🔴 |
| `Stop` | `done` ✅ |
| `SessionStart`, `SessionEnd` | `clear` |

Restart your Claude Code sessions (or start new ones) so the hooks take effect.

## Configuration

Everything works with zero configuration. To customize, copy the committed templates — the real files are git-ignored, so your local values never end up in a commit:

```sh
cp tmux-jw.config.example      tmux-jw.config        # shell settings, read by the hooks
cp tmux-jw.local.tmux.example  tmux-jw.local.tmux    # tmux overrides (e.g. a different prefix)
```

| File | Controls |
|---|---|
| `tmux-jw.config` | Parking-session name (`TMUXJW_PARKING`), new-session prefix (`TMUXJW_SESSION_PREFIX`), tmux binary for the test suite (`TMUXJW_TMUX_BIN`), no-project badge (`TMUXJW_PROJ_MARKER`) |
| `tmux-jw.local.tmux` | Any tmux option or binding — sourced as the **last** line of `tmux.conf`, so it wins over everything in it (the committed prefix is `C-k`; override it here) |

## Keybindings

See [`docs/KEYBINDINGS.md`](docs/KEYBINDINGS.md) for the full prefix-key reference (defaults + the custom bindings this config adds).

## Layout

```
tmux-jw/
├── tmux.conf                  # the tmux config (heavily commented)
├── hooks/
│   ├── tmux-claude-state.sh           # hook target: writes @ccstate
│   ├── tmux-claude-reconcile.sh       # reconciler + summarizer
│   ├── tmux-claude-statusline.sh      # instant status-right reader
│   ├── tmux-claude-jump.sh            # jump-to-session
│   ├── tmux-claude-dashboard.sh       # multi-session cockpit popup (prefix+o/m)
│   └── tmux-claude-dashboard-open.sh  # size-aware popup launcher
├── tests/
│   └── run-tests.sh           # e2e regression suite (scratch tmux server, headless TUI)
├── docs/
│   ├── KEYBINDINGS.md         # prefix-key reference
│   └── notes/                 # historical design docs + incident write-ups
├── tmux-jw.config.example     # optional local config template (see Configuration)
├── tmux-jw.local.tmux.example # optional tmux-override template
├── hooks.example.json         # Claude Code settings.json hook wiring to merge
└── install.sh
```

Runtime state lives outside the repo, in `~/.cache/tmux-claude/`.

## License

[MIT](LICENSE).

---

🤖 Built with [Claude Code](https://claude.com/claude-code).
