# Troubleshooting

## Leftover iTerm2 windows

iTerm2's AppleScript interface can be flaky about *when* it actually
opens or closes a window relative to when it tells `osascript` it's
done — a `create window` call can report a timeout while iTerm2 goes
ahead and creates the window moments later anyway, and a `close` call
can report success (exit 0) while the window visibly lingers for a beat
before it actually disappears. Either one, if it happens at the wrong
moment, can look like "the previous worktree's window didn't close."

`ruori` logs every step of this — which window id it thinks is active,
every close it attempts (with the exit code and whether the window was
still open immediately afterward), and every window it opens (with the
raw AppleScript response) — to `<git-common-dir>/ruori/iterm.log`, e.g.
run `git rev-parse --git-common-dir` from any worktree of the repo to
find it, or just watch for the "logging iTerm2 window open/close
activity to ..." line `ruori` prints on startup. It's appended to, not
rotated or cleared automatically, so delete it yourself if it grows
large. If you hit a leftover window again, that log is the place to
look — it'll show whether `ruori` thought it closed the window (and
iTerm2 just hadn't caught up yet) or never learned that window's id in
the first place.

The id of the window `ruori` is currently tracking is also persisted, to
`<git-common-dir>/ruori/iterm-window`, so that **restarting `ruori`
doesn't orphan the window it had open**. Before this, that id lived
only in the running manager process: restarting `ruori` (to pick up an
update, say) made the fresh process forget which window belonged to
it, so the next switch skipped the close entirely and you ended up with
two worktree windows on screen. The file records iTerm2's pid next to
the id, and the id is only adopted on startup if iTerm2 hasn't
restarted in the meantime and the window is still open — iTerm2
numbers windows from a counter that resets with the app, so an id from
a previous run can name an unrelated window, and `ruori` would rather
leave a stray window for you to close than close the wrong one. Both
non-adoptions are logged.

## File I/O log

Every read/write `ruori`'s own script code performs against a file —
`.ruori.conf`, its state/cache files under `ruori/`, a worktree
copy-in, a generated file like the `ruori init` skill — is logged,
append-only, to `<git-common-dir>/ruori/file-io.log`, one
`<timestamp> READ|WRITE <path>` line per operation. This exists for
the same reason as `iterm.log` above: if a `copy` pattern didn't pick
up a file, or a cache looks stale, or you just want to know what
`ruori` actually touched on a given run, this log is the record —
rather than having to infer it from source. Like `iterm.log`, it's
never rotated or cleared automatically; delete it yourself if it grows
large (a `ruori list`/`details`/Ctrl-F usage-cost fetch that scans your
whole `~/.claude/projects` history logs one `READ` line per session
transcript file it opens, which can add up on a heavy user's machine).

Scope: only file I/O `ruori`'s own script code performs directly (a
`cat`/redirect/`cp`/`mv` it runs). File access performed *inside* a
child process it shells out to — `git`, `docker`, `code`, `fzf`,
`osascript` — isn't observable from bash without OS-level tracing
(`strace`/`dtrace`), so none of that is in this log; e.g. `git worktree
list --porcelain`'s own reads of `.git` internals never appear here,
only `ruori`'s own reads/writes of files like `.ruori.conf` or the
`ruori/` state files do.

## Stale or failed `container-overlay`

If a container's view of a `container-overlay`-managed file looks
wrong or out of date, check two things, in order:

1. **The warning `ruori` prints at switch time.** A patch that no
   longer applies cleanly against the current host file prints `ruori:
   warning: container-overlay for <relpath> failed to generate; ...` —
   this means the container is either seeing the unmodified host file
   (first-ever generation) or whatever the last successfully-generated
   overlay was (a later `ruori rebuild` that hit a broken patch); it
   never silently applies a half-merged result.
2. **`<git-common-dir>/ruori/overlay.log`.** Append-only, same
   convention as `iterm.log`/`file-io.log` above: one line per
   patch-apply failure, naming the worktree, the relpath, and — when
   `patch` left one — a `.rej` file sitting next to the generated file
   under `<git-common-dir>/ruori/overlays/` (never inside the worktree
   itself, so a broken patch never pollutes `git status`). Open the
   `.rej` file to see exactly which hunk didn't match.

Remember that `container-overlay` content is only ever generated once,
at container creation or `ruori rebuild` — editing the host file or the
patch file has no effect on an already-running container by design; see
[container-sandbox-guide.md](container-sandbox-guide.md)'s
"`container-overlay` applies a patch at container creation, not a live
link". If the *set* of `container-overlay` directives changed (one
added or removed) rather than their content, `ruori` prints
`container-overlay targets changed (+…); run 'ruori rebuild <branch>'
to apply` on the next switch instead — that's a different, unrelated
message from the patch-failure warning above.
