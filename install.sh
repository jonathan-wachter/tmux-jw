#!/bin/bash
# install.sh — set up tmux-jw on this machine.
#
# Idempotent and conservative: it never clobbers an existing ~/.tmux.conf, and
# it only creates symlinks / chmods scripts. Re-run it any time.
set -euo pipefail

# Resolve the directory this script lives in (the repo root), following symlinks.
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
REPO="$(cd -P "$(dirname "$SOURCE")" && pwd)"

say()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }

say "tmux-jw installer — repo at: $REPO"

# ── 1. Dependency checks ─────────────────────────────────────────────────────
command -v tmux >/dev/null || { warn "tmux not found — install it first (brew install tmux)"; exit 1; }
command -v jq   >/dev/null || warn "jq not found — the reconciler needs it (brew install jq)"
command -v bash >/dev/null || warn "bash not found (unexpected)"

# tmux ≥ 3.5a is required for extended-keys-format csi-u.
ver="$(tmux -V | awk '{print $2}')"
case "$ver" in
  1.*|2.*|3.0*|3.1*|3.2*|3.3*|3.4*) warn "tmux $ver detected — this config wants ≥ 3.5a (some lines may warn)";;
  *) ok "tmux $ver";;
esac

# ── 2. Canonical path the config + scripts reference: ~/.config/tmux-jw ───────
mkdir -p "$HOME/.config"
TARGET="$HOME/.config/tmux-jw"
if [ "$(cd "$REPO" && pwd)" = "$(cd "$TARGET" 2>/dev/null && pwd || echo /nonexistent)" ]; then
  ok "repo is already at ~/.config/tmux-jw"
else
  ln -sfn "$REPO" "$TARGET"
  ok "linked ~/.config/tmux-jw → $REPO"
fi

# ── 3. Make hooks executable ─────────────────────────────────────────────────
chmod +x "$REPO/hooks/"*.sh
ok "hooks are executable"

# ── 4. tmux.conf — symlink only if you don't already have one ────────────────
if [ -e "$HOME/.tmux.conf" ] || [ -L "$HOME/.tmux.conf" ]; then
  warn "~/.tmux.conf already exists — NOT touching it."
  echo "    To use this config, either replace it with a symlink:"
  echo "        ln -sfn ~/.config/tmux-jw/tmux.conf ~/.tmux.conf"
  echo "    or source it from your existing config:"
  echo "        echo 'source-file ~/.config/tmux-jw/tmux.conf' >> ~/.tmux.conf"
else
  ln -s "$REPO/tmux.conf" "$HOME/.tmux.conf"
  ok "linked ~/.tmux.conf → tmux-jw/tmux.conf"
fi

# ── 5. Next steps ────────────────────────────────────────────────────────────
say ""
say "Next steps:"
echo "  1. Reload tmux:        tmux source-file ~/.tmux.conf"
echo "  2. (optional) Install TPM plugins for reboot-survival:  prefix + I"
echo "  3. Wire up Claude Code hooks: merge hooks.example.json into the"
echo "     \"hooks\" block of ~/.claude/settings.json, then restart your"
echo "     Claude Code sessions. See README.md for the event→state mapping."
ok "done"
