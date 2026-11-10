#!/bin/sh
# tests/oracle/panes.sh -- x-tmux's session, run inside a real tmux pane.
#
# Usage: X=/path/to/x sh tests/oracle/panes.sh
#
# tmux is the terminal here: x-tmux runs in a detached tmux session of
# 80x24, keys are sent to it with send-keys, and what it draws is read
# back with capture-pane.  Each pane's shell is /bin/sh.
#
#   type      a command typed in the first pane, and its output
#   alt       a program on the alternate screen, its screen gone when it
#             leaves, the shell's lines back
#   utf8      wide and combining characters, each in its cells
#   styles    256 colours, RGB, italics and underscore drawn as tmux draws
#             them; a program's ?25l hiding the cursor, ?25h showing it
#   split -h  C-b %: a second pane right of the first, the border between,
#             each pane's terminal its own size (stty size)
#   split -v  C-b ": a third pane below the second
#   next      C-b o from the last pane comes back to the first
#   kill      C-b x, asked and answered y: the active pane gone, its
#             sibling given its space
#   exit      a pane's shell exiting removes the pane
#   zoom      C-b z: the active pane over the whole window, Z on the
#             status line, and back
#   arrows    C-b Left and Right: the pane that way, a zoomed pane put
#             back first
#   borders   C-b C-arrows and M-arrows: the border moved 1 and 5 cells,
#             an arrow repeating without the prefix
#   last      C-b ;: the pane active before, and back
#   swap      C-b { and }: the pane swapped with the one before and after,
#             taking its cell's size
#   rotate    C-b C-o and M-o: the panes moved on and back through the
#             cells, the pane moved into the active cell active
#   layouts   C-b M-2, M-1, Space: even-vertical, even-horizontal, and
#             the one after the last given
#   numbers   C-b q: each pane's size at its top right, its number red or
#             blue; a digit picking that pane, another key not typed, and
#             gone after a second
#   resize    the window grown to 100x30: the pane's terminal follows
#   copy      C-b [ and C-b PgUp: the history paged through, the position
#             at the top right, q and a page down to the bottom leaving
#   paste     two rows selected with emacs's keys and drawn black on
#             yellow, M-w copying them, C-b ] typing them to a cat
#   windows   C-b c, 1, l, n, p: windows made and shown, the status line
#             listing them with tmux's flags; a missing number refused for
#             a moment; C-b & asked, a no keeping the window and a yes
#             killing it; a window's last pane exiting closing it
#   detach    C-b d: the client leaves with status 0 and tmux's line, the
#             session kept by the server
#   ls        the session listed as tmux lists one
#   attach    the session back, as it was left; a session that is not
#             there refused as tmux refuses it
#   names     a window named after its foreground program, [tmux] in copy
#             mode, the shell's name back; C-b , edited and Escaped, then
#             taken, the name kept
#   prompt    C-b :: a command run, an unknown one refused, the history,
#             Tab completing and offering names, commands split by ; run
#             in order, a pane not there stopping the rest
#   status    status-left and status-right's formats at each end, the
#             windows' format justified right, status-style's colours,
#             display-message on the status line and -p in view mode,
#             status off giving the pane every row and set status back
#   exited    the last pane's shell exiting ends the session, the client
#             and the server
#   kill      kill-server ends a session made with new -d, and the server
#   config    -f FILE read as the server starts, a session made with no
#             command after it: its prefix, bind and bind
#             -n, a block over lines; source-file from the prompt, a file
#             not there refused, one that does not read shown and not run;
#             each line's error at start shown over the first pane
#   shell     commands from a shell, run against x-tmux and against tmux
#             on a socket of its own, their output and status the same:
#             has-session, display -p, targets, split-window, new-window
#             and select-layout -t, list-windows and list-panes in their
#             forms, show-options, rename-session, send-keys' bytes,
#             kill-session, and the errors of each
#
# x-tmux runs from a shell in the tmux pane, on a socket of its own, -f
# /dev/null keeping the tester's own tmux.conf out of it.
#
# The real tmux is the oracle twice over: it runs the test, and the sizes
# and layouts asserted are the ones it gives its own panes.
set -u
X=${X:-x}
BUNDLE="$(cd "$(dirname "$0")/../.." && pwd)"
fx=$(mktemp -d "${TMPDIR:-/tmp}/x-tmux-oracle.XXXXXX")
mkdir -p "$fx/langs"
ln -s "$BUNDLE" "$fx/langs/x-tmux"
s=xtmux-oracle-$$
c=/tmp/xtc$$
r=xtmux-oracle-sh-$$
trap 'tmux kill-session -t $s 2>/dev/null; X_LANG_DIR=$fx/langs/ TMUX_TMPDIR=$fx $X -l tmux -- -L oracle kill-server 2>/dev/null; tmux -L $r kill-server 2>/dev/null; X_LANG_DIR=$fx/langs/ TMUX_TMPDIR=$fx $X -l tmux -- -L oracle-sh kill-server 2>/dev/null; rm -f "$c"; rm -rf "$fx"' EXIT
failed=0

