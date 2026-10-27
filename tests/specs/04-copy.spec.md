# Copy mode
# @weight 2

tmux/copy against tmux 3.8's copy mode, in an 80x24 pane that has
printed 1 to 100 and a prompt, `$ `: 77 rows of history, the cursor on
the prompt's row at column 2.  After each command, the position tmux
shows at the pane's top right (its scroll_position and history_size)
and the copy's cursor (copy_cursor_y and copy_cursor_x).  In a key's
string, ^ is ESC.

## moves

### the cursor moves a row and scrolls at the edges, a page is two rows short, half a page is half

```tmux
(do (def h (spec-screen vt-feed-pure! (Str8 append (spec-lines 1 100) "\r\n$ ")))
    (def at (fn (_ c) (list (copy-position c) (first (copy-cursor c)) (rest (copy-cursor c)))))
    (def steps
      (list (list 'page-up) (list 'up) (List map (fn (_ i) 'up) (List range 0 23)) (list 'page-down)
            (list 'down) (list 'history-top) (list 'history-bottom) (list 'halfpage-up)
            (list 'halfpage-down)))
    (write
      (rest (List fold
              (fn (_ acc cmds)
                ((fn (_ c) (pair c (List append (rest acc) (list (at c)))))
                 (List fold copy-do (first acc) cmds)))
              ((fn (_ c) (pair c (list (at c)))) (copy-enter h #f #f))
              steps))))
```
---
    (("[0/77]" 23 2) ("[22/77]" 23 2) ("[22/77]" 22 2) ("[23/77]" 0 2) ("[1/77]" 0 2) ("[1/77]" 1 2) ("[77/77]" 0 0) ("[0/77]" 23 1) ("[12/77]" 23 2) ("[0/77]" 23 1))

### a page up shows the rows above the screen

```tmux
(do (def h (spec-screen vt-feed-pure! (Str8 append (spec-lines 1 100) "\r\n$ ")))
    (write (List map (fn (_ r) (Str8 trim-right (vt-row (copy-view (copy-do (copy-enter h #f #f) 'page-up)) r)))
             (list 0 23))))
```
---
    ("56" "79")

### cancel ends the mode, and so does a page down to the bottom after a PgUp

```tmux
(do (def h (spec-screen vt-feed-pure! (Str8 append (spec-lines 1 100) "\r\n$ ")))
    (def e (copy-do (copy-enter h #t #f) 'page-up))
    (write (list (copy-do (copy-enter h #f #f) 'cancel) (copy-position e) (copy-do e 'page-down))))
```
---
    (() "[22/77]" ())

### the copy is the pane as it was: output after the mode began does not move it

```tmux
(do (def h (spec-screen vt-feed-pure! (Str8 append (spec-lines 1 100) "\r\n$ ")))
    (def c (copy-enter h #f #f))
    (spec-feed! vt-feed-pure! h (Str8 append "\r\n" (spec-lines 101 110)))
    (write (list (copy-position (copy-do c 'page-up)) (Str8 trim-right (vt-row (copy-view c) 0)))))
```
---
    ("[22/77]" "78")

## keys

### tmux's keys for emacs, a command each

