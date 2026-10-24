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
#   kill      C-b x: the active pane gone, its sibling given its space
#   exit      a pane's shell exiting removes the pane
#   resize    the window grown to 100x30: the pane's terminal follows
#   leave     C-b d: x-tmux ends with status 0, its shells hung up
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
trap 'tmux kill-session -t $s 2>/dev/null; rm -rf "$fx"' EXIT
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
	"SHELL=/bin/sh X_LANG_DIR=$fx/langs/ $X -l tmux -- new 2>$fx/err; echo EXIT \$? > $fx/status; sleep 600"
wait_for '[0] 0:x-tmux*' || { echo "FAIL: no status line" >&2; cat "$fx/err" >&2; exit 1; }

# type
tmux send-keys -t "$s" 'echo one; echo two' Enter
wait_for 'two'
check "type -- the command's output in the pane" "$(screen | grep -c '^one$') $(screen | grep -c '^two$')" "1 1"
check "type -- the status line on the bottom row" "$(row 24)" "[0] 0:x-tmux*"

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

# leave
tmux send-keys -t "$s" C-b d
i=0
while [ ! -s "$fx/status" ] && [ $i -lt 60 ]; do i=$((i + 1)); sleep 0.5; done
check "leave -- C-b d ends x-tmux with status 0" "$(cat "$fx/status" 2>/dev/null)" "EXIT 0"

exit $failed
