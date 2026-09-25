# Gimmicks: the non-obvious problems and what we decided

Every entry here is something that surprised us — a tool behaving in a
way you wouldn't guess from its documentation, a platform quirk, or an
approach that looked right and wasn't. Each records the surprising
fact, what was rejected (when something was), and the decision the
code now embodies. Read this before changing anything in the area it
covers; add to it whenever a change works around something a future
reader wouldn't guess. References are to function names in `bin/ruori`
and section titles in `docs/`, not line numbers.

---

## Host vs. container filesystem

### Per-platform generated directories can't be shared between host and container

**Fact.** The worktree is one live bind mount and the container is
Linux while the host is macOS. Anything a toolchain generates for the
platform it runs on — native addons in `node_modules`, build output,
`.pnpm-store`, a Rust `target/`, a Python venv — is only valid on the
side that produced it. An install run inside the container leaves
Linux binaries where the host editor's language server then tries to
load them; the reverse leaves macOS binaries the container can't run.
There is no way to make one copy serve both. Separately, some
self-relaunching native binaries (a Go/Rust tool shipped as an npm
optional dependency) don't reliably execute at all straight off Docker
Desktop's virtiofs bind mount.

**Rejected.**
- *Bidirectional file sync (Mutagen, Docker Synchronized File Shares)
  instead of a bind mount.* Docker's version needs a paid plan; more
  importantly, a synced working tree has a lag window, so a `git
  commit` from the container right after a host edit can silently
  capture the stale version — a worse failure than the one being
  fixed. Source files don't need separate copies; only generated
  directories do.
