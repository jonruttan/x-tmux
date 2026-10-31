# A command line
# @weight 1

tmux/command: a line typed at C-b : read as tmux reads one.  Each
message is the one tmux 3.8 shows on its status line for the same line.

## words

### commands separated by ;, words by spaces, quotes kept together

```tmux
(write (command-parse "rename-window \"a b\"; neww"))
```
---
    (#t (("rename-window" () ("a b")) ("new-window" () ())))

### a ; inside a word separates too, and an escaped one does not

```tmux
(write (list (command-parse "renamew x;neww") (command-parse "renamew x\;y")))
```
---
    ((#t (("rename-window" () ("x")) ("new-window" () ()))) (#t (("rename-window" () ("x;y")))))

### single quotes as they are, a backslash in double quotes escaping, a quote left open running to the end

```tmux
(write (list (command-parse "renamew 'a\\b'") (command-parse "renamew \"q\\\"x\"") (command-parse "renamew 'abc")))
```
---
    ((#t (("rename-window" () ("a\\b")))) (#t (("rename-window" () ("q\"x")))) (#t (("rename-window" () ("abc")))))

### a backslash at the end is a syntax error, and an empty line no commands

```tmux
(write (list (command-parse "renamew a\\") (command-parse "") (command-parse "   ")))
```
---
    ((#f "syntax error") (#t ()) (#t ()))

## names

### an alias, a whole name, or a prefix of only one name

```tmux
(write (list (command-find "splitw") (command-find "split") (command-find "next") (command-find "lastp")))
```
---
    ((#t "split-window") (#t "split-window") (#t "next-window") (#t "last-pane"))

### an unknown name, and a prefix of several

```tmux
(write (list (command-find "bar") (command-find "n")))
```
---
    ((#f "unknown command: bar") (#f "ambiguous command: n, could be: new-pane, new-session, new-window, next-layout, next-window"))

### the names a prefix completes to, in tmux's order

```tmux
(write (list (command-matches "sel") (command-matches "split-w") (command-matches "z")))
```
---
    (("select-layout" "select-pane" "select-window") ("split-window") ())

### a line with an unknown command runs none of it

```tmux
(write (list (command-parse "foo; neww") (command-parse "neww; foo")))
```
---
    ((#f "unknown command: foo") (#f "unknown command: foo"))

## flags and arguments

### flags alone or together, a value in the next word or the same one

```tmux
(write (list (command-parse "split-window -hv") (command-parse "selectp -t 1") (command-parse "selectp -t1")
             (command-parse "selectp -l -- ")))
```
---
    ((#t (("split-window" (("h" . #t) ("v" . #t)) ()))) (#t (("select-pane" (("t" . "1")) ()))) (#t (("select-pane" (("t" . "1")) ()))) (#t (("select-pane" (("l" . #t)) ()))))

### an unknown flag, a value missing, too few and too many arguments

```tmux
(List for-each (fn (_ line) (write (List ref 1 (command-parse line))) (write "|"))
  (list "split-window -x" "detach-client -x" "selectp -t" "kill-window -t" "rename-window" "rename-window a b"))
```
---
    "command split-window: unknown flag -x""|""command detach-client: unknown flag -x""|""command select-pane: -t expects an argument""|""command kill-window: -t expects an argument""|""command rename-window: too few arguments (need at least 1)""|""command rename-window: too many arguments (need at most 1)""|"

### a value looked up

```tmux
(def c (List ref 1 (first (List ref 1 (command-parse "selectp -l -t 2")))))
(write (list (command-flag c "t") (command-flag c "l") (command-flag c "U")))
```
---
    ("2" #t ())
