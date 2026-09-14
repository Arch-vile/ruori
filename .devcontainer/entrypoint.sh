#!/usr/bin/env bash
# Runs every time this container starts (ruori always invokes the image
# as `... sleep infinity`; with this script set as ENTRYPOINT, that
# arrives here as "$@" and gets exec'd at the end, so ruori's own
# behavior is otherwise unchanged).
#
# Points Claude Code's whole config (login, settings.json/hooks,
# session history) at shared storage under RUORI_SHARED_DIR (injected
# by ruori -- see bin/ruori's container_start_if_needed), via its own
# CLAUDE_CONFIG_DIR env var, so every worktree's container for this
# repo shares the *same* login: log in once, in any one container, and
# every other one picks it up immediately.
#
# This uses CLAUDE_CONFIG_DIR rather than symlinking ~/.claude, because
# Claude Code's login isn't just ~/.claude/.credentials.json -- it also
# needs ~/.claude.json, a *sibling* file directly in $HOME, not
# something under ~/.claude at all. Symlinking that sibling file
# wouldn't survive: Claude Code writes it via write-then-rename (same
# as .credentials.json), which replaces a symlink with a fresh local
# file rather than writing through it. CLAUDE_CONFIG_DIR sidesteps this
# entirely by consolidating everything -- .claude.json, credentials,
# settings.json, session history -- into one real directory, which
# also happens to be the one under RUORI_SHARED_DIR: no symlink
# anywhere, so no rename-onto-a-leaf-symlink problem. (Verified: with
# CLAUDE_CONFIG_DIR set, Claude Code ignores ~/.claude/settings.json
# entirely, so this repo's baked-in hooks settings only take effect
# once seeded into the shared dir below -- confirmed empirically, not
# assumed.)
#
# CLAUDE_CONFIG_DIR has to be visible to whatever later runs `claude`
# inside the container -- the tmux session ruori attaches to, or any
# `docker exec` -- not just this script's own process. A plain `export`
# here wouldn't reach those (they're separate processes spawned fresh
# against the container's own config, not children of this script), so
# it's appended to /etc/bash.bashrc instead, sourced automatically by
# every interactive bash shell -- confirmed empirically to reach a
# tmux-created shell the same way ruori creates one.
#
# See docs/container-sandbox-guide.md's "Recipe: Claude Code auth" for
# the tradeoffs (this shares session transcripts/history across every
# worktree's containers for this repo, not just the login, and trades
# away per-container isolation for never needing to re-authenticate).
set -euo pipefail

if [ -n "${RUORI_SHARED_DIR:-}" ]; then
  shared_claude_dir="$RUORI_SHARED_DIR/ruori-claude-home"
  mkdir -p "$shared_claude_dir"

  # First container to ever start seeds the shared dir's settings.json
  # from whatever this image bakes into ~/.claude/settings.json (the
  # hooks config) -- no-clobber, so a later container never overwrites
  # a login/history already in the shared dir. Delete the shared dir
  # yourself to force a fresh reseed after changing the Dockerfile's
  # baked-in settings.
  if [ -e "$HOME/.claude/settings.json" ] && [ ! -e "$shared_claude_dir/settings.json" ]; then
    cp "$HOME/.claude/settings.json" "$shared_claude_dir/settings.json"
  fi

  marker="export CLAUDE_CONFIG_DIR=\"$shared_claude_dir\""
  grep -qxF "$marker" /etc/bash.bashrc 2>/dev/null || echo "$marker" >>/etc/bash.bashrc
fi

exec "$@"
