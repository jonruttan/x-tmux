# x-tmux

A terminal multiplexer on x-lang, after tmux, as a lang bundle.

    x -l tmux -- [COMMAND [ARGS]]

`new-session` (or `new`) makes a session and shows it on the terminal it
runs in: numbered windows of panes, each a shell on a pseudo-terminal,
laid out and bordered as tmux lays out its panes, with tmux's status
line listing the windows.  A
server keeps the sessions, as tmux's does; a client shows one, and
detaching leaves it running.  Each pane keeps a screen: the
bytes its program writes, read as a terminal reads them, into a grid of
cells and attributes, and the rows that changed rendered back out at the
pane's place.  tmux is what it is tested against.

## Panes and windows

The prefix is C-b, and after it:

    %     split the active pane left and right
    "     split it top and bottom
    o     the next pane
    x     kill the active pane, asked first
    c     a new window
    n     the next window
    p     the previous window
    l     the window last shown
    0-9   the window of that number
    &     kill the window, asked first
    ,     rename the window
    d     detach
    [     copy mode
    PgUp  copy mode, a page up; a page down to the bottom leaves it
    C-b   a C-b to the pane

A new window takes the lowest free number and starts its shell where the
session was made.  The status line marks the shown window `*`, underlined,
and the one shown before it `-`; closing the shown window shows that one.
A question on the status line takes `y` for yes and any other key for no.
A window is named after its active pane's foreground program, `[tmux]`
while that pane is in copy mode, looked at as its panes write and at most
every half second, as tmux's automatic-rename names it; the name is the
kernel's for the process.  C-b `,` asks for a name on the status line,
the old one there to edit with emacs's keys, Enter taking it and Escape
leaving it; a renamed window keeps its name.
A pane whose shell exits is removed and its space given to its sibling;
every window follows the terminal's size.  A window ends with its last
pane, a session with its last window, and the server with its last
session.

## Copy mode

Each pane keeps the 2000 rows that scroll off its top, as tmux keeps its
history.  Copy mode shows the pane as it was when the mode began, history
and all, with tmux's position at its top right, and moves through it as
tmux's does, with tmux's keys: emacs's, or vi's when `VISUAL` or `EDITOR`
names vi.

    Up Down          the cursor a row, scrolling at the top and bottom
                     (emacs C-p C-n, vi k j)
    Left Right       a column (emacs C-f, vi h l)
    PgUp PgDn        a page, two rows short of the pane (emacs M-v C-v;
                     vi C-f, a page down)
    vi C-u C-d       half a page
    Home End         the row's start and end (emacs C-a C-e, vi 0 $)
    emacs M-< M->    the top of the history and the bottom (vi g G)
    q                leave (emacs Escape and C-c too)

Not yet: selecting and copying, searching, and the time a row entered the
history, which tmux shows beside the position.

## The screen

`tmux/vt` is the engine in x, the reference.  `tmux/vt-jit` compiles the
same engine with x-lang's assembler lane, proves it against the
reference on a random exercise of every sequence the screen reads, and
adopts it; where there is no JIT, or the two disagree, the reference
stays.  Compiled, a full 24x80 coloured repaint is read and rendered in
about 0.16 ms, against about 45 ms for the reference.  The rows are
reached through a row map, as tmux keeps its lines: a scroll turns the
region's part of the map and blanks the rows it frees, so a line
scrolled off a 24x80 screen costs about 1 µs compiled.  A line feed at the
bottom of a region on the main screen copies the region's top row to the
history first, and an erase of the whole screen copies the rows in use,
as tmux's scroll-on-clear does; ED 3 empties the history.

Read: printable bytes (wrapping at the margin, tmux's cursor running to
column 80 before a wrap), CR, LF, VT, FF, BS, TAB; CUP, HVP, CUU, CUD,
CUF, CUB, CHA, VPA; EL, ED, ECH; ICH, DCH; IL, DL; DECSTBM, IND, RI,
NEL; DECSC, DECRC; SGR bold, reverse, foreground and background; the
alternate screen, ?1049 (with the cursor saved and restored), ?47 and
?1047, as tmux keeps it; OSC strings and charset designations,
swallowed.  UTF-8: a character takes the cells its width gives, wide
ones two and combining marks none, by a table that agrees with tmux 3.8;
a byte no character starts with, or a character cut short, is U+FFFD.
The compiled engine hands each byte past ASCII to the reference, so text
past ASCII reads at the reference's speed, and each ED.  Not yet: SU and
SD, mouse and bracketed-paste modes.

## Commands

    new-session, new [-d] [-s NAME]      a session made and shown here,
                                         or with -d only made
    attach-session, attach, a [-t NAME]  a session shown here: NAME, or
                                         the newest not shown elsewhere
    list-sessions, ls                    the sessions, as tmux lists them
    kill-server                          every session ended, and the server

Each may be led by `-L NAME` or `-S PATH` for the server's socket,
`$TMUX_TMPDIR/x-tmux-UID/NAME` (`/tmp` when `TMUX_TMPDIR` is not set,
`default` with no `-L`).  The engine's own commands:

    vt check FILE         FILE fed to a screen by each engine, compared
                          after every 4096-byte read
    vt bench FILE         FILE fed and rendered by each engine, timed
    vt dump FILE          FILE fed to a 24x80 screen: its rows and cursor
    vt exercise SEED N    N random operations, as bytes

## Tests

    make test     the suite
    make check    the suite against tests/contract/known-failures.txt

`tests/specs/01-screen` pins the reference against what tmux 3.8 shows
for the same bytes; `02-compiled` holds the compiled engine to the
reference, read by read, on exercises fed in reads that end inside
sequences; `03-layout` holds the split tree to the pane sizes tmux 3.8
reports for the same splits; `04-copy` holds copy mode's moves to the
positions and cursors tmux 3.8 reports for the same keys.

    X=/path/to/x sh tests/oracle/panes.sh

runs x-tmux inside a real tmux pane, drives it with send-keys and reads
it with capture-pane: typing, both splits, the next pane, a kill, a shell
exiting, a resize, each pane's size checked by `stty size`; copy mode;
windows made, shown, refused, asked about, killed and closed; then
detaching, `ls`, attaching again, window names and renaming, the last
pane exiting and
`kill-server`, with tmux's messages.

## Install

    make install    copies the bundle to <share>/langs/tmux and writes
                    its boot image

## Licence

MIT No Attribution: see LICENSE.
