# Setting up `ruori` config for a new repo — instructions for an AI agent

You are being asked to create the config `ruori` (a
git-worktree context switcher) needs for **this repo** —
`.ruori.conf` *and* a `.devcontainer/Dockerfile` (plus two
small files the Dockerfile copies in, see step 3). All of this is part
of the same one-off setup: `ruori`'s whole point is to run a coding agent
and its dev server inside a container, confined to just the worktree
it's working in — so a devcontainer isn't an optional extra bolted
onto `ruori`, it's the thing `ruori` is built around. Setting `ruori` up for a
repo means giving it one. This guide is self-contained; everything you
need is below.

**This guide only creates config files.** It does not check for,
install, or run `ruori`, Docker, or anything else — see "Before you're
done" at the end for that, as a plain pointer, not something to act on
here.

## Ground rules — read this before doing anything else

- **Do not create, modify, or delete any file until you've presented a
  plan (step 4, below) and the user has explicitly confirmed it.**
  Read-only investigation — `.gitignore`, `package.json`, other project
  files — is fine before that; writing anything is not.
- **Ask clarifying questions whenever something is ambiguous.** Don't
  silently guess whether a file is actually needed to bootstrap the
  dev environment, or what the container needs to run this project's
  dev server — get an answer, or put your best-effort proposal in the
  plan for them to correct.
- **The devcontainer is not optional and not something to ask
  permission for up front** — building one is exactly what this guide
  is for, same as the `.ruori.conf` file. If this particular
  repo genuinely can't be containerized (rare — e.g. it needs direct
  hardware/GUI access), say so explicitly and explain why, rather than
  quietly skipping it or asking "do you want this?" as if it were a
  nice-to-have.

## Step 1 — find the main worktree root

`.ruori.conf` must live at the **main worktree's root** — the
original checkout with a real `.git` directory, not a linked worktree's
`.git` *file*, and not necessarily wherever you're currently standing
(some repos nest their worktrees inside the main tree itself, e.g.
under `.claude/worktrees/<name>/`, which looks like an ordinary
subdirectory). Find it explicitly:

```sh
git worktree list --porcelain | awk '/^worktree /{print $2; exit}'
```

This is where you'll write the config file in step 5 — nowhere else.
If a `.ruori.conf` already exists somewhere other than this
path, that's a sign an earlier setup got it wrong; plan to move it,
not leave a second copy behind.

## Step 2 — work out `copy` directives

`git worktree add` only checks out files tracked by git, so a new
worktree starts with none of the repo's gitignored, machine-local files
(env files, local config overrides, local certs) even though the app
usually can't run without them. The `copy` directive tells `ruori` which
of those to copy from the main worktree into a new one (only if it's
missing there — never overwriting a file already present).

Format: one directive per line, `copy <pattern>`, where `<pattern>` is
relative to the repo root — a plain filename/path matches exactly
(`copy config/local.json`), or a shell wildcard (`*`, `?`, `[...]`)
works too, including partway through a path (`copy .env.*`,
`copy secrets/*.local.yaml`). Order doesn't matter; overlapping
patterns are harmless.

To build the list for this repo:

1. **Look at `.gitignore`** for entries that are actual runtime/dev
   config rather than build noise, and check whether matching files
   already exist in the repo root or common config directories.
2. **Include** things a fresh worktree needs to actually run or be
   developed against, that aren't committed to git: env files
   (`.env`, `.env.local`, or whatever this repo's convention is — a
   tracked `.env.example` needs no `copy` line, since `git worktree
   add` already checks that out), local config overrides
   (`config/local.*`, `docker-compose.override.yml`, local TLS certs
   used only in dev), or anything else gitignored that the app reads
   at startup and isn't safe to regenerate from a template
   automatically.
3. **Exclude** everything else gitignored but not needed to bootstrap a
   worktree — build output (`dist/`, `node_modules/`), logs, caches,
   IDE state, OS files. Don't add a line just because something is
   gitignored; only add one if a fresh worktree actually needs it.
