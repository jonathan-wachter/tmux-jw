# Upstream tmux bug report (draft) — server `fatal: tty_clamp_area: y too big`

**Ready to file at https://github.com/tmux/tmux/issues** — review, then submit (or run the `gh` command at the bottom).

---

### Title
Server crash `fatal: tty_clamp_area: y too big, N > N-1` with multiple different-sized clients (3.6b)

### tmux version
`tmux 3.6b` (Homebrew, macOS 26 / Apple Silicon). Reproduced against current `master` — the `fatalx` call is still present in `tty.c`.

### What happens
With **two or more clients of different heights** attached to the same session and `window-size latest` (the default), a full-screen redraw in a pane — e.g. an application starting and emitting `ED` (`\033[2J`) plus a scroll region (`DECSTBM`) — **crashes the entire server**, killing every session:

```
fatal: tty_clamp_area: y too big, 54 > 53
```

The window is sized to the *taller* active client; the region computed for it is then sent to a *shorter* attached client. `tty_region_pane()` emits the `DECSTBM`/region using the window geometry **without clamping it to the receiving client's `tty->sy`**, and `tty_clamp_area()` (and `tty_clamp_line()`) respond to the resulting overflow with `fatalx()` instead of clamping.

### Trigger conditions (observed)
- ≥2 clients attached to one session at **different heights** (here 56-row and 53/60-row; also seen with 150x62 / 186x53 / 130x43 transiently).
- `window-size latest` (default).
- A multi-line `status` (here `status 3`) widens the offset math, but the root cause is the size mismatch, not the status height.
- A full-screen redraw in a pane (an app launching / clearing / a resize) — intermittent, it's a resize/redraw race.

### Log excerpt (server `-vv`), leading directly into the crash
```
clients_calculate_size: calculated size 150x62
clients_calculate_size: calculated size 186x53
recalculate_size: @13 is 186x53
screen_write_start_pane: size 186x53, pane %14 (at 0,0)
input_parse_buffer: %14 esc_enter, 3 bytes: [2J
input_csi_dispatch: 'J' "" "2"
/dev/ttys015: \033[2;54r
fatal: tty_clamp_area: y too big, 54 > 53
```
`/dev/ttys015` is a 53-row client; the `[2;54r` scroll region (computed for the 56-row active client's geometry) exceeds it by one row.

### Root cause (tty.c)
`tty_clamp_area()` computes the clamped height `*ry`, then:
```c
if (*ry > ny)
    fatalx("%s: y too big, %u > %u", __func__, *ry, ny);
```
The same pattern exists for `*rx`/`nx` in `tty_clamp_area()` and `tty_clamp_line()`. When a region computed for a taller client is drawn to a shorter one, `*ry` can legitimately exceed `ny`, and the server aborts rather than clamping. There is no bounds-check against the receiving client's `tty->sy` before the region is emitted in `tty_region_pane()`.

### Suggested fix
Clamp instead of aborting — the functions' purpose is clamping, and the worst case becomes a single misdrawn frame that self-heals on the next redraw:
```c
- if (*ry > ny)
-     fatalx("%s: y too big, %u > %u", __func__, *ry, ny);
+ if (*ry > ny)
+     *ry = ny;
```
(and likewise for the two `*rx > nx` sites). This has eliminated the crashes locally. A more thorough fix would clamp the region to the receiving client's `tty->sy` in `tty_region_pane()` before emitting, so a too-tall region is never produced in the first place.

### Related
#1930, #1736, #1049 — same `tty_clamp_area`/multi-client crash family (earlier variants showed the `4294967295 > 0` underflow; this one is a clean off-by-one `54 > 53`).

---
**Submit with gh (optional):**
```bash
gh issue create --repo tmux/tmux \
  --title "Server crash: tty_clamp_area y too big with multiple different-sized clients (3.6b)" \
  --body-file ~/projects/tmux-jw/UPSTREAM-tty_clamp_area-crash.md
```
