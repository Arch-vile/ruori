# wt-orchestrator

Worktree context switcher — MVP.

**Setting `wt` up for a repo that doesn't have it yet?** Point an AI
agent at `docs/new-repo-setup-guide.md` — it's a self-contained guide
for generating that repo's `.wt-orchestrator.conf` and its
`.devcontainer/Dockerfile` (container mode is core to how `wt` works,
not an optional extra), asking before it writes anything. It doesn't
install or run `wt` itself — see "Install" below for that.

Run `wt` (with no args) in a terminal window you keep open as your
**manager** — it lists the git worktrees of whatever repo you're standing
in, lets you fzf-pick one, and on each pick:

**Must be launched from the main worktree**, not a linked one — `wt`
refuses to start otherwise (with a message telling you where the main
worktree is). This isn't arbitrary: several things (the tmux session-name
prefix, the PR/usage/current-worktree caches) key off the directory you
launched `wt` from on the assumption that it's one stable, repo-wide
identity — but that directory is actually wherever `git
rev-parse --show-toplevel` resolves to, which is whichever worktree's
tree you're standing in. Launching from a linked worktree would silently
give those a different value depending on where you happened to launch
`wt` from, rather than erroring loudly.

- copies files matching the configured patterns (`.env`/`.env.*` by
  default — see "Config file" below) from the main worktree into the
  target worktree if they're missing there (never overwrites an
  existing file — see "Env files" below)
- creates (or reuses) a tmux session named `<repo>__<branch>__<hash>`
  rooted in that worktree — a brand-new session starts `claude --resume`
  (Claude's own picker: resume a past conversation for that directory, or
  start fresh); an already-running session is left alone
- opens/focuses a VS Code window rooted in that worktree
- opens a **new iTerm2 window** attached to that tmux session

The manager terminal itself is never attached/replaced — after each pick
it loops back to the fzf prompt so it stays open as your dedicated
switcher. Press Esc/Ctrl-C at the picker to exit the manager loop.

Only one wt-managed VS Code window and one iTerm2 window exist at a time:
switching worktrees reuses/refocuses the VS Code window and closes the
previous iTerm2 window before opening a new one.

### Troubleshooting: leftover iTerm2 windows

iTerm2's AppleScript interface can be flaky about *when* it actually
opens or closes a window relative to when it tells `osascript` it's
done — a `create window` call can report a timeout while iTerm2 goes
ahead and creates the window moments later anyway, and a `close` call
can report success (exit 0) while the window visibly lingers for a
beat before it actually disappears. Either one, if it happens at the
wrong moment, can look like "the previous worktree's window didn't
close."