screen() { tmux capture-pane -p -t "$s" | sed 's/ *$//'; }
row() { screen | sed -n "$1p"; }
# Waits up to 60 seconds for TEXT on the screen.
wait_for() {
	i=0
	while ! screen | grep -qF -- "$1"; do
		i=$((i + 1))
		[ $i -lt 120 ] || return 1
		sleep 0.5
	done
}
check() {
	if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -- got '$2', want '$3'" >&2; screen >&2; failed=1; fi
}

# The pane gets the tester's PATH: the shell tmux starts it with may put
# another x first.
tmux new-session -d -s "$s" -x 80 -y 24 \
	"env PATH='$PATH' SHELL=/bin/sh PS1='$ ' VISUAL= EDITOR= X_LANG_DIR=$fx/langs/ TMUX_TMPDIR=$fx /bin/sh"
xt="$X -l tmux -- -L oracle -f /dev/null"
# The name tmux gives a window whose program is /bin/sh, which x-tmux's
# panes run: x-tmux names its windows as tmux does.
tmux new-window -d -t "$s" -n probe /bin/sh
sleep 1
W=$(tmux display -p -t "$s:probe" '#{pane_current_command}')
tmux kill-window -t "$s:probe"
# The status line's row without status-right's default, the host in
# quotes and the time.
H=$(tmux display -p '#{host}')
bar() { row "$1" | sed "s/ *\"$H\" [0-9][0-9]:[0-9][0-9] [0-9][0-9]-[A-Z][a-z][a-z]-[0-9][0-9]\$//"; }
tmux send-keys -t "$s" "$xt new 2>$fx/err; echo EXIT \$?" Enter
wait_for "[0] 0:$W*" || { echo "FAIL: no status line" >&2; cat "$fx/err" >&2; exit 1; }

# type
tmux send-keys -t "$s" 'echo one; echo two' Enter
wait_for 'two'
check "type -- the command's output in the pane" "$(screen | grep -c '^one$') $(screen | grep -c '^two$')" "1 1"
check "type -- the status line on the bottom row" "$(bar 24)" "[0] 0:$W*"
check "type -- status-right's pane title and time at its right end" \
	"$(row 24 | grep -cE "^\[0\] 0:$W\* +\"$H\" [0-9]{2}:[0-9]{2} [0-9]{2}-[A-Z][a-z]{2}-[0-9]{2}\$") $(row 24 | wc -c | tr -d ' ')" "1 81"

# alt
tmux send-keys -t "$s" "printf '\\033[?1049h\\033[HFULL-SCREEN'; sleep 2; printf '\\033[?1049l'; echo after-alt" Enter
wait_for 'FULL-SCREEN'
check "alt -- the program's screen shows alone" "$(screen | grep -c '^one$') $(row 1)" "0 FULL-SCREEN"
wait_for 'after-alt'
check "alt -- its screen gone when it leaves, the shell's lines back" "$(screen | grep -c '^FULL-SCREEN') $(screen | grep -c '^one$') $(screen | grep -c '^after-alt$')" "0 1 1"
tmux send-keys -t "$s" 'clear' Enter
sleep 1

# utf8
tmux send-keys -t "$s" "printf '\\346\\227\\245\\346\\234\\254|e\\314\\201|\\360\\237\\230\\200|\\n'" Enter
wait_for '|'
want=$(printf '\346\227\245\346\234\254|e\314\201|\360\237\230\200|')
check "utf8 -- wide and combining characters in a pane, as tmux shows them" "$(screen | grep -cxF "$want")" "1"
tmux send-keys -t "$s" 'clear' Enter
sleep 1

# styles
# The letters in octal, so the line typed does not hold what is checked.
tmux send-keys -t "$s" "printf '\\033[38;5;196m\\120\\033[m\\n\\033[48;2;1;2;3m\\121\\033[m\\n\\033[3;4m\\122\\033[m\\n'" Enter
wait_for 'R'
sleep 1
styled() { tmux capture-pane -e -p -t "$s" | grep -c -- "$1"; }
check "styles -- 256 colours, RGB, italics and underscore reach the terminal" \
	"$(styled '38;5;196mP') $(styled '48;2;1;2;3mQ') $(styled '3;4mR')" "1 1 1"