4. **Verify before proposing**: only include a pattern for something
   that actually exists (or, for a wildcard, plausibly will) in this
   repo. If unsure whether a file is needed, prefer leaving it out —
   a missing file is easy to notice and add later; over-copying is
   not obviously wrong until it causes confusion.

Example:

```
# .ruori.conf — files to copy into a new worktree if missing
copy .env
copy .env.*
copy config/local.json
```

## Step 3 — work out the devcontainer setup

This is the core of the setup, not a side option: `ruori` runs the coding
agent and dev server inside a container confined to just this
worktree — no host filesystem access beyond an explicit allowlist —
and gives each concurrently-open worktree its own free host port
instead of colliding on the same one. Every repo `ruori` is set up for
gets this.

Four directives go in the same `.ruori.conf` from step 2:

- **`container on`** — activates it. (Bare `container`, i.e. no value,
  also works.) Always include this line — it's what turns the rest of
  this section's directives, and the Dockerfile, into something `ruori`
  actually uses, rather than a Dockerfile just sitting there unused.
  `ruori` requires this line explicitly rather than inferring container
  mode from a Dockerfile's mere presence, so that a repo with some
  *unrelated* pre-existing `.devcontainer/Dockerfile` (not written for
  `ruori`) never gets silently containerized by accident — but for a repo
  you're setting `ruori` up on via this guide, always write it.
- **`container-file <path>`** — Dockerfile path relative to the main
  worktree root. Defaults to `.devcontainer/Dockerfile` if omitted.
- **`container-port <port>[:<NAME>]`** — repeatable, one per port the
  app exposes. `ruori` allocates a free host port for each and injects it
  into the container's environment as `<NAME>` (or `PORT_<port>` if
  `:<NAME>` is omitted).
- **`container-copy <host-path>[:<container-path>]`** — repeatable.
  Copies a host file into the container's own filesystem once, at
  creation time only (a private, writable copy — not a live link back
  to the host). `<container-path>` defaults to the same path as
  `<host-path>` if omitted; a leading `~/` in `<host-path>` expands to
  the host's home directory.

Ask the user what you need to draft (or verify an existing) Dockerfile
— this part genuinely needs their input, unlike whether to do container
mode at all:

- The project's language/runtime and how its dependencies are
  installed.
- How the dev server is started, and which port(s) it listens on.
- Whether any host credentials need `container-copy`ing in (and their
  exact host path) — e.g. an agent's own credentials file. Only ever
  copy what the user explicitly names; never propose copying something
  by default.
- **Whether the project depends on other backing services** (a
  database, cache, queue — anything normally started via
  `docker-compose` or similar alongside the app). The dev container
  can't start these itself (no Docker-in-Docker — see below), so this
  is a real, current limitation, not something to quietly skip past:
  the documented answer is that such a service runs natively on the
  host, **shared across every worktree's dev container** (not one per
  worktree), reachable from inside the container at
  `host.docker.internal:<port>` instead of `localhost`. Tell the user
  this plainly if it applies, and don't confuse that service's own
  containerization (if it has any) with `ruori`'s dev container — they're
  unrelated (see the intro above).

The Dockerfile itself needs: `git`, `tmux`, and `jq` installed (`git`
and `tmux` for `ruori` to attach a session inside the container at all;
`jq` for the status hook below), the project's runtime, and — if the
user wants something to auto-start (an agent, the dev server) —
either the image's own `CMD`/`ENTRYPOINT` or a tmux `default-command`
baked into a `~/.tmux.conf`. It does not need Docker itself, or any
host secret beyond what's explicitly `container-copy`'d. Minimal
shape:

```dockerfile
FROM <base-image>
RUN apt-get update && apt-get install -y --no-install-recommends git tmux jq <runtime> \
    && rm -rf /var/lib/apt/lists/*
# optional: auto-start something in every new tmux session
RUN echo 'set -g default-command "<command>"' >> /root/.tmux.conf
WORKDIR /workspace
```

### Claude Code status hook — bake it into the image, always

