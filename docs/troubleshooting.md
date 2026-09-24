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

## A `worktree-overlay` didn't get applied

`ruori` prints `ruori: warning: worktree-overlay for <relpath> not
applied -- see <log file>` on a switch when the patch neither applies
cleanly nor is already applied to that worktree's file — usually
because the patched lines were edited in that worktree, or the file
changed underneath a now-stale patch. The file is left untouched
(never half-patched). Check
`<git-common-dir>/ruori/overlay.log`: one line per failure, with the
worktree, relpath, and a `.rej` file under
`<git-common-dir>/ruori/overlays/` (never inside the worktree) showing
which hunk didn't match. Fix the file or regenerate the patch; the
next switch retries.

### `Device or resource busy` from git inside a container

`error: unable to unlink old '<file>': Device or resource busy` means
git tried to rewrite a path that's a bind mount inside the container —
left over from the old `container-overlay` directive (since replaced by
`worktree-overlay`, which patches the worktree's file instead of
mounting over it). Run that git command on the host instead (the host
file is a normal file), then `ruori rebuild <branch>` to get a
container without the mount.

If the failing command was a rebase with autostash, git may have
finished the rebase but died re-applying the autostash, leaving
`$(git rev-parse --git-dir)/rebase-merge/` behind with only an
`autostash` file in it; a later `git rebase --continue` then warns
that `head-name` can't be read. That file holds the only reference to
your uncommitted changes, so save it before cleaning up, on the host:

```sh
W="$(git rev-parse --git-dir)"
git stash store -m "rescued rebase autostash" "$(cat "$W/rebase-merge/autostash")"
rm -r "$W/rebase-merge"
git stash apply
```

The stash may include the overlay's patched content for the tracked
file; `git checkout -- <file>` on the host discards it.
