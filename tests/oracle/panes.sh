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
#   split -h  C-b %: a second pane right of the first, the border between,
#             each pane's terminal its own size (stty size)
#   split -v  C-b ": a third pane below the second
#   next      C-b o from the last pane comes back to the first
#   kill      C-b x, asked and answered y: the active pane gone, its
#             sibling given its space
#   exit      a pane's shell exiting removes the pane
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
#   exited    the last pane's shell exiting ends the session, the client
#             and the server
#   kill      kill-server ends a session made with new -d, and the server
#
# x-tmux runs from a shell in the tmux pane, on a socket of its own.
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
trap 'tmux kill-session -t $s 2>/dev/null; X_LANG_DIR=$fx/langs/ TMUX_TMPDIR=$fx $X -l tmux -- -L oracle kill-server 2>/dev/null; rm -rf "$fx"' EXIT
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

tmux new-session -d -s "$s" -x 80 -y 24 \
	"env SHELL=/bin/sh PS1='$ ' VISUAL= EDITOR= X_LANG_DIR=$fx/langs/ TMUX_TMPDIR=$fx /bin/sh"
xt="$X -l tmux -- -L oracle"
# The name tmux gives a window whose program is /bin/sh, which x-tmux's
# panes run: x-tmux names its windows as tmux does.
tmux new-window -d -t "$s" -n probe /bin/sh
sleep 1
W=$(tmux display -p -t "$s:probe" '#{pane_current_command}')
tmux kill-window -t "$s:probe"
tmux send-keys -t "$s" "$xt new 2>$fx/err; echo EXIT \$?" Enter
wait_for "[0] 0:$W*" || { echo "FAIL: no status line" >&2; cat "$fx/err" >&2; exit 1; }

# type
tmux send-keys -t "$s" 'echo one; echo two' Enter
wait_for 'two'
check "type -- the command's output in the pane" "$(screen | grep -c '^one$') $(screen | grep -c '^two$')" "1 1"
check "type -- the status line on the bottom row" "$(row 24)" "[0] 0:$W*"

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
check "kill -- C-b x asks first, the pane by its number" "$(row 24)" "kill-pane 0? (y/n)"
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
st() { row 30; }
tmux send-keys -t "$s" C-b c
wait_for "1:$W*"
check "windows -- C-b c a new window, listed after the first, the first the last shown" "$(st)" "[0] 0:$W- 1:$W*"
tmux send-keys -t "$s" 'stty size; echo in-one' Enter
wait_for 'in-one'
check "windows -- the new window's pane is the window less the status line" "$(screen | grep -c '^29 100$')" "1"
tmux send-keys -t "$s" C-b c
wait_for "2:$W*"
check "windows -- a third, the last shown the second" "$(st)" "[0] 0:$W 1:$W- 2:$W*"
tmux send-keys -t "$s" C-b 1
wait_for 'in-one'
check "windows -- C-b 1 shows the second, as it was left" "$(st) $(screen | grep -c '^in-one$')" "[0] 0:$W 1:$W* 2:$W- 1"
tmux send-keys -t "$s" C-b l
sleep 1
check "windows -- C-b l the last shown" "$(st)" "[0] 0:$W 1:$W- 2:$W*"
tmux send-keys -t "$s" C-b n
wait_for 'still-here'
check "windows -- C-b n wraps to the first" "$(st)" "[0] 0:$W* 1:$W 2:$W-"
tmux send-keys -t "$s" C-b p
sleep 1
check "windows -- C-b p wraps back to the third" "$(st)" "[0] 0:$W- 1:$W 2:$W*"
tmux send-keys -t "$s" C-b 7
wait_for "Can't find window"
check "windows -- C-b 7 refused on the status line" "$(st)" "Can't find window: 7"
sleep 2
check "windows -- the message gone after a moment" "$(st)" "[0] 0:$W- 1:$W 2:$W*"
tmux send-keys -t "$s" C-b '&'
wait_for 'kill-window'
check "windows -- C-b & asks first" "$(st)" "kill-window $W? (y/n)"
tmux send-keys -t "$s" n
sleep 1
check "windows -- a no keeps the window" "$(st)" "[0] 0:$W- 1:$W 2:$W*"
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
check "attach -- the session back as it was left" "$(screen | grep -c '^still-here$') $(row 30)" "1 [0] 0:$W*"
tmux send-keys -t "$s" "$xt ls" Enter
wait_for '(attached)'
check "attach -- ls marks the session attached" "$(screen | grep -c '^0: 1 windows (created .*) (attached)$')" "1"

# names
tmux send-keys -t "$s" 'clear; cat' Enter
sleep 1
tmux send-keys -t "$s" 'hello' Enter
wait_for '0:cat*'
check "names -- a window named after its foreground program" "$(row 30)" "[0] 0:cat*"
tmux send-keys -t "$s" C-b '['
wait_for '0:[tmux]*'
check "names -- [tmux] while the pane is in copy mode" "$(row 30)" "[0] 0:[tmux]*"
tmux send-keys -t "$s" q
wait_for '0:cat*'
tmux send-keys -t "$s" C-d
wait_for "0:$W*"
check "names -- the shell's name back when the program ends" "$(row 30)" "[0] 0:$W*"
tmux send-keys -t "$s" C-b ,
wait_for '(rename-window)'
check "names -- C-b , asks for the name, the old one to edit" "$(row 30)" "(rename-window) $W"
tmux send-keys -t "$s" C-u wurk Left Left BSpace o
sleep 1
check "names -- the name edited as tmux's prompt edits" "$(row 30)" "(rename-window) work"
tmux send-keys -t "$s" Escape
sleep 1
check "names -- Escape leaves the name as it was" "$(row 30)" "[0] 0:$W*"
tmux send-keys -t "$s" C-b ,
wait_for '(rename-window)'
tmux send-keys -t "$s" C-u work Enter
wait_for '0:work*'
tmux send-keys -t "$s" 'echo after-rename' Enter
wait_for 'after-rename'
sleep 1
check "names -- a renamed window keeps its name" "$(row 30)" "[0] 0:work*"

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

exit $failed