```tmux
(write (List map (fn (_ t) ((fn (_ b) (copy-key (%spec-str->ptr (first b)) 0 (rest b) #f)) (spec-bytes t)))
         (list "^[A" "^[B" "^[5~" "^[6~" "^OA" "^v" "^" "q" "\x10" "\x0e" "\x16" "k")))
```
---
    (('up . 3) ('down . 3) ('page-up . 4) ('page-down . 4) ('up . 3) ('page-up . 2) ('cancel . 1) ('cancel . 1) ('up . 1) ('down . 1) ('page-down . 1) (() . 1))

### and for vi

```tmux
(write (List map (fn (_ t) ((fn (_ b) (copy-key (%spec-str->ptr (first b)) 0 (rest b) #t)) (spec-bytes t)))
         (list "k" "j" "\x15" "\x04" "g" "G" "q" "^" "^[5~")))
```
---
    (('up . 1) ('down . 1) ('halfpage-up . 1) ('halfpage-down . 1) ('history-top . 1) ('history-bottom . 1) ('cancel . 1) ('clear-selection . 1) ('page-up . 4))

## selection

A pane that has printed `alpha beta  `, `gamma delta`, an empty line and
`epsilon zeta eta`, copy mode at its top.  What tmux 3.8 copies after
each run of commands, its keys sent there to a pane of the same lines.

### emacs: the selection stops short of the later end, a row's blanks left out, its end taken past its last character

```tmux
(do (def h (spec-screen vt-feed-pure! "alpha beta  \r\ngamma delta\r\n\r\nepsilon zeta eta\r\n"))
    (def take
      (fn (_ vi cmds)
        (def c (List fold copy-do (copy-do (copy-enter h #f vi) 'history-top) (List reverse (rest (List reverse cmds)))))
        (copy-text c (first (List reverse cmds)))))
    (write (List map (fn (_ cmds) (take #f cmds))
             (list (list 'begin-selection 'right 'right 'copy)
                   (list 'right 'right 'begin-selection 'down 'down 'copy)
                   (list 'down 'begin-selection 'up 'right 'copy)
                   (list 'begin-selection 'clear-selection 'copy)
                   (list 'copy)
                   (list 'right 'copy-end-of-line)
                   (list 'begin-selection 'down 'down 'down 'end-of-line 'copy)
                   (list 'down 'down 'begin-selection 'copy)))))
```
---
    ("al" "pha beta\ngamma delta\n" "lpha beta\n" () () "lpha beta" "alpha beta\ngamma delta\n\nepsilon zeta eta" "")

### vi: the selection takes the later end's cell; V takes whole rows; o swaps the ends

```tmux
(do (def h (spec-screen vt-feed-pure! "alpha beta  \r\ngamma delta\r\n\r\nepsilon zeta eta\r\n"))
    (def take
      (fn (_ vi cmds)
        (def c (List fold copy-do (copy-do (copy-enter h #f vi) 'history-top) (List reverse (rest (List reverse cmds)))))
        (copy-text c (first (List reverse cmds)))))
    (write (List map (fn (_ cmds) (take #t cmds))
             (list (list 'begin-selection 'right 'right 'copy)
                   (list 'right 'right 'begin-selection 'down 'down 'copy)
                   (list 'down 'begin-selection 'up 'right 'copy)
                   (list 'right 'copy-end-of-line)
                   (list 'right 'select-line 'copy)
                   (list 'down 'right 'select-line 'down 'copy)
                   (list 'right 'begin-selection 'right 'right 'other-end 'copy)
                   (list 'right 'begin-selection 'right 'right 'other-end 'left 'append)
                   (list 'begin-selection 'down 'down 'down 'end-of-line 'copy)
                   (list 'down 'down 'begin-selection 'copy)))))
```
---
    ("alp" "pha beta\ngamma delta\n\n" "lpha beta\ng" "lpha beta" "alpha beta\n" "gamma delta\n\n" "lph" "alph" "alpha beta\ngamma delta\n\nepsilon zeta eta" "\n")

### vi's cursor stays on a row's characters; with whole rows selected it goes to a row's start above where they began

```tmux
(do (def h (spec-screen vt-feed-pure! "alpha beta  \r\ngamma delta\r\n\r\nepsilon zeta eta\r\n"))
    (def at
      (fn (_ vi cmds)
        (copy-cursor (List fold copy-do (copy-do (copy-enter h #f vi) 'history-top) cmds))))
    (write (list (at #t (list 'end-of-line 'down)) (at #t (list 'end-of-line 'down 'down))
                 (at #t (list 'end-of-line 'right)) (at #t (list 'down 'end-of-line 'up))
                 (at #t (list 'select-line)) (at #t (list 'down 'select-line 'up))
                 (at #f (list 'end-of-line 'down 'down)) (at #t (list 'right 'begin-selection 'down 'other-end)))))
```
---
    ((1 . 9) (2 . 0) (1 . 0) (0 . 9) (0 . 9) (0 . 0) (2 . 0) (0 . 1))

### the selection drawn: each row it is on, from where it starts, to the edge but on its last

```tmux
(do (def h (spec-screen vt-feed-pure! "alpha beta  \r\ngamma delta\r\n\r\nepsilon zeta eta\r\n"))
    (def marks
      (fn (_ vi cmds)
        (List map (fn (_ m) (list (first m) (List ref 1 m) (Str8 length (List ref 2 m))))
          (copy-marks (List fold copy-do (copy-do (copy-enter h #f vi) 'history-top) cmds)))))
    (def sel (list 'right 'right 'begin-selection 'down 'down))
    (write (list (marks #f sel) (marks #t sel) (marks #t (list 'down 'select-line)) (marks #f (list 'down)))))
```
---
    (((0 2 78) (1 0 80)) ((0 2 78) (1 0 80) (2 0 1)) ((1 0 80)) ())

### the keys

```tmux
(write (list (List map (fn (_ t) (first ((fn (_ b) (copy-key (%spec-str->ptr (first b)) 0 (rest b) #f)) (spec-bytes t))))
               (list "\x07" "\x17" "\x0b" "^w"))
             (List map (fn (_ t) (first ((fn (_ b) (copy-key (%spec-str->ptr (first b)) 0 (rest b) #t)) (spec-bytes t))))
               (list " " "\r" "\n" "V" "o" "D" "A" "^"))))
```
---
    (('clear-selection 'copy 'copy-end-of-line 'copy) ('begin-selection 'copy 'copy 'select-line 'other-end 'copy-end-of-line 'append 'clear-selection))
