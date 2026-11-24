# Capture
# @weight 1

tmux/capture: a screen's lines as tmux 3.8's capture-pane writes them,
the lines -S and -E name, plain, with -e's codes, with -C's escapes, and
with -J and -N, which read what each line holds and whether it wrapped.
Each case is what tmux 3.8 writes for a pane of the same size given the
same bytes.  In a case's string, ^ is ESC.

## the lines -S and -E name

### a 6-row screen with 4 rows of history: the screen, a span of both, the history, swapped, held to the lines there are, and a word that is no number

```tmux
(def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100) "l1\r\nl2\r\nl3\r\nl4\r\nl5\r\nl6\r\nl7\r\nl8\r\nl9\r\n"))
(def lines (fn (_ s e) (capture-lines h (capture-range h s e) #f #f #f #f)))
(write (list (lines () ()) (lines "-2" "1") (lines "-" "-1") (lines "4" "2") (lines "100" ()) (lines () "-100") (lines "x" "0")))
```
---
    (("l5" "l6" "l7" "l8" "l9" "") ("l3" "l4" "l5" "l6") ("l1" "l2" "l3" "l4") ("l7" "l8" "l9") ("") ("l1" "l2" "l3" "l4" "l5") ("l5"))

## -e

### each change of style as tmux writes it: a 0 when an attribute goes, the colours apart, the default again at the first cell a line holds and did not write

```tmux
(def esc (first (spec-bytes "^")))
(def shown (fn (_ s) (if (null? (Str8 index-of esc s)) s (Str8 join "^" (Str8 split esc s)))))
(def h (spec-feed! vt-feed-pure! (vt-make-history 10 30 100)
  (Str8 append "a^[1mb^[22mc\r\n" "^[1;31mbr^[0mn\r\n" "^[38;5;100mx^[48;2;1;2;3my^[m\r\n"
    "^[7mrv^[27m^[4mul^[24m^[3mit^[m\r\n" "^[32mgreen to end\r\n" "still^[m\r\n" "^[44m   ^[m|\r\n"
    "^[95mbright^[m^[2;9mdimstrike^[m\r\n" "wide中x\r\n")))
(write (List map shown (capture-lines h (capture-range h () ()) #t #f #f #f)))
```
---
    ("a^[1mb^[0mc" "^[1m^[31mbr^[0mn" "^[38;5;100mx^[48;2;1;2;3my^[39m^[49m" "^[7mrv^[0;4mul^[0;3mit^[0m" "^[32mgreen to end^[39m" "^[32mstill^[39m" "^[44m   ^[49m|" "^[95mbright^[2;9m^[39mdimstrike^[0m" "wide中x" "")

### trailing spaces: plain, dropped; with -e, dropped only in the default style

```tmux
(def esc (first (spec-bytes "^")))
(def shown (fn (_ s) (if (null? (Str8 index-of esc s)) s (Str8 join "^" (Str8 split esc s)))))
(def h (spec-feed! vt-feed-pure! (vt-make-history 3 30 100) "bg^[44m  ^[m\r\nrv^[7m  ^[m\r\nplain   "))
(write (list (capture-lines h (capture-range h () ()) #f #f #f #f) (List map shown (capture-lines h (capture-range h () ()) #t #f #f #f))))
```
---
    (("bg" "rv" "plain") ("bg^[44m  ^[49m" "rv^[7m  ^[0m" "plain"))

## -a

### the screen under the alternate one, with no history; none when the alternate screen is not on

```tmux
(def h (spec-feed! vt-feed-pure! (vt-make-history 3 20 100) "h1\r\nh2\r\nh3\r\nmain\r\n^[?1049halt"))
(def a (vt-alternate h))
(write (list (capture-lines a (capture-range a "-" ()) #f #f #f #f) (capture-lines h (capture-range h () ()) #f #f #f #f)
  (vt-alternate (spec-feed! vt-feed-pure! (vt-make-history 3 20 100) "x"))))
```
---
    (("h3" "main" "") ("" "" "alt") ())

## -J and -N

### a line to the cells it holds, a quarter of the width, a half or all of it, or with -J to its last cell written, an erase keeping it; -e's style carried from line to line

```tmux
(def esc (first (spec-bytes "^")))
(def shown (fn (_ s) (if (null? (Str8 index-of esc s)) s (Str8 join "^" (Str8 split esc s)))))
(def h (spec-feed! vt-feed-pure! (vt-make-history 6 20 100)
  "bg^[44m  ^[m\r\nabcdefghijklmnopqrstuvwxyz\r\nab  \r\nabc^[2D^[K\r\n^[1mx^[m"))
(def lines (fn (_ codes join keep) (List map shown (capture-lines h (capture-range h () ()) codes #f join keep))))
(write (list (lines #f #f #f) (lines #t #f #f) (lines #f #t #f) (lines #f #f #t) (lines #t #f #t) (lines #t #t #f)))
```
---
    (("bg" "abcdefghijklmnopqrst" "uvwxyz" "ab" "a" "x") ("bg^[44m  ^[49m" "abcdefghijklmnopqrst" "uvwxyz" "ab" "a" "^[1mx^[0m") ("bg  " "abcdefghijklmnopqrstuvwxyz" "ab  " "a  " "x") ("bg   " "abcdefghijklmnopqrst" "uvwxyz    " "ab   " "a    " "x    ") ("bg^[44m  ^[49m " "abcdefghijklmnopqrst" "uvwxyz    " "ab   " "a    " "^[1mx^[0m    ") ("bg^[44m  " "^[49mabcdefghijklmnopqrstuvwxyz" "ab  " "a  " "^[1mx"))

### a line wrapped into the history joined to its rest; an erase of a whole line unwrapping the one above, and emptying its own

```tmux
(def h (spec-feed! vt-feed-pure! (vt-make-history 3 10 100)
  "0123456789abcdef\r\nx\r\ny\r\nAAAAAAAAAABB^[2K^[1A^[2Kq^[1B"))
(def lines (fn (_ join keep) (capture-lines h (capture-range h "-" ()) #f #f join keep)))
(write (list (lines #f #f) (lines #t #f) (lines #f #t)))
```
---
    (("0123456789" "abcdef" "x" "y" "  q" "") ("0123456789abcdef" "x" "y" "  q" "") ("0123456789" "abcdef    " "x " "y " "  q  " ""))

## -C

### a backslash written twice, and a code's ESC as \033

```tmux
(def h (spec-feed! vt-feed-pure! (vt-make-history 2 20 100) "a\\b\r\n^[1mB^[m"))
(write (list (capture-lines h (capture-range h () ()) #f #t #f #f) (capture-lines h (capture-range h () ()) #t #t #f #f)))
```
---
    (("a\\\\b" "B") ("a\\\\b" "\\033[1mB\\033[0m"))