tmux send-keys -t "$s" "printf '\\033[?25l'; sleep 2; printf '\\033[?25h'" Enter
sleep 1
check "styles -- a program's ?25l hides the cursor" "$(tmux display -p -t "$s" '#{cursor_flag}')" "0"
sleep 3
check "styles -- and ?25h shows it" "$(tmux display -p -t "$s" '#{cursor_flag}')" "1"
tmux send-keys -t "$s" 'clear' Enter
sleep 1

# split -h
tmux send-keys -t "$s" C-b %
sleep 2
tmux send-keys -t "$s" 'stty size' Enter
wait_for '23 39'
check "split -h -- the new pane is 39 wide, as tmux's is" "$(screen | grep -c '23 39$')" "1"
blank40=$(printf '%40s' '')
check "split -h -- the border is column 41" "$(row 5)" "$blank40│"

# split -v
tmux send-keys -t "$s" C-b '"'
sleep 2
tmux send-keys -t "$s" 'stty size' Enter
wait_for '11 39'
check "split -v -- the new pane is 11 rows of 39" "$(screen | grep -c '11 39$')" "1"
check "split -v -- the border row is 12, right of the column" "$(row 12)" "$blank40│$(printf '─%.0s' $(seq 1 39))"

# next
tmux send-keys -t "$s" C-b o
sleep 1
tmux send-keys -t "$s" 'echo first again' Enter
wait_for 'first again'
check "next -- C-b o from the last pane is the first" "$(screen | grep -c '^first again ')" "1"

# kill
tmux send-keys -t "$s" C-b x
wait_for 'kill-pane 0? (y/n)'
check "kill -- C-b x asks first, the pane by its number" "$(bar 24)" "kill-pane 0? (y/n)"
tmux send-keys -t "$s" y
sleep 2
tmux send-keys -t "$s" 'stty size' Enter
wait_for '11 80'
check "kill -- the right column takes the window, its panes 80 wide" "$(screen | grep -c '^11 80$')" "1"

# exit
tmux send-keys -t "$s" 'exit' Enter
sleep 2
tmux send-keys -t "$s" 'stty size' Enter
wait_for '23 80'
check "exit -- the last pane takes the window" "$(screen | grep -c '^23 80$')" "1"

# zoom, arrows, resize: each pane's size as its shell's stty reads it
size() { tmux send-keys -t "$s" "clear; echo $1:\$(stty size)" Enter; wait_for "$1:" && sleep 0.5; screen | grep -o "$1:[0-9]* [0-9]*" | sed "s/^$1://"; }
tmux send-keys -t "$s" C-b %
sleep 2
tmux send-keys -t "$s" C-b z
sleep 1
check "zoom -- C-b z gives the active pane the window, marked Z" "$(size z1) $(bar 24)" "23 80 [0] 0:$W*Z"
tmux send-keys -t "$s" C-b z
sleep 1
check "zoom -- again puts it back" "$(size z2) $(bar 24)" "23 39 [0] 0:$W*"
tmux send-keys -t "$s" C-b Left
sleep 1
check "arrows -- C-b Left the pane on the left" "$(size a1)" "23 40"
tmux send-keys -t "$s" C-b C-Right
sleep 1
check "borders -- C-b C-Right moves its border a cell right" "$(size r1)" "23 41"
tmux send-keys -t "$s" C-b M-Left
sleep 1
check "borders -- C-b M-Left 5 cells left" "$(size r2)" "23 36"
tmux send-keys -t "$s" C-b C-Right C-Right C-Right
sleep 1
check "borders -- an arrow repeats without the prefix for a moment" "$(size r3)" "23 39"
tmux send-keys -t "$s" C-b z
sleep 1
tmux send-keys -t "$s" C-b Right
sleep 1
check "arrows -- an arrow from a zoomed pane puts it back first" "$(size a2) $(bar 24)" "23 40 [0] 0:$W*"

