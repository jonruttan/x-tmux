# Buffers
# @weight 1

tmux/paste, the paste buffers as tmux 3.8's paste.c keeps them, and
tmux/tree, the list buffer mode draws, as its mode-tree.c draws one.
Each case is what tmux 3.8 gives for the same buffers: their names and
order from `list-buffers`, a sample as it writes one, and the list as
`choose-buffer` draws it in an 80x24 pane.  In a case's string, ^ is ESC.

## the store

### automatic buffers are named bufferN, the newest first; one set by name is not automatic, and the newest automatic one is the top

```tmux
(import tmux/paste paste-empty paste-buffers paste-name paste-add paste-set paste-top)
(def s0 (paste-add (paste-add paste-empty "one" 50 1) "two" 50 2))
(def s2 (paste-add (first (paste-set s0 "a named" "named" 50 3)) "three" 50 4))
(write (list (List map paste-name (paste-buffers s2)) (paste-name (paste-top s2))))
```
---
    (("buffer2" "named" "buffer1" "buffer0") "buffer2")

### sorted by creation, name or size, a tie by name, -r turning it about

```tmux
(import tmux/paste paste-empty paste-name paste-add paste-sorted)
(def s (paste-add (paste-add paste-empty "one" 50 1) "three" 50 2))
(write (List map (fn (_ o) (List map paste-name (paste-sorted s (first o) (rest o))))
  (list (pair 'creation #f) (pair 'name #f) (pair 'size #t) (pair 'size #f))))
```
---
    (("buffer1" "buffer0") ("buffer0" "buffer1") ("buffer1" "buffer0") ("buffer0" "buffer1"))

### past the limit the oldest automatic buffer goes, the names going on

```tmux
(import tmux/paste paste-empty paste-buffers paste-name paste-add)
(write (List map paste-name (paste-buffers (List fold (fn (_ s i) (paste-add s "z" 3 i)) paste-empty (list 1 2 3 4 5)))))
```
---
    ("buffer4" "buffer3" "buffer2")

### a name with a control character is refused, a rename takes the buffer out of the automatic ones in its place

```tmux
(import tmux/paste paste-empty paste-buffers paste-name paste-add paste-set paste-rename paste-top)
(def s (paste-add (paste-add paste-empty "one" 50 1) "two" 50 2))
(def r (first (paste-rename s "buffer1" "z")))
(write (list (rest (paste-set s "x" "tab\tx" 50 5)) (rest (paste-set s "x" "" 50 5)) (rest (paste-rename s "nosuch" "y"))
  (List map paste-name (paste-buffers r)) (paste-name (paste-top r))))
```
---
    ("invalid buffer name: tab\tx" "empty buffer name" "no buffer nosuch" ("z" "buffer0") "buffer0")

### a sample: a tab, a newline, a backslash and a control byte as C writes them, UTF-8 as it is, "..." past 200 bytes

```tmux
(import tmux/paste paste-sample)
(def esc (first (spec-bytes "^")))
(def b (fn (_ data) (list "b" data #t 0 0)))
(write (list (paste-sample (b (Str8 append "a\tb" esc "c\\d"))) (paste-sample (b "two\nlines 中"))
  (Str8 length (paste-sample (b (Str8 pad-right 205 #\y ""))))))
```
---
    ("a\\tb\\033c\\\\d" "two\\nlines 中" 203)

## the list

### each buffer led by its key, the preview's box under the list titled with the selected one and the order

```tmux
(import tmux/tree tree-enter tree-screen)
(def items (list (list "b2" "buffer2" "18:19: third") (list "n" "named" "18:19: a named buffer")
                 (list "b1" "buffer1" "18:19: second\\nline two") (list "b0" "buffer0" "18:19: first one")))
(def t (tree-enter (fn (_ o r) items) (fn (_ tag cols rows) (list "third")) 24 80 (list 'creation 'name 'size) () #f 'normal))
(write (List map (fn (_ r) (Str8 trim-right (vt-row (tree-screen t) r))) (list 0 1 3 4 12 13 14 23)))
```
---
    ("(0) buffer2: 18:19: third" "(1) named: 18:19: a named buffer" "(3) buffer0: 18:19: first one" "" "┌ buffer2 (sort: creation) ────────────────────────────────────────────────────┐" "│ third                                                                        │" "│                                                                              │" "└──────────────────────────────────────────────────────────────────────────────┘")

### t tags a buffer and goes down: its name and text cyan, the key and the colon grey, the selected row black on yellow

```tmux
(import tmux/tree tree-enter tree-key tree-screen tree-tagged)
(def items (list (list "b2" "buffer2" "18:19: third") (list "n" "named" "18:19: a named buffer")))
(def t (first (tree-key (tree-enter (fn (_ o r) items) (fn (_ tag cols rows) ()) 24 80 (list 'creation 'name 'size) () #f 'normal) "t")))
(def esc (first (spec-bytes "^")))
(def shown (fn (_ s) (if (null? (Str8 index-of esc s)) s (Str8 join "^" (Str8 split esc s)))))
(write (list (tree-tagged t) (List map shown (capture-lines (tree-screen t) (capture-range (tree-screen t) "0" "1") #t #f #f #f))))
```
---
    (("b2") ("^[37m(0) ^[36mbuffer2*^[37m: ^[36m18:19: third^[39m" "^[30m^[43m(1) named: 18:19: a named buffer"))

### a buffer's key picks it as Enter; q ends the mode; O sorts the next way; v hides the preview, then makes it big

```tmux
(import tmux/tree tree-enter tree-key tree-screen tree-current tree-order)
(def items (list (list "b2" "buffer2" "x") (list "n" "named" "y") (list "b1" "buffer1" "z") (list "b0" "buffer0" "w")))
(def t (tree-enter (fn (_ o r) items) (fn (_ tag cols rows) ()) 24 80 (list 'creation 'name 'size) () #f 'normal))
(def picked (tree-key t "2"))
(def row (fn (_ t r) (Str8 trim-right (vt-row (tree-screen t) r))))
(def off (first (tree-key t "v")))
(def big (first (tree-key off "v")))
(write (list (tree-current (first picked)) (List ref 2 picked) (List ref 1 (tree-key t "q"))
  (tree-order (first (tree-key t "O"))) (row (first (tree-key t "O")) 12) (row off 12) (row big 4)))
```
---
    ("b1" "Enter" #t 'name "┌ buffer2 (sort: name) ────────────────────────────────────────────────────────┐" "" "┌ buffer2 (sort: creation) ────────────────────────────────────────────────────┐")

### the list wraps from the top to the bottom; a pane of 12 rows has no room for the preview

```tmux
(import tmux/tree tree-enter tree-key tree-screen tree-current)
(def items (list (list "b2" "buffer2" "x") (list "n" "named" "y") (list "b1" "buffer1" "z") (list "b0" "buffer0" "w")))
(def t (tree-enter (fn (_ o r) items) (fn (_ tag cols rows) ()) 12 80 (list 'creation 'name 'size) () #f 'normal))
(write (list (tree-current (first (tree-key t "Up"))) (tree-current (first (tree-key (first (tree-key t "End")) "Down")))
  (Str8 trim-right (vt-row (tree-screen t) 6))))
```
---
    ("b0" "b2" "")
