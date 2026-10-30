# Keys and files of commands
# @weight 1

tmux/keys: a key typed, named as tmux names it, and a key's name read as
tmux 3.8's bind reads it; tmux/command: a file of commands read as tmux
3.8 reads its configuration.  The names and messages are tmux 3.8's for
the same keys and files.

## keys typed

### characters, control keys and the named ones

```tmux
(def bytes
  (fn (_ xs)
    (List fold (fn (_ acc b) (Str8 append acc ((fn (_ s) ((prim-ref (lit ptr) (lit set!)) ((prim-ref (lit str) (lit ->ptr)) s) 0 b 1) s) ((prim-ref (lit str) (lit make)) 1)))) "" xs)))
(def typed (fn (_ xs) ((fn (_ s) (key-read ((prim-ref (lit str) (lit ->ptr)) s) 0 ((prim-ref (lit str) (lit byte-len)) s))) (bytes xs))))
(write (List map typed (list (list 97) (list 2) (list 0) (list 9) (list 13) (list 32) (list 127) (list 27) (list 31))))
```
---
    (("a" . 1) ("C-b" . 1) ("C-Space" . 1) ("Tab" . 1) ("Enter" . 1) ("Space" . 1) ("BSpace" . 1) ("Escape" . 1) ("C-_" . 1))

### arrows, pages and function keys, with their modifiers

```tmux
(def bytes
  (fn (_ xs)
    (List fold (fn (_ acc b) (Str8 append acc ((fn (_ s) ((prim-ref (lit ptr) (lit set!)) ((prim-ref (lit str) (lit ->ptr)) s) 0 b 1) s) ((prim-ref (lit str) (lit make)) 1)))) "" xs)))
(def typed (fn (_ xs) ((fn (_ s) (key-read ((prim-ref (lit str) (lit ->ptr)) s) 0 ((prim-ref (lit str) (lit byte-len)) s))) (bytes xs))))
(write (List map typed
  (list (list 27 91 65) (list 27 79 66) (list 27 91 49 59 53 65) (list 27 91 49 59 51 68) (list 27 27 91 67)
        (list 27 91 53 126) (list 27 91 54 59 53 126) (list 27 79 80) (list 27 91 50 52 126) (list 27 91 51 126))))
```
---
    (("Up" . 3) ("Down" . 3) ("C-Up" . 6) ("M-Left" . 6) ("M-Right" . 4) ("PPage" . 4) ("C-NPage" . 6) ("F1" . 3) ("F12" . 5) ("DC" . 4))

### Meta: an ESC before a key

```tmux
(def bytes
  (fn (_ xs)
    (List fold (fn (_ acc b) (Str8 append acc ((fn (_ s) ((prim-ref (lit ptr) (lit set!)) ((prim-ref (lit str) (lit ->ptr)) s) 0 b 1) s) ((prim-ref (lit str) (lit make)) 1)))) "" xs)))
(def typed (fn (_ xs) ((fn (_ s) (key-read ((prim-ref (lit str) (lit ->ptr)) s) 0 ((prim-ref (lit str) (lit byte-len)) s))) (bytes xs))))
(write (List map typed (list (list 27 49) (list 27 111) (list 27 24) (list 27 91))))
```
---
    (("M-1" . 2) ("M-o" . 2) ("C-M-x" . 2) ("M-[" . 2))

## names bind reads

### modifiers in any case and order, ^x, other spellings

```tmux
(write (List map key-name (list "C-M-x" "M-C-y" "^z" "m-z" "c-z" "C-A" "PageUp" "pagedown" "enter" "S-Up" "C-Left" "F12" "%" "\"" "Any")))
```
---
    ("C-M-x" "C-M-y" "C-z" "M-z" "C-z" "C-a" "PPage" "NPage" "Enter" "S-Up" "C-Left" "F12" "%" "\"" "Any")

### a name that is no key

```tmux
(write (List map key-name (list "Foo" "C-" "F13" "")))
```
---
    (() () () ())

### the bytes send-prefix sends for a key

```tmux
(write (List map (fn (_ k) ((prim-ref (lit str) (lit byte-len)) (key-bytes k))) (list "C-b" "C-a" "M-x" "a" "Space" "F1")))
(write (List map (fn (_ k) ((prim-ref (lit ptr) (lit ref)) ((prim-ref (lit str) (lit ->ptr)) (key-bytes k)) 0 1)) (list "C-b" "C-a" "M-x" "a" "Space")))
```
---
    (1 1 2 1 1 0)(2 1 27 97 32)

## files of commands

### each command and the line it starts on; comments, joined lines and blocks

```tmux
(write (command-read "# a comment\nset -g display-time 2000\nbind Q \\\n  display-panes\nbind c { neww\n  renamew x }\nneww; lastp"))
```
---
    (#t ((2 "set-option" (("g" . #t)) ("display-time" "2000")) (3 "bind-key" () ("Q" "display-panes")) (5 "bind-key" () ("c" " neww\n  renamew x ")) (7 "new-window" () ()) (7 "last-pane" () ())))

### a line that does not read refuses the file, with its line

```tmux
(write (list (command-read "set -g display-time 1\nsplitw -x") (command-read "set x 1\nbind q { neww\n") (command-read "neww\nfoo")))
```
---
    ((#f 2 "command split-window: unknown flag -x") (#f 3 "syntax error") (#f 2 "unknown command: foo"))

### a command of tmux's that x-tmux does not run reads

```tmux
(write (command-read "run-shell -b 'echo hi'"))
```
---
    (#t ((1 "run-shell" #f ("-b" "echo hi"))))

### a key's commands: one word read as a line, or words split by ;

```tmux
(write (list (command-list (list "splitw -h ; splitw -v")) (command-list (list "neww" ";" "renamew" "x")) (command-list (list "selectp" "-t" "1"))))
```
---
    ((#t (("split-window" (("h" . #t)) ()) ("split-window" (("v" . #t)) ()))) (#t (("new-window" () ()) ("rename-window" () ("x")))) (#t (("select-pane" (("t" . "1")) ()))))
