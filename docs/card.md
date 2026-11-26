# x-tmux card

## Run

```sh
x -l tmux                         # a session, shown here; C-b d detaches
x -l tmux -- --help               # the options and the commands
x -l tmux -- new                  # a session, as with no command
x -l tmux -- new -d -s NAME       # a session made and not shown
x -l tmux -- ls                   # the sessions the server keeps
x -l tmux -- attach [-t NAME]     # back into one
x -l tmux -- kill-server          # every session ended, and the server
x -l tmux -- COMMAND [ARG ...]    # any command below, run in the server
x -l tmux -- -L NAME COMMAND      # a server of its own, by its socket's name
x -l tmux -- -f FILE new          # the server reads FILE, not ~/.tmux.conf
```

| Word                  | Is                                                |
|-----------------------|---------------------------------------------------|
| server                | keeps the sessions; started by the first `new`    |
| session               | numbered windows; lives on when detached          |
| window                | panes laid out on one screen                      |
| pane                  | a shell on a pseudo-terminal                      |
| prefix                | C-b: the key before each key below                |
| target                | `SESSION:WINDOW.PANE`, parts optional; `%N` a pane |
| `~/.tmux.conf`        | commands the server runs as it starts             |
| `$TMUX` `$TMUX_PANE`  | set in each pane; name the session a command runs in |

## Sessions and windows

```tmux
new-session -d -s work
rename-window editor
new-window -d -n logs
split-window -h
display-message -p '#S #I:#W #{window_panes}'    # -> work 0:editor 2
list-windows -F '#I:#W has #{window_panes}'      # -> 0:editor has 2
                                                 # -> 1:logs has 1
select-window -t logs
display-message -p '#I:#W'                       # -> 1:logs
rename-session play
has-session -t play
display-message -p '#S'                          # -> play
kill-session
```

| After C-b            | Does                                               |
|----------------------|----------------------------------------------------|
| `c`                  | a new window                                       |
| `n` `p` `l`          | the next window; the previous; the one last shown  |
| `0` to `9`           | the window of that number                          |
| `,`                  | rename the window                                  |
| `&`                  | kill the window, asked first                       |
| `d`                  | detach: the session stays with the server          |
| `:`                  | the command prompt                                 |
| `C-b`                | a C-b to the pane                                  |

## Panes

```tmux
new-session -d -s grid
split-window -h
split-window -v
list-panes -F '#P #{pane_width}x#{pane_height}'  # -> 0 40x23
                                                 # -> 1 39x11
                                                 # -> 2 39x11
select-layout even-horizontal
list-panes -F '#P #{pane_width}x#{pane_height}'  # -> 0 26x23
                                                 # -> 1 26x23
                                                 # -> 2 26x23
select-pane -t 0
resize-pane -Z
display-message -p '#{window_zoomed_flag} #P'    # -> 1 0
swap-pane -D
list-panes -F '#P #D'                            # -> 0 %1
                                                 # -> 1 %0
                                                 # -> 2 %2
kill-pane -t 2
display-message -p '#{window_panes}'             # -> 2
```

| After C-b            | Does                                               |
|----------------------|----------------------------------------------------|
| `%` `"`              | split the active pane left and right; top and bottom |
| `o` `;`              | the next pane; the pane active before              |
| arrows               | the pane that way                                  |
| `C-`arrows `M-`arrows | move the active pane's border 1 cell; 5 cells     |
| `z`                  | zoom the active pane, or put it back               |
| `q`                  | show the panes' numbers; a digit picks one         |
| `{` `}`              | swap the active pane with the one before; after    |
| `C-o` `M-o`          | rotate the panes forward; backward                 |
| `M-1` to `M-7`       | a preset layout                                    |
| `Space`              | the next preset layout                             |
| `x`                  | kill the active pane, asked first                  |

| Layout                     | Is                                           |
|----------------------------|----------------------------------------------|
| `even-horizontal` `M-1`    | the panes side by side                       |
| `even-vertical` `M-2`      | one above another                            |
| `main-horizontal` `M-3`    | the first pane above the others              |
| `main-vertical` `M-4`      | the first pane left of the others            |
| `tiled` `M-5`              | a grid                                       |
| `main-horizontal-mirrored` `M-6` | the first pane below the others        |
| `main-vertical-mirrored` `M-7` | the first pane right of the others       |

## Buffers, options, formats

```tmux
new-session -d -s opts
set-buffer -b note 'hello card'
set-buffer 'second'
list-buffers -F '#{buffer_name} #{buffer_size}'  # -> buffer0 6
                                                 # -> note 10
delete-buffer -b note
list-buffers                             # -> buffer0: 6 bytes: "second"
show-options -g prefix                           # -> prefix C-b
set-option -g prefix C-a
show-options -gv prefix                          # -> C-a
set-option -g status-left '[#S] '
show-options -g status-left                      # -> status-left "[#S] "
display-message -p '#{?window_zoomed_flag,big,plain}'    # -> plain
display-message -p '#{=3:session_name} #{==:a,a}'        # -> opt 1
bind-key -n F5 new-window
unbind-key -n F5
```

