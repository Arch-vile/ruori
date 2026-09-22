# Container-based agent sandboxing for `ruori`

## Context

Today `ruori` runs everything on the host: it opens a tmux session per worktree and sends `claude --resume` into it, then attaches an iTerm2 window to that host tmux session. Running Claude Code with `--dangerously-skip-permissions` ("yolo mode") this way means the agent can touch anything the host user account can touch — no containment.

The goal is to sandbox what a coding agent (not necessarily Claude Code — any CLI agent) can access on the host, while keeping `ruori`'s actual UX (fzf picker, iTerm2 window automation, VS Code) unchanged. Two problems get solved by the same mechanism:

1. **File-access containment** — the agent should only ever be able to read/write the current worktree (+ the shared git dir git worktrees need to function), never sibling worktrees, the home directory, or anything else on the host.
2. **Port collisions across concurrently-open worktrees** — `TODO.md` already flagged this as the #1 daily pain point and had sketched an `.env`-injection-only fix; that's superseded here since containers give a cleaner mechanism (per-worktree published ports) for the same problem.

Decisions made (not up for re-litigation during implementation):
- `ruori` itself, iTerm2 automation, and `code -r` (VS Code) all stay host-side, unchanged. Only the **tmux session and everything run inside it** — whatever agent, the project's dev server, and any ad-hoc terminal commands — moves into **one container per worktree**.
- **`ruori` does not know or care what agent (if any) runs.** The container is entirely the user's own devcontainer setup (their own Dockerfile). By default, `ruori`'s job in container mode is only to start a *bare* tmux session inside the container and attach iTerm2 to it — no command is ever injected. Whatever starts (an agent, a shell, nothing) is fully up to the container image (its own `CMD`/entrypoint, a tmux `default-command`, or the user typing it by hand). This made the feature agent-agnostic by omission rather than by configuration. **Revisited in [issue #45](https://github.com/Arch-vile/ruori/issues/45):** the "no `agent-command`-style directive needed at all" half of this decision is superseded by the opt-in, repeatable `container-command` directive (each value gets its own tmux pane in a freshly created session — see `docs/container-sandbox-guide.md`'s "The eight directives"); the agent-agnosticism itself stands — `ruori` still doesn't know or care *what* a `container-command` runs, and a repo that sets none behaves exactly as before.
- The app's dev server, the agent, and ad-hoc commands all run in that *same* container (rejected: a separate app container, or Docker-in-Docker/socket-mounting so the agent could drive its own containers — socket access is ~root-equivalent and defeats the sandboxing goal).
- Sandbox mounts only: the worktree's own directory + the shared git common dir (git worktrees share one `.git`; the worktree's `.git` file points at an absolute host path inside the common dir, so both must be bind-mounted at matching paths for git to work at all). **Nothing else, ever, by default** — no implicit mounts or copies of any host path, including `~/.claude` or any other config/credential directory. Anything beyond the worktree + git dir is opt-in, one line at a time.
- **Credentials/config are copied in, not bind-mounted.** A user-opted directive triggers a one-time `docker cp` from a host path into the container's own filesystem at creation time only — after that it's a private, writable copy with no live link back to the host. This sidesteps the read-only-vs-write-access tradeoff entirely (a tool refreshing its own token writes to its private copy; the host file is never touched) and fits the fact these containers are throwaway: staleness is resolved by deleting and recreating the container, which naturally re-copies fresh host state. SSH access (agent-forwarded signing) is explicitly out of scope for now — not designed in this pass.
- The project owns its own container image (a per-repo Dockerfile) — `ruori` only orchestrates lifecycle (build/start/stop/copy-in), not image contents or what runs inside.
- **`ruori`'s config files (including whatever holds these new directives) are assumed not git-tracked at all**, for now — a single untracked, per-machine file. This sidesteps any shared-repo-config-vs-personal-machine-config split, since nothing here is ever shared via git.
- Opt-in per repo; zero behavior change for repos that don't opt in.
- **Open assumption to confirm before/at implementation start**: this plan uses plain `docker build`/`run`/`exec`/`inspect`/`cp` from bash, not the `devcontainer.json` spec + `@devcontainers/cli`. Confirmed via research: the standalone `devcontainer` CLI doesn't implement `forwardPorts` at all (that's a VS Code-client-side feature only, and VS Code never attaches to this container by design here); `appPort` is static and described as primarily for VS Code integration. Plain `docker run -p` with `ruori`-managed dynamic allocation is simpler and gets no less than the spec would without VS Code attached.

