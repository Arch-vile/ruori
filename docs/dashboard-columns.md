# Dashboard columns

Detail on how the picker's `TMUX`, `CLAUDE`, `PR`, and `USAGE` columns
work, and why they're refreshed differently. For the picker itself, see
[commands.md](commands.md).

## `TMUX` and Ctrl-R

Whether a tmux session is currently running for that worktree
(`active`/`-`). Not live/automatic — press **Ctrl-R** to refresh
`TMUX`/`CLAUDE` on demand without leaving the picker.

**Whatever's running in a worktree keeps running when you switch
away.** Each worktree has its own tmux session on the tmux server,
independent of any terminal window — switching only closes the iTerm2
*window* (a client view attached to that session), not the session
itself. So Claude Code, a dev server, a build, a long-running script,
etc. all keep running in the background; switching back to that
worktree later reuses the same session right where you left it. If you
want to actually stop something, kill its tmux session — either `tmux
kill-session -t <name>` (see `ruori list` for session names), or
"kill tmux"/"stop container" from the picker's Enter action menu.

(An earlier attempt at automatic periodic refresh was tried and
reverted twice: killing/restarting fzf reset the cursor and search text
on every refresh, and pushing a `reload` into the running fzf process —
the same in-place `reload` mechanism the picker's old Ctrl-X/Ctrl-D
bindings used to use, before those actions moved into the Enter menu —
turned out to reset the cursor unpredictably in real use despite
working correctly in every isolated test. Ctrl-R still uses that same
`reload` mechanism, just triggered deliberately instead of on a timer,
which sidesteps whatever that race condition was; the Enter menu's
delete/kill actions, by contrast, exit the picker and let the manager
loop re-invoke fzf fresh next iteration, same as switching already
does, so cursor/search state doesn't carry over across them.)

## `CLAUDE` busy/waiting/idle status

Only works in **container mode** (see the
[container sandbox guide](container-sandbox-guide.md)) — without it,
`CLAUDE` just always shows `-`. Where it applies, it shows:

- `busy` — Claude Code is actively working (including while a subagent
  it spawned is still running — see below)
- `waiting` — blocked on a permission prompt or an interactive
  multiple-choice question, needing you specifically
- `idle` — finished, waiting on a fresh prompt

so you can tell at a glance which agents are still working, which need
you right now, and which are just waiting around — without leaving the
picker.

This works by having several Claude Code hooks write status to a
`.ruori/claude-status` file right at the root of the worktree the
session is running in, which `ruori` reads. It's not just
`UserPromptSubmit`/`Stop`: `Stop` fires the moment the *main* agent
hands off to a subagent (Task tool), well before that subagent
finishes, so `PreToolUse`/`PostToolUse` are also hooked to keep `busy`
accurate for the whole time a subagent is running;
`PermissionRequest`/`Elicitation` drive the `waiting` state.

**These hooks live entirely inside the repo's own container image** —
baked into the Dockerfile by whatever coding agent followed the guide
`ruori init` copies out — never in the host's own
`~/.claude/settings.json`.
`ruori` itself never edits any Claude Code config, on the host or
otherwise; a repo not in container mode simply doesn't get this column,
by design, rather than `ruori` reaching into your host Claude Code
setup to provide it. Writing the status file *inside* the worktree
(rather than some central location) means it's automatically gone when
that worktree is removed — no separate cleanup needed. The tradeoff:
it's an untracked file, so it needs an entry in your **global**
gitignore (not any repo's own `.gitignore`) — otherwise `git worktree
remove` will refuse to remove a worktree it's sitting in.

## `PR` status and Ctrl-F

Shows the GitHub pull request (if any, in any state) for a worktree's
branch, using the [GitHub CLI](https://cli.github.com/) (`gh`) — no
setup needed beyond having `gh` installed and authenticated (`gh auth
login`) in a repo with a GitHub remote. It shows:

- `?` — Ctrl-F has never been pressed (nothing's been fetched yet); not
  the same as `-`, which means it *was* fetched and there's just no PR
- `-` — no PR (open, closed, or merged) has ever existed for this
  branch, after at least one fetch (also shown if `gh`/`jq` aren't
  installed, there's no GitHub remote, or the lookup otherwise fails —
  those look identical to "no PR" rather than erroring)
- `merged` — merged
- `closed` — closed without merging
- `draft` — an open draft PR
- `unresolved` — open, has review comment threads you haven't resolved
  yet
- `changes` — open, reviewers requested changes (every thread resolved)
- `approved` — open, approved, with no unresolved review threads
- `pending` — open, not draft, no unresolved threads, but not yet
  approved or changes-requested (e.g. no reviews yet)

If a branch somehow matches more than one PR (rare — e.g. an old branch
name reused for a new PR after the first one merged), the most
actionable status wins, in the order listed above (`unresolved`
outranks everything, `closed` is the lowest).

Unlike `TMUX`/`CLAUDE`, this one is *not* refreshed by Ctrl-R — it looks
up each worktree branch individually (`gh pr list --head <branch>
--state all`, one call per worktree — deliberately not a single
repo-wide `gh pr list` call: that needs a `--limit`, and on an active
repo the most-recent-N PRs can already exclude an older worktree
branch's PR entirely, silently showing "-" instead of e.g. "merged" for
a perfectly real PR), plus one review-threads query per open, non-draft
match to find unresolved comments. Redoing that on every reload made
the whole picker sluggish, so press **Ctrl-F** ("fetch") instead — one
key refreshes both `PR` and `USAGE` (see below) rather than a separate
refresh per column. Every other reload (Ctrl-R, and looping back after
switching to/deleting/killing a worktree via the Enter menu) reuses
whatever Ctrl-F last fetched, cached on disk at
`<git-common-dir>/ruori/pr-status.cache` (shared by every worktree of
the repo) so it survives across the `fzf reload`s each of those spawn
as a fresh process. Until you press Ctrl-F at least once, `PR` shows
`?` for everything, not `-`.

## `USAGE` cost

Each worktree's total Claude Code spend in USD, summed across every
Claude Code session that's ever run in that worktree, started at its
root or in any subdirectory of it (e.g. `apps/api`). It's the same
figure Claude Code itself shows as a session's cost: computed locally
from token counts at list price, so on a Pro/Max subscription it's
what the work *would* have cost on the API, not what you pay — still
useful for seeing which worktree is burning the most. No network calls
either way. Where the number comes from depends on the repo's mode.

**Container mode** reads one small file per Claude Code session from
`.ruori/usage/` at the worktree root: each is named after the session
id and holds that session's running cost. They're written from inside
the container by `ruori-claude-statusline`, a script set as Claude
Code's status line in the repo's own image (see
`docs/new-repo-setup-guide.md`), which Claude Code re-runs every few
seconds with the session's JSON — including `cost.total_cost_usd`.
`ruori` just sums the files, live, on every picker draw and reload, so
this column needs no Ctrl-F in container mode and never shows `?`: `-`
means no session has written a file yet (or the image has no status
line). The files sit on the bind-mounted worktree rather than in the
container, so they survive `ruori rebuild`; `/clear` starts a new
session (a new file) and resuming a session keeps updating its own
file, so nothing is counted twice. Delete `.ruori/usage/` to reset a
worktree's `USAGE` to zero.

**Host mode** reads Claude Code's own local transcripts
(`~/.claude/projects/<encoded-path>/*.jsonl`, one directory per project
path), which already contain a running cost total per session. Same
`?`/`-` distinction as `PR`: `?` means never fetched, `-` means fetched
and genuinely $0 (no Claude Code session has ever run there). Like
`PR`, this is *not* refreshed by Ctrl-R — computing it means scanning
Claude Code's session transcripts to find the ones that belong to this
repo's worktrees, which gets slower as your overall Claude Code
history grows. **Ctrl-F** refreshes `USAGE` too; it's cached on disk at
`<git-common-dir>/ruori/usage-cost.cache` the same way `PR`'s cache
works, keyed by worktree path (not branch, since the cost is tied to
which directory the sessions ran in). Until you press Ctrl-F at least
once, `USAGE` shows `?` for everything. Only `~/.claude/projects` is
scanned, so sessions run with a different `CLAUDE_CONFIG_DIR` aren't
counted.

`ruori list` fetches both `PR` and `USAGE` fresh every time, since it's a
one-shot command rather than a hot reload loop.