| Command                             | Does                                |
|-------------------------------------|-------------------------------------|
| `bind-key [-nr] [-T TABLE] KEY COMMAND` | a key; `-n` no prefix, `-r` repeat |
| `unbind-key [-an] [-T TABLE] [KEY]` | take a key away                     |
| `set-option [-gqsuw] OPTION [VALUE]` | set an option                      |
| `show-options [-gqsvw] [NAME]`      | print options                       |
| `source-file [-q] FILE`             | run a file of commands              |
| `send-keys [-Hl] [-N COUNT] [-t PANE] KEY ...` | type keys into a pane    |
| `capture-pane -p [-S START] [-E END]` | print a pane's lines              |
| `pipe-pane [-IOo] [COMMAND]`        | a pane's output through a command   |
| `wait-for [-L \| -S \| -U] CHANNEL` | wait for a signal; send one; lock   |
| `display-message [-p] [FORMAT]`     | a format, on the status line or out |

| Option                 | Default                                         |
|------------------------|-------------------------------------------------|
| `prefix`               | `C-b`                                           |
| `mode-keys`            | `emacs`, or `vi` when VISUAL or EDITOR is vi's  |
| `history-limit`        | 2000 rows a new pane keeps                      |
| `display-time`         | 750 ms a message shows                          |
| `repeat-time`          | 500 ms a `-r` key repeats                       |
| `status`               | `on`                                            |
| `status-left` `status-right` | `[#{session_name}]`; the title and the time |
| `status-style`         | `bg=green,fg=black`                             |
| `window-status-format` | `#I:#W` and the window's flags                  |

| Format                    | Gives                                        |
|---------------------------|----------------------------------------------|
| `#{NAME}`                 | a name's value, or an option's               |
| `#S` `#I` `#W` `#P` `#D`  | session; window number; window; pane; pane id |
| `#F` `#T` `#H`            | window flags; pane title; host               |
| `#{?COND,A,B}`            | A when COND holds, else B                    |
| `#{==:A,B}` `!=` `<` `>` `\|\|` `&&` | 1 or 0                            |
| `#{=N:X}` `#{=-N:X}`      | X cut to its first N characters; its last N  |
| `#{b:X}` `#{d:X}`         | a path's last part; the rest                 |
| `#[STYLE]`                | a style: `fg=` `bg=` and attributes          |
| `%H:%M` `%F`              | strftime, in the status line's parts         |

## Copy mode

| Key                         | Does                                        |
|-----------------------------|---------------------------------------------|
| C-b `[`                     | copy mode                                   |
| C-b `PgUp`                  | copy mode, a page up                        |
| arrows, `PgUp` `PgDn`       | move a cell or a row; a page                |
| `Home` `End`                | the line's start; its end                   |
| `q`                         | leave                                       |
| C-b `]`                     | paste the newest buffer                     |
| C-b `#` `=` `-`             | list the buffers; choose one; delete one    |

| Does                        | emacs keys      | vi keys                   |
|-----------------------------|-----------------|---------------------------|
| a row up; down              | `C-p` `C-n`     | `k` `j`                   |
| a column left; right        | Left, `C-f`     | `h` `l`                   |
| the line's start; end       | `C-a` `C-e`     | `0` `$`                   |
| a page up; down             | `M-v` `C-v`     | PgUp, `C-f`               |
| half a page up; down        |                 | `C-u` `C-d`               |
| the history's top; the bottom | `M-<` `M->`   | `g` `G`                   |
| begin a selection           | `C-Space`       | `Space`                   |
| select whole lines          |                 | `V`                       |
| a rectangle, or back to rows | `R`            | `v` `C-v`                 |
| clear the selection         | `C-g`           | `Escape`                  |
| copy it and leave           | `M-w` `C-w`     | `Enter`                   |
| copy to the line's end      | `C-k`           | `D`                       |
| append to the newest buffer |                 | `A`                       |
| search down; up             | `C-s` `C-r`     | `/` `?`                   |
| search again; the other way | `n` `N`         | `n` `N`                   |
| the word at the cursor, down; up |            | `*` `#`                   |
| jump to a character; back   | `f` `F`         | `f` `F`                   |
| jump short of it; back      | `t` `T`         | `t` `T`                   |
| jump again; the other way   | `;` `,`         | `;` `,`                   |
| which keys                  | the default     | `VISUAL` or `EDITOR` is vi |

## Differs

| Here                                        | In tmux                       |
|---------------------------------------------|-------------------------------|
| a `-d` session's panes have 23 rows         | 24: no status line yet        |
| `list-sessions -F FORMAT` prints the usual line | the format                |
| `#(COMMAND)` in a format is empty           | the command's output          |
| a command x-tmux lacks says `not in x-tmux` | runs                          |
| lacks `list-keys` `list-commands` `list-clients` | has them                 |
| lacks `run-shell` `if-shell` `show-buffer` `save-buffer` | has them         |
| lacks `break-pane` `join-pane` `move-window` `swap-window` | has them       |
| lacks `find-window` `choose-tree` `clock-mode` | has them                   |
| lacks `set-environment` `show-environment`  | has them                      |
| the socket is `/tmp/x-tmux-UID/NAME`        | `/tmp/tmux-UID/NAME`          |

## More

| Where                               | What                              |
|-------------------------------------|-----------------------------------|
| `README.md`                         | every key, command and option     |
| `tests/specs/`                      | each part, held to tmux 3.8       |
| `tests/oracle/panes.sh`             | x-tmux driven inside a real tmux  |
| `make card`                         | runs every program on this page   |
