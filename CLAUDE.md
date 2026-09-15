# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ruori` is a single Bash script (`bin/ruori`, ~1900 lines) that fzf-picks
between git worktrees and, per pick, sets up a tmux session, a VS Code
window, and an iTerm2 window rooted there — then loops back to the
picker so the invoking terminal stays a persistent "manager" process.
There is no other source: no package manifest, no build step, no test
suite, no linter config. `docs/*.md` hold design rationale and
deep-dive guides; `README.md` and `TODO.md` are the user-facing and
roadmap docs.

## Commands

There is no build/test/lint tooling in this repo. Useful checks:

```sh
bash -n bin/ruori          # syntax-check the script
shellcheck bin/ruori       # if installed (not a repo dependency)
./bin/ruori list           # exercise the script against a real repo's worktrees
./bin/ruori                # run the interactive picker/manager loop
```

`bin/ruori` requires `git`, `tmux`, `fzf`, `code`, and `osascript` on
`PATH` (checked at startup) and `docker` when a repo opts into
container mode. There's no way to unit-test the tmux/VS Code/iTerm2
side effects other than running the script for real — when changing
behavior in `activate_worktree`, `open_iterm_window_for`, or the
container-lifecycle functions, verify manually against an actual repo
with worktrees rather than assuming correctness from reading the diff.

## Architecture

Everything lives in one file, organized top-to-bottom into sections
(each with its own block comment). Reading order to understand a
change:

1. **Startup/identity** — resolves `repo_root`/`main_worktree_path` and
   refuses to run from a linked worktree (everything below assumes a
   single stable, repo-wide identity for cache-file locations and tmux
   session-name prefixes).
2. **`parse_worktrees`** — re-parses `git worktree list --porcelain`
   into parallel `paths`/`branches` arrays on *every* loop iteration
   (not cached), since `ruori rm`/Ctrl-D can change the worktree list
   mid-session. `sort_worktrees_by_activation` then reorders those
   arrays using a persisted last-activated timestamp so the
   most-recently-switched-to worktree sorts first.
3. **Config file (`.ruori.conf`)** — `config_directives` is the single
   parser every accessor (`copy_patterns`, `container_mode_enabled`,
   `container_file_path`, `container_ports`, `container_copy_entries`)
   reads from; `KNOWN_CONFIG_DIRECTIVES` is the one place unrecognized
   keys get flagged. No config file at all falls back to copying
   `.env`/`.env.*`. See `docs/config-file.md`.
4. **Container mode** (`docs/container-sandbox-plan.md`,
   `docs/container-sandbox-guide.md`) — opt-in per *repo* via `container
   on`, never per worktree; `CONTAINER_MODE` is computed once at startup
   and threaded through every code path that differs by it (session
   existence checks, the picker's state column/preview, `ruori rm`,
   iTerm2 attach). `ruori` only orchestrates the container's lifecycle
   (build/start/stop, mounts, port allocation, one-time copy-in on
   creation) — it never decides what runs inside the tmux session
   started inside it, unlike host mode which hardcodes `claude --resume`
   for a brand-new session. Every container also gets `RUORI_SHARED_DIR`
   (an env var pointing at a subdirectory of the common git dir, already
   one of the two bind mounts) so a repo's own image can persist or
   live-share state across every worktree's container for that repo —
   see `docs/container-sandbox-guide.md`'s "Recipe: Claude Code auth"
   for the motivating use case.
5. **Port allocation** (`allocate_port_for`/`ports_cache_file`) — a
   separate mechanism from env-file copying: ports are injected as
   container env vars, never written to a file, and are seeded
   per-`(session, container_port)` from a hash so different repos don't
   all start scanning from the same port.
6. **PR status / usage cost columns** — both follow the same
   cache-then-explicit-fetch split: `load_*_cache` is cheap and runs on
   every picker draw/reload; `fetch_*` is slow (network calls to `gh`,
   or a full scan of `~/.claude/projects/*/*.jsonl`) and only runs from
   the picker's Ctrl-F binding. Both persist through a file so state
   survives across the separate subprocesses fzf's `reload` spawns.
