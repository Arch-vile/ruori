# Command reference

Full detail on every `ruori` command and picker keybinding. For a quick
overview see the "Usage" section of the [README](../README.md).

## `ruori` (no args) — the manager loop

Run this in a terminal window you keep open as your **manager**. It
lists the git worktrees of whatever repo you're standing in, lets you
fzf-pick one, and on each pick:

- copies files matching the configured patterns (`.env`/`.env.*` by
  default — see [config-file.md](config-file.md)) from the main
  worktree into the target worktree if they're missing there (never
  overwrites an existing file)
- creates (or reuses) a tmux session named `<repo>__<branch>__<hash>`
  rooted in that worktree — a brand-new session starts `claude --resume`
  (Claude's own picker: resume a past conversation for that directory,
  or start fresh); an already-running session is left alone
- opens/focuses a VS Code window rooted in that worktree
- opens a **new iTerm2 window** attached to that tmux session

The manager terminal itself is never attached/replaced — after each
pick it loops back to the fzf prompt so it stays open as your dedicated
switcher. Press Esc/Ctrl-C at the picker to exit the manager loop.

Only one ruori-managed VS Code window and one iTerm2 window exist at a
time: switching worktrees reuses/refocuses the VS Code window and
closes the previous iTerm2 window before opening a new one. See
[troubleshooting.md](troubleshooting.md) if a closed window ever seems
to linger on screen.

**Must be launched from the main worktree**, not a linked one — `ruori`
refuses to start otherwise (with a message telling you where the main
worktree is). Several things (the tmux session-name prefix, the
PR/usage/current-worktree caches) key off the directory you launched
`ruori` from on the assumption that it's one stable, repo-wide identity —
but that directory is actually wherever `git rev-parse --show-toplevel`
resolves to, which is whichever worktree's tree you're standing in.
Launching from a linked worktree would silently give those a different
value depending on where you happened to launch `ruori` from, rather
than erroring loudly.

### The picker

Shows a blank/`*` current-worktree marker, `TMUX` (active/-), `CLAUDE`
(busy/waiting/idle/-), `PR`, `USAGE`, and `BRANCH` columns (long branch
names are truncated, not left to shove later columns around);
highlighting a row shows that worktree's full detail — branch
(untruncated), tmux status, Claude status, PR status, usage cost, path,
and tmux session name — in a preview pane underneath the list. See
[dashboard-columns.md](dashboard-columns.md) for what each column means
and how it's computed.

The row marked `*` is whichever worktree you last switched to —
starting from the main worktree, by default, on a repo with no `ruori`
history yet. This is persisted on disk
(`<git-common-dir>/ruori-current-worktree`), so it carries over across
separate runs of `ruori`. If that worktree gets deleted (`ruori rm`/Ctrl-D)
it falls back to the main worktree. Distinct from `TMUX` = `active`,
which just means a tmux session happens to be running there.

Keybindings:

- **Enter** — switch to the highlighted worktree (see above)
- **Ctrl-N** — create a new worktree (prompts for a branch name, creates
  it, reloads the list) without activating it — see "Creating a
  worktree" below for why it stops there
- **Ctrl-X** — kill the highlighted worktree's tmux session in place,
  without leaving the picker; the `TMUX` column updates immediately,
  and Enter on that row afterwards starts a fresh session for it
- **Ctrl-D** — delete the highlighted worktree (see "Deleting a
  worktree" below)
- **Ctrl-R** — refresh `TMUX`/`CLAUDE` on demand (not automatic — see
  [dashboard-columns.md](dashboard-columns.md) for why)
- **Ctrl-F** — fetch `PR` status and `USAGE` cost together (both are
  slow lookups, deliberately kept separate from Ctrl-R — see
  [dashboard-columns.md](dashboard-columns.md))
- **Esc / Ctrl-C** — exit the manager loop

## `ruori list`

Dashboard: which worktree you're in, branch, active tmux session?,
session name, path, PR status, usage cost. Unlike the picker, this
fetches `PR`/`USAGE` fresh every time it runs, since it's a one-shot
command rather than a hot reload loop.

## `ruori new <branch> [start-point]`

Creates a worktree and immediately activates it — same env-file
copy-in, tmux/container session, VS Code window, and iTerm2 window a
picker selection would trigger, without needing to also fzf-pick the
branch you just created afterward.

- If `<branch>` already exists locally, it's checked out as-is (any
  `start-point` argument is ignored, with a warning).
- Otherwise a new branch is created from `start-point` (default: the
  main worktree's current `HEAD`) — equivalent to `git worktree add -b`.
- The worktree is created as a **sibling** of the main worktree, never
  nested inside it: `<main-worktree-parent>/<repo>.worktrees/<branch>`,
  with any `/` in `<branch>` flattened to `-` (so `feat/x` becomes a
  single `feat-x` directory, not a nested `feat/x` one). Nesting under
  the main tree risks tools that walk it (editors, build steps, `find`)
  picking up the new worktree's contents too.
- Refuses if a worktree for that branch already exists (see `ruori list`)
  or if the target path already exists on disk.

Ctrl-N in the picker does the same, minus activation — see "The
picker" above.

## `ruori rm <branch>`

Deletes a worktree and everything `ruori` itself created for it:

1. kills its tmux session, if one is running
2. `git worktree remove`s it — if git refuses (uncommitted/untracked
   changes), you're asked whether to force it, which discards those
   changes
3. asks whether to also delete the local branch (skipped for a detached
   worktree, which has none)
4. drops that branch's entry from the PR-status cache, so a stale row
   doesn't linger after the next reload

Every step that can destroy work has its own `[y/N]` confirmation
prompt; nothing happens silently. The main worktree (the repo root)
can't be deleted this way — `ruori` refuses, same as `git worktree
remove` would. Same as Ctrl-D on the highlighted row in the picker.

## `ruori details <branch-or-session>`

Everything `ruori` knows about one worktree: branch, current?, path,
session name, active tmux?, `CLAUDE` status, `PR`, usage cost, and (in
container mode) Docker state/container id/image/ports.

## `ruori ports`

Dashboard of container-mode host-port allocations. See the
[container sandbox guide](container-sandbox-guide.md).

## `ruori resources [branch-or-session]`

Everything `ruori` itself creates, reads, or manages, grouped into
book-keeping files, configuration, and managed resources (Docker/tmux)
— each section split into Global, Repository, and Worktree scope, with
a full absolute path for every filesystem-backed entry. Meant to make
`ruori` transparent about its own file/resource usage rather than a
magic box; a static description (what it is, why `ruori` needs it,
when/who updates it), not a live exists/missing check.

The Worktree-scope entries describe **one worktree at a time** — same
selector as `ruori details`: pass a branch or session name, or omit it
to default to whichever worktree is "current" (the `*` marker). See
[config-file.md](config-file.md) and the
[container sandbox guide](container-sandbox-guide.md) for detail on
the configuration-driven pieces it points at.

## `ruori init`

One-time per repo: writes a Claude Code skill,
`.claude/skills/ruori-setup-repo/SKILL.md`, that an agent can run to
generate that repo's `.ruori.conf` and `.devcontainer/Dockerfile`. See
the [README's "Setting up ruori for a repo"](../README.md#setting-up-ruori-for-a-repo).