# last pane, swapping, rotating, layouts, numbers: the active pane's
# name, A the left pane and B the right, and its size
who() { tmux send-keys -t "$s" "clear; echo $1:\$P:\$(stty size)" Enter; wait_for "$1:" && sleep 0.5; screen | grep -o "$1:[AB]:[0-9]* [0-9]*" | sed "s/^$1://"; }
# C-b and a key sent as it is; a lone ; ends a command on tmux's command
# line, even after -l, so it goes as \;
prefixed() { tmux send-keys -t "$s" C-b; tmux send-keys -t "$s" -l "$1"; }
tmux send-keys -t "$s" 'P=B' Enter
prefixed '\;'
sleep 1
tmux send-keys -t "$s" 'P=A' Enter
check "last -- C-b ; the pane active before" "$(who l1)" "A:23 39"
prefixed '\;'
sleep 1
check "last -- again the other" "$(who l2)" "B:23 40"
prefixed '{'
sleep 1
check "swap -- C-b { swaps the pane with the one before, its cell's size" "$(who m1)" "B:23 39"
prefixed '}'
sleep 1
check "swap -- C-b } with the one after" "$(who m2)" "B:23 40"
tmux send-keys -t "$s" C-b C-o
sleep 1
check "rotate -- C-b C-o moves the panes on, the active cell's new pane active" "$(who m3)" "A:23 40"
tmux send-keys -t "$s" C-b M-o
sleep 1
check "rotate -- C-b M-o moves them back" "$(who m4)" "B:23 40"
tmux send-keys -t "$s" C-b M-2
sleep 1
check "layouts -- C-b M-2 even-vertical" "$(who y1)" "B:11 80"
tmux send-keys -t "$s" C-b M-1
sleep 1
check "layouts -- C-b M-1 even-horizontal" "$(who y2)" "B:23 39"
tmux send-keys -t "$s" C-b Space
sleep 1
check "layouts -- C-b Space the one after the last given" "$(who y3)" "B:11 80"
tmux send-keys -t "$s" C-b q
sleep 0.3
check "numbers -- C-b q puts each pane's size at its top right" "$(row 1 | grep -c '80x11$') $(row 13 | grep -c '80x11$')" "1 1"
check "numbers -- the active pane's red, the other's blue" \
	"$(tmux capture-pane -e -p -t "$s" | grep -c '41m') $(tmux capture-pane -e -p -t "$s" | grep -c '44m')" "5 5"
tmux send-keys -t "$s" 0
sleep 1
check "numbers -- a digit picks that pane and puts them away" "$(who n1) $(row 1 | grep -c '80x11$')" "A:11 80 0"
tmux send-keys -t "$s" C-b q
sleep 0.3
tmux send-keys -t "$s" x
sleep 1
check "numbers -- another key puts them away, not typed" "$(screen | grep -c '^\$ x') $(row 1 | grep -c '80x11$')" "0 0"
tmux send-keys -t "$s" C-b q
sleep 1.5
check "numbers -- gone after a second" "$(row 13 | grep -c '80x11$')" "0"
tmux send-keys -t "$s" 'exit' Enter
sleep 2
check "arrows -- the left pane takes the window again" "$(size a3)" "23 80"

# resize
tmux resize-window -t "$s" -x 100 -y 30
sleep 2
tmux send-keys -t "$s" 'stty size' Enter
wait_for '29 100'
check "resize -- the pane's terminal is the window less the status line" "$(screen | grep -c '^29 100$')" "1"

# copy
tmux send-keys -t "$s" 'clear; seq 1 200' Enter
wait_for '200'
tmux send-keys -t "$s" C-b '['
wait_for '[0/'
check "copy -- C-b [ shows the position at the top right" "$(row 1 | grep -cE ' \[0/[0-9]+\]$')" "1"
tmux send-keys -t "$s" PageUp
wait_for '[27/'
check "copy -- PgUp is a page, two rows short" "$(row 1 | grep -cE ' \[27/[0-9]+\]$')" "1"
tmux send-keys -t "$s" Up
sleep 1
check "copy -- Up moves the cursor, not the page" "$(row 1 | grep -cE ' \[27/[0-9]+\]$')" "1"
tmux send-keys -t "$s" q
sleep 1
check "copy -- q leaves, the pane as it is" "$(screen | grep -c '\[[0-9]*/[0-9]*\]$') $(screen | grep -c '^200$')" "0 1"
tmux send-keys -t "$s" C-b PageUp
wait_for '[27/'
tmux send-keys -t "$s" PageDown
sleep 1
check "copy -- after C-b PgUp, a page down to the bottom leaves" "$(screen | grep -c '\[[0-9]*/[0-9]*\]$')" "0"
tmux send-keys -t "$s" 'echo still-here' Enter
wait_for 'still-here'
check "copy -- keys reach the shell again" "$(screen | grep -c '^still-here$')" "1"

# paste
tmux send-keys -t "$s" 'clear; echo one-two; echo three' Enter
wait_for 'three'
tmux send-keys -t "$s" C-b '['
wait_for '[0/'
tmux send-keys -t "$s" Up Up C-a C-Space C-e Down
sleep 1
# a row captured alone starts from no attribute, so its own colours show
yellow() { tmux capture-pane -e -p -t "$s" -S "$1" -E "$1" | grep -c '43m'; }
check "paste -- the selection drawn black on yellow" "$(yellow 0) $(yellow 1) $(yellow 2)" "1 1 0"
tmux send-keys -t "$s" M-w
sleep 1
check "paste -- M-w copies and leaves copy mode" "$(screen | grep -c '\[[0-9]*/[0-9]*\]$')" "0"
tmux send-keys -t "$s" "cat >$fx/pasted" Enter
sleep 1
tmux send-keys -t "$s" C-b ']'
sleep 1
tmux send-keys -t "$s" Enter C-d
sleep 1
check "paste -- C-b ] types the newest buffer, a newline a carriage return" "$(cat "$fx/pasted")" "one-two
three"
# the screen as the copy checks left it, for attach's
tmux send-keys -t "$s" 'clear; echo still-here' Enter
wait_for 'still-here'

