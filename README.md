<img src="resources/ruori-large.gif" width="240" alt="ruori picker demo">

# Ruori

A fast, one-key way to switch between git worktrees — and have your
terminal, editor, and coding agent follow you there.

## Why this exists

Working on several branches at once (especially with a coding agent
running in each one) means juggling git worktrees. Every time you
switch, you end up doing the same chores by hand: `cd` into the right
directory, make sure a terminal session is actually running there,
open VS Code in that folder, copy over your `.env` file because a
fresh worktree never has it, and hope you don't collide with another
worktree's dev server port.

`ruori` turns all of that into one keypress. Run it, pick a worktree
from a list, and it sets up everything for you — a persistent terminal
session, an editor window, your env files — so switching context takes
a second instead of a minute, and you can keep several agents working
in parallel without losing track of them.

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

A few commands round out the everyday flow:

```sh
ruori new <branch>   # create a worktree for a new branch and jump into it
ruori list           # see all your worktrees, their branches, and status at a glance
ruori rm <branch>    # clean up a worktree you're done with
```

That's the whole workflow. Run `ruori` with no arguments whenever you
want to switch — it loops back to the picker each time, so you can
leave it running in a terminal you keep around just for this.

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
- **Running your agent in a container**, so it's sandboxed to just the
  worktree it's working in rather than your whole machine:
  [docs/container-sandbox-guide.md](docs/container-sandbox-guide.md)
- **Troubleshooting** — mainly leftover iTerm2 windows:
  [docs/troubleshooting.md](docs/troubleshooting.md)

## Setting up `ruori` for a repo

`ruori` works out of the box with just `.env` copying. To get the full
picture — a generated `.ruori.conf`, a container-mode Dockerfile, and
the Claude Code status hooks that power the `CLAUDE` column — run:

```sh
cd ~/git/some-repo
ruori init   # writes .claude/skills/ruori-setup-repo/SKILL.md
git add .claude && git commit -m "Add ruori-setup-repo skill"
```

Then, in a normal Claude Code session in that repo, ask it to run the
`ruori-setup-repo` skill. It'll inspect the repo, propose config and
Dockerfile contents, and write them once you confirm. Committing the
skill means every contributor's Claude Code session in this repo can
run it, not just yours.

Setting `ruori` up for a repo that doesn't have it yet, without going
through `ruori init` first? Point an AI agent directly at
[docs/new-repo-setup-guide.md](docs/new-repo-setup-guide.md) — it's the
same self-contained guide, and it asks before writing anything.

## Roadmap

Not yet built: AeroSpace workspace assignment, so switching worktrees
also moves the active editor and terminal to a dedicated workspace and
backgrounds the rest. See [TODO.md](TODO.md) for the full list of
in-progress and planned work.
