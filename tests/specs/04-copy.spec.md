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
              ((fn (_ c) (pair c (list (at c)))) (copy-enter h #f))
              steps))))
```
---
    (("[0/77]" 23 2) ("[22/77]" 23 2) ("[22/77]" 22 2) ("[23/77]" 0 2) ("[1/77]" 0 2) ("[1/77]" 1 2) ("[77/77]" 0 0) ("[0/77]" 23 1) ("[12/77]" 23 2) ("[0/77]" 23 1))

### a page up shows the rows above the screen

```tmux
(do (def h (spec-screen vt-feed-pure! (Str8 append (spec-lines 1 100) "\r\n$ ")))
    (write (List map (fn (_ r) (Str8 trim-right (vt-row (copy-view (copy-do (copy-enter h #f) 'page-up)) r)))
             (list 0 23))))
```
---
    ("56" "79")

### cancel ends the mode, and so does a page down to the bottom after a PgUp

```tmux
(do (def h (spec-screen vt-feed-pure! (Str8 append (spec-lines 1 100) "\r\n$ ")))
    (def e (copy-do (copy-enter h #t) 'page-up))
    (write (list (copy-do (copy-enter h #f) 'cancel) (copy-position e) (copy-do e 'page-down))))
```
---
    (() "[22/77]" ())

### the copy is the pane as it was: output after the mode began does not move it

```tmux
(do (def h (spec-screen vt-feed-pure! (Str8 append (spec-lines 1 100) "\r\n$ ")))
    (def c (copy-enter h #f))
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
    (('up . 1) ('down . 1) ('halfpage-up . 1) ('halfpage-down . 1) ('history-top . 1) ('history-bottom . 1) ('cancel . 1) (() . 1) ('page-up . 4))