If the user's agent is Claude Code (ask if unclear), the Dockerfile
must also install the same busy/waiting/idle + usage-cost status hook
`ruori`'s picker relies on for its `CLAUDE`/`USAGE` columns — **entirely
inside the image**. This is not optional and not a separate setup
step done later: without it those two columns just always show `-`
for this repo's worktrees, silently, with no error. And it must never
touch anything on the **host** — no host `~/.claude`, no host
gitignore, nothing outside this Dockerfile and the files it `COPY`s
in. That's the whole point of doing it this way: the hook lives only
inside the container this same Dockerfile builds, gets rebuilt fresh
with every image build, and never leaks into the developer's own
Claude Code config on their machine.

How it works: seven Claude Code hook events (`UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `PermissionRequest`, `Elicitation`,
`ElicitationResult`, `Stop`) all invoke one script with a status
argument, which writes `busy`/`waiting`/`idle` to `.ruori-claude-status`
at the worktree root, and (on `idle`) a running cost total to
`.ruori-agent-usage` there too. `ruori` already bind-mounts the worktree
root into the container (see above), so a file written there from
inside the container is the exact same file `ruori` reads from the host
— no extra plumbing needed, and both files are already covered by the
end user's **global** gitignore if they've used `ruori` in container mode
before (if this is their first container-mode repo, mention it: they
should add `.ruori-claude-status` and `.ruori-agent-usage` to their global
`git config --global core.excludesFile` once, otherwise `git worktree
remove` will refuse to remove a worktree these files are sitting in).

Write these two files next to the Dockerfile (e.g. in `.devcontainer/`
alongside it), then `COPY` them in:

`.devcontainer/ruori-claude-status-hook`:

```bash
#!/usr/bin/env bash
# ruori-claude-status-hook - records Claude Code's busy/waiting/idle status
# (and, on "idle", a running usage-cost total) for the current worktree,
# so ruori's picker can show it. Invoked as a Claude Code hook with one of
# three status arguments: busy, waiting, idle. Reads the hook's JSON
# payload from stdin (needs "cwd") and writes to two fixed filenames at
# the worktree root ("$cwd" — the same directory ruori bind-mounts into
# this container, so the host sees the same files with no extra
# plumbing). Deliberately silent/non-blocking: any failure (bad
# payload, no cwd, unwritable worktree) just exits 0 without writing
# anything, so this can never interfere with a normal Claude Code
# session.
set -euo pipefail

STATUS_FILENAME=".ruori-claude-status"
AGENT_USAGE_FILENAME=".ruori-agent-usage"

status="${1:-}"
case "$status" in
  busy | waiting | idle) ;;
  *)
    echo "ruori-claude-status-hook: usage: ruori-claude-status-hook <busy|waiting|idle>" >&2
    exit 0
    ;;
esac

payload="$(cat)"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)"