- *Attaching the editor into the container (VS Code "Attach to
  Running Container").* Solves it completely for one editor and is
  editor-specific; ruori must stay editor- and agent-agnostic.
- *Glob patterns for `container-volume`* (`apps/*/node_modules`,
  resolved against git-tracked directories). Implemented, then removed
  the same day: `**/node_modules` produced a volume under *every*
  tracked directory at every depth — a set of mounts nobody could read
  off the config file. The directive is also a one-time setup step, so
  auto-discovery wasn't buying much.

**Decision.** Source is shared via the bind mount; each generated
directory gets its own container-only Docker volume via an exact
`container-volume <path>` line; host tooling does its own native
install once per worktree. `warn_container_volume_drift` compares the
config to the container's real mounts on every switch, because Docker
can't change an existing container's mounts — an added/removed line
needs `ruori rebuild`. Sub-gotchas: a shadowed directory is a
mountpoint, so `rm -rf node_modules` inside the container fails with
`Device or resource busy` (empty it with `find … -mindepth 1 -delete`).
Where pnpm's store goes is its own entry below. See
`docs/container-sandbox-guide.md` "Host-side tooling and generated
directories".

### A package store needs one volume per repo, not per worktree

**Fact.** Inside the container, pnpm can't use the image's default
global store (it's on a different filesystem from `node_modules`), so
without a `store-dir` it falls back to an in-tree `.pnpm-store` — on
the host bind mount. The old recipe shadowed that with `container-volume
.pnpm-store`, which fixed the location but made the store per
worktree: every new worktree's first install re-downloaded every
package. Hardlinking from the store into `node_modules` was never on
the table either way: the two are separate mounts, and Linux refuses
hardlinks across mounts (EXDEV) even when both volumes live on the same
disk, so pnpm copies.

**Rejected.**
- *Store under `RUORI_SHARED_DIR`* (no code change). Shared, but it's
  on the host bind mount, and copying tens of thousands of small files
  over Docker Desktop's virtiofs is much slower than volume-to-volume
  inside the VM.
- *pnpm's global virtual store.* It would make `node_modules` mostly
  symlinks into the shared store, but that shares *built* package
  contents (postinstall output included) across worktrees — exactly
  the cross-worktree coupling the per-worktree `node_modules` volume
  exists to avoid.
- *`pnpm fetch` baked into the image.* The lockfile differs per
  branch, and any change to it invalidates the layer and re-downloads
  everything.

**Decision.** A separate `container-shared-volume <absolute-path>`
directive: one named Docker volume per repo (`container_shared_volume_name_for`,
prefixed with the repo name and the main worktree's path hash),
mounted in `container_start_if_needed`, covered by
`warn_container_volume_drift`, listed by `ruori resources`, and
deliberately skipped by `delete_worktree`. Kept separate from
`container-volume` rather than a flag on it, because the two differ in
both path space (container-absolute vs worktree-relative) and lifetime
(repo vs worktree). The Dockerfile sets the store dir via `ENV` rather
than the repo's `.npmrc`, so host installs are unaffected — and sets
it under *both* names, `npm_config_store_dir` and
`pnpm_config_store_dir`: pnpm 10 reads only the former, pnpm 11 only
the latter, and a wrong one fails silently (pnpm just falls back to an
in-tree `.pnpm-store` and downloads everything; the shared volume stays
empty). The first version of the recipe set only `npm_config_store_dir`
and was verified on pnpm 10, which is how that got missed. See
`docs/container-sandbox-guide.md` "Recipe: a Node.js monorepo".

### The host-side install is the user's own concern — ruori tracks nothing about it

**Fact.** Once generated directories are container-only, the host
editor needs its own install, and it's easy to forget in a fresh
worktree. Three ways for ruori to help were considered: a `host-setup
<command>` directive run on `ruori new`/on demand (makes `.ruori.conf`
execute repo-controlled commands on the host); a nudge in the picker
preview/`details`/activation derived from which `container-volume`
directories are empty on the host (implemented, then reverted the same
hour); and a per-repo git `post-checkout` hook. **Decision.** None of
them. ruori orchestrates the container side only and keeps no notion
of host-side state; the host install is a documented step in the
sandbox guide, nothing more. Ecosystem-specific ways to avoid it
(pnpm/Yarn `supportedArchitectures` fetching several platforms into
one tree) were tested and work, but are deliberately not part of the
setup guidance for now — they're per package manager, not general.

### Bind mounts must sit at identical host and container paths

**Fact.** A linked worktree's `.git` is a pointer *file* containing an
absolute host path into the common git dir. Git inside the container
only works if both the worktree and the common dir are mounted at
exactly those same paths. **Decision.** `docker run -v "$path:$path"
-v "$common_dir:$common_dir"`; git is a hard Dockerfile requirement.
(`container_start_if_needed`; plan section D.)

### Per-worktree file tweaks patch the worktree in place, never a bind mount over one file

**Fact.** Making one file differ per worktree/container (a `.env`'s DB
host, a `vite.config.*` bind host) was first built as
`container-overlay`: generate a patched copy under `<git-common-dir>/ruori/`
and bind-mount it read-only over the path inside the container, host
file untouched. Every part of that fought back:
- On Docker Desktop for Mac an individually file-bind-mounted path
  caches its byte length at mount time: host-side rewrites that
  *grow* the file are served silently truncated, indefinitely (shorter
  or equal-length rewrites propagate fine; files reached through the
  directory bind mounts never have the problem). So the overlay could
  only be generated once, before `docker run`, and never refreshed.
- `docker inspect` sometimes reported that mount's `Source` through the
  VM's `/host_mnt/...` view, so the drift check needed a prefix strip
  to stop false "targets changed" warnings.
- For a git-tracked target — the flagship use case — git inside the
  container shares the worktree's index with the host but read the
  patched content, so it always showed the file as modified (easy to
  commit by accident), and couldn't rewrite a mount point at all:
  checkout/stash/reset/rebase failed with `EBUSY` ("unable to unlink
  old '<file>': Device or resource busy"), once mid-rebase, leaving
  `rebase-merge/` holding only the autostash commit.

**Rejected.**
- *Keep the mount, refuse tracked targets* (briefly shipped, as a hard
  error). Removes the git breakage but leaves the size-cache and
  `/host_mnt` workarounds, and the flagship case unsupported.
- *`git update-index --skip-worktree`/`--assume-unchanged`, or a
  separate `GIT_INDEX_FILE` in the container.* The index lives in the
  common git dir shared with the host, so the first hides real host
  edits; the second means two diverging indexes and still `EBUSY`.
- *Padding the generated file, or `docker restart` on growth* to dodge
  the size cache. Padding only moves the truncation cliff; a restart
  kills the tmux session `ruori` exists to preserve.

**Decision.** `worktree-overlay <relpath> <patch-file>`: patch the
worktree's own file in place, on every switch, in both modes, no
mount. Idempotent via a reverse `--dry-run` (already applied → no-op),
else a forward apply, else leave the file alone and warn/log. A patched
tracked file just shows as modified — that's accepted, and git works
normally everywhere. Two `patch` details: `-f`, because BSD patch
(macOS) otherwise auto-detects a "reversed" patch and silently applies
`-R` itself, making the already-applied check always succeed; and
`-F0` plus `-o <scratch>` then `cat >`, so there's no fuzzy
"success", no `.orig`/`.rej` in the worktree, and the target keeps its
inode. (`worktree_overlay_apply_one`, `apply_worktree_overlays`.)

### `docker cp` neither creates parent directories nor copies a directory the way `cp` does

**Fact.** `docker cp` fails with "Could not find the file <parent> in
container" when the destination's parent doesn't exist in the image
(#10), and a bare directory source is copied *into* an existing
destination directory, so `container-copy ~/.claude-personal:/root/.claude`
landed at `/root/.claude/.claude-personal/` (#14). **Decision.**
`docker exec mkdir -p "$(dirname …)"` before every copy; directory
sources use the `SRC/.` form. (`container_start_if_needed`, the
container-copy loop.)

### `container-copy` is a one-time snapshot, and `~/` is only ever the host's home

**Fact.** A live bind mount of a credentials file forces a
read-only-vs-writable trade-off (token refresh needs writes; writes
risk corrupting the host file). A `~/` in the *container* path would
mean a different user's home (`/root`), and a value read from a config
file must never go through `eval`. **Decision.** `docker cp` only in
the "container just created" branch; refreshing means recreating the
container (`ruori rebuild`, #12/#31, which keeps ports and volumes); a
literal leading `~/` expands to `$HOME` on the host side only, the
container path is used verbatim. (`container_copy_entries`; guide
"`container-copy` is a one-time snapshot".)

### Dockerfile `COPY` paths are relative to the main worktree root

**Fact.** ruori runs `docker build -f <container-file>
<main-worktree-root>`, so `COPY hook.sh …` next to
`.devcontainer/Dockerfile` fails with a checksum "not found" — the
generated Dockerfile and the guide's own example both had this bug
(#9). **Decision.** The setup guide mandates `COPY .devcontainer/<file>`.
(`container_build_if_needed`.)

### Docker image names must be lowercase

**Fact.** `sanitize()` keeps case (fine for tmux/container names) but
`docker build -t ruori/packPixie` fails with "repository name must be
lowercase". **Decision.** `container_image_for` lowercases.

### Always `docker build`, no staleness heuristic

**Fact.** A hand-rolled "has the Dockerfile changed?" check can't know
about files the Dockerfile `COPY`s. **Decision.** Build every time;
Docker's layer cache keeps it near-instant. (Plan section B.)

## Container networking

### `container-port` published but "connection refused" from the host

**Fact.** `docker run -p` forwards to the container's bridge interface,
never its loopback — a Linux network-namespace boundary, not a Docker
flag. A dev server bound to `127.0.0.1`/`::1` (often because
`localhost` resolves to IPv6 first) is reachable only from another
`docker exec`. Tell: in-container `curl -v localhost:<port>` fails on
`127.0.0.1` then succeeds on `[::1]`. **Decision.** Not fixable in
ruori; documented — bind the server to `0.0.0.0`. (Guide "Recipe:
`container-port` published but connection refused".)

### Host services reached via `socat`, not `--network host`

**Fact.** Docker has a flag for container→host publishing (`-p`) but
nothing that puts a *host* port onto the container's own loopback,
which is what checked-in `.env` templates saying `localhost:5432`
expect. `--network host` would remove the isolation the container
exists for. **Decision.** `container-host-port` runs `docker exec -d …
socat TCP-LISTEN:<port>,fork,reuseaddr TCP:host.docker.internal:<port>`
on every transition to running (`docker stop` kills it); warn-and-skip
if the image lacks `socat`. Every worktree shares the same host
instance — an acknowledged gap, not a design point; ruori-orchestrated
sidecars are the suggested follow-up. (`container_start_host_port_forwards`;
guide "Current limitation: shared backing services".)

### No Docker-in-Docker, no socket mount

**Fact.** The Docker socket is root-equivalent on the host; handing it
to the agent defeats the sandbox. **Decision.** Dev server, agent, and
ad-hoc commands all run in the one container; the previous entry is
the consequence. (Plan Context; guide "What container mode does — and
doesn't — sandbox".)

### Host ports are seeded from a hash so repos don't cluster

**Fact.** The ports cache is per repo, so nothing knows another repo's
allocations, and Docker bakes the host port into the container at
creation without re-checking on `docker start`. If every repo scanned
from the same base, a stopped container's port would routinely be
taken by another repo and its restart would fail with "port is already
allocated". **Decision.** `port_seed_for` = 20000 + cksum(session:port)
% 10000, then a forward scan with `lsof`; the result is persisted in
`ruori/ports` precisely because the scan is non-deterministic. Reduces
the race, doesn't eliminate it — a conflict surfaces as a clear Docker
error, not corruption. (`allocate_port_for`; plan "Open risks".)

## Credentials inside the container

### Claude Code's login is in the macOS Keychain, and its files can't be symlinked

**Fact.** Nothing on a Mac host for `container-copy` to copy. Logging
in from inside a Linux container yields plain files — but
`.credentials.json` alone still shows "Not logged in": the sibling
`~/.claude.json` (in `$HOME`, not under `~/.claude`) is also required.
Neither can be symlinked to shared storage, because Claude Code writes
both via write-then-rename and `rename()` onto a symlink replaces the
symlink with a plain file, silently un-sharing it. With
`CLAUDE_CONFIG_DIR` set, `~/.claude/settings.json` (the baked-in hooks)
is ignored entirely. A plain `export` in the entrypoint doesn't reach
tmux/`docker exec` shells. **Decision.** ruori injects
`RUORI_SHARED_DIR` (a subdirectory of the already-mounted common git
dir, named for purpose not implementation) into every container; the
repo's own entrypoint sets `CLAUDE_CONFIG_DIR=$RUORI_SHARED_DIR/…` via
`/etc/bash.bashrc` and seeds `settings.json` no-clobber. Sessions stay
per worktree because Claude Code buckets by absolute cwd. This trades
per-container isolation for one shared login — pair it with a
dedicated account. (Guide "Recipe: Claude Code auth";
`.devcontainer/entrypoint.sh`.)

### `gh`'s `hosts.yml` may be only a Keychain reference

**Fact.** On macOS `gh auth login` defaults to keyring storage, so
`hosts.yml` holds a reference, not the token; copying it in yields a
`gh` that can't authenticate. `gh auth status` showing `(keyring)` is
the tell. **Decision.** `gh auth login --insecure-storage`, ideally
under a per-identity `GH_CONFIG_DIR` mapped to `/root/.config/gh`, with
a narrowly scoped token since it's now cleartext on the host. (Guide
"Recipe: GitHub CLI (`gh`) auth", corrected in #35.)

### Container `$HOME` is `/root`, so a same-path copy of `~/.gitconfig` lands where git never looks

**Fact.** `container-copy ~/.gitconfig` with no target puts it at
`/Users/<you>/.gitconfig` inside the container; `git commit` fails
"unable to auto-detect email address". **Decision.** Always
`container-copy ~/.gitconfig:/root/.gitconfig`, or bake identity with
`git config --system`. (Guide "Recipe: git commit identity".)

### SSH remotes: no ssh in minimal images, and `--global` gets overwritten

**Fact.** `git@github.com:` remotes fail "cannot run ssh"; forwarding
the agent would need a live `$SSH_AUTH_SOCK` mount, which contradicts
the copy-in model. The remote URL lives in the shared common dir, so it
can't be switched to HTTPS for the container alone. And a
`container-copy` of `~/.gitconfig` overwrites the `--global` file on
every creation, wiping anything put there. **Decision.** Bake
`url."https://github.com/".insteadOf "git@github.com:"` and the `gh`
credential helper into `/etc/gitconfig` with `git config --system` at
build time. (Guide "Recipe: `git push`/`pull` fails over an SSH
remote".)

### `container-init` must run after `container-copy`, not before

**Fact.** Same root cause as the SSH-remote gotcha above: a
`container-copy ~/.gitconfig:/root/.gitconfig` (the documented git
identity recipe) overwrites the container's entire `~/.gitconfig`
verbatim from the host's copy on every container creation — including
anything an earlier-run setup step already put there. The gitignore
recipe (`docs/container-sandbox-guide.md`'s "Recipe: container-only
gitignore patterns") relies on a `container-init` command's `git
config --global core.excludesFile ...` write surviving that. **Decision.**
`container_init_commands_run` runs in `container_start_if_needed`'s
"just created" branch strictly after the `container-copy` loop, so any
`container-init` command is always free to depend on or override
whatever `container-copy` set up, never the reverse.
(`container_init_commands_run`.)

## Status and cost columns

### Hooks can only be baked into the repo's Dockerfile; the status file lives in the worktree

**Fact.** ruori refuses to edit the host's `~/.claude/settings.json`,
so the `CLAUDE` column is live only in container mode. `Stop` fires
when the main agent hands off to a subagent, so `PreToolUse`/`PostToolUse`
must also be hooked or `busy` goes stale. A file *inside* the worktree
is host/container-transparent via the existing bind mount and
auto-cleaned on removal — but as an untracked file it makes `git
worktree remove` refuse unless it's in the **global** gitignore.
**Decision.** One `.ruori/` directory holding `claude-status` and the
optional `agent-usage`, so a single gitignore entry covers both.
(`docs/dashboard-columns.md` "CLAUDE busy/waiting/idle status".)

### Usage-cost scan predicts Claude Code's project-dir name — but only for the host

**Fact.** `~/.claude/projects/<dir>` is the session cwd with every
non-alphanumeric character replaced by `-`, so worktree paths can be
forward-encoded as an exact pre-filter instead of opening every
transcript on the machine (`file-io.log` made the host-wide scan
visible). But a container session's cwd is *not* guaranteed to equal
the host path (a `WORKDIR /workspace`, or a bare `docker exec bash`),
so the filter can't be applied to the `RUORI_SHARED_DIR` scan.
`*/subagents/*.jsonl` is skipped because its cost is already rolled
into the parent session. (`fetch_usage_costs`.)

### `printf %.2f` is locale-sensitive

**Fact.** Under `fi_FI.UTF-8`, `printf '%.2f' 34.81` fails with
"invalid number" and `set -e` kills the picker; jq always emits `.`.
**Decision.** `LC_NUMERIC=C printf`. (`usage_cost_for`.)

### `gh pr list` per branch, never one repo-wide call

**Fact.** A repo-wide list needs `--limit`, and on a busy repo a PR
merged weeks ago can already be outside the most recent 200 — showing
`-` instead of `merged`. **Decision.** One `gh pr list --head <branch>
--state all` per worktree, only on Ctrl-F, cached to
`pr-status.cache`. (`fetch_pr_statuses`; `docs/dashboard-columns.md`.)

## The fzf picker

### fzf `reload`/`execute` bindings run in a fresh process

**Fact.** A reload can't see the manager's in-memory maps or the
tracked iTerm2 window; and a `--header-lines=1` reload that omits the
header swallows the first real row. **Decision.** Hidden commands
(`__fzfgen`, `__fzfgen_fetch`, `__new_prompt`, `__delete_by_fields`)
re-derive everything from on-disk caches and always emit the header
line first; `__new_prompt` creates but deliberately does not activate,
because the iTerm2 lifecycle lives in the parent loop. The Enter action
menu runs *after* the outer fzf has exited so it's plain bash with a
terminal (why the old Ctrl-D/Ctrl-X `execute` bindings went, #11).
Anything `--preview` needs is `export`ed. (`CLAUDE.md` item 10.)

### Automatic periodic refresh was tried and reverted twice

**Fact.** Killing and restarting fzf reset the cursor and query;
pushing an in-place `reload` reset the cursor unpredictably in real use
despite passing every isolated test. **Decision.** Refresh is manual
(Ctrl-R, same `reload` mechanism but user-triggered); destructive menu
actions exit the picker and let the loop re-invoke it fresh.
(`docs/dashboard-columns.md`.)

### Picker startup was dominated by per-row Docker round-trips (#32/#33)

**Fact.** With 24 worktrees in container mode, each row did several
`docker inspect`/`docker exec` calls — 110 Docker subprocesses, ~5s
before the picker appeared; each is a gRPC hop to Docker Desktop, not
local work. **Decision.** One `docker ps -a --format` per draw fills
`_docker_state_by_name`/`_docker_id_by_name`
(`refresh_docker_container_table`); image info primed once; `tmux
has-session` only checked for running containers. ~1.5s, 2 Docker
calls.

### OSC 8 hyperlinks are emitted unconditionally

**Fact.** Terminals without support (fzf's preview pane included) just
render the text with inert escape bytes, so no capability check is
needed. (`browser_links_for`.)

### Container tmux draws every non-ASCII character as `_`

**Fact.** `docker exec` forwards none of the host's locale, and
minimal base images (`ubuntu`, `debian`) set no `LANG`, so everything
exec'd into a container runs under `POSIX`. tmux decides whether an
attached client can take UTF-8 from that client's locale, finds none,
and substitutes `_` for every non-ASCII cell — Claude Code's arrows,
lazygit's box drawing (issue #4). The tmux server, and therefore every
pane, inherits the same locale from the `docker exec` that started it.
**Rejected.** Requiring each repo's Dockerfile to set `ENV LANG`
(every image would hit this, and forgetting it looks like a ruori
bug); passing `-e LANG` at `docker run` (only takes effect after a
`ruori rebuild`). **Decision.** Every `docker exec` that starts or
attaches the session passes `-e LANG=<image's own LANG, else
C.UTF-8>`, and the attach also passes `tmux -u`. A session started
before this fix keeps its POSIX panes until it's killed and recreated,
but `-u` fixes the rendering on the next attach regardless.
(`container_lang_for`, `activate_worktree`, `open_iterm_window_for`.)

## Container terminal color coding

### The palette must avoid tmux's own default status-bar green

**Fact.** tmux's built-in default `status-bg` is green. A palette
color that's itself green-ish reads the same as an unstyled status
bar at a glance, so a container could look indistinguishable from a
plain host session — defeating the whole point of the cue (issue
#30: make it obvious you're on a container). **Decision.**
`CONTAINER_COLOR_PALETTE` (`container_color_for`) excludes every
green/green-adjacent xterm-256 index, so any assigned color reads as
clearly "colored" against tmux's own default.

## iTerm2

### Spawned processes don't inherit the login-shell `PATH`

**Fact.** iTerm2 runs a profile's command directly, not via a login
shell, so `~/.zshrc` additions (Homebrew's `tmux`) are invisible in the
spawned window. **Decision.** `tmux_bin`/`docker_bin` resolved once at
the top of the script and interpolated into the generated attach
script; inside a container, bare `tmux` on purpose (the container's
own). (`CLAUDE.md` "Notable cross-cutting behavior".)

### Window ids are reused across app restarts

**Fact.** iTerm2 numbers windows from a counter that resets on
restart, so a persisted id can name an unrelated window; closing it
would destroy real work. **Decision.** `iterm-window` stores
`<iterm_pid>\t<window_id>`; the id is adopted only if the pid matches
and the window still exists. Wrong-direction safety: better a stray
window than closing the wrong one. (`load_active_iterm_window_id`;
`docs/troubleshooting.md`.)

### `pgrep -x iTerm2` never matches an iTerm2 installed under `~/Applications`

**Fact.** macOS reports the process comm as the full executable path
there, so the exact match returns nothing; every save wrote an empty
pid, every load treated that as "not running", and windows piled up
permanently. **Decision.** `iterm_pid` uses `ps -axo pid=,comm=` and
matches `comm == "iTerm2" || comm ~ /\/iTerm2$/`.

### The persisted window id must be re-read on every switch

**Fact.** Two manager loops for the same repo (a second tab left at
the picker) each held their own stale in-memory idea of the current
window; the idle one then opened a new window without closing the real
one (#26). **Decision.** `load_active_iterm_window_id` runs at the top
of every `open_iterm_window_for`; the file is the single source of
truth.

### AppleScript `create window`/`close` return before the window appears/disappears

**Fact.** `create window` can report a timeout while the window still
appears moments later; `close` returns 0 while the window lingers, so a
naive "still open?" check warned on nearly every successful switch.
**Decision.** Poll `iterm_window_ids` for up to ~2s after close; on
create, treat any non-numeric reply as "unknown id" and diff the
before/after id lists after a short sleep. Every step is appended to
`iterm.log` (never rotated) because by the time a leftover window is
noticed, in-memory state is gone. (`open_iterm_window_for`;
`docs/troubleshooting.md`.)

### A generated attach script, and pause-on-failure only if the session still exists

**Fact.** Nested quoting inside an AppleScript string is unmanageable,
and many iTerm2 profiles "Close Sessions On End", so a fast attach
failure flashes and vanishes unread — but a session torn down on
purpose also makes attach exit non-zero. An AppleScript-side `set name`
doesn't survive the exec into tmux. **Decision.** Write a `mktemp`
bash script; on non-zero exit re-check the session and only pause with
"press Enter" if it's genuinely still there; set the title with an OSC
escape from inside the script.

### `set -e` turned "iTerm2 not running" into a silent exit

**Fact.** `iterm_pid`/`iterm_window_ids` piped into `head`/`tr` and
returned the pipeline status; a normal "not found" killed the script
with no message during a bare assignment (#15). Same class: Esc on the
fzf action menu, and `grep` legitimately returning 1 in the usage scan.
**Decision.** `|| true` at each of those sites.

## Startup, identity, bash

### Must run from the main worktree

**Fact.** `git rev-parse --show-toplevel` resolves to whichever
worktree you're standing in; session-name prefixes and cache locations
keyed on it would differ per launch location. **Decision.** Hard
refusal with both paths shown. (`CLAUDE.md` item 1.)

### Per-repo state lives under `<git-common-dir>/ruori/`

**Fact.** Linked worktrees share one common git dir, so keying on it
gives one copy per repo; loose `ruori-*` files in `.git/` were hard to
clear. Also, bash only knows a function once it has read past its
definition — `git_common_dir` had to move to the top of the script
because state accessors ran before the container section, which
surfaced as a real "command not found" against a live container.
**Decision.** `ruori_state_dir`, `rm -rf`-able as one unit.
(`CLAUDE.md` item 9.)

### Memoization inside `$(...)` never writes back

**Fact.** Every caller invokes `git_common_dir`/`config_directives`/
`container_image_info_for` through a subshell, so a cache assignment in
the function body is lost and code that looked memoized re-ran `git
rev-parse` / re-parsed `.ruori.conf` on every call. **Decision.**
`*_prime` functions run each once in the parent process right after
the definition; subshelled calls then only print the cached value.

### `local a=… b=$a` expands `$a` before the assignment

**Fact.** Within one `local` command bash expands every right-hand
side before any assignment takes effect, so `local session="$1"
name="$session"` sees the caller's `session` (unset under `set -u`).
**Decision.** Separate `local` statements. (`container_start_if_needed`.)

### `readlink -f` doesn't exist on macOS

**Decision.** `ruori init` walks the symlink chain by hand from
`BASH_SOURCE[0]` (not `$0`, which is just the invoked name).

### `sanitize()` is lossy, so session names hash the full path

**Fact.** `feat/a` and `feat-a` collide after sanitizing, and a detached
worktree has no branch at all. **Decision.** `session_name_for` appends
a hash of the worktree path. (`TODO.md` section 1.)

### Worktrees are siblings under `<repo>.worktrees/`, branch slashes flattened

**Fact.** Nesting under the main tree gets picked up by scanners;
keeping `feat/x` as a directory would leave an empty `feat/` behind on
removal and make prompts print "x on feat/x". (`new` command.)

### A branch name that exists only on a remote must not be branched off `HEAD`

**Fact.** `git worktree add -b foo <path> HEAD` with only `origin/foo`
existing creates an unrelated local `foo`. It looks like the remote
branch but shadows its work, and nothing warns you. **Rejected.**
Relying on `git worktree add <path> foo`'s own remote guessing, since
ruori always passes `-b`. **Decision.** When there's no local branch
and no explicit start point, and exactly one remote has the name, that
remote ref becomes the start point. `-b` off a remote-tracking ref
already sets upstream. With two or more matching remotes the name is
ambiguous, so ruori falls back to `HEAD`. Ctrl-N additionally asks
"new branch" vs "existing branch" up front (#48): "new" refuses any
name that already exists locally or on a remote, and "existing" picks
from `branches_without_worktree` rather than a typed name.
(`create_worktree_for_branch`, `__new_prompt`.)

### Container mode is never inferred from a Dockerfile on disk

**Fact.** A repo can have an unrelated pre-existing
`.devcontainer/Dockerfile`. **Decision.** Only `container on` opts in.
(Plan decision I.)

### Volumes are cleaned up by name prefix, not by re-reading directives

**Fact.** A volume created under a directive since removed from
`.ruori.conf` must still be deleted by `ruori rm`. **Decision.**
Deterministic names `<session>__vol-<sanitized-path>` (no cache file
needed, unlike ports) and `docker volume ls --filter name=^<session>__vol-`.
