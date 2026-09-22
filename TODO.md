# ruori — Next steps

Status: MVP works (`bin/ruori list`, `bin/ruori switch`) — fzf-pick a git worktree,
create/reuse a tmux session (running `host-command` if configured, a
plain shell otherwise), launch/focus VS Code, and pop an iTerm2 window
for the session, looping back to the picker so the invoking terminal
stays a persistent manager. See README.md for usage.

Section 1's bugs are fixed. The manager-loop / iTerm2-window / claude
--resume behavior above was also just implemented (per live user feedback,
not originally in this TODO) — AeroSpace orchestration in section 3 should
now move/focus the iTerm2 window this script opens, not a generic "terminal
window".

This file lists what's missing to reach the full vision in the original TRD
(worktree dashboard + automated env spin-up + collision-free execution +
window-manager orchestration). Roughly ordered by priority/dependency, not
strict sequence — pick based on what's most annoying day-to-day.

## 1. ~~Fix known MVP bugs first~~ — done

Detached-HEAD/session-name collisions and bare/branchless porcelain
parsing are fixed (`session_name_for` now hashes the full path; detached
worktrees get a short-SHA label; the parser tracks a per-entry flush and
skips `bare` lines).

## 2. Port isolation — done

The TRD's #1 daily pain point after context-switching itself.

Done: on every switch, `ruori` copies files matching patterns from
`.ruori.conf` (falling back to `.env`/`.env.*` if that file
doesn't exist) from the main worktree into the target worktree if
missing there (never overwriting an existing file) — see README.md
"Env files" and "Config file".

Port collisions across worktrees are solved by container mode (see
`docs/container-sandbox-plan.md`, `docs/container-sandbox-guide.md`,
and README.md "Container mode"): a repeatable `container-port`
directive gets each port a freshly-allocated, worktree-specific host
port, injected into the container's environment (never written to a
file — a deliberately separate mechanism from the `.env` copying
above). `ruori ports` shows current allocations; `ruori rm`/Ctrl-D releases
them. This superseded the `.env`-injection-only approach originally
sketched here — see the plan doc's Context section for why.

## 3. AeroSpace workspace orchestration

- Script AeroSpace CLI (`aerospace list-workspaces`, `aerospace
  move-node-to-workspace`, etc.) so that after `ruori switch`:
  - the VS Code window and the tmux terminal window for the *active*
    worktree get moved to a dedicated workspace (e.g. always workspace 1).
  - windows belonging to the previously active worktree get moved out of
    the way (a background workspace) rather than closed.
- Needs a way to identify "which window belongs to which worktree" —
  likely by matching window title (VS Code shows the folder name in its
  title bar; terminal app title can be set via tmux's `set-titles`).
- Confirm AeroSpace is actually installed/configured on this machine
  before building against it (`aerospace list-workspaces` as a smoke
  test).

## 4. Dashboard improvements

Done: a `CLAUDE` (busy/idle/-) column, via Claude Code's
`UserPromptSubmit`/`Stop` hooks writing status to a small state file
`ruori` reads — see README.md "Claude busy/idle status". Container-mode
only, by design: the hooks are baked into the repo's own Dockerfile
(via `ruori init` and the guide it copies out, see
`docs/new-repo-setup-guide.md`), never installed on the host. A repo
not in container mode just always reads `-`.

- `ruori list` should also show port allocation (once #2 exists) and maybe
  last-modified/last-commit time per worktree, so it's a real "status"
  view, not just a branch/path table.
- Consider a lightweight persistent TUI (still via fzf, or a small
  Node/Go program) instead of a static `list` printout, if the plain
  table becomes hard to scan across many worktrees (already saw 14 in
  the k-tavara repo during MVP testing).

## 5. Config

Done: `.ruori.conf` exists (simple line-based, `<directive>
<value>` per line, extensible — see README.md "Config file"), with the
`copy` directive for which files get copied into a new worktree, and
(see #2 above) `container`/`container-file`/`container-port`/
`container-copy` for opting a repo into container mode.

Done: tmux post-create command in host mode is no longer hardcoded to
`claude --resume` — a brand-new session is a plain shell unless
`.ruori.conf` sets `host-command`, matching container mode's
already-agnostic behavior (see docs/config-file.md).

Done: container mode's own equivalent, `container-command` (issue
#45) — repeatable, each value gets its own tmux pane in a freshly
created session (an agent and a dev server side by side, say), tiled
once they're all up. Still opt-in/agnostic by default: no
`container-command` lines means the bare-session behavior above,
unchanged (see docs/container-sandbox-guide.md).

Still to add, as a new directive in the same file: editor override
(`code` vs `cursor` vs other).

## Explicitly out of scope for now

- Cross-repo/global dashboard (aggregating worktrees across multiple
  git repos in one view) — not requested, revisit only if needed.

## Worktree creation — done

`ruori new <branch> [start-point]` creates a worktree (as a sibling of the
main worktree — `<main-worktree-parent>/<repo>.worktrees/<branch>`, never
nested inside it) and immediately activates it via the same code path a
picker selection uses (env-file copy-in, tmux/container session, VS
Code, iTerm2 window) — see README.md "Creating a worktree". This
reverses the earlier "out of scope" stance below: `ruori` already owned
per-worktree setup (env copy, port allocation) keyed off the worktree
path, so leaving creation to a separate `git worktree add` meant that
setup didn't happen until the first switch anyway.
