# Linux test compatibility headers

Test scaffolding only — none of this is compiled into the tweak.

The Learning Filter sources build and run under GNUstep when it is linked
against libobjc2 (see the note at the top of `run.sh`). One thing is still
missing on that platform: libdispatch.

The code under test uses exactly two dispatch APIs — `dispatch_once` for
singletons and cached regular expressions, and `dispatch_async` onto the main
queue to post one notification. Both are replaced here with synchronous
equivalents, which is what a single-threaded test wants anyway: the notification
is delivered before the call returns, so a test can assert on it.

On macOS `run.sh` ignores this directory and links Foundation directly.
