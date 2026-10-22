# x-tmux

A terminal multiplexer on x-lang, after tmux, as a lang bundle.

    x -l tmux -- [COMMAND [ARGS]]

`new-session` (or `new`) opens a window of panes on the terminal it runs
in, each a shell on a pseudo-terminal, laid out and bordered as tmux lays
out its panes, with tmux's status line.  Each pane keeps a screen: the
bytes its program writes, read as a terminal reads them, into a grid of
cells and attributes, and the rows that changed rendered back out at the
pane's place.  tmux is what it is tested against.

## Panes

The prefix is C-b, and after it:

    %     split the active pane left and right
    "     split it top and bottom
    o     the next pane
    x     kill the active pane
    d     leave, ending the panes
    C-b   a C-b to the pane

A pane whose shell exits is removed and its space given to its sibling;
the window follows the terminal's size.  There is no server yet, so
leaving ends the panes rather than detaching from them; and no
alternate-screen save, so a full-screen program's last screen stays when
it exits.

## The screen

`tmux/vt` is the engine in x, the reference.  `tmux/vt-jit` compiles the
same engine with x-lang's assembler lane, proves it against the
reference on a random exercise of every sequence the screen reads, and
adopts it; where there is no JIT, or the two disagree, the reference
stays.  Compiled, a full 24x80 coloured repaint is read and rendered in
about 0.16 ms, against about 45 ms for the reference.

Read: printable bytes (wrapping at the margin, tmux's cursor running to
column 80 before a wrap), CR, LF, VT, FF, BS, TAB; CUP, HVP, CUU, CUD,
CUF, CUB, CHA, VPA; EL, ED, ECH; ICH, DCH; IL, DL; DECSTBM, IND, RI,
NEL; DECSC, DECRC; SGR bold, reverse, foreground and background; the
alternate screen's clear; OSC strings and charset designations,
swallowed.  Not yet: UTF-8 widths (a byte is a cell), scrollback, mouse
and bracketed-paste modes.

## Commands

    new-session, new      a window of panes on this terminal
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
reports for the same splits.

    X=/path/to/x sh tests/oracle/panes.sh

runs x-tmux inside a real tmux pane, drives it with send-keys and reads
it with capture-pane: typing, both splits, the next pane, a kill, a shell
exiting, a resize and leaving, each pane's size checked by `stty size`.

## Install

    make install    copies the bundle to <share>/langs/tmux and writes
                    its boot image

## Licence

MIT No Attribution: see LICENSE.
