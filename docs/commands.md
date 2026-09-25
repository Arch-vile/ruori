# Command reference

Full detail on every `ruori` command and picker keybinding. For a quick
overview see the "Usage" section of the [README](../README.md).

## `ruori` (no args) — the manager loop

Run this in a terminal window you keep open as your **manager**. It
lists the git worktrees of whatever repo you're standing in, lets you
fzf-pick one, and on each pick:

- copies files matching the configured `copy` patterns (see
  [config-file.md](config-file.md); nothing is copied without a
  `.ruori.conf`) from the main worktree into the target worktree if
  they're missing there (never overwrites an existing file)
- creates (or reuses) a tmux session named `<repo>__<branch>__<hash>`
  rooted in that worktree — a brand-new session is a plain shell unless
  the repo's `.ruori.conf` sets `host-command` (see
  [config-file.md](config-file.md)); an already-running session is left
  alone
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

If this repo doesn't have [container mode](container-sandbox-guide.md)
turned on, each `switch`/`new` pauses once with a reminder before
falling through to host mode — Enter continues either way, it's a nudge
rather than a gate. Pass `--host-mode-fine` once, anywhere in the
arguments (`ruori --host-mode-fine`, `ruori new <branch>
--host-mode-fine`), to acknowledge it for this repo; after that, every
`switch`/`new` still prints a one-line reminder that host mode is on
(so it's never silently forgotten), but no longer blocks waiting for
Enter. See `ruori resources` for the marker file that tracks the
acknowledgment and how to delete it to bring the blocking nudge back.

### The picker

Shows a blank/`*` current-worktree marker, `TMUX` (active/-), `CLAUDE`
(busy/waiting/idle/-), `PR`, `USAGE`, and `BRANCH` columns (long branch
names are truncated, not left to shove later columns around);
highlighting a row shows that worktree's full detail — branch
(untruncated), tmux status, Claude status, PR status, usage cost, path,
and tmux session name — in a preview pane underneath the list. See
[dashboard-columns.md](dashboard-columns.md) for what each column means
and how it's computed. In container mode, `BRANCH` is also colored to
match that worktree's tmux status-bar color — see [container sandbox
guide](container-sandbox-guide.md)'s "Terminal color coding".