# windows
st() { bar 30; }
tmux send-keys -t "$s" C-b c
wait_for "1:$W*"
check "windows -- C-b c a new window, listed after the first, the first the last shown" "$(st)" "[0] 0:$W- 1:$W*"
tmux send-keys -t "$s" 'stty size; echo in-one' Enter
wait_for 'in-one'
check "windows -- the new window's pane is the window less the status line" "$(screen | grep -c '^29 100$')" "1"
tmux send-keys -t "$s" C-b c
wait_for "2:$W*"
check "windows -- a third, the last shown the second" "$(st)" "[0] 0:$W  1:$W- 2:$W*"
tmux send-keys -t "$s" C-b 1
wait_for 'in-one'
check "windows -- C-b 1 shows the second, as it was left" "$(st) $(screen | grep -c '^in-one$')" "[0] 0:$W  1:$W* 2:$W- 1"
tmux send-keys -t "$s" C-b l
sleep 1
check "windows -- C-b l the last shown" "$(st)" "[0] 0:$W  1:$W- 2:$W*"
tmux send-keys -t "$s" C-b n
wait_for 'still-here'
check "windows -- C-b n wraps to the first" "$(st)" "[0] 0:$W* 1:$W  2:$W-"
tmux send-keys -t "$s" C-b p
sleep 1
check "windows -- C-b p wraps back to the third" "$(st)" "[0] 0:$W- 1:$W  2:$W*"
tmux send-keys -t "$s" C-b 7
wait_for "Can't find window"
check "windows -- C-b 7 refused on the status line" "$(st)" "Can't find window: 7"
sleep 2
check "windows -- the message gone after a moment" "$(st)" "[0] 0:$W- 1:$W  2:$W*"
tmux send-keys -t "$s" C-b '&'
wait_for 'kill-window'
check "windows -- C-b & asks first" "$(st)" "kill-window $W? (y/n)"
tmux send-keys -t "$s" n
sleep 1
check "windows -- a no keeps the window" "$(st)" "[0] 0:$W- 1:$W  2:$W*"
tmux send-keys -t "$s" C-b '&'
wait_for 'kill-window'
tmux send-keys -t "$s" y
wait_for "0:$W*"
check "windows -- a yes kills it, the last shown shown" "$(st)" "[0] 0:$W* 1:$W-"
tmux send-keys -t "$s" C-b 1
wait_for "1:$W*"
tmux send-keys -t "$s" 'exit' Enter
wait_for "[0] 0:$W*"
check "windows -- a window's last pane exiting closes it" "$(st) $(screen | grep -c '^still-here$')" "[0] 0:$W* 1"

# detach
tmux send-keys -t "$s" C-b d
wait_for 'EXIT 0'
check "detach -- the client leaves with tmux's line and status 0" \
	"$(screen | grep -cxF '[detached (from session 0)]') $(screen | grep -cx 'EXIT 0')" "1 1"

# ls
tmux send-keys -t "$s" 'clear' Enter
sleep 1
tmux send-keys -t "$s" "$xt ls; echo LS \$?" Enter
wait_for 'LS 0'
check "ls -- the session kept, listed as tmux lists it" "$(screen | grep -cE '^0: 1 windows \(created [A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9][0-9] [0-9:]{8} [0-9]{4}\)$')" "1"

# attach
tmux send-keys -t "$s" "$xt attach -t nosuch; echo EXIT \$?" Enter
wait_for 'EXIT 1'
check "attach -- a session that is not there refused as tmux refuses it" "$(screen | grep -cxF "can't find session: nosuch")" "1"
tmux send-keys -t "$s" "$xt attach; echo EXIT \$?" Enter
wait_for "[0] 0:$W*"
check "attach -- the session back as it was left" "$(screen | grep -c '^still-here$') $(bar 30)" "1 [0] 0:$W*"
tmux send-keys -t "$s" "$xt ls" Enter
wait_for '(attached)'
check "attach -- ls marks the session attached" "$(screen | grep -c '^0: 1 windows (created .*) (attached)$')" "1"

