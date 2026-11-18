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

## wrapped rows

### a row the terminal wrapped is one line with the next: a selection goes on into it, the line's start and end are its rows', and C-k copies to its end

```tmux
(do (def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100) "abcdefghijklmnopqrstuvwxyz0123\r\nshort\r\n"))
    (def run (fn (_ vi cmds) (List fold copy-do (copy-do (copy-enter h #f vi) 'history-top) cmds)))
    (def take
      (fn (_ vi cmds) (copy-text (run vi (List reverse (rest (List reverse cmds)))) (first (List reverse cmds)))))
    (write (list (take #f (list 'right 'right 'begin-selection 'down 'copy))
                 (take #f (list 'right 'right 'copy-end-of-line))
                 (take #f (list 'begin-selection 'end-of-line 'copy))
                 (take #f (list 'down 'begin-selection 'up 'copy))
                 (copy-cursor (run #f (list 'end-of-line)))
                 (copy-cursor (run #f (list 'down 'right 'right 'right 'start-of-line))))))
```
---
    ("cdefghijklmnopqrstuv" "cdefghijklmnopqrstuvwxyz0123" "abcdefghijklmnopqrstuvwxyz0123" "abcdefghijklmnopqrst" (1 . 10) (0 . 0))

### vi: V takes the whole line, from the row it began on to the cursor's; a selection's last row runs past its end

```tmux
(do (def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100) "abcdefghijklmnopqrstuvwxyz0123\r\nshort\r\n"))
    (def run (fn (_ vi cmds) (List fold copy-do (copy-do (copy-enter h #f vi) 'history-top) cmds)))
    (def take
      (fn (_ vi cmds) (copy-text (run vi (List reverse (rest (List reverse cmds)))) (first (List reverse cmds)))))
    (write (list (take #t (list 'down 'select-line 'copy))
                 (take #t (list 'begin-selection 'down 'down 'copy))
                 (take #t (list 'right 'right 'copy-end-of-line))
                 (take #t (list 'begin-selection 'end-of-line 'copy))
                 (take #t (list 'down 'down 'select-line 'up 'copy))
                 (take #t (list 'select-line 'down 'down 'copy))
                 (take #t (list 'down 'down 'begin-selection 'up 'copy))
                 (copy-cursor (run #t (list 'end-of-line)))
                 (copy-cursor (run #t (list 'down 'select-line 'up)))
                 (copy-cursor (run #t (list 'down 'down 'select-line 'up))))))
```
---
    ("abcdefghijklmnopqrstuvwxyz0123\n" "abcdefghijklmnopqrstuvwxyz0123\ns" "cdefghijklmnopqrstuvwxyz0123" "abcdefghijklmnopqrstuvwxyz0123" "uvwxyz0123\nshort\n" "abcdefghijklmnopqrstuvwxyz0123\nshort\n\n" "uvwxyz0123\ns" (1 . 9) (0 . 19) (1 . 0))

### a wrapped row keeps the spaces it holds

```tmux
(do (def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100) "abcdefghijklmnopqr  xyz\r\nnext\r\n"))
    (def run (fn (_ vi cmds) (List fold copy-do (copy-do (copy-enter h #f vi) 'history-top) cmds)))
    (def take
      (fn (_ vi cmds) (copy-text (run vi (List reverse (rest (List reverse cmds)))) (first (List reverse cmds)))))
    (write (list (take #f (list 'begin-selection 'down 'end-of-line 'copy))
                 (take #t (list 'begin-selection 'down 'end-of-line 'copy))
                 (take #f (list 'right 'copy-end-of-line))
                 (take #t (list 'select-line 'copy)))))
```
---
    ("abcdefghijklmnopqr  xyz" "abcdefghijklmnopqr  xyz" "bcdefghijklmnopqr  xyz" "abcdefghijklmnopqr  xyz\n")

## search

A 20x6 pane, as tmux 3.8's searched with send -X: after each search, the
cursor's column and row and the position, its count of the matches.

### vi: n and N search again its way and the other, from the end round to the start; the cursor goes to a match's start

