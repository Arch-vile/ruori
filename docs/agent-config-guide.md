# Building `.wt-orchestrator.conf` — instructions for an AI agent

You are being asked to create or update a `.wt-orchestrator.conf` file
in the root of a git repository, for use with `wt` (wt-orchestrator), a
git-worktree context switcher. These instructions are self-contained —
you don't need anything else from wt-orchestrator's own codebase to do
this task. Follow them for whatever repo you've been pointed at.

## What this file is for

`wt` lets a developer fzf-pick between git worktrees and switches
context into one (tmux session, editor window, etc.). `git worktree
add` only checks out files tracked by git — so a brand-new worktree
starts with none of the repo's gitignored, machine-local files (env
files, local config overrides, local certs, etc.), even though the app
usually can't run without them.

On every switch, `wt` reads `.wt-orchestrator.conf` from the repo root
and copies any file matching a `copy` pattern in it from the main
worktree into the target worktree — but **only if that file doesn't
already exist there**. It never overwrites a file already present, so
once a worktree has its own copy, the developer can freely diverge it
(e.g. a different port, a different local secret) without a later
switch clobbering it.

Your job: figure out, for *this* repo, which gitignored files a fresh
worktree needs copied in for the dev environment to actually work, and
write the `copy` lines for them.

## File format

Plain text, one directive per line: `<directive> <value>`.

- Blank lines and lines starting with `#` are ignored.
- This guide only covers `copy`. There are also four `container`/
  `container-*` directives for opting a repo into container-based
  sandboxing — see `docs/container-sandbox-guide.md` for those; don't
  add them speculatively here. An unrecognized directive is just
  skipped with a warning, not an error, so don't worry about breaking
  anything by leaving unrelated directives in the file if they're
  already there.
- `copy`'s value is a path pattern **relative to the repo root**:
  - A plain filename or path matches exactly, e.g. `copy .env` or
    `copy config/local.json`.
  - Shell wildcards work too — `*`, `?`, `[...]` — including partway
    through a path, e.g. `copy .env.*` or `copy secrets/*.local.yaml`.
- Order doesn't matter. Duplicate/overlapping patterns are harmless
  (a file just gets matched more than once, which is a no-op).

Minimal example:

```
# .wt-orchestrator.conf — files copied into a new worktree if missing
copy .env
copy .env.local
```

## How to build the list for a given repo

1. **Look at `.gitignore`** for entries that are actual runtime/dev
   config rather than build noise. Also check for any files already
   present in the repo root or common config directories that match
   those patterns.
2. **Include** things a fresh worktree needs to actually run or be
   developed against, that aren't committed to git:
   - Env files: `.env`, `.env.local`, `.env.development.local`, or
     whatever this repo's naming convention is — check what's
     `.gitignore`d vs. what similarly-named files *are* tracked (a
     tracked `.env.example` needs no `copy` line — it's already
     checked out by `git worktree add`).
   - Local config overrides: things like `config/local.*`,
     `docker-compose.override.yml`, a local database file, local TLS
     certs used only in dev.
   - Anything else gitignored that the app reads at startup and that
     isn't safe/sensible to regenerate from a template automatically.
3. **Exclude** everything else that's gitignored but not needed to
   bootstrap a worktree — build output (`dist/`, `build/`,
   `node_modules/`), logs, caches, IDE state (`.vscode/`, `.idea/`),
   OS files (`.DS_Store`). Don't add a `copy` line just because
   something is gitignored; only add one if a fresh worktree actually
   needs that file to work.
4. **Verify before adding**: only write a `copy` pattern for something
   that actually exists (or, for a wildcard, plausibly will exist) in
   this repo — don't guess conventions from other projects. If you're
   unsure whether a file is needed, prefer leaving it out over adding
   a speculative pattern; a missing file is easy for the developer to
   notice and add later, while over-copying unrelated files is not
   obviously wrong until it causes confusion.
5. **Keep secrets in mind, but don't worry about this file leaking
   them**: `.wt-orchestrator.conf` itself only contains filenames/glob
   patterns, never file contents or secret values, so it's fine (and
   expected) to commit it to the repo alongside the code. It's the
   *files it names* that stay gitignored, not the config file itself.

## Where to put it — this is the step most likely to go wrong

The file must live at the **main worktree's root** — the original
checkout with a real `.git` directory, not any linked worktree's `.git`
*file*. `wt` only ever reads it from that one location; if it ends up
anywhere else, `wt` won't error, it'll just silently fall back to
copying `.env`/`.env.*` and nothing else, which is a confusing failure
to debug later.

**Don't assume your current working directory is the main worktree.**
Some repos organize their worktrees *inside* the main repo's own
directory tree (e.g. under `.claude/worktrees/<name>/` or similar) —
that layout looks and feels like an ordinary subdirectory, so `pwd` or
"the repo root I was pointed at" is not a reliable signal. Instead,
find it explicitly:

```sh
git worktree list --porcelain | awk '/^worktree /{print $2; exit}'
```

This prints the main worktree's absolute path — it's always the first
entry `git worktree list` reports, regardless of where you're currently
standing or how worktrees are laid out on disk. Write
`.wt-orchestrator.conf` there, e.g.:

```sh
main_root="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
# then create/edit "$main_root/.wt-orchestrator.conf"
```

If a `.wt-orchestrator.conf` already exists somewhere else (e.g. you
find one sitting inside a linked worktree instead), that's a sign an
earlier setup got this wrong — move it to `$main_root`, don't leave a
second copy behind.

## After writing it

- Confirm the file is really at `$main_root/.wt-orchestrator.conf`
  (see above), not wherever you happened to be invoked from.
- Sanity-check your list by re-reading `.gitignore` once more and
  confirming every `copy` pattern's target either exists now or is
  clearly something the app creates locally (e.g. a `.env` a developer
  fills in once) — you're aiming for "a new worktree can run" not
  "every gitignored file is covered."
