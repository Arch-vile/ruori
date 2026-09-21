<img src="resources/ruori-large.gif" width="240" alt="ruori picker demo">

# Ruori

Supercharge your agentic workflow. Ruori makes running simultaneous coding agents
painless with one-key git worktree switching—keeping your terminal, editor, and AI
sessions aligned.

<img width="755" height="462" alt="image" src="https://github.com/user-attachments/assets/fcdfc853-6f1d-44de-b125-49e97d6b879c" />


## Motivation

Running more than one coding agent at once means running more than one
git worktree, since each agent needs its own directory so they don't
step on each other's toes. Worktrees make that possible, but
switching between them by hand is a chore: opening your IDE there,
copying env files to start the application and handling port conflicts
to name a few.

`ruori` makes working with worktrees painless — simple TUI
switches your terminal, editor, and agent over to a different
worktree and takes care of all the plumbing work.

## Install

| TODO: list needs updating, alternatives and such.

Requirements: `git`, `tmux`, `fzf`, and the `code` CLI (VS Code) on your
`PATH`, plus iTerm2 with **Settings > General > Magic > "Allow all apps
to control iTerm2 via AppleEvents"** turned on (so `ruori` can open
windows for you). All are standard installs — `brew install tmux fzf`
covers the two you probably don't have yet, VS Code's `code` command is
added via its command palette ("Shell Command: Install 'code' command
in PATH"), and iTerm2 is at [iterm2.com](https://iterm2.com/).

Then symlink the `ruori` script onto your `PATH`:

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

See available commands in [docs/commands.md](docs/commands.md).

## Hot features you want to use 🔥

To get the most out of Ruori you want to do a proper configuration per
repository. You can configure Ruori manually (see docs) but the easiest
way is to use your favourite AI agent.

To setup ruori and get access to advanced features:

```sh
cd ~/git/some-repo
ruori init   # copies this README and docs/ into ruori's own state dir
             # and prints a prompt for your coding agent
```

### Handling git ignored files

By default git worktrees do not include git ignored files from parent.
Often you would like some of those files to be carried over to a worktree,
notably any env files needed for to start the application.

Ruori supports copying specified files over to your worktrees.

### Devoloper container

By default Ruori runs all tools directly on your host but you can configure
it to start its own Docker container per worktree allowing isolation from
the rest of your machine.

Now you can finally run your AI agent in YOLO mode.

NOTE: you worktree directory is writable from the container.

See [docs/container-sandbox-guide.md](docs/container-sandbox-guide.md)
for the full container-mode walkthrough.

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
- **Gimmicks** — every non-obvious problem `ruori` has had to work
  around, what was rejected, and why the code is the way it is:
  [docs/gimmicks.md](docs/gimmicks.md)
- **Setting up a new repo** — the full walkthrough `ruori init` (above)
  points your agent at:
  [docs/new-repo-setup-guide.md](docs/new-repo-setup-guide.md)