7. **Claude Code status integration** — `.ruori/claude-status` and
   `.ruori/agent-usage` are files an *external* agent hook writes under
   one `.ruori/` subdirectory at a worktree's root (see
   `docs/dashboard-columns.md`); `ruori` only reads them,
   host/container-transparently, and never installs any hook itself on
   the host. Container mode is the only way the `CLAUDE` column becomes
   live, because hooks there are baked into the repo's own Dockerfile
   via `ruori init` rather than the host's Claude Code config.
   `.ruori/agent-usage` is optional, not required, alongside it:
   `fetch_usage_costs` also scans any `<ruori-state-dir>/shared/*/projects`
   it finds (populated by a repo sharing Claude Code's login via
   `RUORI_SHARED_DIR` — see `docs/container-sandbox-guide.md`'s
   "Recipe: Claude Code auth"), so a repo using that recipe can drop
   the usage half of its hook and rely on the host-side scan instead;
   `.ruori/claude-status` still needs the hook regardless, since status
   is event-driven with no transcript equivalent.
8. **iTerm2 window lifecycle** (`open_iterm_window_for` and the
   `*_iterm_window_id`/`iterm_log_file` machinery) — tracks the one
   currently-open window so a switch replaces it instead of piling up
   windows, persists that id across manager restarts (guarded by
   iTerm2's pid, since window ids are reused across app restarts), and
   logs every open/close attempt to a per-repo log file because this is
   the hardest part of the script to debug after the fact (see
   `docs/troubleshooting.md`).
9. **Per-repo state files** — all cache/state files (activation times,
   ports, current-worktree, PR-status, usage-cost, iTerm window id/log,
   and RUORI_SHARED_DIR) live together under one `ruori/` subdirectory
   of the repo's *common* git dir (`ruori_state_dir`, built on `git
   rev-parse --git-common-dir`) rather than as loose ruori-prefixed
   files directly in it, so all of it can be cleared in one `rm -rf`;
   keyed so every worktree of a repo shares one copy rather than each
   worktree getting its own.
10. **Commands** (the big `case "$cmd" in` block) — user-facing:
    `switch` (default, the manager loop), `new`, `list`, `rm`, `ports`,
    `details`, `resources`, `init`. Hidden, invoked only by the picker's
    own fzf key bindings as subprocesses: `__fzfgen`, `__fzfgen_fetch`,
    `__delete_by_fields`, `__new_prompt` — these exist because fzf's
    `reload`/`execute` bindings shell out to a fresh process that can't
    share this process's in-memory state, so each re-derives whatever it
    needs from the on-disk caches/`parse_worktrees`.

## Notable cross-cutting behavior

- Processes spawned by iTerm2/tmux profiles don't inherit this script's
  login-shell `PATH` (e.g. Homebrew's tmux), so `tmux_bin`/`docker_bin`
  are resolved once at the top of the script and interpolated into any
  command string that will run inside a spawned window, rather than
  relying on a bare `tmux`/`docker` lookup happening again there.
- `ruori init` doesn't configure the repo directly — it copies
  `docs/new-repo-setup-guide.md` into ruori's own state dir
  (`ruori_state_dir`, not the repo) and prints a prompt for the user to
  hand to whatever coding agent they use; nothing about it is
  Claude-Code-specific, and nothing gets committed to the repo on
  ruori's behalf. `docs/agent-config-guide.md` is a similar
  self-contained instruction set, meant to be handed directly to an
  agent to generate just the `.ruori.conf` `copy` directives. Changes to
  either guide should keep them self-contained (an agent may be pointed
  at just that one file with no other repo context).
- Destructive operations (`delete_worktree`, `git worktree remove
  --force`) always confirm interactively — there's no non-interactive
  override, by design.

## Keeping `ruori resources` accurate

`bin/ruori`'s `resources` command (documented in `docs/commands.md`)
is meant to be the single, transparent listing of every file/resource
`ruori` itself creates, reads, or manages — book-keeping cache files,
`.ruori.conf`, generated files, and Docker/tmux resources — split into
Global, Repository, and Worktree scope.

Whenever a change to `bin/ruori` adds, removes, or renames a
file/resource that `ruori` owns or depends on (a new cache file, a new
config directive, a new generated file, a new managed Docker/tmux
resource), update the `resources)` case branch in `bin/ruori` and the
"`ruori resources`" section of `docs/commands.md` in the same change,
so this listing never drifts out of sync with what the script
actually does.
