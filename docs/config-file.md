# Config file (`.ruori.conf`) and env files

## Env files

`git worktree add` only checks out tracked files, so a new worktree
starts with none of your gitignored, machine-local env files (`.env`,
`.env.local`, etc.) — just any tracked template (`.env.example`) if the
repo has one. On every switch, `ruori` copies each file matching a
configured pattern (below) found in the **main worktree** (the repo
root — not necessarily the one you're switching *from*) into the
target worktree, but only ones that don't already exist there. It
never overwrites a file already present, so once a worktree has its
own copy you can freely diverge it (e.g. a different port) without
`ruori` stomping on it on a later switch.

Dynamic port allocation (so worktrees don't collide on the same port)
is handled by container mode's `container-port` directive, a separate
mechanism from env-file copying — see the
[container sandbox guide](container-sandbox-guide.md).

## Config file

`ruori` looks for `.ruori.conf` at the main worktree's root. It's
created by you, not `ruori` — if it doesn't exist, or has no `copy`
lines, `ruori` copies nothing: env-file copying is opt-in, not a
hardcoded default.

Each line is `<directive> <value>`. Blank lines and lines starting with
`#` are ignored; an unrecognized directive is warned about and skipped
rather than breaking the file. This shape is deliberate: the same file
will grow more kinds of setting later (editor override, port range
base — see TODO.md) without needing a new format.

Two directives apply outside container mode: `copy` and `host-command`.

`copy` is for gitignored files that get copied into a new worktree if it's missing them:
the value is a glob pattern relative to the repo root. A plain filename
matches exactly (an exact path, `config/local.json`, works too); shell
wildcards (`*`, `?`, `[...]`) work as well, including partway through a
path; and `**` matches across subdirectories, at any depth, so
`copy **/.env` picks up `.env`, `apps/api/.env`, and
`apps/client/.env` alike without listing each one:

```
# .ruori.conf — files to copy into a new worktree if missing
copy .env
copy .env.*
copy config/local.json
copy **/.env
copy secrets/*.local.yaml
```

You (or an AI coding agent — this page is a fine thing to point one at
directly) can generate this file for a given repo: inspect that repo's
`.gitignore`/config and write a sensible `.ruori.conf` from the format
above.

`host-command <cmd>` sets what a brand-new host-mode tmux session runs
on creation. With no `host-command` line, a new session is just a
plain shell — `ruori` doesn't assume every user wants an AI agent
auto-started:

```
# .ruori.conf — start Claude Code's own resume picker in new host sessions
host-command claude --resume
```

Eight more directives opt a repo into **container mode**: `container`,
`container-file`, `container-port`, `container-copy`,
`container-host-port`, `container-volume`, `container-overlay`,
`container-command`. See the
[container sandbox guide](container-sandbox-guide.md) for what they do
and a worked example — a repo with none of them behaves exactly as
described above.

Note that `copy` is the only directive that takes a glob; the rest,
`container-volume` included, take exact values — a directory the
container gets its own storage for should be readable straight off the
config file, one line each:

```
# .ruori.conf — per-platform generated directories, container-only
container-volume node_modules
container-volume apps/api/node_modules
container-volume apps/web/node_modules
```

The easiest way to get all of this (config file *and* Dockerfile *and*
the Claude Code status hook baked into it) written for a repo in one
shot is `ruori init` — see the
[README's "Setting up ruori for a repo"](../README.md#setting-up-ruori-for-a-repo).
