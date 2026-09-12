# Container-based sandboxing — instructions for setting up `ruori` container mode

You are being asked to set up **container mode** for a repo using
`ruori`, a git-worktree context switcher. These instructions
are self-contained — you don't need ruori's own codebase to
do this; everything you need is below. See
`docs/container-sandbox-plan.md` in ruori's repo for the full
design rationale if you want it; this guide only covers how to use the
feature.

## What container mode does — and doesn't — sandbox

Today, `ruori` runs a worktree's tmux session (and everything started in
it — an agent, `npm run dev`, ad-hoc commands) directly on the host.
Running a coding agent this way with permission checks disabled means
it can touch anything your host user account can touch.

**Container mode moves only the tmux session and everything run inside
it into a container** — one container per worktree. Specifically:

- `ruori` itself, iTerm2 window automation, and `code -r` (VS Code)
  **stay host-side, unchanged**, in both modes.
- The container gets exactly two bind mounts: the worktree's own
  directory, and the shared git common dir (the one `.git` all linked
  worktrees of a repo share). **Nothing else is ever mounted or copied
  in by default** — not `~/.claude`, not your shell config, not
  anything. Only what you explicitly list via `container-copy` (below)
  ever crosses into the container, and even that is a one-time,
  disconnected copy, not a live link.
- **`ruori` never decides what runs inside the container's tmux session.**
  It only creates a *bare* tmux session and attaches iTerm2 to it —
  no command is ever injected. Whatever starts (an agent, a plain
  shell, nothing at all) is entirely up to your own container image:
  its `CMD`/`ENTRYPOINT`, a tmux `default-command`, or you typing it by
  hand after attaching. This makes container mode work with any agent
  (or no agent) without `ruori` needing to know or care which one.
- The app's dev server, the agent, and any ad-hoc commands all run in
  that *same* container — there's no separate "app container," and
  the agent is never given access to the Docker socket (that would be
  close to root-equivalent on the host and defeats the point).

## The four directives

Add these to `.ruori.conf` at the main worktree's root (same
file the `copy` directive already lives in — see
`docs/agent-config-guide.md` for that one). All are opt-in; a repo
with none of these behaves exactly as it does today.

- **`container on`** (bare `container`, i.e. no value, also works) —
  the *only* thing that turns container mode on for this repo. A
  `.devcontainer/Dockerfile` existing on disk does **not** enable it by
  itself — a repo could have an unrelated pre-existing Dockerfile that
  was never meant for `ruori`.
- **`container-file <path>`** — path to the Dockerfile, relative to the
  main worktree root. Defaults to `.devcontainer/Dockerfile` if
  omitted.
