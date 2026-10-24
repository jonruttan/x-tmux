# The compiled screen
# @requires native/jit
# @weight 3

tmux/vt-jit's engine against tmux/vt's: the same exercise fed to a screen
by each, in reads of a given size, both screens rendered after every
read, and compared -- every row's cells and attributes, the cursor, and
the bytes each render wrote.  vt-agree answers #t, or the byte offset
after the first read they disagree on.

An exercise is N random operations from a seed: printable runs, carriage
returns and line feeds, backspace and tab, CSI sequences with up to two
parameters (some empty) for every final the screen reads, ESC 7 8 M D E,
an OSC title, a charset designation, the alternate screen (?1049, ?47,
?1047), a two-byte UTF-8 character.  Reads of a few bytes end inside
sequences.

## building

### the engine builds, agrees with tmux/vt's on its own exercises, and is adopted

```tmux
(write (list (vt-jit!) (vt-compiled?)))
```
---
    (#t #t)

## agreement

### four exercises in 4096-byte reads

```tmux
(do (def e (vt-jit-make))
    (write (List map (fn (_ seed) (vt-agree e (vt-exercise seed 500) 4096)) (list 3 4 5 6))))
```
---
    (#t #t #t #t)

### two exercises in 777-byte reads

```tmux
(do (def e (vt-jit-make))
    (write (List map (fn (_ seed) (vt-agree e (vt-exercise seed 500) 777)) (list 7 8))))
```
---
    (#t #t)

### an exercise in 7-byte reads, nearly every sequence split

```tmux
(do (def e (vt-jit-make))
    (write (vt-agree e (vt-exercise 9 120) 7)))
```
---
    #t

## the cases tmux pins

### the screen spec's cases past the last column, by the compiled engine

```tmux
(do (vt-jit!)
    (def a (Str8 pad-right 80 #\a ""))
    (write (List map (fn (_ t) (spec-rows (spec-screen vt-feed! (Str8 append a t))))
             (list "\x08X" "^[1DX" "^[1X" "^[K" "^[1@" "^[1P" "\nX" "\tX" "^7^[5;5H^8X"))))
```
---
    (((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX") ('cursor 0 80)) ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX") ('cursor 0 80)) ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") ('cursor 0 80)) ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") ('cursor 0 80)) ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") ('cursor 0 80)) ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") ('cursor 0 80)) ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") (2 "X") ('cursor 2 1)) ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") (1 "X") ('cursor 1 1)) ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX") ('cursor 0 80)))

### the alternate-screen cases, by the compiled engine

```tmux
(do (vt-jit!)
    (write (List map (fn (_ t) (spec-rows (spec-screen vt-feed! t)))
             (list "main^[?1049halt^[?1049l" "main^[5;5H^[?1049h^[1;1Hx^[?1049ly" "main^[5;5H^[?47h^[1;1Hx^[?47ly" "main^[?1047halt^[?1047l" "main^[?1049ha^[?1049hb^[?1049l" "main^[?47ha^[?1049l"))))
```
---
    (((0 "main") ('cursor 0 4)) ((0 "main") (4 "    y") ('cursor 4 5)) ((0 "myin") ('cursor 0 2)) ((0 "main") ('cursor 0 7)) ((0 "main") ('cursor 0 4)) ((0 "main") ('cursor 0 5)))