All anchors below were verified directly against `bin/ruori`.

## Design

### A. New `.ruori.conf` directives

Today `config_directives()` (bin/ruori:225-237) parses generic `<key>\t<value>` lines from `.ruori.conf`, and `copy_patterns()` (bin/ruori:245-262) is the *only* consumer — it also happens to own the "unknown directive" warning (bin/ruori:257-259). Adding new directive families means this warning needs to move to a single shared validator (checked once against the full known-key set: `copy`, `container`, `container-file`, `container-port`, `container-copy`) so each new accessor can match only its own keys without re-warning on the others' directives.

New directives, each read by its own accessor function (siblings of `copy_patterns()`), living in an untracked, per-machine config (see Context):
- `container on` (bare `container` also works) — explicit opt-in gate. This is the *only* opt-in signal (see I) — presence of a Dockerfile on disk is deliberately not treated as opt-in, since a repo could have an unrelated pre-existing `.devcontainer/Dockerfile`.
- `container-file <path>` — Dockerfile path relative to main worktree root, default `.devcontainer/Dockerfile`.
- `container-port <port>[:<name>]` — repeatable, one per port the app exposes (e.g. frontend + backend).
- `container-copy <host-path>[:<container-path>]` — repeatable. Copied into the container's own filesystem via `docker cp`, once, at container-creation time only (never re-copied while the container exists — see B) — not a live mount, fully read-write, no link back to the host afterward. Only minimal `~/`-prefix expansion (substitute `$HOME`) — no `eval`/arbitrary shell expansion of a value that comes from a config file, to avoid a crafted config executing anything at parse time. Nothing is copied unless explicitly listed here — no defaults, ever (not `~/.claude`, not anything else).

No agent-launch directive exists — `ruori` never sends a command into the container's tmux session (see D).

### B. Container naming & lifecycle