[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0

printf '%s\n%s\n' "$status" "$(date +%s)" >"$cwd/$STATUS_FILENAME" 2>/dev/null || true

if [ "$status" = "idle" ]; then
  projects_dir="$HOME/.claude/projects"
  total="0"
  if [ -d "$projects_dir" ]; then
    for f in "$projects_dir"/*/*.jsonl; do
      [ -f "$f" ] || continue
      file_cwd="$(grep -m1 '"cwd":"' "$f" 2>/dev/null | jq -r '.cwd // empty' 2>/dev/null)" || true
      [ "$file_cwd" = "$cwd" ] || continue
      file_cost="$(grep '"type":"cost-state"' "$f" 2>/dev/null | tail -1 | jq -r '.totalCostUSD // empty' 2>/dev/null)" || true
      [ -n "$file_cost" ] || continue
      total="$(printf '%s\n%s\n' "$total" "$file_cost" | jq -s 'add')"
    done
  fi
  printf '%s\n%s\n' "$total" "$(date +%s)" >"$cwd/$AGENT_USAGE_FILENAME" 2>/dev/null || true
fi

exit 0
```

`.devcontainer/claude-settings.json` — merge into this only if the
image already needs its own `~/.claude/settings.json` for something
else (e.g. `container-copy`'d credentials write to a different file);
otherwise this file's contents become that settings file verbatim.
Each event needs a short `timeout` so a stuck hook fails fast instead
of stalling a session; `UserPromptSubmit`/`Stop` don't take a
`matcher` field at all, and the rest omit it too since we want it to
match everything:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "ruori-claude-status-hook busy", "timeout": 5 }] }
    ],
    "PreToolUse": [
      { "hooks": [{ "type": "command", "command": "ruori-claude-status-hook busy", "timeout": 5 }] }
    ],
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "ruori-claude-status-hook busy", "timeout": 5 }] }
    ],
    "PermissionRequest": [
      { "hooks": [{ "type": "command", "command": "ruori-claude-status-hook waiting", "timeout": 5 }] }
    ],
    "Elicitation": [
      { "hooks": [{ "type": "command", "command": "ruori-claude-status-hook waiting", "timeout": 5 }] }
    ],
    "ElicitationResult": [
      { "hooks": [{ "type": "command", "command": "ruori-claude-status-hook busy", "timeout": 5 }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "ruori-claude-status-hook idle", "timeout": 5 }] }
    ]
  }
}
```

Then, in the Dockerfile, after `git`/`tmux`/`jq` are installed:

```dockerfile
COPY ruori-claude-status-hook /usr/local/bin/ruori-claude-status-hook
RUN chmod +x /usr/local/bin/ruori-claude-status-hook
# $HOME here must match whichever user actually runs Claude Code in
# this image — /root unless a Dockerfile USER directive says otherwise;
# copy to both homes if you're not sure which one applies.
COPY claude-settings.json /root/.claude/settings.json
```

**Why `PreToolUse`/`PostToolUse` matter, not just
`UserPromptSubmit`/`Stop`:** `Stop` fires whenever the *main* agent's
own turn ends — including the moment it hands off work to a subagent
via the Task tool, well before that subagent actually finishes. Without
`PreToolUse`, that handoff moment gets marked `idle` and stays that way
for the entire time the subagent is running. Hooking
`PreToolUse`/`PostToolUse` for every tool call re-asserts `busy`
immediately whenever anything is happening, closing that gap.

## Step 4 — present the plan

**Stop here — don't create or change anything yet.** Summarize for the
user:

- The exact `copy` directives you're proposing, one line of reasoning
  each.
- The exact `container`/`container-file`/`container-port`/
  `container-copy` directives you're proposing, and the full contents
  of the Dockerfile you're proposing to write (or, if one already
  exists at the target path, whether you're reusing it as-is or
  changing it, and why) — including the Claude Code status hook files
  from the Dockerfile section above, if the agent is Claude Code.
- If you determined this repo can't reasonably be containerized, say
  so here explicitly, with your reasoning, instead of silently leaving
  the container directives out.
- If the project depends on a backing service (database, etc.), state
  the limitation plainly: it needs to run natively on the host, shared
  across worktrees, reachable via `host.docker.internal:<port>` — this
  guide doesn't set that service up, only documents the pattern.
- Ask for confirmation, and answer any follow-up questions, before
  writing anything.

## Step 5 — write the files

Only after the user confirms:

1. Write `.ruori.conf` at the main worktree root (from step
   1) with the confirmed directives — `copy` lines, then the
   `container*` lines.
2. Write the confirmed Dockerfile at the confirmed path (default
   `.devcontainer/Dockerfile`, relative to the main worktree root),
   unless the plan reused an existing one unchanged.
3. Write `ruori-claude-status-hook` and `claude-settings.json` next to it
   (if the agent is Claude Code), per the Dockerfile section above.

Don't run, build, or test anything — this guide's job ends at writing
these files.

## Before you're done — one thing this guide doesn't cover

**`ruori` itself isn't installed or run by this guide.** Make sure the
user actually has it set up (a symlink from their ruori
checkout's `bin/ruori` onto their `PATH` — see that repo's own
`README.md` "Install" section) before expecting any of this config to
take effect. If they don't have it yet, tell them so plainly rather
than assuming.
