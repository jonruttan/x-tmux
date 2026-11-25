#!/bin/sh
# tests/card-run.sh FILE -- run one program of docs/card.md, for the bundle
# kit's card check.  X is the x under test.
#
# A program is tmux commands, one a line, each run from a shell as
# `x -l tmux -- COMMAND` against a server of its own: its socket is in a
# directory made here, it reads no configuration, and its panes run /bin/sh
# with no history file.  The server is ended when the program is.
d=$(mktemp -d) || exit 1
t() {
	env -u TMUX -u TMUX_PANE SHELL=/bin/sh HISTFILE=/dev/null TMUX_TMPDIR="$d" \
		"${X:-x}" -l tmux -- -L card -f /dev/null "$@" < /dev/null
}
trap 't kill-server 2> /dev/null; rm -rf "$d"' EXIT
sed -e 's/[[:space:]]*# -> .*$//' -e '/^[[:space:]]*$/d' "$1" > "$d/program"
while IFS= read -r line; do
	eval "t $line"
done < "$d/program"