# names
tmux send-keys -t "$s" 'clear; cat' Enter
sleep 1
tmux send-keys -t "$s" 'hello' Enter
wait_for '0:cat*'
check "names -- a window named after its foreground program" "$(bar 30)" "[0] 0:cat*"
tmux send-keys -t "$s" C-b '['
wait_for '0:[tmux]*'
check "names -- [tmux] while the pane is in copy mode" "$(bar 30)" "[0] 0:[tmux]*"
tmux send-keys -t "$s" q
wait_for '0:cat*'
tmux send-keys -t "$s" C-d
wait_for "0:$W*"
check "names -- the shell's name back when the program ends" "$(bar 30)" "[0] 0:$W*"
tmux send-keys -t "$s" C-b ,
wait_for '(rename-window)'
check "names -- C-b , asks for the name, the old one to edit" "$(bar 30)" "(rename-window) $W"
tmux send-keys -t "$s" C-u wurk Left Left BSpace o
sleep 1
check "names -- the name edited as tmux's prompt edits" "$(bar 30)" "(rename-window) work"
tmux send-keys -t "$s" Escape
sleep 1
check "names -- Escape leaves the name as it was" "$(bar 30)" "[0] 0:$W*"
tmux send-keys -t "$s" C-b ,
wait_for '(rename-window)'
tmux send-keys -t "$s" C-u work Enter
wait_for '0:work*'
tmux send-keys -t "$s" 'echo after-rename' Enter
wait_for 'after-rename'
sleep 1
check "names -- a renamed window keeps its name" "$(bar 30)" "[0] 0:work*"

# prompt
prefixed :
sleep 1
check "prompt -- C-b : asks for a command" "$(bar 30)" ":"
tmux send-keys -t "$s" -l 'renamew cmd'
tmux send-keys -t "$s" Enter
wait_for '0:cmd*'
check "prompt -- a command run" "$(bar 30)" "[0] 0:cmd*"
prefixed :
tmux send-keys -t "$s" -l 'foo'
tmux send-keys -t "$s" Enter
check "prompt -- an unknown command refused with tmux's message" \
	"$(wait_for 'Unknown command: foo' && echo seen)" "seen"
prefixed :
tmux send-keys -t "$s" Up Up
sleep 1
check "prompt -- Up goes back through the history" "$(bar 30)" ":renamew cmd"
tmux send-keys -t "$s" C-u
tmux send-keys -t "$s" -l 'sel'
tmux send-keys -t "$s" Tab
sleep 1
check "prompt -- Tab completes what the names share" "$(bar 30)" ":select-"
tmux send-keys -t "$s" Tab
sleep 1
check "prompt -- a second Tab offers the names" "$(bar 30)" ":select- select-layout select-pane select-window"
tmux send-keys -t "$s" C-c
sleep 1
prefixed :
tmux send-keys -t "$s" -l 'splitw -h ; renamew two'
tmux send-keys -t "$s" Enter
wait_for '0:two*'
check "prompt -- commands split by ; run in order" "$(bar 30) $(row 2 | grep -c '│')" "[0] 0:two* 1"
prefixed :
tmux send-keys -t "$s" -l 'killp -t 9 ; renamew no'
tmux send-keys -t "$s" Enter
check "prompt -- a pane not there refused, the commands after it not run" \
	"$(wait_for "Can't find pane: 9" && echo seen)" "seen"
wait_for '0:two*'
prefixed :
tmux send-keys -t "$s" -l 'killp -t 1 ; renamew work'
tmux send-keys -t "$s" Enter
wait_for '0:work*'
sleep 1
check "prompt -- kill-pane -t the pane of that number" "$(bar 30) $(row 2 | grep -c '│')" "[0] 0:work* 0"

# status
typed() { prefixed :; tmux send-keys -t "$s" -l "$1"; tmux send-keys -t "$s" Enter; }
typed "set -g status-left '<#S|#I> ' ; set -g status-right '#{=3:window_name}|#{window_panes}'"
wait_for 'wor|1'
check "status -- status-left and status-right's formats, at each end" "$(row 30)" "$(printf '%-95s%s' '<0|0> 0:work*' 'wor|1')"
typed "set -g status-justify right ; set -g window-status-current-format '(#W#{?window_zoomed_flag,+,})'"
wait_for '(work)'
check "status -- the windows' own format, justified right" "$(row 30)" "$(printf '%s%89s%s' '<0|0> ' '(work)' 'wor|1')"
typed "set -g status-style bg=blue,fg=white"
sleep 1
check "status -- status-style's colours" "$(tmux capture-pane -e -p -t "$s" | sed -n 30p | grep -c '44m')" "1"
typed "display -d 5000 '#{session_name}.#{window_index}.#{pane_index} #{==:#W,work}'"
wait_for '0.0.0 1'
check "status -- display-message's format on the status line" "$(bar 30)" "0.0.0 1"
sleep 5
typed "display -p 'shown #{window_name}'"
wait_for 'shown work'
check "status -- display-message -p's text over the pane, in view mode" "$(row 1 | grep -c '^shown work  *\[0/0\]$')" "1"
tmux send-keys -t "$s" q
sleep 1
typed "set status off"
sleep 1
check "status -- status off gives the pane every row" "$(size off) $(screen | grep -c 'wor|1')" "30 100 0"
typed "set status"
wait_for 'wor|1'
check "status -- set status again turns it back on" "$(size on)" "29 100"
typed "set -gu status-left ; set -gu status-right ; set -gu status-justify ; set -gu window-status-current-format ; set -gu status-style"
wait_for '[0] 0:work*'