```tmux
(do (copy-count-limit! 0)
    (def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100) "abc one\r\nxx abc\r\nabc abc abc\r\nnone\r\n"))
    (def at (fn (_ c) (list (rest (copy-cursor c)) (first (copy-cursor c)) (copy-position c))))
    (def steps
      (fn (_ c fs) (rest (List fold (fn (_ acc f) ((fn (_ n) (pair n (List append (rest acc) (list (at n))))) (do (Heap collect) (f (first acc)))))
                           (pair c ()) fs))))
    (def again (fn (_ c) (copy-do c 'search-again)))
    (write (steps (copy-enter h #f #t)
             (list (fn (_ c) (copy-search c "abc" #f #t)) again again again (fn (_ c) (copy-do c 'search-reverse))
                   (fn (_ c) (copy-search c "abc" #t #t)) again again again again again))))
```
---
    ((8 2 "[0/0] (5 results)") (4 2 "[0/0] (5 results)") (0 2 "[0/0] (5 results)") (3 1 "[0/0] (5 results)") (0 2 "[0/0] (5 results)") (4 2 "[0/0] (5 results)") (8 2 "[0/0] (5 results)") (0 0 "[0/0] (5 results)") (3 1 "[0/0] (5 results)") (0 2 "[0/0] (5 results)") (4 2 "[0/0] (5 results)"))

### emacs: a search down puts the cursor past the match; a move lets the matches go, and the next search does not count them

```tmux
(do (copy-count-limit! 0)
    (def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100) "abc one\r\nxx abc\r\nabc abc abc\r\nnone\r\n"))
    (def at (fn (_ c) (list (rest (copy-cursor c)) (first (copy-cursor c)) (copy-position c))))
    (def steps
      (fn (_ c fs) (rest (List fold (fn (_ acc f) ((fn (_ n) (pair n (List append (rest acc) (list (at n))))) (do (Heap collect) (f (first acc)))))
                           (pair c ()) fs))))
    (def again (fn (_ c) (copy-do c 'search-again)))
    (write (steps (copy-enter h #f #f)
             (list (fn (_ c) (copy-search c "abc" #f #f)) again (fn (_ c) (copy-do c 'search-reverse))
                   (fn (_ c) (copy-search c "abc" #t #f)) again again (fn (_ c) (copy-do c 'left)) again))))
```
---
    ((8 2 "[0/0] (5 results)") (4 2 "[0/0] (5 results)") (7 2 "[0/0] (5 results)") (11 2 "[0/0] (5 results)") (3 0 "[0/0] (5 results)") (6 1 "[0/0] (5 results)") (5 1 "[0/0]") (3 2 "[0/0]"))

### emacs's incremental search: = the way it began, + down, - up; new text goes back to where it began; no text lets the matches go

```tmux
(do (copy-count-limit! 0)
    (def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100) "abc one\r\nxx abc\r\nabc abc abc\r\nnone\r\n"))
    (def at (fn (_ c) (list (rest (copy-cursor c)) (first (copy-cursor c)) (copy-position c))))
    (def steps
      (fn (_ c fs) (rest (List fold (fn (_ acc f) ((fn (_ n) (pair n (List append (rest acc) (list (at n))))) (do (Heap collect) (f (first acc)))))
                           (pair c ()) fs))))
    (def up (fn (_ arg) (fn (_ c) (copy-incremental c arg #t))))
    (def down (fn (_ arg) (fn (_ c) (copy-incremental c arg #f))))
    (write (steps (copy-enter h #f #f)
             (list (up "=a") (up "=ab") (up "-ab") (up "+ab") (up "=a") (up "=") (down "=x") (down "+x") (down "+x")
                   (down "-x") (down "=zz")))))
```
---
    ((8 2 "[0/0] (5 results)") (8 2 "[0/0] (5 results)") (4 2 "[0/0] (5 results)") (6 2 "[0/0] (5 results)") (8 2 "[0/0] (5 results)") (0 4 "[0/0]") (1 1 "[0/0] (2 results)") (2 1 "[0/0] (2 results)") (1 1 "[0/0] (2 results)") (0 1 "[0/0] (2 results)") (0 4 "[0/0]"))

### text all in lower case matches either case, else its own; a search that finds nothing lets the matches go

```tmux
(do (copy-count-limit! 0)
    (def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100) "Abc abc ABC\r\nabc\r\n"))
    (def at (fn (_ c) (list (rest (copy-cursor c)) (first (copy-cursor c)) (copy-position c))))
    (def steps
      (fn (_ c fs) (rest (List fold (fn (_ acc f) ((fn (_ n) (pair n (List append (rest acc) (list (at n))))) (do (Heap collect) (f (first acc)))))
                           (pair c ()) fs))))
    (def again (fn (_ c) (copy-do c 'search-again)))
    (write (steps (copy-enter h #f #t)
             (list (fn (_ c) (copy-search c "abc" #f #t)) again again (fn (_ c) (copy-search c "Abc" #f #t)) again
                   (fn (_ c) (copy-search c "ABC" #f #t)) (fn (_ c) (copy-search c "aBc" #t #t))))))
```
---
    ((0 1 "[0/0] (4 results)") (8 0 "[0/0] (4 results)") (4 0 "[0/0] (4 results)") (0 0 "[0/0] (1 results)") (0 0 "[0/0] (1 results)") (8 0 "[0/0] (1 results)") (8 0 "[0/0]"))

