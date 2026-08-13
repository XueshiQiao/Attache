This directory is what the app hands libghostty as GHOSTTY_RESOURCES_DIR, and
it is nearly empty on purpose.

libghostty asks that variable two questions. The one this app needs answered is
"where is the terminfo database", and it answers it by string arithmetic —
<resources>/../terminfo — without ever looking at this directory. Measured
2026-08-09: pointing the variable at a directory that does not exist at all
still produced a working pane, as long as the sibling terminfo was there. So
this directory exists for people, not for the library: it is the thing you find
when you go looking for why the variable points here.

The other question is where the shell-integration scripts are, and this app has
no answer to it. Its surfaces run `tmux attach` and the git tool's program
directly — there is no shell in them for anything to be injected into.

What actually matters is ../terminfo, which is ours: see
Resources/xterm-ghostty.terminfo for where it came from and how to refresh it.
Before this existed the variable was inherited from whatever shell launched the
app and pointed into Ghostty.app, so moving that unrelated application left
every pane blank. GitHub issue #12.
