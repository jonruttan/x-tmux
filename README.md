# x-tmux

A terminal multiplexer on x-lang, after tmux, as a lang bundle.

    x -l tmux -- [COMMAND [ARGS]]

Sessions and panes are still to come.  What is here is the screen every
pane will keep: the bytes a program writes, read as a terminal reads
them, into a grid of cells and attributes, and the rows that changed
rendered back out as a terminal redraws them.  tmux is what it is
tested against.

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
sequences.

## Install

    make install    copies the bundle to <share>/langs/tmux and writes
                    its boot image

## Licence

MIT No Attribution: see LICENSE.
