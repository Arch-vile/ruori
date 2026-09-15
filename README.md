<img src="resources/ruori-large.gif" width="240" alt="ruori picker demo">

# Ruori

A fast, one-key way to switch between git worktrees — and have your
terminal, editor, and coding agent follow you there.

## Why this exists

Running more than one coding agent at once means running more than one
git worktree — each agent needs its own directory so they don't step
on each other's files. Worktrees make that possible, but switching
between them by hand is a chore: `cd` into the right one, make sure a
terminal's running there, open an editor, copy over `.env` files,
dodge port collisions.

`ruori` handles two things:

1. **Makes working with worktrees painless** — one keypress switches
   your terminal, editor, and agent over to a different worktree.
2. **Containerizes each worktree**, so an agent running with
   permission checks off is boxed in to that worktree instead of your
   whole machine.

## Install

Requirements: `git`, `tmux`, `fzf`, and the `code` CLI (VS Code) on your
`PATH`, plus iTerm2 with **Settings > General > Magic > "Allow all apps
to control iTerm2 via AppleEvents"** turned on (so `ruori` can open
windows for you). All are standard installs — `brew install tmux fzf`
covers the two you probably don't have yet, VS Code's `code` command is
added via its command palette ("Shell Command: Install 'code' command
in PATH"), and iTerm2 is at [iterm2.com](https://iterm2.com/).

Then symlink the script onto your `PATH`:

```sh
ln -s "$(pwd)/bin/ruori" ~/.local/bin/ruori   # or any dir on your PATH
```

## Quick start

```sh
cd ~/git/some-repo
ruori          # opens the picker — try it on any repo, right away
```

The picker lists that repo's git worktrees. Pick one (or just the repo
root, if that's all there is) and `ruori` opens a terminal session and a
VS Code window rooted there. Pick a different one later and it switches
you over cleanly, closing the old terminal window while leaving
whatever was running in it untouched in the background.

That's the whole workflow. Run `ruori` with no arguments whenever you
want to switch — it loops back to the picker each time, so you can
leave it running in a terminal you keep around just for this. For the
other commands (`new`, `list`, `rm`, and the rest), see
[docs/commands.md](docs/commands.md).

## Dev container

By default `ruori` runs a worktree's terminal session — and whatever
agent or dev server you start in it — directly on your host. If that
agent has permission checks turned off, it can touch anything your
host user account can touch.

**Container mode** boxes each worktree's session into its own Docker
container instead, mounting only that worktree's directory (and the
shared git data all worktrees of a repo need) — nothing else on your
machine is reachable from inside it. It's opt-in per repo and works
with any agent, since `ruori` only manages the container's lifecycle
and never decides what runs inside it.

This is also what closes
[Arch-vile/ruori#16](https://github.com/Arch-vile/ruori/issues/16).
See [docs/container-sandbox-guide.md](docs/container-sandbox-guide.md)
for the full setup walkthrough — or just run `ruori init` (below) and
hand the prompt to your coding agent.

## Getting the most out of `ruori`

`ruori` works out of the box with just `.env` copying. To get the full
picture — a generated `.ruori.conf`, a container-mode Dockerfile, and
the Claude Code status hooks that power the `CLAUDE` column — run:

```sh
cd ~/git/some-repo
ruori init   # copies this README and docs/ into ruori's own state dir
             # and prints a prompt for your coding agent
```

`ruori init` doesn't touch this repo at all — it just copies these
docs into ruori's own storage (`ruori resources` shows exactly where)
and prints a prompt. Paste that into a session with your coding
agent — any agent, this isn't a Claude Code skill — and it'll follow
`new-repo-setup-guide.md` to inspect the repo, propose `.ruori.conf`
and Dockerfile contents, and write them once you confirm. Nothing to
commit on ruori's behalf.

## Going further

- **Full command and keybinding reference** — every command, and every
  key you can press in the picker (create/delete a worktree, kill a
  session, refresh status): [docs/commands.md](docs/commands.md)
- **What the picker's columns mean** — the `TMUX`, `CLAUDE`,
  `PR`, and `USAGE` columns, and how each is kept up to date:
  [docs/dashboard-columns.md](docs/dashboard-columns.md)
- **The config file** — `.ruori.conf`, and how `ruori` decides which
  env files to copy into a new worktree:
  [docs/config-file.md](docs/config-file.md)
- **Troubleshooting** — mainly leftover iTerm2 windows:
  [docs/troubleshooting.md](docs/troubleshooting.md)
- **Setting up a new repo** — the full walkthrough `ruori init` (above)
  points your agent at:
  [docs/new-repo-setup-guide.md](docs/new-repo-setup-guide.md)

## Roadmap

Not yet built: AeroSpace workspace assignment, so switching worktrees
also moves the active editor and terminal to a dedicated workspace and
backgrounds the rest. See [TODO.md](TODO.md) for the full list of
in-progress and planned work.