### a match runs on into the row a wrap joins; vi's next search starts past the match the cursor is on

```tmux
(do (copy-count-limit! 0)
    (def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100) "abcdefghijklmnopqrstuvwxyz0123\r\nqrst\r\n"))
    (def at (fn (_ c) (list (rest (copy-cursor c)) (first (copy-cursor c)) (copy-position c))))
    (def steps
      (fn (_ c fs) (rest (List fold (fn (_ acc f) ((fn (_ n) (pair n (List append (rest acc) (list (at n))))) (do (Heap collect) (f (first acc)))))
                           (pair c ()) fs))))
    (def again (fn (_ c) (copy-do c 'search-again)))
    (write (steps (copy-enter h #f #t)
             (list (fn (_ c) (copy-search c "stuvw" #f #t)) again (fn (_ c) (copy-search c "s.u" #f #t)) again
                   (fn (_ c) (copy-search c "qrst" #t #t)) again again))))
```
---
    ((18 0 "[0/0] (1 results)") (18 0 "[0/0] (1 results)") (18 0 "[0/0] (1 results)") (18 0 "[0/0] (1 results)") (0 2 "[0/0] (2 results)") (16 0 "[0/0] (2 results)") (0 2 "[0/0] (2 results)"))

### a regular expression: a line's blanks are its end's; one that does not read finds nothing; up, the last of a line's matches one after another

```tmux
(do (copy-count-limit! 0)
    (def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100) "abc one\r\nxx abc\r\nabc abc abc\r\nnone\r\n"))
    (def at (fn (_ c) (list (rest (copy-cursor c)) (first (copy-cursor c)) (copy-position c))))
    (def steps
      (fn (_ c fs) (rest (List fold (fn (_ acc f) ((fn (_ n) (pair n (List append (rest acc) (list (at n))))) (do (Heap collect) (f (first acc)))))
                           (pair c ()) fs))))
    (def again (fn (_ c) (copy-do c 'search-again)))
    (def up (fn (_ text) (fn (_ c) (copy-search c text #f #t))))
    (write (steps (copy-enter h #f #t) (list (up "^xx") (up "b+c") again (up "o.e$") (up "(") (up "n[eo]") again again))))
```
---
    ((0 1 "[0/0] (1 results)") (1 0 "[0/0] (5 results)") (9 2 "[0/0] (5 results)") (9 2 "[0/0]") (9 2 "[0/0]") (5 0 "[0/0] (3 results)") (2 3 "[0/0] (3 results)") (0 3 "[0/0] (3 results)"))

### a match in the history scrolls to it, a quarter of the rows above it

```tmux
(do (copy-count-limit! 0)
    (def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100)
             (Str8 append (spec-lines 1 40) "\r\nend\r\n")))
    (def at (fn (_ c) (list (rest (copy-cursor c)) (first (copy-cursor c)) (copy-position c))))
    (def steps
      (fn (_ c fs) (rest (List fold (fn (_ acc f) ((fn (_ n) (pair n (List append (rest acc) (list (at n))))) (do (Heap collect) (f (first acc)))))
                           (pair c ()) fs))))
    (def again (fn (_ c) (copy-do c 'search-again)))
    (write (steps (copy-enter h #f #t)
             (list (fn (_ c) (copy-search c "7" #f #t)) again again again again (fn (_ c) (copy-search c "end" #t #t))
                   (fn (_ c) (copy-search c "^1$" #f #t)) (fn (_ c) (copy-search c "^2" #f #t)) again
                   (fn (_ c) (copy-do c 'history-bottom)) again))))
```
---
    ((1 0 "[0/36] (4 results)") (1 5 "[15/36] (4 results)") (1 5 "[25/36] (4 results)") (0 5 "[35/36] (4 results)") (1 5 "[5/36] (4 results)") (0 5 "[1/36] (1 results)") (0 5 "[1/36]") (0 5 "[13/36] (11 results)") (0 4 "[13/36] (11 results)") (0 5 "[0/36] (11 results)") (0 5 "[13/36] (11 results)"))