- **`container-port <port>[:<NAME>]`** — repeatable, one per port the
  app exposes (e.g. a frontend and a backend). `ruori` allocates a free
  host port for each, publishes it (`-p 127.0.0.1:<host>:<container>`),
  and injects it into the container's environment as `<NAME>=<host
  port>`. If you omit `:<NAME>`, the env var defaults to
  `PORT_<container-port>` (e.g. `container-port 3000` sets
  `PORT_3000`).
- **`container-copy <host-path>[:<container-path>]`** — repeatable.
  Copies `<host-path>` into the container's own filesystem, once, the
  moment the container is first created — never re-copied afterward,
  even across `docker start`/`docker stop`. `<container-path>` defaults
  to the same path as `<host-path>` if omitted. A leading `~/` is
  expanded to your home directory.

There is **no directive that launches an agent** — see "what container
mode does and doesn't sandbox" above for why.

## `container-copy` is a one-time snapshot, not a live link

This is the piece most likely to surprise you. Once `docker cp` has put
a file into the container, that's it — the container's copy and the
host's original are two independent files from that point on:

- The container can freely read *and write* its copy — e.g. a CLI tool
  refreshing its own OAuth token — without ever touching the host file.
- The host file can change (you rotate a credential, edit a config)
  and the container's copy won't see it.
- **To refresh a container's copy from the current host state, delete
  the container and let `ruori` recreate it** (`docker rm -f
  <container-name>`, or however your workflow removes containers — the
  next `ruori` switch recreates it and copies fresh). There's no partial
  "re-sync" — it's all-or-nothing by design, which is what makes
  "delete to refresh" a simple, predictable mental model instead of a
  stale-cache guessing game.

This deliberately sidesteps the read-only-vs-writable tradeoff a live
bind mount would force: a tool that needs to write back (refresh a
token, update a lockfile-like state file) just works, and the host's
real file is never at risk of being corrupted by something inside the
container.

**Security note:** copying a credential in removes the "container
corrupts my real credential file" risk, but not all exposure risk — a
compromised or rogue process inside the container could still exfiltrate
a copied token over the network, or bake it into an image if someone
`docker commit`s/exports the container. Use narrowly-scoped,
project-specific tokens for anything you `container-copy` in, and don't
publish images built from these containers.

**SSH access is not addressed by this feature.** If you need agent-
forwarded SSH inside the container, that needs a live bind-mount of
`$SSH_AUTH_SOCK` (so key material never leaves the host), which doesn't
fit the copy-in model above — it isn't set up by `ruori` today.

## Directive comparison — don't mix these up

| Directive | Direction | Timing | Ends up... |
|---|---|---|---|
| `copy` | host → host | once, only if the target file doesn't already exist there | a plain file in the target **worktree** |
| `container-port` | n/a (env injection) | fresh, every container start | an env var in the container process — **never written to any file** |
| `container-copy` | host → container | once, only at container **creation** | a private, writable copy inside the container's own filesystem |

If your app reads its assigned port from a `.env` file rather than an
env var, `container-port` alone won't get it there — write a small
entrypoint script in your image that reads the env var and writes the
file your app expects.

## Dockerfile requirements

Your `.devcontainer/Dockerfile` (or wherever `container-file` points)
needs:

- **`git`** — the worktree bind mount needs `git` inside the container
  to function at all (it resolves the worktree's `.git` file, which
  points at the shared common dir mount).
- **`tmux`** — `ruori` creates a bare session with `docker exec ... tmux
  new-session`.
- Your project's own runtime (Node, Python, whatever the app needs).
- Whatever you want auto-started (an agent, a dev server) — via your
  own `CMD`/`ENTRYPOINT`, or a tmux `default-command` set in a
  `~/.tmux.conf` baked into the image.

It does **not** need: Docker itself (no Docker-in-Docker — the agent
never gets to drive its own containers), or any host secret beyond
what you explicitly list in `container-copy`.

## Current limitation: shared backing services (databases, etc.)

Some apps depend on other services during development — a database,
a cache, a queue — often started via `docker-compose` alongside the
app. Because the dev container can't run Docker itself (see above), it
can't start those the usual way.

**Current answer, for now: run that dependency natively on the host,
shared across every worktree's dev container**, rather than one
instance per worktree. This is a container running your **app's own
containerized architecture, if it has one — a completely different
thing from `ruori`'s own dev container** (see the top of this guide): a
project's `docker-compose.yml` for its backing services is unrelated
to, and not reused by, the `.devcontainer/Dockerfile` `ruori` builds.

Point the app's connection strings/env vars at
`host.docker.internal:<port>` instead of `localhost`/`127.0.0.1` —
Docker Desktop (which this whole tool assumes, given its iTerm2/macOS
dependencies elsewhere) resolves that hostname to the host
automatically, no extra container flags needed. `ruori` doesn't manage
this dependency's lifecycle or isolate it per worktree at all; it's on
you to start it once and leave it running.

This is a known gap, not a deliberate design point like the
Docker-in-Docker restriction itself: every worktree's dev container
currently shares the *same* instance of whatever backing service you
run this way (e.g. two worktrees both writing to the same dev
database), with no per-worktree isolation. A cleaner fix — `ruori`
itself (never the agent) orchestrating per-worktree sidecar
containers via `docker compose`, on the host side where it already
has Docker access — is a plausible follow-up, not built yet.

## Worked example: a frontend + backend app

`.ruori.conf`:

```
container on
container-file .devcontainer/Dockerfile
container-port 3000:FRONTEND_PORT
container-port 8000:BACKEND_PORT
container-copy ~/.claude/.credentials.json:/root/.claude/.credentials.json
```

`.devcontainer/Dockerfile`:

```dockerfile
FROM node:20-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    git tmux python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Whatever coding agent you want available — installed into the image,
# never configured by `ruori` itself.
RUN npm install -g @anthropic-ai/claude-code

# Start the agent automatically whenever a new tmux session is created
# in this image. `ruori` never sends this command itself — this is the
# ENTIRE mechanism by which anything starts at all.
RUN echo 'set -g default-command "claude --resume"' >> /root/.tmux.conf

WORKDIR /workspace
```

With this config, `ruori` will:

1. Build `ruori/<repo>:latest` from that Dockerfile on first use.
2. Start the container with the worktree + git common dir mounted at
   matching paths, `FRONTEND_PORT`/`BACKEND_PORT` env vars set to
   freshly-allocated host ports, and (only on the container's first
   creation) `docker cp` your Claude Code credentials file in.
3. Open a bare tmux session inside it — which, per the Dockerfile
   above, starts `claude --resume` automatically via tmux's own
   `default-command`, entirely outside `ruori`'s knowledge.
4. Attach an iTerm2 window via `docker exec -it <container> tmux
   attach`.

Run `ruori ports` any time to see each worktree's live host-port
mappings.

## Verifying it works

- `git status` inside the worktree, run from inside the container
  (`docker exec -it <container> git -C <worktree-path> status`),
  should work cleanly — that confirms both mounts are set up right.
- The copied-in file should be present inside the container and
  independently editable without touching the host original.
- The published port(s) should be reachable from a host browser at
  `http://localhost:<host-port>`.
- `ruori rm` on that worktree should remove the container (`docker ps -a`
  no longer lists it) and free its ports (`ruori ports` no longer lists
  them).

## What's not covered here

- Idle-eviction of long-running containers — none is built in; `ruori rm`
  is the only teardown trigger, so remove worktrees you're done with.
- Multi-service naming beyond the informal `:<NAME>` convention on
  `container-port` — `ruori` doesn't validate or coordinate names across
  services.
- Per-worktree isolation of shared backing services (databases, etc.)
  — see "Current limitation: shared backing services" above.