The row marked `*` is whichever worktree you last switched to —
starting from the main worktree, by default, on a repo with no `ruori`
history yet. This is persisted on disk
(`<git-common-dir>/ruori/current-worktree`), so it carries over across
separate runs of `ruori`. If that worktree gets deleted (`ruori rm`/the
Enter menu's "delete worktree") it falls back to the main worktree.
Distinct from `TMUX` = `active`, which just means a tmux session
happens to be running there.

Keybindings:

- **Enter** — opens a small action menu on the highlighted worktree,
  with that same row's detail (branch, tmux/Docker state, Claude
  status, PR, usage, path, session) shown in a preview pane underneath
  it, same as the picker's own preview. Items: **switch to** (first, so
  it stays the fast path — see above), **delete worktree** (see
  "Deleting a worktree" below), **open host terminal** (see "`ruori
  terminal [branch-or-session]`" below), **open in browser** (container
  mode only, and only when this worktree has at least one `:http`-typed
  `container-port` allocated — see the `container-port` directive in
  [container-sandbox-guide.md](container-sandbox-guide.md); prints a
  clickable `http://localhost:<host-port>` link per such port rather
  than launching a browser itself, and waits for Enter before
  returning to the picker so the link doesn't scroll away unread),
  **rebuild container** (container mode only — see "`ruori rebuild
  <branch>`" below), **kill tmux**/**stop container** (kills the tmux
  session, or in container mode stops the container outright; the
  `TMUX`/Docker state updates on the next picker reload, and switching
  to that row afterwards starts a fresh session for it), and **back**.
  Esc/Ctrl-C on the menu does the same as picking "back" — both return to the
  worktree picker rather than exiting `ruori`.
- **Ctrl-N** — create a new worktree without activating it. First
  asks **new branch** or **existing branch** (Esc goes back to the
  list):
  - *new branch* prompts for a name and refuses one that already
    exists locally or on any remote, pointing you to *existing branch*
    instead.
  - *existing branch* shows an fzf list of branches that don't have a
    worktree yet: local branches first, then remote-only ones (as of
    your last `git fetch`, shown as `origin/foo  (remote)`), newest
    commit first. Picking a remote one creates a local branch that
    tracks it.

  Either way the list then reloads with the new row. Pick it with Enter
  to activate it. See [gimmicks.md](gimmicks.md) ("fzf `reload`/`execute`
  bindings run in a fresh process") for why Ctrl-N doesn't activate it
  itself
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
- If `<branch>` doesn't exist locally but exists on exactly one remote
  (e.g. only `origin/<branch>`) and no `start-point` is given, a local
  branch tracking that remote branch is created, instead of an
  unrelated new branch off `HEAD`.
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
remove` would. Same as picking "delete worktree" from the Enter menu
on the highlighted row in the picker.

## `ruori rebuild <branch>`

Container mode only — deletes and recreates the container for that
worktree: `docker rm -f` followed by the same build/`docker
run`/container-copy sequence a fresh `switch` to that worktree would
trigger. Use this to pick up a Dockerfile change or refresh a stale
`container-copy`'d file (env files copied in on container creation are
never re-copied into an already-running container — see
[container-sandbox-guide.md](container-sandbox-guide.md)).

- Allocated host ports (`ruori ports`) are kept, not reassigned, so
  anything pointing at the old port mapping keeps working.
- Any `container-volume` native volumes are left alone — only the
  container object itself is disposable here; volume data survives a
  rebuild the same way it survives a plain restart. The directives
  *are* re-read, though: this is how a `container-volume` line added
  or removed since the container was created takes effect, since
  Docker can't change the mounts of an existing container. `ruori`
  prints `container-volume targets changed (+…); run 'ruori rebuild
  <branch>' to apply` on a switch whenever that's pending; the new
  subpaths start empty, the rest keep their data. The same goes for
  `container-shared-volume` lines; the shared volumes themselves are
  never touched by a rebuild (or by `ruori rm`), since other
  worktrees' containers mount them too.
- Confirms interactively first (`[y/N]`), since it discards whatever
  state lived only inside the old container.

Same as picking "rebuild container" from the Enter menu on the
highlighted row in the picker.

## `ruori details <branch-or-session>`

Everything `ruori` knows about one worktree: branch, current?, path,
session name, active tmux?, `CLAUDE` status, `PR`, usage cost, and (in
container mode) Docker state/container id/image/ports. One `URL:` line
per `:http`-typed `container-port` with a host port allocated, each a
clickable `http://localhost:<host-port>` link — omitted entirely if
there are none.

## `ruori terminal [branch-or-session]`

Opens a brand-new iTerm2 window with a plain login shell rooted at that
worktree — always on the host, even in [container
mode](container-sandbox-guide.md), unlike the tmux-attached (and, in
container mode, containerized) window the manager loop itself opens.
This is what "Host-side tooling and generated directories" in the
container sandbox guide means by running something "outside any
`ruori` session": a native `pnpm install`, a one-off host-side `git`
command, anything that needs to run on macOS rather than inside the
worktree's Linux container.

Same selector as `ruori details`/`ruori resources`: a branch or session
name, or nothing to default to whichever worktree is "current" (the
`*` marker). Unlike the manager loop's own iTerm2 window, this one
isn't tracked or replaced by anything `ruori` does later — it's an
ordinary iTerm2 window you open and close by hand, so opening several
in a row piles up windows rather than reusing one.

Same as picking "open host terminal" from the Enter menu on the
highlighted row in the picker.

## `ruori ports`

Dashboard of container-mode host-port allocations. The `URL` column is
a clickable `http://localhost:<host-port>` link for ports whose
`container-port` directive is marked `:http`, and `-` for the rest.
See the [container sandbox guide](container-sandbox-guide.md).

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

In container mode, the Repository scope under managed resources also
lists every `container-shared-volume` Docker volume of this repo (by
name prefix, so one whose directive has since been removed still
shows up) — the one kind of volume `ruori rm` never removes, since
every worktree's container shares it; remove it yourself with `docker
volume rm` when you no longer need it.

## `ruori init`

One-time per repo: copies ruori's own `README.md` and `docs/` into its
state dir (`<common-git-dir>/ruori/readme.md` and `.../ruori/docs/`,
see `ruori resources`) and prints a prompt to hand to your coding
agent — any agent, since these are just files, not a
Claude-Code-specific skill. The agent follows the copied
`docs/new-repo-setup-guide.md` to propose that repo's `.ruori.conf` and
`.devcontainer/Dockerfile`, with the rest of the copied docs available
for context. See the
[README's "Setting up ruori for a repo"](../README.md#setting-up-ruori-for-a-repo).
