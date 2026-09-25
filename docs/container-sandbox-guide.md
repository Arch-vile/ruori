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
  disconnected copy, not a live link. The one opt-in exception is
  `container-volume` (below): each subpath you name gets its own
  Docker-managed volume, living on the container's native storage
  instead of the bind-mounted worktree. See "Host-side tooling and
  generated directories" below for why you want that for anything a
  toolchain generates per platform.
- **`ruori` doesn't decide what runs inside the container's tmux session
  unless you tell it to.** By default it only creates a *bare* tmux
  session and attaches iTerm2 to it — no command is ever injected.
  Whatever starts (an agent, a plain shell, nothing at all) is entirely
  up to your own container image: its `CMD`/`ENTRYPOINT`, a tmux
  `default-command`, or you typing it by hand after attaching. This
  makes container mode work with any agent (or no agent) without
  `ruori` needing to know or care which one. If you *do* want something
  started automatically, repeatable `container-command` directives
  (below) each get their own tmux *window* in a fresh session — e.g. an
  agent in one window and `npm run dev` in another, switchable with
  Ctrl-b `<number>`, every time a worktree's container starts from
  scratch.
- The app's dev server, the agent, and any ad-hoc commands all run in
  that *same* container — there's no separate "app container," and
  the agent is never given access to the Docker socket (that would be
  close to root-equivalent on the host and defeats the point).

## Terminal color coding

Every container-mode worktree's tmux status bar gets a color,
deterministically derived from its session name — the same container
always gets the same color across restarts, and different containers
usually get different colors from a small fixed palette. It's purely a
visual "you're on a container, not the host" cue: it shows in *any*
terminal attached to that tmux session (the iTerm2 window `ruori`
opens, but also a manual `tmux attach` or an integrated terminal), and
matches the color of that worktree's `BRANCH` column in the picker.
There's nothing to configure, and a host-mode worktree shows no color
at all.

## The eleven directives

Add these to `.ruori.conf` at the main worktree's root (same
file the `copy` directive already lives in — see
`docs/config-file.md` for that one). All are opt-in; a repo
with none of these behaves exactly as it does today.

- **`container on`** (bare `container`, i.e. no value, also works) —
  the *only* thing that turns container mode on for this repo. A
  `.devcontainer/Dockerfile` existing on disk does **not** enable it by
  itself — a repo could have an unrelated pre-existing Dockerfile that
  was never meant for `ruori`.
- **`container-file <path>`** — path to the Dockerfile, relative to the
  main worktree root. Defaults to `.devcontainer/Dockerfile` if
  omitted.
- **`container-port <port>[:<NAME>][:http]`** — repeatable, one per
  port the app exposes (e.g. a frontend and a backend). `ruori`
  allocates a free host port for each, publishes it (`-p
  127.0.0.1:<host>:<container>`), and injects it into the container's
  environment as `<NAME>=<host port>`. If you omit `:<NAME>`, the env
  var defaults to `PORT_<container-port>` (e.g. `container-port 3000`
  sets `PORT_3000`). Add a trailing `:http` to mark the port as an HTTP
  server — e.g. `container-port 3000:FRONTEND_PORT:http`, or
  `container-port 3000::http` to keep the default env var name — and
  `ruori` offers a clickable `http://localhost:<host-port>` link for it
  in the Enter action menu's "open in browser" item and in `ruori
  ports`'s `URL` column. Ports without `:http` (a database, say) never
  get a link. `:http` only marks a port as browser-able; it doesn't
  change the `-p`/env-var behavior above.
- **`container-copy <host-path>[:<container-path>]`** — repeatable.
  Copies `<host-path>` into the container's own filesystem, once, the
  moment the container is first created — never re-copied afterward,
  even across `docker start`/`docker stop`. `<container-path>` defaults
  to the same path as `<host-path>` if omitted. A leading `~/` is
  expanded to your home directory.
- **`container-host-port <port>`** — repeatable, one per host port a
  process inside the container should be able to reach at
  `localhost:<port>`, unmodified. `ruori` runs a `socat` relay inside
  the container (`docker exec -d ... socat TCP-LISTEN:<port>,fork,reuseaddr
  TCP:host.docker.internal:<port>`) so anything in the container dialing
  `localhost:<port>` transparently reaches that port on the host,
  instead of your app config having to be edited to say
  `host.docker.internal` in container mode — see "Current limitation:
  shared backing services" below for the motivating case. Requires
  `socat` in the container image; if it's missing, `ruori` logs a
  warning and skips that port rather than failing the whole container
  start. Started fresh every time the container transitions to
  running (a stopped container has no processes left inside it,
  forwarders included), never persisted to a file.
- **`container-volume <relative-path>`** — repeatable, one per subpath
  (relative to the worktree root) that should live on the container's
  own native Docker storage instead of the bind-mounted worktree — the
  common case is whatever your toolchain generates per platform
  (`node_modules`, build output, caches — see "Host-side tooling and
  generated directories" below), but the directive itself doesn't know
  or care what the path is for. `ruori` adds an extra
  `-v <volume>:<worktree-path>/<relative-path>` to the container's
  `docker run`, shadowing just that subpath; everything else in the
  worktree stays live-shared with the host exactly as without this
  directive. The path is taken as-is and needn't exist yet — Docker
  creates the mountpoint, which is what lets a fresh worktree get its
  `node_modules` volume before anything has been installed there. The
  volume is created empty the first time the container starts — run
  whatever populates that path (`pnpm install`, etc.) *inside* the
  container afterward, same as you would without this directive, since
  nothing is copied in from the host side. Only actually removed by
  `ruori rm`, same as the container itself; `docker start`/`docker
  stop` leaves it untouched. See "Directive comparison" below for how
  this differs from `container-copy`.

  Docker can't add or remove a mount on an existing container, so a
  `container-volume` line added or removed later only takes effect on
  the next container creation. `ruori` checks on every switch and
  prints `container-volume targets changed (+…); run 'ruori rebuild
  <branch>' to apply` when that's pending — see `docs/commands.md`.
  Existing volumes keep their data across a rebuild; only the new
  subpaths start empty.
