# tmux Keybinding Cheatsheet

**Prefix = `C-k`** (Ctrl+k — remapped from the default `C-b` in `tmux.conf`, 2026-07-02).
Press prefix, release, then the key. Notation: `C-`=Ctrl · `M-`=Alt/Option · `S-`=Shift · `DC`=Delete · `PPage`=PageUp.

> ⚠️ `C-k` is readline/zsh **kill-line**: inside a shell, press `C-k C-k` to send a literal Ctrl+k through. Plain `C-b` now passes straight to apps (Claude Code etc.).

> ⚠️ `base-index 1` + `pane-base-index 1` are set, so windows/panes count **from 1**.
> `C-k 1` is your first window; there is normally **no window 0**.

---

## 🔧 Your custom bindings & option changes (from `tmux.conf`)

These override or add to stock tmux — the reason each exists is in `tmux.conf`.

| Key / Option | Effect | Why |
|---|---|---|
| `C-k g` | Jump to the Claude session that needs you most (🔴 > 💬 > 🟠 > ✅) | `tmux-claude-jump.sh` — attention router across sessions |
| `C-k o` | **Cockpit popup** (v3.4, 2026-07-16): header bar = a `[ ➕ NEW ]` button in its own section at the left (tap it, or `←` past the first tab + `⏎`, to create a window in the *viewed* session), the Claude-active session tabs (`↑` reaches the bar, blue when focused; `←/→`/tap browse another session *without leaving yours*), and a `[ ❌ CLOSE ]` button top-right; each window is a flush-left `N) name ────` entry with its recap below; on the selected entry `←/→` walk the **control chips** (only text inside `❯ ❮` highlighted, accelerator letter underlined) — `open` · one chip per other Claude session (move there; `cc-parking` always offered) · **(n)ew session** (spin window into a fresh session) · **(m)ove** (teleport to an absolute slot, like `C-k .`) · **(r)ename** (inline-edit the name) · **(c)lose** (red, two-step confirm, graceful `/exit`; closing a session's *last* window first lands your client in the most-recently-active other session instead of kicking you out of tmux); n/m/r/c are direct accelerators · `⏎` run/open · `.` **global cross-session search** (type to filter windows across all sessions, shown with `· session` suffix; stays until Esc) · `t` sort · `s` **new blank session** (`cc-mmdd`, sized to your client) · `?` **tmux key-binding help** (live filterable 2-col reference of the prefix bindings; `↑↓←→`/tap select a binding, `⏎` runs it as if typed, Esc closes) · number to jump · `q`/`Esc` close | `tmux-claude-dashboard-open.sh`; dropdown under the bar; full-screen on iPhone; shadows stock o (next pane) |
| `C-k b` | Toggle the boxbar: 3-line box ribbon ⇆ 1-line compact | `tmux-claude-bar.sh toggle` |
| `C-k R` | **Restore** every Claude session that crashed/died (`claude --resume` in rebuilt windows) | `tmux-claude-restore.sh`; additive + idempotent. Fallback: `cc-restore`. Complements `C-k C-r` (which restores tmux layout, not the Claude processes) |
| `C-k <` | Move the current window one slot **left** (repeatable; focus follows) | `swap-window -t -1 \; previous-window`, `-r` |
| `C-k >` | Move the current window one slot **right** (repeatable; focus follows) | `swap-window -t +1 \; next-window`, `-r` |
| `C-k C-s` | **Save** all sessions/layout to disk (tmux-resurrect) | Reboot/disconnect survival |
| `C-k C-r` | **Restore** the saved sessions/layout (tmux-resurrect) | Brings Claude Code layout back after a crash |
| *Mouse on* | Tap to select panes, trackpad/Magic-Keyboard scroll, drag borders to resize | `set -g mouse on` |
| *Esc 10ms* | Esc interrupts Claude Code instantly; Esc-Esc opens rewind | `escape-time 10` (default 500ms swallows Esc) |
| *Shift+Enter* | Sends `\x1b[13;2u` through tmux to Claude Code (newline-in-prompt) | `extended-keys always` + `csi-u` |
| *Auto-restore* | Sessions autosave every 5 min and restore on tmux start / after Mac reboot | tmux-continuum |

> 💡 `C-k g`, `C-k o`, and `C-k b` are **not** stock tmux bindings — they're yours (`o` replaces stock next-pane; `w` is back to the stock window chooser). `C-k C-s` / `C-k C-r` come from the tmux-resurrect plugin.

---

## 🪟 Windows (the "tabs" at the top)

| Key | Action |
|---|---|
| `C-k c` | Create a new window |
| `C-k ,` | Rename current window |
| `C-k &` | Kill current window |
| `C-k .` | Move the current window (prompt for new index) |
| `C-k '` | Prompt for a window index to select |
| `C-k 0`–`9` | Select window N |
| `C-k n` | Select the **next** window |
| `C-k p` | Select the **previous** window |
| `C-k l` | Select the **previously current** window (toggle back) |
| `C-k w` | Choose a window from a list |
| `C-k f` | Search for a pane (by content) |
| `C-k i` | Display window information |
| `C-k !` | Break the active pane out into a new window |
| `C-k M-n` | Next window with an **alert** |
| `C-k M-p` | Previous window with an **alert** |

## ▭ Panes (splits)

| Key | Action |
|---|---|
| `C-k %` | Split **horizontally** → left / right |
| `C-k "` | Split **vertically** → top / bottom |
| `C-k x` | Kill the active pane |
| `C-k o` | ~~Select the next pane~~ **overridden** → cockpit popup (see custom table above) |
| `C-k ;` | Jump to the previously active pane (toggle back) |
| `C-k ↑ ↓ ← →` | Select pane in that direction |
| `C-k q` | Display pane numbers (then press one to jump) |
| `C-k z` | **Zoom** the active pane (full-screen toggle) |
| `C-k {` | Swap active pane with the one **above** |
| `C-k }` | Swap active pane with the one **below** |
| `C-k C-o` | Rotate through panes |
| `C-k M-o` | Rotate through panes in **reverse** |
| `C-k m` | Toggle the **marked** pane |
| `C-k M` | Clear the marked pane |
| `C-k E` | Spread panes out evenly |
| `C-k >` | Display the pane menu |

## ↔ Resize panes

| Key | Action |
|---|---|
| `C-k M-↑ ↓ ← →` | Resize the pane by **5** in that direction |
| `C-k C-↑ ↓ ← →` | Resize the pane by **1** in that direction |

## ▦ Layouts

| Key | Action |
|---|---|
| `C-k Space` | Cycle to the next layout |
| `C-k M-1` | even-horizontal |
| `C-k M-2` | even-vertical |
| `C-k M-3` | main-horizontal |
| `C-k M-4` | main-vertical |
| `C-k M-5` | tiled |
| `C-k M-6` | main-horizontal-mirrored |
| `C-k M-7` | main-vertical-mirrored |

## 🗂 Sessions & clients

| Key | Action |
|---|---|
| `C-k d` | **Detach** the current client (tmux keeps running) |
| `C-k D` | Choose & detach a client from a list |
| `C-k s` | Choose a session from a list |
| `C-k $` | Rename the current session |
| `C-k (` | Switch to the previous client |
| `C-k )` | Switch to the next client |
| `C-k L` | Switch to the **last** client |
| `C-k C-z` | Suspend the current client |

## 📋 Copy mode, scrollback & paste buffers

| Key | Action |
|---|---|
| `C-k [` | Enter **copy mode** (scroll/search/select; `q` exits) |
| `C-k PPage` | Enter copy mode and scroll up one page |
| `C-k ]` | Paste the most recent paste buffer |
| `C-k #` | List all paste buffers |
| `C-k =` | Choose a paste buffer from a list |
| `C-k -` | Delete the most recent paste buffer |
| `C-k S-↑ ↓ ← →` | Pan the **visible** part of the window |
| `C-k DC` | Reset so the visible part follows the cursor |

> With `mouse on`, you can also just scroll the trackpad to enter copy mode and drag to select.

## 🛠 Meta / utility

| Key | Action |
|---|---|
| `C-k :` | Prompt for a tmux **command** |
| `C-k ?` | List **all** key bindings |
| `C-k /` | Describe a key binding (press the key after) |
| `C-k C` | Customize options interactively |
| `C-k <` | Display the window menu |
| `C-k t` | Show a clock |
| `C-k ~` | Show recent tmux messages |
| `C-k C-k` | Send a literal prefix key to the app inside |

---

*Stock defaults captured from `C-k ?` (tmux 3.6b). Custom rows reflect this repo's [`tmux.conf`](../tmux.conf). Regenerate the default list anytime with `tmux list-keys -T prefix`.*
