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

The prefix is C-b, and after it, as tmux binds its keys:

    %     split the active pane left and right
    "     split it top and bottom
    o     the next pane
    arrows    the pane that way
    C-arrows  move the active pane's border a cell that way
    M-arrows  5 cells
    z     zoom the active pane to fill the window, or put it back
    ;     the pane active before
    q     show the panes' numbers; a digit then picks that pane
    {     swap the active pane with the one before it
    }     swap it with the one after it
    C-o   rotate the panes forward through their places
    M-o   rotate them backward
    M-1   even-horizontal layout: the panes side by side
    M-2   even-vertical: one above another
    M-3   main-horizontal: the first pane above the others
    M-4   main-vertical: the first pane left of the others
    M-5   tiled: a grid
    M-6   main-horizontal-mirrored: the first pane below the others
    M-7   main-vertical-mirrored: the first pane right of the others
    Space the next of those layouts
    x     kill the active pane, asked first
    c     a new window
    n     the next window
    p     the previous window
    l     the window last shown
    0-9   the window of that number
    &     kill the window, asked first
    ,     rename the window
    :     the command prompt
    d     detach
    [     copy mode
    PgUp  copy mode, a page up; a page down to the bottom leaves it
    ]     paste the newest buffer
    C-b   a C-b to the pane