`wt` logs every step of this — which window id it thinks is active,
every close it attempts (with the exit code and whether the window was
still open immediately afterward), and every window it opens (with the
raw AppleScript response) — to
`<git-common-dir>/wt-iterm.log`, e.g. run `git rev-parse --git-common-dir`
from any worktree of the repo to find it, or just watch for the
"logging iTerm2 window open/close activity to ..." line `wt` prints on
startup. It's appended to, not rotated or cleared automatically, so
delete it yourself if it grows large. If you hit a leftover window
again, that log is the place to look — it'll show whether `wt` thought
it closed the window (and iTerm2 just hadn't caught up yet) or never
learned that window's id in the first place.

The id of the window `wt` is currently tracking is also persisted, to
`<git-common-dir>/wt-iterm-window`, so that **restarting `wt` doesn't
orphan the window it had open**. Before this, that id lived only in the
running manager process: restarting `wt` (to pick up an update, say)
made the fresh process forget which window belonged to it, so the next
switch skipped the close entirely and you ended up with two worktree
windows on screen. The file records iTerm2's pid next to the id, and the
id is only adopted on startup if iTerm2 hasn't restarted in the meantime
and the window is still open — iTerm2 numbers windows from a counter
that resets with the app, so an id from a previous run can name an
unrelated window, and `wt` would rather leave a stray window for you to
close than close the wrong one. Both non-adoptions are logged.

**Whatever's running in a worktree keeps running when you switch away.**
Each worktree has its own tmux session on the tmux server, independent of
any terminal window — switching only closes the iTerm2 *window* (a client
view attached to that session), not the session itself. So Claude Code, a
dev server, a build, a long-running script, etc. all keep running in the
background; switching back to that worktree later reuses the same session
right where you left it. If you want to actually stop something, kill
its tmux session — either `tmux kill-session -t <name>` (see `wt list`
for session names), or right from the picker: highlight a worktree and
press **Ctrl-X** to kill its tmux session without leaving the picker.
The TMUX column updates immediately, and you can keep browsing — Enter
on that same row afterwards starts a fresh session for it.

The picker itself shows a blank/`*` current-worktree marker, `TMUX`
(active/-), `CLAUDE` (busy/waiting/idle/-), `PR` (see below), `USAGE`
(see below), and `BRANCH` columns (long branch names are truncated, not
left to shove later columns around); highlighting a row shows that
worktree's full detail — branch (untruncated), tmux status, Claude
status, PR status, usage cost, path, and tmux session name — in a
preview pane underneath the list.

The row marked `*` is whichever worktree you last switched to — starting
from the main worktree, by default, on a repo with no `wt` history yet.
This is persisted on disk (`<git-common-dir>/wt-current-worktree`), so it
carries over across separate runs of `wt`: quit the manager, come back
later, and `*` still marks the worktree you were last working in rather
than resetting. If that worktree gets deleted (`wt rm`/Ctrl-D) it falls
back to the main worktree. Distinct from `TMUX` = `active`, which just
means a tmux session happens to be running there.

Status isn't live/automatic — press **Ctrl-R** to refresh `TMUX`/`CLAUDE`
on demand without leaving the picker. (An earlier attempt at automatic
periodic refresh was tried and reverted twice: killing/restarting fzf
reset the cursor and search text on every refresh, and pushing a
`reload` into the running fzf process — the same mechanism Ctrl-X
already uses successfully — turned out to reset the cursor
unpredictably in real use despite working correctly in every
isolated test. Ctrl-R uses that same `reload` mechanism, just
triggered deliberately instead of on a timer, which sidesteps
whatever that race condition was.)

`PR` and `USAGE` are refreshed together by a separate command, **Ctrl-F**
("fetch") — see "PR status" and "Usage cost" below for why they're kept
apart from Ctrl-R ("refresh").

## Claude busy/waiting/idle status

The `CLAUDE` column only works in **container mode** (see "Container
mode" below) — without it, `CLAUDE` just always shows `-`. Where it
applies, it shows:

- `busy` — Claude Code is actively working (including while a subagent
  it spawned is still running — see below)
- `waiting` — blocked on a permission prompt or an interactive
  multiple-choice question, needing you specifically
- `idle` — finished, waiting on a fresh prompt

so you can tell at a glance which agents are still working, which need
you right now, and which are just waiting around — without leaving the
picker.

This works by having several Claude Code hooks write status to a
`.wt-claude-status` file right at the root of the worktree the session
is running in, which `wt` reads. It's not just `UserPromptSubmit`/
`Stop`: `Stop` fires the moment the *main* agent hands off to a
subagent (Task tool), well before that subagent finishes, so
`PreToolUse`/`PostToolUse` are also hooked to keep `busy` accurate for
the whole time a subagent is running; `PermissionRequest`/`Elicitation`
drive the `waiting` state.

**These hooks live entirely inside the repo's own container image** —
baked into the Dockerfile by the `wt-setup-repo` skill that `wt init`
installs (see "Setting up `wt` for a repo" below) — never in the
host's own `~/.claude/settings.json`. `wt` itself never edits any Claude Code
config, on the host or otherwise; a repo not in container mode simply
doesn't get this column, by design, rather than `wt` reaching into
your host Claude Code setup to provide it. Writing the status file
*inside* the worktree (rather than some central location) means it's
automatically gone when that worktree is removed — no separate cleanup
needed. The tradeoff: it's an untracked file, so it needs an entry in
your **global** gitignore (not any repo's own `.gitignore`) — otherwise
`git worktree remove` will refuse to remove a worktree it's sitting in.

## PR status

The `PR` column shows the GitHub pull request (if any, in any state) for
a worktree's branch, using the [GitHub CLI](https://cli.github.com/)
(`gh`) — no setup needed beyond having `gh` installed and authenticated
(`gh auth login`) in a repo with a GitHub remote. It shows:

- `?` — Ctrl-F has never been pressed (nothing's been fetched yet — see
  below); not the same as `-`, which means it *was* fetched and there's
  just no PR
- `-` — no PR (open, closed, or merged) has ever existed for this branch,
  after at least one fetch (also shown if `gh`/`jq` aren't installed,
  there's no GitHub remote, or the lookup otherwise fails — those look
  identical to "no PR" rather than erroring)
- `merged` — merged
- `closed` — closed without merging
- `draft` — an open draft PR
- `unresolved` — open, has review comment threads you haven't resolved yet
- `changes` — open, reviewers requested changes (every thread resolved)
- `approved` — open, approved, with no unresolved review threads
- `pending` — open, not draft, no unresolved threads, but not yet
  approved or changes-requested (e.g. no reviews yet)

If a branch somehow matches more than one PR (rare — e.g. an old branch
name reused for a new PR after the first one merged), the most
actionable status wins, in the order listed above (`unresolved` outranks
everything, `closed` is the lowest).

Unlike `TMUX`/`CLAUDE`, this one is *not* refreshed by Ctrl-R — it looks
up each worktree branch individually (`gh pr list --head <branch>
--state all`, one call per worktree — deliberately not a single
repo-wide `gh pr list` call: that needs a `--limit`, and on an active
repo the most-recent-N PRs can already exclude an older worktree
branch's PR entirely, silently showing "-" instead of e.g. "merged" for
a perfectly real PR), plus one review-threads query per open, non-draft
match to find unresolved comments. Redoing that on every Ctrl-R/Ctrl-X
reload made the whole picker sluggish, so press **Ctrl-F** ("fetch")
instead to refresh `PR` (and `USAGE`, see below — one key for both slow
columns rather than a separate refresh per column); every other reload
(Ctrl-R, Ctrl-X, Ctrl-D, looping back after a switch) reuses whatever
Ctrl-F last fetched, cached on disk at `<git-common-dir>/wt-pr-status.cache`
(shared by every worktree of the repo) so it survives across the `fzf
reload`s each of those spawn as a fresh process. Until you press Ctrl-F
at least once, `PR` shows `?` for everything, not `-` — see the `?`
entry above.

## Usage cost

The `USAGE` column shows each worktree's total Claude Code spend in USD
— the same number `/usage` reports — summed across every Claude Code
session that's ever run with that worktree as its working directory.
It reads this straight out of Claude Code's own local transcripts
(`~/.claude/projects/<encoded-path>/*.jsonl`, one directory per project
path), which already contain a running cost total per session; no
network calls, no separate accounting setup. Same `?`/`-` distinction as
`PR`: `?` means never fetched, `-` means fetched and genuinely $0 (no
Claude Code session has ever run there).

Like `PR`, this is *not* refreshed by Ctrl-R — computing it means
scanning every Claude Code session transcript on the machine to find
the ones that belong to this repo's worktrees, which gets slower as
your overall Claude Code history grows regardless of how many
worktrees this repo has. **Ctrl-F** (the same key that refreshes `PR`)
refreshes `USAGE` too; it's cached on disk at
`<git-common-dir>/wt-usage-cost.cache` the same way `PR`'s cache works,
keyed by worktree path (not branch, since the cost is tied to which
directory the sessions ran in). Until you press Ctrl-F at least once,
`USAGE` shows `?` for everything.

`wt list` fetches both `PR` and `USAGE` fresh every time, since it's a
one-shot command rather than a hot reload loop.

## Creating a worktree

`wt new <branch> [start-point]` creates a worktree and immediately
activates it — same env-file copy-in, tmux/container session, VS Code
window, and iTerm2 window a picker selection would trigger, without
needing to also fzf-pick the branch you just created afterward.

- If `<branch>` already exists locally, it's checked out as-is (any
  `start-point` argument is ignored, with a warning).
- Otherwise a new branch is created from `start-point` (default: the
  main worktree's current `HEAD`) — equivalent to `git worktree add -b`.
- The worktree is created as a **sibling** of the main worktree, never
  nested inside it: `<main-worktree-parent>/<repo>.worktrees/<branch>`,
  with any `/` in `<branch>` flattened to `-` (so `feat/x` becomes a
  single `feat-x` directory, not a nested `feat/x` one — the worktree's
  directory name is independent of the branch's own ref name).
  Nesting under the main tree risks tools that walk it (editors, build
  steps, `find`) picking up the new worktree's contents too.
- Refuses if a worktree for that branch already exists (see `wt list`)
  or if the target path already exists on disk.

**Ctrl-N** in the picker does the same from inside the manager loop:
prompts for a branch name, creates the worktree, and reloads the list so
the new row appears — but deliberately stops there rather than also
activating it. Activation (tmux/container start, VS Code, iTerm2 window)
stays in the main loop's `enter: switch` path so the single, persistent
manager process remains the only thing that ever opens/closes the
tracked iTerm2 window; press Enter on the new row to actually switch to
it. `wt new` on the command line doesn't have this constraint (there's
no already-running manager loop's window state to conflict with), so it
activates the worktree immediately.

## Deleting a worktree

`wt rm <branch>` (or **Ctrl-D** on the highlighted row in the picker)
deletes a worktree and everything `wt` itself created for it:

1. kills its tmux session, if one is running
2. `git worktree remove`s it — if git refuses (uncommitted/untracked
   changes), you're asked whether to force it, which discards those
   changes
3. asks whether to also delete the local branch (skipped for a detached
   worktree, which has none)
4. drops that branch's entry from the PR-status cache (see "PR status"
   above), so a stale row doesn't linger after the next reload

Every step that can destroy work — the worktree removal itself, forcing
past git's refusal, and the branch deletion — has its own `[y/N]`
confirmation prompt; nothing happens silently. The main worktree (the
repo root) can't be deleted this way — `wt` refuses, same as `git
worktree remove` would.

## Env files

`git worktree add` only checks out tracked files, so a new worktree
starts with none of your gitignored, machine-local env files (`.env`,
`.env.local`, etc.) — just any tracked template (`.env.example`) if the
repo has one. On every switch, `wt` copies each file matching a
configured pattern (see "Config file" below) found in the **main
worktree** (the repo root — not necessarily the one you're switching
*from*) into the target worktree, but only ones that don't already
exist there. It never overwrites a file already present, so once a
worktree has its own copy you can freely diverge it (e.g. a different
port) without `wt` stomping on it on a later switch.

Dynamic port allocation (so worktrees don't collide on the same port)
is handled by container mode's `container-port` directive, a separate
mechanism from env-file copying — see "Container mode" below.

## Config file

`wt` looks for `.wt-orchestrator.conf` at the main worktree's root.
It's created by you, not `wt` — if it doesn't exist, `wt` falls back to
copying just `.env`/`.env.*` (the previous hardcoded behavior).

Each line is `<directive> <value>`. Blank lines and lines starting with
`#` are ignored; an unrecognized directive is warned about and skipped
rather than breaking the file. This shape is deliberate: the same file
will grow more kinds of setting later (editor override, port range
base — see TODO.md) without needing a new format.

The only directive today is `copy`, for which gitignored files get
copied into a new worktree if it's missing them: the value is a glob
pattern relative to the repo root. A plain filename matches exactly
(an exact path, `config/local.json`, works too); shell wildcards (`*`,
`?`, `[...]`) work as well, including partway through a path:

```
# .wt-orchestrator.conf — files to copy into a new worktree if missing
copy .env
copy .env.*
copy config/local.json
copy secrets/*.local.yaml
```

You (or an AI coding agent) can generate this file for a given repo —
see `docs/agent-config-guide.md` for a self-contained set of
instructions written for exactly that: point an agent at it, in
whatever repo you want `wt` set up in, and it'll inspect that repo's
`.gitignore`/config and write a sensible `.wt-orchestrator.conf`.

Four more directives opt a repo into **container mode** (see
"Container mode" below): `container`, `container-file`,
`container-port`, `container-copy`. See
`docs/container-sandbox-guide.md` for what they do and a worked
example — a repo with none of them behaves exactly as described above.

The easiest way to get all of this (config file *and* Dockerfile *and*
the Claude Code status hook baked into it) written for a repo in one
shot is `wt init` — see "Setting up `wt` for a repo" below.

## Setting up `wt` for a repo

`wt init`, run once inside a repo, writes a Claude Code skill there:
`.claude/skills/wt-setup-repo/SKILL.md`, containing the full,
self-contained instructions from `docs/new-repo-setup-guide.md`
(everything above: `.wt-orchestrator.conf`, the Dockerfile, and the
container-only Claude Code status hook). `wt init` itself only writes
that one file — it never touches `.wt-orchestrator.conf`, a
Dockerfile, Docker, or anything on your host's own Claude Code config.

```sh
cd ~/git/some-repo
wt init      # writes .claude/skills/wt-setup-repo/SKILL.md
git add .claude && git commit -m "Add wt-setup-repo skill"
```

Then, in a normal Claude Code session in that repo (on your host — no
container needed for this part), ask it to run the `wt-setup-repo`
skill. It'll inspect the repo, propose `.wt-orchestrator.conf` and
Dockerfile contents (including the status hook), and write them once
you confirm — see `docs/new-repo-setup-guide.md` for exactly what it
does.

Committing the skill means every contributor's Claude Code session in
this repo can run it, not just yours — worth doing even if you're the
only one setting `wt` up today.

## Container mode

By default `wt` runs a worktree's tmux session — and everything
started in it, including any coding agent run with permission checks
disabled — directly on the host, with the same filesystem access as
your user account. Adding `container on` to `.wt-orchestrator.conf`
moves *just* that tmux session (and everything run inside it) into a
per-worktree Docker container instead: `wt`, iTerm2 window automation,
and `code -r` all stay host-side and unchanged either way. The
container only ever gets the worktree's own directory and the shared
git common dir mounted — nothing else, ever, unless you explicitly list
it via `container-copy`. `wt` never decides what runs inside the
container's tmux session — that's entirely up to your own
`.devcontainer/Dockerfile` (its `CMD`/entrypoint, a tmux
`default-command`, or you typing it by hand), which also makes this
work with any agent, or no agent at all.

This also solves port collisions across concurrently-open worktrees:
`container-port` directives get a freshly-allocated, worktree-specific
host port each, published from the container and injected into its
environment — run `wt ports` to see current allocations. `wt rm` tears
the container down and frees its ports along with everything else it
already cleans up.

See `docs/container-sandbox-guide.md` for the full directive reference,
Dockerfile authoring requirements, and a worked example. A repo with no
`container` directive is completely unaffected — container mode is
strictly opt-in, per repo.

## Requirements

- `git`, `tmux`, `fzf`, `code` (VS Code CLI) on `PATH`
- iTerm2, with **Settings > General > Magic > "Allow all apps to control
  iTerm2 via AppleEvents"** enabled (needed for `wt` to open windows for you)
- `docker` on `PATH` — only required for a repo that opts into
  container mode (see "Container mode" above); repos that don't use it
  need no Docker installation at all

## Install

```sh
ln -s "$(pwd)/bin/wt" ~/.local/bin/wt   # or any dir on your PATH
```

## Usage

```sh
cd ~/git/some-repo
wt init        # one-time per repo: write the wt-setup-repo Claude Code
               # skill — see "Setting up wt for a repo"
wt list        # dashboard: which worktree you're in, branch, active tmux
               # session?, session name, path, PR status, usage cost
               # (fetches PR/usage fresh every time — it's a one-shot
               # command, not a hot loop)
wt new <branch> [start-point]
               # create + activate a worktree for <branch> — see "Creating a worktree"
wt rm <branch> # delete the worktree for <branch> — see "Deleting a worktree"
wt details <branch-or-session>
               # everything wt knows about one worktree: branch, current?,
               # path, session name, active tmux?, CLAUDE status, PR, usage
               # cost, and (container mode) Docker state/container id/image/ports
wt ports       # dashboard of container-mode host-port allocations — see "Container mode"
wt             # manager loop: pick a worktree, get an iTerm2 window for it, repeat
               # in the picker: Enter switches, Ctrl-N creates a worktree
               # (see "Creating a worktree"), Ctrl-X kills the highlighted
               # worktree's tmux session in place, Ctrl-D deletes the
               # highlighted worktree, Ctrl-R refreshes TMUX/CLAUDE, Ctrl-F
               # fetches PR status + usage cost together (see "PR status"/
               # "Usage cost" below — kept separate from Ctrl-R since both
               # are slow); highlighting a row previews its path/session
               # below the list
```

## Roadmap (not yet built)

- AeroSpace workspace assignment (move active editor+terminal to a
  dedicated workspace, background the rest)
