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