A new window takes the lowest free number and starts its shell where the
session was made.  The status line marks the shown window `*`, underlined,
and the one shown before it `-`; closing the shown window shows that one.
The status line's parts and styles are options, below.
A question on the status line takes `y` for yes and any other key for no.
A window is named after its active pane's foreground program, `[tmux]`
while that pane is in copy mode, looked at as its panes write and at most
every half second, as tmux's automatic-rename names it; the name is the
kernel's for the process.  C-b `,` asks for a name on the status line,
the old one there to edit with emacs's keys, Enter taking it and Escape
leaving it; a renamed window keeps its name.
C-b `:` reads a line of tmux's commands, by their names, their aliases
or a prefix of only one name, with their flags and arguments as tmux
reads them; `;` splits the line and quotes and `\` work as in tmux.  A
line that does not read runs none of it, and a command that fails stops
the ones after it, tmux's message on the status line.  Up and Down go
through the last 100 lines, and Tab completes a command's name, a second
Tab showing the names it could be.  The commands are those of the keys
above: split-window, new-window, kill-pane, kill-window, kill-session,
select-pane, last-pane, select-window, next-window, previous-window,
last-window, rename-window, resize-pane, swap-pane, rotate-window,
select-layout, next-layout, previous-layout, display-panes, copy-mode,
paste-buffer, send-prefix and detach-client, those of the shell below,
with command-prompt,
confirm-before, display-message and those of the configuration below.
`display-message [-lp] [-d MS] [-F FORMAT] [FORMAT]` shows a format on
the status line for display-time, or MS, or until a key for 0; `-p`
shows it over the pane, `-l` as it is, and with no format tmux's
`[#{session_name}] #{window_index}:...` line.
An arrow picks, of the panes across the border that way, the one most
recently active, wrapping at the window's edges.  A resize moves the
border beside the pane, taking cells from the panes beyond it, each
keeping one, as tmux's resize-pane does; for half a second after a
key bound with -r, as the arrows are, another such key runs without the
prefix, tmux's repeat-time.  A zoomed window is marked `Z` on the status line;
splitting, killing, resizing, picking, moving or laying out panes puts
its pane back first.
A pane's number is its place in the window's pane order, which a split,
a swap or a rotation changes and a layout does not; swapping and
rotating move the panes through the places, each place keeping its
size.  The preset layouts are tmux's, sized as tmux sizes them, the main
pane 80 cells wide or 24 rows high; Space goes on from the layout last
given.  C-b `q` shows each pane's number for a second, in tmux's clock
digits where the pane has room, red for the active pane and blue for the
others, with its size at its top right; a digit picks that pane, the
prefix goes on as the prefix, and any other key puts the numbers away.
A pane whose shell exits is removed and its space given to the pane
after it, or before it when it was the last, and the pane active before
it is active again; every window's layout follows the terminal's size,
the change spread over its panes as tmux spreads it.  A window ends with
its last pane, a session with its last window, and the server with its
last session.

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

With vi's keys the cursor stays on a row's characters, its end the last of
them.  A selection runs from where it began to the cursor, drawn black on
yellow, and copying it leaves the mode:

    emacs C-Space, vi Space    begin a selection
    emacs C-g, vi Escape       clear it
    vi V                       select whole rows
    vi o                       the cursor to the selection's other end
    emacs M-w C-w, vi Enter    copy it
    vi A                       copy it to the end of the newest buffer
    emacs C-k, vi D            copy from the cursor to the row's end

As tmux copies: with emacs's keys a selection stops short of the cell its
later end is on, and with vi's takes it; a row's trailing blanks are left
out, and a row's end, a newline, is taken where the selection runs past
its last character.  What is copied is kept as the newest of the server's
paste buffers, 50 at most, and C-b `]` types the newest to the active
pane, each newline a carriage return.  Keys and pastes a pane's program
does not take at once wait for it, in order.

Not yet: rectangles, a row the terminal wrapped copied as one line,
bracketed paste, the buffer commands (`#`, `=`, `-`), searching, and the
time a row entered the history, which tmux shows beside the position.

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
CUF, CUB, CHA, VPA; EL, ED, ECH; ICH, DCH; IL, DL; SU (each row kept in
the history, as a line feed keeps it) and SD; DECSTBM, IND, RI, NEL;
DECSC, DECRC; the alternate screen, ?1049 (with the cursor saved and
restored), ?47 and ?1047, as tmux keeps it; OSC strings and charset
designations, swallowed.  UTF-8: a character takes the cells its width
gives, wide ones two and combining marks none, by a table that agrees
with tmux 3.8; a byte no character starts with, or a character cut
short, is U+FFFD.

SGR: bold, dim, italics, underscore (4:0 to 4:5 too, any but 4:0 an
underscore), blink, reverse, hidden and strikethrough, each with its
reset; a foreground and a background of the 8 colours, the 8 bright
ones (90-97, 100-107), the 256 (38;5;N) and RGB (38;2;R;G;B), with
semicolons or colons; an underscore's colour (58) passed over.  A
sequence with a private marker (`CSI > 4;1 m`) is not an SGR.  A cell's
attribute byte numbers its style in the screen's table of 255, which a
render writes as each style's SGR; a table that fills gives up the
styles no cell uses.

The modes a program sets: ?25l hides the terminal's cursor while its
pane is the active one; ?1h has the arrows, Home and End sent to it as
ESC O X, whichever the terminal sends; ?2004h brackets C-b `]`'s paste between
ESC [ 200 ~ and ESC [ 201 ~, as `paste-buffer -p` does.  The mouse's
modes (?1000, ?1002, ?1003, ?1006) are kept, but no mouse report is
sent yet.  The compiled engine hands each byte past ASCII to the
reference, so text past ASCII reads at the reference's speed, and each
ED, SGR, SU, SD, mode set and reset, and colon between parameters.

## Configuration

As the server starts it reads tmux's files of commands, as tmux reads
them: `-f FILE`'s, else those of `/etc/tmux.conf`, `~/.tmux.conf`,
`$XDG_CONFIG_HOME/tmux/tmux.conf` and `~/.config/tmux/tmux.conf` that
are there.  A file holds a command a line, `;` splitting a line, `#`
starting a comment, `\` at a line's end joining the next, and `{ }`
holding commands over lines.  A file that does not read runs none of
it; otherwise each command runs and each that fails is reported, as
`FILE:LINE: MESSAGE` over the first session's first pane.  A tmux
command x-tmux does not have reads, and says `command NAME: not in
x-tmux` when it runs.

    bind-key, bind [-nr] [-T TABLE] KEY COMMAND...
    unbind-key, unbind [-an] [-T TABLE] [KEY]
    set-option, set [-gqsuw] OPTION [VALUE]
    source-file, source [-q] FILE...

A key is named as tmux names it (`C-a`, `M-Left`, `^x`, `PPage`, `F5`);
`-n` binds it without the prefix, `-r` lets it repeat, and the keys
above are tmux's own bindings, which bind and unbind change.  The
options, with tmux's defaults:

    prefix              C-b
    display-time        750, milliseconds a message shows; 0 until a key
    display-panes-time  1000, milliseconds C-b q's numbers show
    repeat-time         500, milliseconds a -r key repeats
    history-limit       2000, rows a new pane keeps
    mode-keys           emacs, or vi when VISUAL or EDITOR is vi's
    message-style       bg=yellow,fg=black
    status              on, or off: the panes have every row; set
                        status without a value turns it over
    status-interval     15, seconds between the status line's drawings
    status-justify      left, centre, right or absolute-centre
    status-left         [#{session_name}]
    status-left-length  10
    status-left-style   default
    status-right        tmux's: the pane's title in quotes and the time
    status-right-length 40
    status-right-style  default
    status-style        bg=green,fg=black
    window-status-format          #I:#W#{?window_flags,#{window_flags}, }
    window-status-current-format  the same
    window-status-style           default
    window-status-current-style   underscore
    window-status-last-style      default
    window-status-separator       a space

The status line is tmux's: status-left, then the windows, each in its
format and style, the shown one in window-status-current-*, the
separator between them, then status-right at the right end, each side
cut to its length.  When the windows do not fit they are cut about the
shown one, `<` and `>` where they are cut.  A style is tmux's: `fg=` and
`bg=` a colour's name, `bright` name, `colourN` or `#RRGGBB`, or
`default`; the attributes bold, dim, italics, underscore, blink, reverse,
hidden and strikethrough, `no` before one taking it away; `none` and
`default`.  A style option lies over status-style, and `#[STYLE]` in a
format over the style of its part.

A format is tmux's: `#{NAME}`; `#{?COND,A,B}`; `#{==:A,B}`, `!=`, `<`,
`>`, `<=`, `>=`, `||` and `&&`; `#{=N:X}` and `#{=-N:X}` cut to N
characters; `#{l:X}`, `#{b:X}` and `#{d:X}`; the letters `#H #h #D #P
#T #S #I #W #F`; `##`, `#,` and `#}`.  `#(COMMAND)` is empty.  The
names: session_name, session_windows, session_attached,
session_created; window_index, window_name, window_flags,
window_active, window_last_flag, window_zoomed_flag, window_panes,
window_width, window_height; pane_id, pane_index, pane_title (the host,
as tmux gives it), pane_current_command, pane_pid, pane_width,
pane_height, pane_active, pane_in_mode; client_width, client_height,
client_prefix; host, host_short, pid; and an option by its name.
status-left, status-right and display-message write strftime's `%H %M
%S %d %e %m %y %Y %b %h %B %a %A %I %p %R %T %D %F %j` and `%%` first.

source-file from the prompt shows a file that does not read in the same
view, and a failing command's message on the status line.

## Commands

    new-session, new [-d] [-s NAME]      a session made and shown here,
                                         or with -d only made
    attach-session, attach, a [-t NAME]  a session shown here: NAME, or
                                         the newest not shown elsewhere
    list-sessions, ls                    the sessions, as tmux lists them
    kill-server                          every session ended, and the server
    any other command x-tmux runs        sent to the server and run there

Any other command is the prompt's, read from the shell's words as tmux
reads them, `;` a word of its own between commands, and run in the
session tmux would run it in: the one holding the pane `$TMUX` and
`$TMUX_PANE` name, which x-tmux sets in each pane, else the one used
last.  What it prints goes to standard output, its message to standard
error, and the status is tmux's.  With no server, `no server running on
PATH`.  Those that serve scripts:

    has-session, has [-t SESSION]         status 0 when it is there
    rename-session, rename [-t SESSION] NAME
    kill-session [-t SESSION]
    display-message, display -p [-t PANE] [FORMAT]
    list-windows, lsw [-a] [-F FORMAT] [-f FILTER] [-t SESSION]
    list-panes, lsp [-as] [-F FORMAT] [-f FILTER] [-t TARGET]
    send-keys, send [-Hl] [-N COUNT] [-t PANE] KEY ...
    show-options, show [-gqsvw] [NAME]
    split-window [-hv] [-t PANE], new-window [-d] [-n NAME] [-t SESSION:INDEX],
    select-layout [-np] [-t PANE] [LAYOUT], rename-window [-t WINDOW] NAME

A target is tmux's: `SESSION:WINDOW.PANE`, each part left out for the
current one; `%N` a pane by its id; a session by its name or the
start of only one, `=` asking for the whole name; a window by its number
or name; a pane by its number, `+` or `-`; a bare word a pane, else a
window, else a session.  list-windows and list-panes print tmux's lines,
the layout as tmux 3.8's JSON; send-keys sends a key's bytes as tmux
does, xterm's modifiers on the cursor and function keys; show-options
quotes a value as tmux does.
x-tmux gives a session made with -d and no client a status line, so its
panes have 23 rows where tmux's have 24; list-panes has no
`history_bytes`; send-keys to a pane in copy mode goes to its program;
a command run from inside a pane is not refused as nesting.

Each may be led by `-L NAME` or `-S PATH` for the server's socket,
`$TMUX_TMPDIR/x-tmux-UID/NAME` (`/tmp` when `TMUX_TMPDIR` is not set,
`default` with no `-L`), and `-f FILE` for the file a server it starts
reads; with no command after them, new-session.  The engine's own
commands:

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
sequences; `03-layout` holds the layout to the pane sizes tmux 3.8
reports for the same splits, kills, resizes, swaps, rotations, preset
layouts and window sizes, and the pane an arrow picks to tmux's;
`04-copy` holds copy mode's moves to the
positions and cursors tmux 3.8 reports for the same keys; `05-command`
holds the command line's words, names and flags to how tmux 3.8 reads
them, and its messages to tmux's; `06-keys` holds the keys typed and
the names bind reads to tmux 3.8's, the bytes send-keys sends to
tmux's, and a file of commands and a shell's words to how tmux 3.8
reads them; `07-format` holds formats to what tmux
3.8's display-message -p gives for them.

    X=/path/to/x sh tests/oracle/panes.sh

runs x-tmux inside a real tmux pane, drives it with send-keys and reads
it with capture-pane: typing, both splits, the next pane, a kill, a shell
exiting, zoom, arrows, moved borders, the last pane, swaps, rotations,
layouts, a resize, each pane's size checked by `stty size`; the panes'
numbers; copy mode;
windows made, shown, refused, asked about, killed and closed; then
detaching, `ls`, attaching again, window names and renaming, the command
prompt, the status line's options and display-message, the last
pane exiting and
`kill-server`, with tmux's messages; then a configuration's prefix,
bindings and errors, and source-file; then commands from a shell, run
against x-tmux and against tmux on a socket of its own, their output,
messages, status and send-keys' bytes the same.

## Install

    make install    copies the bundle to <share>/langs/tmux and writes
                    its boot image

## Licence

MIT No Attribution: see LICENSE.