- Container name = `session_name_for()`'s existing output (bin/ruori:294-301) — reused verbatim, no new naming scheme. Same identity key already used for the tmux session.
- One **image per repo** (not per worktree) tagged e.g. `ruori/<repo_name>:latest` — the Dockerfile is the same file regardless of which worktree uses it; only mounts/ports differ per container instance.
- New functions, modeled directly on the existing resume-if-exists shape at bin/ruori:1153-1161:
  - `container_running()` — `docker inspect -f '{{.State.Running}}'`, boolean check mirroring `tmux has-session` (bin/ruori:1153).
  - `container_exists()` — distinguishes "stopped, needs `docker start`" from "never created, needs `docker run`" (a container can outlive a host reboot as a stopped object; its tmux sessions do not, since restarting PID 1 loses in-memory state — the existing "does a tmux session exist inside it" check in D already handles this correctly without extra logic).
  - `container_build_if_needed()` — always invokes `docker build` when the image doesn't exist or is asked for; recommend *always* running `docker build` (not hand-rolling a staleness heuristic) and letting Docker's own layer cache keep repeat builds fast — simpler and avoids missing staleness from files a Dockerfile `COPY`s.
  - `container_start_if_needed()` — running → no-op; stopped → `docker start`; absent → build-if-needed, `docker run -d --name "$session_name" <mounts> <ports> <image> sleep infinity` (a durable PID 1; tmux sessions live inside via `docker exec`, not as the container's main process), then — **only in this "container just created" branch** — run `docker cp` for every configured `container-copy` entry. A stopped-then-restarted container is never re-copied into; copy-in happens exactly once per container's lifetime, which is what makes "delete the container to refresh its copied config" a meaningful, predictable action.

### C. Port allocation & persistence

- New state file `$common_dir/ruori-ports` (same convention as the six existing `git rev-parse --git-common-dir`-keyed caches, e.g. `ruori-iterm.log`, `ruori-current-worktree` — not the separate global path `TODO.md` had floated, to avoid a second storage convention). One line per `<session_name>\t<container_port>\t<host_port>`.
- `allocate_port_for(session_name, container_port)` — reuse an existing row if present (idempotent across restarts); otherwise seed the starting candidate from a hash of `session_name:container_port` (not a shared fixed base — see the port-collision risk below for why), scan forward for the first port that's free both in this repo's own cache and actually on the host, append, return it.
- `release_ports_for(session_name)` — strips that session's rows, called from teardown (F).
- Port values are injected as `-e <NAME>=<host_port>` args straight into `docker run` — **never written to any file**. This is deliberately a separate mechanism from `sync_env_files` (bin/ruori:270-288), which only copies static files once and never overwrites — unsuitable for a value that must be fresh every container start. Keep these two clearly separated in the docs (H) so a user doesn't expect a `container-port` value to show up in a synced `.env` file.
- New `ruori ports` subcommand (already anticipated by `TODO.md:47`) prints the state file joined with worktree path/branch.

### D. Main flow changes (bin/ruori:1151–1166)

Branch once on `container_mode_enabled` (computed from config, not per-iteration):
- **Container mode**: `container_start_if_needed` (build/start/no-op + copy-in-if-just-created, per B), then check `docker exec "$session_name" tmux has-session -t "$session_name"`; if absent, `docker exec -d "$session_name" tmux new-session -d -s "$session_name" -c "$selected_path"` — nothing else. No `send-keys`, no injected command: the session opens onto whatever the container image itself starts (its own `CMD`/entrypoint or tmux `default-command`), or a plain shell if it starts nothing in particular. The container-side path can be identical to `$selected_path` as long as the bind mount target equals the host source path exactly — the simplest possible mount scheme, and required for git's `.git` pointer file to resolve inside the container.
- **Host mode (today's behavior)**: completely unchanged, including the existing hardcoded `'claude --resume'` — this plan doesn't touch host-mode behavior at all (that hardcoding is a separate, pre-existing item already tracked in `TODO.md:88-90`, out of scope here).
- `code -r "$selected_path"` (bin/ruori:1165) and everything else stays untouched — host-side per the core requirement.

### E. iTerm2 attach change

Verified anchor: bin/ruori:1034, inside `open_iterm_window_for()`'s heredoc (bin/ruori:1032-1043), the literal line `'$tmux_bin' attach -t '$session'`. In container mode this becomes `docker exec -it '$session' tmux attach -t '$session'` (bare `tmux`, not `$tmux_bin` — the container's tmux is whatever the project's Dockerfile installs, not necessarily at the host's path). Thread a new boolean parameter into `open_iterm_window_for(session, use_container)` so the call site (D) supplies it explicitly, rather than having this function re-derive config itself.

### F. `ruori rm` teardown

In `delete_worktree()` (bin/ruori:718-765), right after the existing `tmux kill-session -t "$session" 2>/dev/null || true`, add (gated on `container_mode_enabled`):
```
docker rm -f "$session" 2>/dev/null || true
release_ports_for "$session"
```
before `git worktree remove` (bin/ruori:743) — same ordering principle as today (kill live processes before removing the worktree). The shared per-repo image is intentionally *not* removed here.

### G. Dependency check

Don't add `docker` to the universal check at bin/ruori:18 (it runs before `main_worktree_path`/config are even known). Add a separate `require_docker_if_container_mode()` check, same error-message style as bin/ruori:18, called once after config parsing and before the manager loop starts — only enforced for repos that opt in.

### H. Docs

New `docs/container-sandbox-guide.md` (mirrors `docs/agent-config-guide.md`'s structure): what container mode does and doesn't sandbox (not `ruori`/VS Code/iTerm2 — those stay host-side; and `ruori` itself never decides what runs in the session — that's entirely the Dockerfile's business), the four directives from A, Dockerfile authoring requirements (needs `git`, `tmux`, the project's own runtime, and whatever the author wants to auto-start — does *not* need Docker itself or any host secrets beyond explicit `container-copy` entries), an explicit statement that nothing is ever copied/mounted by default, an explanation that `container-copy` is a one-time snapshot (not a live link — the container can write to its copy freely, and recreating the container is how you refresh it from host), a worked example (Dockerfile + matching config for a frontend+backend app), and a callout distinguishing `copy` (static, copy-once *worktree* files, host-to-host) from `container-port` (dynamic, injected fresh, never touches disk) from `container-copy` (one-time, host-to-container, writable). Note SSH access is explicitly not addressed by this feature yet. Update README.md's "Config file" and "Requirements" sections to list the new directives and note `docker` is required only for repos using container mode.

### I. Opt-in gating

`container_mode_enabled()` = true iff `.ruori.conf` contains an explicit `container on` (or bare `container`) directive — never inferred from a Dockerfile merely existing on disk. Every new code path (D, E, F, G) gates on this one function; a repo with no config, or a config without this directive, must behave byte-identically to today. This is the acceptance test for the whole feature.

### J. Agent metrics (state + usage) in container mode

`ruori`'s fzf picker has two existing per-worktree metrics columns, both Claude-Code-specific today, that interact with container mode in different ways (neither was addressed by A–I):

- **CLAUDE state column** (`claude_status_for()`, bin/ruori:316-320) reads `.ruori-claude-status`, a file at the **worktree root** written by a Claude Code hook (`bin/ruori-claude-status-hook`) on prompt/tool/permission/stop events. Because the worktree root is one of the two paths already bind-mounted into the container (per D), this mechanism needs **no code change** — the hook can run inside the container and the host sees the same file, unmodified. The only requirement is documentation: whoever authors the container image configures Claude Code's hooks *inside* that image (the same one-time setup `docs/agent-hooks-setup-guide.md` already describes for host mode) — `ruori` itself still never configures anything inside the container, per the plan's core decision.
- **USAGE cost column** (`usage_cost_for()`/`fetch_usage_costs()`, bin/ruori:555-603) works differently and does break: it scans `~/.claude/projects/*/*.jsonl` **on the host**, matching each transcript's `cwd` against worktree paths — zero-config, no hook required. In container mode, Claude Code runs inside the container and writes transcripts to the *container's own* filesystem. Per this plan's Decisions, `~/.claude` is never live-mounted (only one-time `container-copy` snapshots are allowed), so the USAGE column goes stale/blank for any worktree running in container mode.

Fix: extend the pattern that already works — a small file at the worktree root, inherently host/container-transparent via the existing bind mount — to also carry usage data, instead of relying on host-side visibility into a directory containers break:

- New well-known file at the worktree root, `.ruori-agent-usage`, mirroring `.ruori-claude-status`'s two-line convention: `<cost_usd>\n<epoch>\n`.
- `usage_cost_for()` checks this file first (if present and recent); falls back to the existing `~/.claude/projects` host jsonl-scan only when absent — preserving today's zero-config host-mode behavior.
- `bin/ruori-claude-status-hook` gains an additional write on the `Stop` event: compute total cost the same way `fetch_usage_costs()` does today, but scanning `~/.claude/projects/*/*.jsonl` **locally to wherever the hook executes** (host or in-container — always local to the agent, never needing a live mount either way), and write the result to `.ruori-agent-usage`. Same trick as the state file: push a summary through the one channel that's always shared, rather than having `ruori` reach into a filesystem it can't see.
- `.ruori-agent-usage` is documented as the generic, agent-owned extension point — `ruori` reads it without knowing who wrote it, same spirit as `.ruori-claude-status`. Any other agent's own wrapper/hook can populate it the same way; no per-agent code is ever added to `ruori`.
- No change to caching: `ruori-usage-cost.cache` keeps caching whichever value was resolved, same Ctrl-F/Ctrl-R refresh behavior as today — this is a data-source change, not a UX change.

## Open risks (not required to resolve before starting)

- Multi-service apps: repeatable `container-port` handles allocation fine; naming/discoverability across services is an informal `:<name>` convention `ruori` won't validate — likely adequate for 2-3 services, revisit if more is needed.
- Resource usage: one long-lived container per open worktree (`sleep infinity`) is cheap at rest but scales linearly — `TODO.md` mentions having had ~14 worktrees open at once. No idle-eviction is designed now; `ruori rm` is the only teardown trigger. Defer an idle-timeout reaper to a follow-up if this proves heavy in practice.
- If a project's app specifically expects the assigned port via a `.env` file (not an env var), the Dockerfile author would need their own small entrypoint script to write it out — `ruori` only guarantees the env var lands in the container process environment.
- The plain-Docker-vs-devcontainer.json choice (see Context) is the single biggest reversible assumption in this plan — cheap to flag now, expensive to unwind after B/D are implemented against raw `docker` calls.
- `container-copy` removes the read-only/refresh-token tension and the "container corrupts host's real credential file" risk, but does **not** remove exposure risk entirely: a copied token still lets a compromised or rogue process inside the container exfiltrate it over the network, or (if someone `docker commit`/exports the container as an image) bake it into an artifact. Worth a docs warning: use narrowly-scoped, project-specific tokens for anything copied in, and don't publish images built from these containers.
- SSH access is out of scope for this pass (per decision above) — if it's needed later, agent-socket forwarding (a live bind-mount of `$SSH_AUTH_SOCK`, not a copy) is the right pattern, since the point of SSH agent forwarding is that key material never leaves the host at all — it doesn't fit the copy-in model and would need its own narrow exception.
- Non-Claude agents adopting the `.ruori-agent-usage`/`.ruori-claude-status` file convention (J) is opt-in and undocumented for now beyond Claude Code's own hook — no `ruori`-side work is needed to support another agent's metrics beyond honoring the files if present.
- Cross-repo port collision on restart: the ports cache is per-repo (deliberately, per C above), and a container's published host port is only liveness-checked once, at first allocation — `docker start` on an existing container never re-verifies it's still free, since a stopped container's port mapping can't be changed without recreating it. If a different repo's container claims that exact port number while the first one is stopped, restarting the first one later fails with Docker's own "port is already allocated". `allocate_port_for` seeds its scan from a hash of `session_name:container_port` rather than a shared fixed base specifically to keep this rare (different repos land in different parts of the range instead of all racing for the same low numbers first) — this reduces the odds a lot but doesn't eliminate the race, since it's still just a live check at allocation time. Closing it fully would mean re-verifying liveness on every `docker start` and recreating (not just restarting) the container on conflict — which also means `container-copy` re-runs, since it's a creation-time-only step. Not built; the failure mode today is a clear, recoverable Docker error, not silent corruption.
- Shared backing services (a database, cache, queue, etc. a project's app depends on): since the no-Docker-in-Docker decision above means the dev container can't start these itself (e.g. via its own `docker-compose`), the current documented answer (see `docs/container-sandbox-guide.md`) is to run them natively on the host, shared across every worktree's dev container, reachable via `host.docker.internal:<port>`. This gives every worktree the *same* instance with no per-worktree isolation — a real gap, not a deliberate design point. A cleaner follow-up would have `ruori` itself (host-side, never the agent) orchestrate per-worktree sidecar containers via `docker compose`, but that's not built.

## Verification

- Unaffected repos (no `container` directive): run `ruori` end-to-end on an existing worktree and confirm behavior is byte-identical to before (host tmux session, `claude --resume`, iTerm2 attach, `code -r`) — this is the core regression check.
- Opted-in repo: add a minimal `.devcontainer/Dockerfile` (git, tmux, a small default command e.g. a shell) + config with `container on`, one `container-port`, and a harmless `container-copy` entry (e.g. a throwaway test file); run `ruori`, confirm: image builds, container starts, `docker exec` creates a bare tmux session, iTerm2 attaches via `docker exec ... tmux attach` and drops you into whatever the image starts, the mounted worktree + git common dir let `git status` work inside the container, the copied-in file is present and independently writable without affecting the host original, the published port is reachable from the host browser, and `ruori rm` removes the container and frees the port (`ruori ports` reflects it).
- Concurrency check: open two worktrees of the same repo in container mode simultaneously, confirm they get distinct host ports and independent containers.