### the matches on the view, the one the cursor is on apart, with emacs's keys after a search down the one before it; a match's rows

```tmux
(do (copy-count-limit! 0)
    (def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100) "abc one\r\nxx abc\r\nabc abc abc\r\nnone\r\n"))
    (def w (spec-feed! vt-feed-pure! (vt-make-history 6 20 100) "abcdefghijklmnopqrstuvwxyz0123\r\n"))
    (write (list (copy-matches (copy-search (copy-enter h #f #t) "abc" #f #t))
                 (copy-matches (copy-search (copy-enter h #f #f) "abc" #t #f))
                 (copy-matches (copy-search (copy-enter w #f #t) "stuvw" #f #t)))))
```
---
    (((0 0 "abc" #f) (1 3 "abc" #f) (2 0 "abc" #f) (2 4 "abc" #f) (2 8 "abc" #t)) ((0 0 "abc" #t) (1 3 "abc" #f) (2 0 "abc" #f) (2 4 "abc" #f) (2 8 "abc" #f)) ((0 18 "st" #t) (1 0 "uvw" #t)))

### vi's * and #: the word at the cursor searched down or up, a wrap carried, the cursor on a separator taking the word after it; none on a blank row

```tmux
(do (copy-count-limit! 0)
    (def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100) "foo.bar foo\r\nbar_x foo-bar\r\nabcdefghijklmnopqrstfoo\r\n"))
    (def at (fn (_ c) (list (rest (copy-cursor c)) (first (copy-cursor c)) (copy-position c))))
    (def steps
      (fn (_ c fs) (rest (List fold (fn (_ acc f) ((fn (_ n) (pair n (List append (rest acc) (list (at n))))) (do (Heap collect) (f (first acc)))))
                           (pair c ()) fs))))
    (def k (fn (_ cmd) (fn (_ c) (copy-do c cmd))))
    (write (list
      (steps (copy-enter h #f #t)
        (list (k 'search-word-down) (k 'up) (k 'search-word-down) (k 'search-word-up) (k 'up) (k 'right) (k 'right) (k 'right)
              (k 'search-word-down) (k 'search-word-up) (k 'history-top) (k 'search-word-down) (k 'search-word-down)
              (k 'search-word-up)))
      (steps (copy-enter h #f #t)
        (list (k 'history-top) (k 'right) (k 'right) (k 'right) (k 'search-word-down) (k 'search-word-down)
              (k 'search-word-down) (k 'search-word-up) (k 'end-of-line) (k 'left) (k 'left) (k 'left) (k 'search-word-up)
              (k 'search-again))))))
```
---
    (((0 4 "[0/0]") (2 3 "[0/0]") (0 2 "[0/0] (1 results)") (0 2 "[0/0] (1 results)") (0 1 "[0/0] (1 results)") (1 1 "[0/0] (1 results)") (2 1 "[0/0] (1 results)") (3 1 "[0/0] (1 results)") (0 1 "[0/0] (1 results)") (0 1 "[0/0] (1 results)") (0 0 "[0/0] (1 results)") (8 0 "[0/0] (4 results)") (6 1 "[0/0] (4 results)") (8 0 "[0/0] (4 results)")) ((0 0 "[0/0]") (1 0 "[0/0]") (2 0 "[0/0]") (3 0 "[0/0]") (4 0 "[0/0] (3 results)") (0 1 "[0/0] (3 results)") (0 1 "[0/0] (1 results)") (0 1 "[0/0] (1 results)") (12 1 "[0/0] (1 results)") (11 1 "[0/0] (1 results)") (10 1 "[0/0] (1 results)") (9 1 "[0/0] (1 results)") (0 1 "[0/0] (3 results)") (4 0 "[0/0] (3 results)")))

### the keys: emacs's C-s C-r n N, vi's / ? n N * #

```tmux
(write (list (List map (fn (_ t) ((fn (_ b) (first (copy-key (%spec-str->ptr (first b)) 0 (rest b) #f))) (spec-bytes t)))
               (list "\x13" "\x12" "n" "N"))
             (List map (fn (_ t) ((fn (_ b) (first (copy-key (%spec-str->ptr (first b)) 0 (rest b) #t))) (spec-bytes t)))
               (list "/" "?" "n" "N" "*" "#"))))
```
---
    (('incremental-down 'incremental-up 'search-again 'search-reverse) ('prompt-down 'prompt-up 'search-again 'search-reverse 'search-word-down 'search-word-up))