# exited
tmux send-keys -t "$s" 'exit' Enter
wait_for '[exited]'
check "exited -- the client leaves with tmux's line" "$(screen | grep -cxF '[exited]')" "1"
tmux send-keys -t "$s" "clear; $xt ls; echo GONE \$?" Enter
wait_for 'GONE 1'
check "exited -- the session and the server gone with the last pane" "$(screen | grep -c '^no server running on ')" "1"

# kill
tmux send-keys -t "$s" "clear; $xt new -d -s work; $xt ls | sed 's/ (created.*//'; echo MADE \$?" Enter
wait_for 'MADE 0'
check "kill -- new -d makes the session named" "$(screen | grep -cx 'work: 1 windows')" "1"
tmux send-keys -t "$s" "clear; $xt kill-server; echo KILLED \$?; $xt ls; echo LISTED \$?" Enter
wait_for 'LISTED 1'
check "kill -- kill-server ends it and the server" \
	"$(screen | grep -cx 'KILLED 0') $(screen | grep -c '^no server running on ') $(ls "$fx/x-tmux-$(id -u)" | wc -l | tr -d ' ')" "1 1 0"

# config, its files at a short path so that their errors fit a row
ln -s "$fx" "$c"
printf '%s\n' '# keys of its own' 'set -g prefix C-a' 'bind r renamew fromconf' 'bind -n M-z renamew zed' \
	'bind q { renamew \' '  queued }' >"$c/good.conf"
printf '%s\n' 'renamew sourced' >"$c/more.conf"
printf '%s\n' 'set -g display-time abc' 'bind Foo neww' 'set -g history-limit 50' >"$c/bad.conf"
printf '%s\n' 'renamew never' 'foo' >"$c/unread.conf"
tmux send-keys -t "$s" "clear; $X -l tmux -- -L oracle -f $c/good.conf; echo CONF \$?" Enter
wait_for "0:$W*"
tmux send-keys -t "$s" C-a r
wait_for '0:fromconf*'
check "config -- -f FILE's prefix and its binding" "$(screen | grep -c '0:fromconf\*')" "1"
tmux send-keys -t "$s" M-z
wait_for '0:zed*'
check "config -- bind -n a key bound without the prefix" "$(screen | grep -c '0:zed\*')" "1"
tmux send-keys -t "$s" C-a q
wait_for '0:queued*'
check "config -- a block over lines, a line joined by \\" "$(screen | grep -c '0:queued\*')" "1"
tmux send-keys -t "$s" C-a :
sleep 1
tmux send-keys -t "$s" -l "source-file $c/more.conf"
tmux send-keys -t "$s" Enter
wait_for '0:sourced*'
check "config -- source-file from the prompt runs the file" "$(screen | grep -c '0:sourced\*')" "1"
tmux send-keys -t "$s" C-a :
sleep 1
tmux send-keys -t "$s" -l "source-file $c/none.conf"
tmux send-keys -t "$s" Enter
check "config -- a file that is not there refused as tmux refuses it" \
	"$(wait_for "No such file or directory: " && echo seen)" "seen"
tmux send-keys -t "$s" C-a :
sleep 1
tmux send-keys -t "$s" -l "source-file $c/unread.conf"
tmux send-keys -t "$s" Enter
wait_for "$c/unread.conf:2: unknown command: foo"
check "config -- a file that does not read shown, none of it run" \
	"$(screen | grep -cF "$c/unread.conf:2: unknown command: foo") $(screen | grep -c '0:never')" "1 0"
tmux send-keys -t "$s" q
sleep 1
tmux send-keys -t "$s" C-d
wait_for 'CONF 0'
tmux send-keys -t "$s" "clear; $X -l tmux -- -L oracle -f $c/bad.conf new; echo BAD \$?" Enter
wait_for "$c/bad.conf:2: unknown key: Foo"
check "config -- each line's error shown over the first pane, the rest run" \
	"$(screen | grep -cF "$c/bad.conf:1: value is invalid: abc") $(screen | grep -cF "$c/bad.conf:2: unknown key: Foo") $(screen | grep -c '0:\[tmux\]\*')" "1 1 1"
tmux send-keys -t "$s" q
sleep 1
tmux send-keys -t "$s" C-d
wait_for 'BAD 0'


