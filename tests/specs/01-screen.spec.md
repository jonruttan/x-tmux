# The screen
# @weight 2

tmux/vt's engine, the reference: what a 24x80 screen holds after the bytes
a program writes.  Each case is what tmux 3.8 shows for the same bytes in
an 80x24 pane (output processing off, so a line feed is only a line
feed): the rows that are not blank, their trailing blanks dropped, and
the cursor.  In a case's string, ^ is ESC.

tmux's cursor runs to column 80: a row just filled leaves it there, and
the next byte printed wraps first.  The cases past the last column pin
what every sequence does from there.

## text and controls

### text, carriage returns and line feeds

```tmux
(write (spec-vt "one\r\ntwo\r\nthree"))
```
---
    ((0 "one") (1 "two") (2 "three") ('cursor 2 5))

### a line feed alone keeps the column

```tmux
(write (spec-vt "ab\ncd"))
```
---
    ((0 "ab") (1 "  cd") ('cursor 1 4))

### a row filled wraps the next byte to the next row

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 78 #\a "") "bcde")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabc") (1 "de") ('cursor 1 2))

### a filled row leaves the cursor past the last column, and an erase there touches nothing

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "^[K")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") ('cursor 0 80))

### backspace and tab

```tmux
(write (spec-vt "abc\x08X\tY"))
```
---
    ((0 "abX     Y") ('cursor 0 9))

## the cursor

### CUP places the cursor, and keeps it on the screen

```tmux
(write (spec-vt "^[5;10Hhere^[2;3Hx^[99;99Hz"))
```
---
    ((1 "  x") (4 "         here") (23 "                                                                               z") ('cursor 23 80))

### CUU CUD CUF CUB move from the cursor

```tmux
(write (spec-vt "^[10;10H^[3Aup^[2Bdn^[5Cr^[20Dl"))
```
---
    ((6 "         up") (8 "l          dn     r") ('cursor 8 1))

### CHA sets the column, VPA the row

```tmux
(write (spec-vt "^[10Gg^[7dv"))
```
---
    ((0 "         g") (6 "          v") ('cursor 6 11))

### DECSC and DECRC save and restore the cursor

```tmux
(write (spec-vt "^[5;5H^7^[1;1Hx^8y"))
```
---
    ((0 "x") (4 "    y") ('cursor 4 5))

## erasing

### EL 0 erases to the row's end

```tmux
(write (spec-vt "abcdefgh^[1;4H^[K"))
```
---
    ((0 "abc") ('cursor 0 3))

### EL 1 erases to the cursor

```tmux
(write (spec-vt "abcdefgh^[1;4H^[1K"))
```
---
    ((0 "    efgh") ('cursor 0 3))

### EL 2 erases the row

```tmux
(write (spec-vt "abcdefgh^[1;4H^[2K"))
```
---
    (('cursor 0 3))

### ED 0 erases to the screen's end

```tmux
(write (spec-vt "row1\r\nrow2\r\nrow3^[2;2H^[J"))
```
---
    ((0 "row1") (1 "r") ('cursor 1 1))

### ED 1 erases to the cursor

```tmux
(write (spec-vt "row1\r\nrow2\r\nrow3^[2;2H^[1J"))
```
---
    ((1 "  w2") (2 "row3") ('cursor 1 1))

### ED 2 erases the screen

```tmux
(write (spec-vt "row1\r\nrow2\r\nrow3^[2;2H^[2J"))
```
---
    (('cursor 1 1))

### ECH erases characters in place

```tmux
(write (spec-vt "abcdefgh^[1;3H^[3X"))
```
---
    ((0 "ab   fgh") ('cursor 0 2))

## characters

### ICH inserts blanks, pushing the rest right

```tmux
(write (spec-vt "abcdefgh^[1;3H^[2@"))
```
---
    ((0 "ab  cdefgh") ('cursor 0 2))

### DCH deletes characters, pulling the rest left

```tmux
(write (spec-vt "abcdefgh^[1;3H^[2P"))
```
---
    ((0 "abefgh") ('cursor 0 2))

## scrolling

### a line feed on the bottom row scrolls the screen

```tmux
(write (spec-vt "top^[24;1Hlast\nnext"))
```
---
    ((22 "last") (23 "    next") ('cursor 23 8))

### DECSTBM sets a region a line feed scrolls within

```tmux
(write (spec-vt "a\r\nb\r\nc\r\nd^[2;3r^[3;1H\n\nX"))
```
---
    ((0 "a") (2 "X") (3 "d") ('cursor 2 1))

### IL inserts lines in the region

```tmux
(write (spec-vt "a\r\nb\r\nc^[2;1H^[L"))
```
---
    ((0 "a") (2 "b") (3 "c") ('cursor 1 0))

### DL deletes lines in the region

```tmux
(write (spec-vt "a\r\nb\r\nc^[2;1H^[M"))
```
---
    ((0 "a") (1 "c") ('cursor 1 0))

### RI on the top row scrolls the screen down

```tmux
(write (spec-vt "a\r\nb^[1;1H^MX"))
```
---
    ((0 "X") (1 "a") (2 "b") ('cursor 0 1))

### a region whose top is not above its bottom is ignored

```tmux
(write (spec-vt "top^[26r^[24;1Hz\n"))
```
---
    ((22 "z") ('cursor 23 1))

## strings

### an OSC string is swallowed to its BEL

```tmux
(write (spec-vt "a^]0;title\x07b"))
```
---
    ((0 "ab") ('cursor 0 2))

## past the last column

### backspace past the last column comes back to it

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "\x08X")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX") ('cursor 0 80))

### CUB past the last column counts from it

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "^[1DX")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX") ('cursor 0 80))

### CUF past the last column holds the last column

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "^[1CX")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX") ('cursor 0 80))

### CHA past the last column

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "^[1GX")))
```
---
    ((0 "Xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") ('cursor 0 1))

### ECH past the last column erases nothing

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "^[1X")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") ('cursor 0 80))

### EL 0 past the last column erases nothing

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "^[K")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") ('cursor 0 80))

### EL 1 past the last column erases the row

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "^[1K")))
```
---
    (('cursor 0 80))

### ICH past the last column inserts nothing

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "^[1@")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") ('cursor 0 80))

### DCH past the last column deletes nothing

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "^[1P")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") ('cursor 0 80))

### a carriage return past the last column

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "\rX")))
```
---
    ((0 "Xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") ('cursor 0 1))

### a line feed past the last column keeps it there, and the next byte wraps

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "\nX")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") (2 "X") ('cursor 2 1))

### a tab past the last column stays

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "\tX")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") (1 "X") ('cursor 1 1))

### DECRC brings a cursor saved past the last column back onto it

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "^7^[5;5H^8X")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX") ('cursor 0 80))

### CUU past the last column comes back onto it

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "\n^[1AX")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX") ('cursor 0 80))

## attributes

### SGR kept as a cell's attribute byte: 1, plus 1 bold, 2 reverse, 4(N+1) a foreground N, 64 a background

```tmux
(do (def h (spec-screen vt-feed-pure! "^[1;31mA^[0mB^[7mC^[42mD^[39mE^[mF"))
    (write (spec-attrs h 0 6)))
```
---
    (10 1 3 67 67 1)

## the render

### a new screen's first render writes every row

```tmux
(write (vt-render-pure! (vt-make 24 80)))
```
---
    2175

### a render writes the rows marked since the last, a cursor move and then each run of one attribute behind its SGR; the next writes nothing

```tmux
(do (def h (vt-make 24 80))
    (vt-render-pure! h)
    (spec-feed! vt-feed-pure! h "ab^[31mc^[3;1Hz")
    (def n (vt-render-pure! h))
    (write (list (spec-rendered h n) (vt-render-pure! h))))
```
---
    ("^[1;1H^[0mab^[0;31mc^[0m                                                                             ^[3;1H^[0;31mz^[0m                                                                               " 0)