- **`container-shared-volume <absolute-container-path>`** — repeatable,
  one per path *inside the container* that should be backed by one
  Docker volume shared by **every worktree's container of this repo**,
  rather than one per worktree like `container-volume`. Made for a
  package manager's download store (pnpm's content-addressed store,
  a yarn/npm cache): with it, a new worktree's first install copies
  packages from the shared store instead of downloading all of them
  again. The path is absolute and must not be inside the worktree —
  anything under the worktree belongs to one worktree and goes in
  `container-volume` instead. Docker creates the volume the first time
  any container mounting it starts, seeding it from the image's
  contents and ownership at that path, so create the directory in the
  Dockerfile (owned by the container's user) before pointing a tool at
  it. Never removed by `ruori rm` — other worktrees still use it; `ruori
  resources` lists it under Repository, and `docker volume rm` removes
  it once no container mounts it. Same creation-time rule and drift
  warning as `container-volume`: an added or removed line needs `ruori
  rebuild <branch>`. Only share something that's safe to share: a
  content-addressed cache is (entries are keyed by content and
  version, so worktrees on different dependency versions just add
  entries side by side); `node_modules` or build output is not. See
  "Recipe: a Node.js monorepo" below.
- A file that should differ in every worktree (and so in its container)
  — a `.env` pointing at the container's database host, say — isn't a
  container directive: use `worktree-overlay`, which patches the
  worktree's own file in place in both modes. See
  [config-file.md](config-file.md).

- **`container-command <cmd>`** — repeatable, one per command to run
  automatically in a freshly created session, each in its own tmux
  *window* (switchable with Ctrl-b `<number>`, or Ctrl-b `w` for the
  window list — not a split pane, so each command gets the full
  screen). Only applies the moment a worktree's session is created from
  scratch (same as `host-command` in host mode — see
  `docs/config-file.md`); resuming an already-running session never
  re-sends these, so they won't duplicate windows on every switch. The
  first directive starts the session itself (window 0); each further
  one opens as the next window:

  ```
  # .ruori.conf — agent in one window, dev server in another
  container-command claude --resume
  container-command npm run dev
  ```

  With no `container-command` lines, container mode is exactly as
  agent-agnostic as it always was — a bare tmux session, nothing
  injected.

- **`container-init <cmd>`** — repeatable, one per shell command to run
  once via `docker exec`, only the moment this worktree's container is
  first created — never on a later `docker start`, and deliberately
  *after* any `container-copy` entries (see "Recipe: container-only
  gitignore patterns" below for why ordering matters). Unlike
  `container-command`, this doesn't open a tmux window and isn't tied
  to a session at all — it's invisible one-time container setup, run
  once per container lifetime regardless of how many tmux sessions come
  and go inside it. Each command runs with the worktree's own path as
  its working directory, so `$PWD` inside it resolves to the worktree
  root without needing a dedicated env var:

  ```
  # .ruori.conf — point the container's git at a tracked ignore file
  container-init git config --global core.excludesFile "$PWD/.devcontainer/container.gitignore"
  ```

  Deliberately generic rather than a directive per one-time setup
  need — same trust level as `container-command`/`host-command`
  (an arbitrary string from a human-authored `.ruori.conf`, run via a
  shell). Editing the command list later needs `ruori rebuild <branch>`
  to take effect, exactly like `container-copy`.

- **`container-env <NAME>`** — repeatable, one per host environment
  variable to forward into the container. `ruori` looks up `<NAME>` in
  its *own* process environment — the shell you launched `ruori` from,
  since `ruori` runs as one long-lived process across an entire picker
  session rather than re-executing per worktree switch — at
  container-creation time, and passes it through as `-e
  <NAME>=<value>`. A name with nothing set in `ruori`'s environment is
  silently skipped, not forwarded as an empty string, so it can't
  override an `ENV` default the image's own Dockerfile already sets.
  Like `container-copy`, only ever applied at creation — Docker has no
  way to add an env var to an existing container, so `ruori rebuild
  <branch>` is what picks up a changed value. See "Recipe: git commit
  identity" below for the motivating use case.

## Automatic environment: `RUORI_SHARED_DIR`

Every container also gets one env var set automatically, no directive
needed: `RUORI_SHARED_DIR`, pointing at a directory inside the
container that's shared, writable, and identical across **every
worktree's container for this repo** — today that's a subdirectory of
the common git dir (already one of the two bind mounts above, so
nothing extra needs mounting), but the name describes what it's *for*,
not how it's implemented, so don't hardcode assumptions about that.

`ruori` itself never writes anything under it — it's purely there for
your own Dockerfile/entrypoint to build on, for anything that should
persist or stay in sync across every worktree's container rather than
being private to one (a live-shared auth credential, e.g. — see the
Claude Code recipe below — or any other cross-worktree cache/state your
image wants). Read it from an `ENTRYPOINT` script, not a Dockerfile
`RUN` step — the mount (and the env var) only exist once the container
actually starts, not at image build time.

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

## Recipe: container-only gitignore patterns

Container-side tooling sometimes produces artifacts (a stray build
log, a lockfile variant only the container writes) that you want
`git status`/`git add -A` *inside the container* to quietly ignore,
without adding them to the repo's tracked `.gitignore` — that file is
committed, so a change there is visible to every collaborator and to
the host's own `git status` too.

Since the worktree is already bind-mounted into the container, a
plain, repo-tracked file needs no copying in — it's already visible at
the same path. Point the container's git at it with `container-init`:

```
# .ruori.conf
container on
container-init git config --global core.excludesFile "$PWD/.devcontainer/container.gitignore"
```

```
# .devcontainer/container.gitignore — ordinary gitignore syntax
.pnpm-store
*.local.log
```

`$PWD` resolves to the worktree root because `container-init` commands
run with that as their working directory (see "The eleven directives"
above), so the value git stores is an absolute path — `core.excludesFile`
resolved relative to the current directory at git's invocation time
would break if git were ever run from a subdirectory. This only ever
changes what *this container's* git reports; the host, and any other
container, still see the exact same tracked `.gitignore` as before.

Runs once, at container creation, deliberately *after* any configured
`container-copy` entries: a `container-copy ~/.gitconfig:/root/.gitconfig`
(the git-identity recipe further down) overwrites the container's
entire `~/.gitconfig` verbatim on every creation, which would silently
undo this setting if it ran first — see `docs/gimmicks.md`. Editing
either the command or the tracked ignore file later needs `ruori
rebuild <branch>` to take effect.

To make a tracked file's *content* differ, either make the behavior
configurable (an env var the file reads, set via `container-env` or
the Dockerfile, or a CLI flag passed via `container-command`) or patch
it in every worktree with `worktree-overlay` (see
[config-file.md](config-file.md)) — the latter changes the host's view
of that worktree too, and shows up in `git status`.

## Host-side tooling and generated directories

The container is Linux; your host is macOS. Anything a toolchain
*generates* for the platform it runs on — native addons and
platform-specific binaries in `node_modules`, compiled build output,
`.pnpm-store`, a Rust `target/`, a Python venv — is only valid on the
side that produced it. Because the worktree is one live bind mount,
without further configuration those artifacts land in a directory both
sides see: an install run inside the container leaves Linux binaries
where the host's editor tooling then tries to load them (or an install
run on the host leaves macOS ones for the container). There's no way
to make one copy work for both, so the model is:

- **Source files**: one shared copy via the bind mount. Zero lag, no
  sync, no way for the two sides to diverge — and `git` sees the same
  working tree from either side, so commits from the container and
  from the host are interchangeable.
- **Generated directories**: container-only, one Docker volume each,
  declared with `container-volume`. Inside the container the path is
  the volume; on the host the same path is just an ordinary (usually
  empty) directory that the container never touches.
- **Host-side tooling** that needs those dependencies — an editor's
  language server, a host-side test runner — gets them from its own
  native install, run once per worktree on the host (`pnpm install` in
  the worktree directory, outside any `ruori` session). The container
  neither sees nor is affected by it.

The rule of thumb when writing `.ruori.conf`: shadow every directory
the toolchain generates per platform, one explicit `container-volume`
line each. This is a one-time setup step per repo, and adding a
directory later (a new workspace package, say) is one more line plus
`ruori rebuild <branch>` — `ruori` reminds you on the next switch.
`container-volume` deliberately takes exact paths, not patterns: the
set of directories you're shadowing should be something you can read
off the config file, not something resolved behind your back.

Not every generated artifact needs its own volume, though: if it's
small and doesn't need storage isolation, but would otherwise just be
noise in `git status`/`git add -A` *inside the container*, "Recipe:
container-only gitignore patterns" above may be enough, with no
`container-volume` line at all.

### Recipe: a Node.js monorepo

For a workspace layout (pnpm/npm/yarn workspaces, Turborepo), list the
root and each package's generated directories:

```
container-volume node_modules
container-volume apps/api/node_modules
container-volume apps/web/node_modules
container-volume packages/ui/node_modules
container-shared-volume /pnpm-store
```

plus, in the Dockerfile (use whichever user the container runs as):

```dockerfile
RUN mkdir -p /pnpm-store && chown node:node /pnpm-store
ENV npm_config_store_dir=/pnpm-store
```

- With pnpm's default layout, per-package `node_modules` hold only
  symlinks into the root `node_modules/.pnpm`, so the root line does
  the heavy lifting — but the per-package lines are still worth having
  (they hold `.bin` shims and any `node-linker=hoisted`/`npm`-style
  real files), and they cost nothing.
- The store is shared by every worktree's container, so pnpm
  downloads each package once per repo rather than once per worktree;
  a new worktree's first `pnpm install` mostly copies from the store.
  Only the store is shared. Your own source and workspace packages
  never go into it (workspace deps are symlinks into the worktree's own
  `packages/*`), and each worktree's `node_modules` and build output
  stay on its own volumes, so worktrees can't clobber each other.
- Changing dependency versions in one worktree just adds entries to
  the store: it's content-addressed, so `foo@1.0.0` and `foo@1.1.0`
  sit side by side and each worktree's install takes exactly what its
  own lockfile says. The store only grows; `pnpm store prune` shrinks
  it, but don't run it while another container is installing — at
  worst, a pruned package gets downloaded again later. Two containers
  installing at once is safe (pnpm writes store entries atomically).
- `npm_config_store_dir` is set in the Dockerfile rather than as
  `store-dir` in the repo's `.npmrc`, so the host's own `pnpm install`
  keeps using the host's global store untouched.
- pnpm can't hardlink from the store into `node_modules`, since they're
  separate mounts (hardlinks can't cross mounts even on one disk), so
  it copies instead. That's still a local disk-to-disk copy inside
  Docker's own VM — far faster than a download. Without a `store-dir`
  pointing at a mounted store, pnpm falls back to a `.pnpm-store`
  inside the worktree — on the host bind mount, visible in `git
  status`, and re-downloaded per worktree.
- Inside the container, a shadowed directory is a mountpoint, so
  `rm -rf node_modules` fails with `Device or resource busy`. Clear its
  *contents* instead: `find node_modules -mindepth 1 -delete`, then
  reinstall. Cleanup scripts that end with `rm -rf node_modules` need
  the same change.
- `container-volume` volumes are per worktree, so each worktree's
  container still runs its own install once (from the shared store);
  `ruori rebuild` keeps them, `ruori rm` removes them. The shared store
  survives `ruori rm`.
- Migrating from an older `container-volume .pnpm-store` line: replace
  it with the lines above, then `ruori rebuild <branch>` each existing
  worktree (the switch-time drift warning will prompt for it). The old
  per-worktree `…__vol--pnpm-store` volumes can be removed with `docker
  volume rm`.

## Recipe: Claude Code auth

Claude Code's login can't be treated like `gh`'s: on macOS it lives in
the Keychain, not a plain file, so there's nothing on a Mac host for
`container-copy` (which only ever reads a host **file**) to point at.
Bootstrapping it from *inside* a container instead sidesteps that
entirely — a container is Linux, so `claude` there always writes plain
files regardless of what your host OS does.

**This recipe shares one login live across every worktree's container
for a repo, via `RUORI_SHARED_DIR` (above), rather than copying it into
each container separately.** Log in once, in any one container, and
every other container — existing or future, any worktree — sees it
immediately, because they all end up reading and writing the exact
same files.

**It's not just `~/.claude/.credentials.json`.** Claude Code also
needs `~/.claude.json` — a *sibling* file directly in `$HOME`, not
something under `~/.claude` at all — to consider itself logged in;
verified by hand, copying only the credentials file into a second
container left it still showing "Not logged in," and copying
`.claude.json` in too made it work. Neither file can just be
symlinked to a shared location: Claude Code writes both via
write-then-rename (same pattern most tools use to avoid ever leaving a
half-written file on disk), and a `rename()` onto a symlink doesn't
follow it — it deletes the symlink and drops a plain file right back
outside the shared location, silently un-sharing itself the moment
anyone logs in or the token refreshes.

**The fix is Claude Code's own `CLAUDE_CONFIG_DIR` env var**, which
consolidates *everything* — `.claude.json`, `.credentials.json`,
`settings.json`, session history — into one directory, no sibling file
left in `$HOME` at all. Point it straight at a real directory under
`RUORI_SHARED_DIR` and there's no symlink anywhere, so the
rename-onto-a-symlink problem above never comes up: Claude just reads
and writes ordinary files in an ordinary (if oddly-located) directory.
Verified by hand: with `CLAUDE_CONFIG_DIR` set to an otherwise-empty
directory containing only files copied from an already-logged-in
container, a fresh container answered a real prompt correctly; with it
unset, the same container said "Not logged in."

In your `ENTRYPOINT` script (not a `RUN` step — see above):

```sh
if [ -n "${RUORI_SHARED_DIR:-}" ]; then
  shared_claude_dir="$RUORI_SHARED_DIR/ruori-claude-home"
  mkdir -p "$shared_claude_dir"

  # Verified by hand: with CLAUDE_CONFIG_DIR set, Claude Code ignores
  # ~/.claude/settings.json entirely, so this image's baked-in hooks
  # only take effect once seeded into the shared dir -- and only the
  # very first container ever does that seeding (the ! -e check is a
  # no-clobber guard), so a later container never overwrites a
  # login/history already there. Delete the shared dir yourself to
  # force a fresh reseed after changing the Dockerfile's settings.
  if [ -e "$HOME/.claude/settings.json" ] && [ ! -e "$shared_claude_dir/settings.json" ]; then
    cp "$HOME/.claude/settings.json" "$shared_claude_dir/settings.json"
  fi

  # CLAUDE_CONFIG_DIR has to be visible to whatever later runs `claude`
  # -- the tmux session ruori attaches to, or any `docker exec` -- not
  # just this script's own process. A plain `export` here wouldn't
  # reach those (separate processes spawned fresh against the
  # container's own config, not children of this script), so it goes
  # in /etc/bash.bashrc instead, sourced by every interactive shell.
  marker="export CLAUDE_CONFIG_DIR=\"$shared_claude_dir\""
  grep -qxF "$marker" /etc/bash.bashrc 2>/dev/null || echo "$marker" >>/etc/bash.bashrc
fi
exec "$@"
```

Then just run `claude` inside any one worktree's container and complete
the login (Claude Code's device-code flow needs no browser inside the
container — it prints a URL and code to open on any device). Every
other container for this repo picks it up immediately, with nothing
further to copy or configure.

**One consequence worth knowing:** session transcripts/history are now
shared across every worktree's containers for this repo too, not just
the login — but `claude --resume`/session listing stays correctly
scoped per worktree regardless, since Claude Code buckets sessions by
the full absolute `cwd` path, and every worktree has a distinct one
even when they all share the same `CLAUDE_CONFIG_DIR` (verified by
hand: three different working directories under one shared config dir
produced three separate, non-overlapping project buckets).

**This trades away per-container isolation — know what you're giving
up.** Elsewhere in this guide, `container-copy`'s one-time,
disconnected copy is treated as a feature specifically because a rogue
container can only ever corrupt *its own* copy. Sharing via
`RUORI_SHARED_DIR` deliberately gives that up: a rogue or compromised
container in any one worktree can now corrupt, revoke, or exfiltrate
the credential used by *every other worktree's* container for this
repo too. The blast radius is still just this one repo's containers —
not your primary host identity, not other repos — so pair this with a
dedicated login for container use (never your daily-driver account),
same reasoning as `gh`'s separate-identities recipe below. If you'd
rather keep full per-container isolation and don't mind re-doing the
login per container, use `container-copy` instead (see the directive
above) with `~/.claude/.credentials.json` **and** `~/.claude.json` as
sources on a Linux host, or export a container's copies of both back
out once via `docker cp` on a Mac host and point two `container-copy`
lines at them.

**Handling expiry:** Claude Code auto-refreshes its own short-lived
access token on every run, using the embedded refresh token, writing
the refreshed value straight back to the shared directory — no manual
step needed. Only if the refresh token itself is invalidated (explicit
logout, long inactivity, manual revoke) does `claude` start asking to
log in again; when that happens, just log in again in any one
container — every other container picks it up the same way it did the
first time.

**Bonus: your status hook no longer needs to compute usage.** If your
container-baked Claude Code status hook also writes a running cost
total to `.ruori/agent-usage` (see `docs/container-sandbox-plan.md`),
you can drop that half once you adopt this recipe — session transcripts
under `$shared_claude_dir/projects` are now host-visible, so `ruori`'s
own `USAGE` column reads them directly the same way it already does
for host-mode worktrees (see `docs/dashboard-columns.md`). Keep writing
`.ruori/claude-status` for the live busy/waiting/idle signal — that one
still needs the hook, since it's event-driven and has no transcript
equivalent.

## Recipe: GitHub CLI (`gh`) auth

`gh` *can* store its login as a plain file — `~/.config/gh/hosts.yml`
(or `$GH_CONFIG_DIR/hosts.yml` if you've set that env var) — which fits
the copy-in model above exactly like the Claude Code credentials
example does. **But check first:** on macOS, `gh auth login` defaults
to storing the token in the OS Keychain instead, in which case
`hosts.yml` only holds a reference to it, not the token itself, and
`container-copy` (which only ever reads a host **file**) copies in
something that won't actually authenticate. Run `gh auth status` — a
`(keyring)` suffix means you're in this situation. Force plain-file
storage instead by adding `--insecure-storage` to any `gh auth login`
below; the name is accurate; see the security note after "Separate
identities" below before doing this to your main, daily-driver login.

**Single identity, simplest case:**

```
container-copy ~/.config/gh/hosts.yml
```

(add `--insecure-storage` to whatever `gh auth login` produced this
host's `hosts.yml` if `gh auth status` showed `(keyring)`.)

Every worktree's container for this repo now has `gh` already
authenticated the moment it's created — no `gh auth login` inside the
container, ever.

**Separate identities per repo (e.g. work vs. personal), with no `gh
auth switch` on the host:** use `gh`'s own `GH_CONFIG_DIR` to keep each
identity in its own directory on the host, once:

```sh
GH_CONFIG_DIR=~/.config/gh-work     gh auth login --insecure-storage
GH_CONFIG_DIR=~/.config/gh-personal gh auth login --insecure-storage
```

`--insecure-storage` forces the token itself into that directory's
`hosts.yml` as plain text — instead of the OS keychain — which is what
makes `container-copy` (below) actually work, at the cost of the token
sitting in cleartext at that path on your host, not just inside the
container. This is exactly why you're using a separate,
narrowly-scoped login for this rather than your everyday `gh` identity.

Then point a given repo's `.ruori.conf` at the identity it should use,
mapped onto `gh`'s normal *default* location inside the container so
nothing in there needs to know `GH_CONFIG_DIR` exists:

```
container-copy ~/.config/gh-work:/root/.config/gh
```

A different repo's `.ruori.conf` can point at `~/.config/gh-personal`
instead — each repo's containers get whichever identity its config
names, independently, with the host's own `gh auth` never switched at
all.

This is still a one-time snapshot (see above): if you rotate or
re-`gh auth login` an identity, `docker rm -f` the affected
container(s) so `ruori` re-copies it fresh. The same security note
applies too — these are real, usable credentials once copied in.

## Recipe: git commit identity

A worktree's container gets no git identity of its own by default —
`git commit` inside it fails outright:

```
*** Please tell me who you are.
fatal: unable to auto-detect email address (got 'root@<container-id>.(none)')
```

If your host `~/.gitconfig` has a `[user]` section directly in it,
this is a plain file, no keychain involved, so it fits the copy-in
model exactly:

```
container-copy ~/.gitconfig:/root/.gitconfig
```

The explicit `:/root/.gitconfig` target matters here — the container's
`$HOME` is `/root`, not your host username's home directory, so the
"same path as the host" default `container-copy` falls back to when
you omit a target would land the file somewhere `git` never looks.
This brings over `user.name`/`user.email` plus anything else in your
gitconfig (aliases, `core.*`, etc.) as a one-time snapshot — same
"edit the host file, then `docker rm -f`/recreate to pick it up"
caveat as every other `container-copy` (see above).

If your host `~/.gitconfig` instead routes identity through
`includeIf "gitdir:~/work/"`-style conditional includes (no `[user]`
section of its own, just per-account files switched by which directory
a repo lives under), `container-copy` doesn't work: it only copies the
one top-level file, never whatever it `include`s, and even copying
those in too wouldn't help, since `~` inside `includeIf
"gitdir:~/…"` resolves against the *container's* `$HOME` (`/root`),
not your host user's, so the conditional never matches inside the
container regardless of what's on disk there. Sidestep `.gitconfig`
resolution entirely instead: git already reads `GIT_AUTHOR_NAME`,
`GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` from
the environment for every commit, no config file involved. Resolve
those once per repo, on the host, where your conditional includes
already work — e.g. a wrapper alias:

```sh
alias ruori='GIT_AUTHOR_NAME="$(git config user.name)" GIT_AUTHOR_EMAIL="$(git config user.email)" GIT_COMMITTER_NAME="$(git config user.name)" GIT_COMMITTER_EMAIL="$(git config user.email)" command ruori'
```

(run from inside the repo, so `git config` resolves through your
conditional includes correctly) — then forward them with
`container-env`:

```
container-env GIT_AUTHOR_NAME
container-env GIT_AUTHOR_EMAIL
container-env GIT_COMMITTER_NAME
container-env GIT_COMMITTER_EMAIL
```

Every worktree of one repo already shares a single identity — that's
what the conditional-include routing is *for* — so this only needs to
resolve once per `ruori` session, not per worktree. Same "change the
host value, then `ruori rebuild <branch>`" caveat as every other
one-time-at-creation directive: `ruori` only reads the environment
variable at container creation, never again.

If you'd rather commits made inside the container be attributed to
something other than your personal identity — the same
dedicated-identity reasoning as the recipes above — skip either of the
above and bake a fixed identity into the Dockerfile instead:

```dockerfile
RUN git config --system user.name "ruori agent" \
 && git config --system user.email "agent@example.invalid"
```

If you're also using `container-init` for something that touches git
config — the "Recipe: container-only gitignore patterns" above is the
motivating case — remember `container-copy ~/.gitconfig` overwrites
the container's *entire* `~/.gitconfig` verbatim on every creation.
`ruori` already runs `container-init` commands after `container-copy`
entries for exactly this reason, so a `container-init git config
--global core.excludesFile ...` line always wins regardless of order
in `.ruori.conf` — but a bare `--system` identity (the Dockerfile
alternative just above) plus a `container-copy`'d `~/.gitconfig` that
*also* happens to set `core.excludesFile` would still have the
`--global` value win, same as it would for identity. See
`docs/gimmicks.md`.

## Recipe: vite's dev-server bind host

Vite's default dev-server `host` binds to `localhost`, which resolves
to the *container's* loopback interface, not something reachable from
the host or another container — inside container mode you generally
want `0.0.0.0` there. Keep the tracked `vite.config.*` untouched and
pass the difference in from outside. Either start the dev server with
the flag directly:

```
container-command npm run dev -- --host 0.0.0.0
```

or have the config read an env var (`server: { host:
process.env.VITE_HOST ?? 'localhost' }`) and set `VITE_HOST=0.0.0.0` in
the Dockerfile (`ENV VITE_HOST=0.0.0.0`) so it only applies inside the
container. The same pattern — a flag or env var the host leaves unset —
covers most "this tracked config must differ in the container" needs.

If you'd rather not touch the dev command or the config's source,
`worktree-overlay` (see [config-file.md](config-file.md)) can patch
`vite.config.*` in every linked worktree instead — at the cost of the
host binding `0.0.0.0` in those worktrees too, and the file showing as
modified in `git status`.

## Recipe: `git push`/`pull` fails over an SSH remote from inside the container

Most minimal base images ship no `ssh` client at all, so a remote like
`git@github.com:org/repo.git` fails outright the moment git tries to
shell out to it:

```
error: cannot run ssh: No such file or directory
fatal: unable to fork
```

As noted at the top of this guide, agent-forwarded SSH isn't something
`ruori` sets up. Rather than installing `openssh-client` and
`container-copy`-ing a raw private key in, reuse the `gh` recipe above
for authentication instead, and have git transparently treat
SSH-style GitHub URLs as HTTPS ones — the remote itself, in
`.git/config`, never has to change from `git@github.com:...` to
`https://...`, on the host or anywhere else, since that config is
shared across every worktree (see "Per-repo state files" in
`CLAUDE.md`).

1. **Install `gh` in the image** — it's not in Debian's default repos,
   so this is GitHub's own apt-repo install recipe (adjust for a
   different base image):

   ```dockerfile
   RUN (curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg) \
       && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
       && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
       && apt-get update && apt-get install -y --no-install-recommends gh \
       && rm -rf /var/lib/apt/lists/*
   ```

2. **Wire git's credential helper to `gh`, and rewrite SSH-style GitHub
   URLs to HTTPS — both with `--system`, not `--global`.** A
   `container-copy ~/.gitconfig:/root/.gitconfig` line (previous
   recipe) overwrites `/root/.gitconfig` — the `--global` file — with
   your host's own gitconfig on every container creation, which would
   silently wipe out either setting if it were put there instead.
   `--system` writes to `/etc/gitconfig`, baked into the image at
   build time and untouched by that copy:

   ```dockerfile
   RUN git config --system credential.https://github.com.helper "!gh auth git-credential" \
       && git config --system url."https://github.com/".insteadOf "git@github.com:"
   ```

   The `credential.helper` line makes `gh` supply the token from
   whichever `hosts.yml` you `container-copy`'d in (see the `gh` recipe
   above — check whether you need `--insecure-storage` there first).
   The `insteadOf` line is what avoids ever touching the real remote:
   git rewrites `git@github.com:...` to `https://github.com/...` for
   any operation, but only inside processes that read this container's
   `/etc/gitconfig` — your host's own git, and `.git/config` itself,
   are untouched, so SSH keeps working there exactly as before.

## Recipe: `container-port` published but connection refused from the host

Symptom: `docker ps` shows the expected `127.0.0.1:<host>-><container>/tcp`
mapping, `ruori ports` shows the right host port, but a browser or
`curl http://localhost:<host-port>` from the host gets connection
refused — even though `curl http://localhost:<container-port>` from
*inside* the container (via `docker exec`) succeeds.

The giveaway is in that inside-the-container `curl -v` output: it
tries `127.0.0.1` first, gets refused, then falls back to `[::1]`
(IPv6 loopback) and connects. That means the dev server is bound to
loopback only — and to only *one* loopback address at that (commonly
`::1`, e.g. when it's told to bind `localhost` and the runtime
resolves that to IPv6 first).

This isn't fixable from the `ruori` / Docker side. `docker run -p`
forwards host traffic to the container's real network interface (the
bridge network's `eth0`), never to the container's loopback — that's a
Linux network-namespace boundary, not a Docker flag. A process bound
to `127.0.0.1`/`::1` inside the container is reachable only from
another process in that same namespace (i.e. another `docker exec`),
never via the published port, no matter what `container-port` says.

Fix it in the app, not the config: bind the dev server to `0.0.0.0`
inside the container so it accepts connections on every interface,
including the bridge one Docker's port-forwarding actually targets.
For a Vite app this is `server.host: '0.0.0.0'` in `vite.config.ts`
(or `--host 0.0.0.0` on the CLI); other dev servers (webpack-dev-server,
Next.js, etc.) have an equivalent `--host`/`host` option. This is a
generic "dev server defaults to localhost-only, which breaks the
moment it's not the same machine/namespace as the client" issue, not
specific to `ruori` — it just tends to surface here because container
mode is often the first time a given dev server runs somewhere other
than the developer's own host namespace.

## Directive comparison — don't mix these up

| Directive | Direction | Timing | Ends up... |
|---|---|---|---|
| `copy` | host → host | once, only if the target file doesn't already exist there | a plain file in the target **worktree** |
| `container-port` | n/a (env injection) | fresh, every container start | an env var in the container process — **never written to any file** |
| `container-copy` | host → container | once, only at container **creation** | a private, writable copy inside the container's own filesystem |
| `container-host-port` | host → container (reverse of `container-port`) | fresh, every transition to running | a `socat` process inside the container — **never written to any file** |
| `container-volume` | n/a (storage swap, not a copy) | once, at container **creation** (`ruori rebuild` to apply an added/removed line) | that one subpath backed by a Docker volume on native storage — starts **empty**, never touches the host |
| `container-shared-volume` | n/a (shared storage, not a copy) | once, at container **creation** (`ruori rebuild` to apply an added/removed line) | one Docker volume per **repo**, mounted at the same absolute path in every worktree's container — unlike `RUORI_SHARED_DIR`, which is also shared but lives on the (slower) host bind mount |
| `container-init` | n/a (arbitrary command) | once, at container **creation**, after `container-copy` (`ruori rebuild` to apply an added/removed/changed line) | whatever the command itself does — `ruori` tracks no specific resulting file |
| `container-env` | host → container (env only, from `ruori`'s own process) | once, at container **creation** (`ruori rebuild` to apply a changed/added/removed line) | an env var in the container process — **never written to any file** |

`container-volume` looks similar to `container-copy` but does the
opposite kind of thing: `container-copy` puts a host file's *contents*
into the container once; `container-volume` gives an *empty* subpath
its own storage and never reads anything from the host at all — you
still populate it yourself from inside the container (e.g. `pnpm
install`), same as you would without the directive. Unlike `copy`, it
takes an exact path, never a glob — see "Host-side tooling and
generated directories" above for why.

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
- **`socat`** — only if you use `container-host-port` (above); ruori
  warns and skips a port rather than failing the container start if
  it's missing.

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

If you'd rather not edit copied `.env`/config values to say
`host.docker.internal` at all (e.g. they're checked in as
`localhost`-pointing templates, or several tools in the image assume
`localhost`), add `container-host-port <port>` (see "The five
directives" above) for each such port instead — `ruori` runs a `socat`
relay inside the container so `localhost:<port>` there reaches the
host transparently, and nothing needs editing. This still doesn't
change the next paragraph's isolation gap; it only removes the
`host.docker.internal` string-editing step.

This is a known gap, not a deliberate design point like the
Docker-in-Docker restriction itself: every worktree's dev container
currently shares the *same* instance of whatever backing service you
run this way (e.g. two worktrees both writing to the same dev
database), with no per-worktree isolation. A cleaner fix — `ruori`
itself (never the agent) orchestrating per-worktree sidecar
containers via `docker compose`, on the host side where it already
has Docker access — is a plausible follow-up, not built yet.

Example: a project whose `compose.yaml` defines `mssql` (port 1433)
and `redis` (port 6379), started natively on the host once
(`docker compose up mssql redis -d`) and shared across every
worktree's dev container:

```
container-host-port 1433
container-host-port 6379
```

...plus `socat` installed in `container-file`'s Dockerfile. The app's
existing `DATABASE_URL`/`REDIS_HOST` values pointing at `localhost` (or
`127.0.0.1`) now work unmodified inside the container — no
`host.docker.internal` edits needed.

## Worked example: a frontend + backend app

`.ruori.conf`:

```
container on
container-file .devcontainer/Dockerfile
container-port 3000:FRONTEND_PORT:http
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
mappings — the `:http`-typed `FRONTEND_PORT` above gets a clickable
`URL` column entry there and an "open in browser" item in the Enter
action menu; `BACKEND_PORT` doesn't, since it has no `:http`.

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