# shell
# tmux's sessions are made 80x23: x-tmux gives a detached session's
# status line its row, where tmux gives a window with no client all 24.
# x-tmux has no history_bytes, so the size list-panes gives is left out,
# and so is history_size: a shell's prompt reaches tmux's history or not by
# when it is drawn against the split.
real() { env -u TMUX -u TMUX_PANE SHELL=/bin/sh tmux -L "$r" -f /dev/null "$@"; }
mine() { env -u TMUX -u TMUX_PANE SHELL=/bin/sh X_LANG_DIR=$fx/langs/ TMUX_TMPDIR=$fx $X -l tmux -- -L oracle-sh -f /dev/null "$@"; }
said() { "$@" 2>&1; echo "rc $?"; }
both() { check "shell -- $1" "$($2 mine)" "$($2 real)"; }
sized() { if [ "$1" = real ]; then echo "-x 80 -y 23"; fi; }
made() {
	$1 new -d -s work $(sized $1); $1 renamew -t work:0 main; $1 neww -d -t work -n ed; $1 new -d -s play $(sized $1); $1 renamew -t play:0 game
	said $1 has -t work; said $1 has -t wo; said $1 has -t nope
}
both "has-session by name, by the start of one, and none" made
shown() {
	said $1 display -p '#S'
	said $1 display -p -t work:1 '#S #I.#P #{pane_id} #{window_id} #{session_id}'
	said $1 display -p -t nope:0 'still #S'
}
both "display -p in the newest session, at a target, and at none" shown
split() {
	said $1 split-window -h -t work:0; said $1 split-window -v -t work:0.1
	said $1 display -p -t work '#I.#P'
	said $1 lsp -t work:0 -F '#{pane_index} #{pane_active} #{pane_width}x#{pane_height}'
}
both "split-window -t in a window not shown" split
windows() {
	said $1 neww -d -t work:5 -n five; said $1 neww -d -t work:1; said $1 neww -d -t zz:1; said $1 neww -d -t ed
	said $1 lsw -t work; said $1 lsw -a; said $1 lsw -t work -F '#I' -f '#{==:#W,ed}'
}
both "new-window -t and list-windows' forms" windows
panes() {
	said $1 lsp -t work:0 | sed 's/history [0-9]*\//history N\//; s/[0-9]* bytes]/ bytes]/'
	said $1 lsp -s -t work | sed 's/history [0-9]*\//history N\//; s/[0-9]* bytes]/ bytes]/'
	said $1 lsp -a | sed 's/history [0-9]*\//history N\//; s/[0-9]* bytes]/ bytes]/'
	said $1 lsp -t work:0 -F '#P' -f '#{pane_active}'
}
both "list-panes' forms" panes
layout() {
	said $1 select-layout -t work:0 even-vertical; said $1 select-layout -t work:0 bogus
	said $1 lsp -t work:0 -F '#P #{pane_width}x#{pane_height}'
	said $1 lsw -t work -F '#{window_layout}' -f '#{==:#I,0}'
}
both "select-layout -t" layout
options() {
	said $1 show -g status; said $1 show -gv status-left; said $1 show -g status-left
	said $1 show -g status-right; said $1 show -gw mode-keys
	said $1 show -g nosuch; said $1 show -gq nosuch; said $1 show status
}
both "show-options, its quoting and its refusals" options
names() {
	said $1 rename -t play work; said $1 rename -t play games; said $1 has -t =games
	said $1 renamew -t work:9 x; said $1 renamew -t work:5 fifth; said $1 lsw -t work -F '#I #W' -f '#{==:#I,5}'
}
both "rename-session and rename-window -t" names
keys() {
	f=$fx/keys.$1
	$1 send -t work:1 "stty raw -echo; head -c 47 >$f; stty sane" Enter
	sleep 2
	said $1 send -t work:1 Up C-Up M-a F1 F5 BTab S-F1 C-Home Home DC C-Space
	said $1 send -N 2 -t work:1 x
	said $1 send -H -t work:1 41 zz 7a
	i=0
	while [ "$(wc -c <"$f" 2>/dev/null | tr -d ' ')" != 47 ] && [ $i -lt 60 ]; do i=$((i + 1)); sleep 0.5; done
	od -An -tu1 "$f"
}
both "send-keys' bytes for keys, -N and -H" keys
wrong() {
	said $1 frob; said $1 has -x; said $1 send -N 0 -t work q; said $1 send -N x -t work q
	said $1 send -t work:0.7 a; said $1 send -t nope a; said $1 kill-session -t games; said $1 kill-session -t games
	said $1 has -t games
}
both "errors, and kill-session" wrong
mine kill-server
real kill-server

exit $failed
