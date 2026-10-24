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

### a render at an origin puts each row's cursor move where the screen sits on the terminal

```tmux
(do (def h (vt-origin! (vt-make 2 10) 12 41))
    (spec-feed! vt-feed-pure! h "ab")
    (def n (vt-render-pure! h))
    (write (spec-rendered h n)))
```
---
    "^[13;42H^[0mab        ^[14;42H^[0m          "

### a screen carried to a new size keeps its cells where they fit, its cursor and its origin

```tmux
(do (def h (vt-origin! (spec-screen vt-feed-pure! "one\r\ntwo\r\nthree") 3 4))
    (def n (vt-carry h 2 3))
    (write (list (spec-rows n) (vt-size n))))
```
---
    (((0 "one") (1 "two") ('cursor 1 3)) (2 . 3))

## the alternate screen

### ?1049l brings the main screen back

```tmux
(write (spec-vt "main^[?1049halt^[?1049l"))
```
---
    ((0 "main") ('cursor 0 4))

### ?1049h shows a cleared screen, the cursor where it was

```tmux
(write (spec-vt "main^[?1049h"))
```
---
    (('cursor 0 4))

### ?1049l puts the cursor back where ?1049h found it

```tmux
(write (spec-vt "main^[5;5H^[?1049h^[1;1Hx^[?1049ly"))
```
---
    ((0 "main") (4 "    y") ('cursor 4 5))

### ?47h shows a cleared screen

```tmux
(write (spec-vt "main^[?47halt"))
```
---
    ((0 "    alt") ('cursor 0 7))

### ?47l brings the main screen back, the cursor left where it is

```tmux
(write (spec-vt "main^[?47halt^[?47l"))
```
---
    ((0 "main") ('cursor 0 7))

### ?47l restores no cursor

```tmux
(write (spec-vt "main^[5;5H^[?47h^[1;1Hx^[?47ly"))
```
---
    ((0 "myin") ('cursor 0 2))

### ?1047h shows a cleared screen

```tmux
(write (spec-vt "main^[?1047halt"))
```
---
    ((0 "    alt") ('cursor 0 7))

### ?1047l brings the main screen back

```tmux
(write (spec-vt "main^[?1047halt^[?1047l"))
```
---
    ((0 "main") ('cursor 0 7))

### ?1047l restores no cursor

```tmux
(write (spec-vt "main^[5;5H^[?1047h^[1;1Hx^[?1047ly"))
```
---
    ((0 "myin") ('cursor 0 2))

### an h with the alternate screen up does nothing

```tmux
(write (spec-vt "main^[?1049ha^[?1049hb^[?1049l"))
```
---
    ((0 "main") ('cursor 0 4))

### an l with it down does nothing

```tmux
(write (spec-vt "main^[?1049lz"))
```
---
    ((0 "mainz") ('cursor 0 5))

### the alternate screen shown again is cleared again

```tmux
(write (spec-vt "main^[?1049ha^[?1049l^[?1049hb"))
```
---
    ((0 "    b") ('cursor 0 5))

### ?1049l after ?47h restores the screen, but no cursor was saved

```tmux
(write (spec-vt "main^[?47ha^[?1049l"))
```
---
    ((0 "main") ('cursor 0 5))

### the scroll region holds across the switch

```tmux
(write (spec-vt "^[2;5r^[?1049h^[5;1Hr5\nnext^[?1049l^[5;1H\nafter"))
```
---
    ((4 "after") ('cursor 4 5))

### DECRC in the alternate screen, then ?1049l's own restore

```tmux
(write (spec-vt "^[3;3H^7^[?1049h^[1;1H^8m^[?1049l"))
```
---
    (('cursor 2 2))

### DECSC's save is its own, not ?1049's

```tmux
(write (spec-vt "^[?1049h^[3;3H^7^[?1049l^[1;1H^8n"))
```
---
    ((2 "  n") ('cursor 2 3))

### ?1049 saves the attribute with the cursor and restores both

```tmux
(do (def h (spec-screen vt-feed-pure! "^[31mred^[?1049h^[0mA^[?1049lX"))
    (write (spec-attrs h 0 4)))
```
---
    (9 9 9 9)

### the alternate screen is cleared with the default attribute, not the current one

```tmux
(do (def h (spec-screen vt-feed-pure! "^[42m^[?1049hA"))
    (write (spec-attrs h 0 3)))
```
---
    (65 1 1)

## UTF-8

A character past ASCII is read from its UTF-8 bytes and takes the cells its
width gives, as tmux 3.8 takes them; a row is written as capture-pane writes
it, padding as nothing.

### a precomposed character is one cell

```tmux
(write (spec-vt "\xc3\xa9x"))
```
---
    ((0 "éx") ('cursor 0 2))

### a wide character is two cells

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xacx"))
```
---
    ((0 "日本x") ('cursor 0 5))

### an emoji is two cells

```tmux
(write (spec-vt "\xf0\x9f\x98\x80x"))
```
---
    ((0 "😀x") ('cursor 0 3))

### a combining mark joins the character before it

```tmux
(write (spec-vt "e\xcc\x81x"))
```
---
    ((0 "éx") ('cursor 0 2))

### a combining mark at the row's start is dropped

```tmux
(write (spec-vt "\xcc\x81x"))
```
---
    ((0 "x") ('cursor 0 1))

### a wide character with one column left wraps first

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 79 #\a "") "\xe6\x97\xa5")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") (1 "日") ('cursor 1 2))

### a wide character fits the last two columns

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 78 #\a "") "\xe6\x97\xa5")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa日") ('cursor 0 80))

### printing over a wide character's right half blanks its left

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;2HX"))
```
---
    ((0 " X本") ('cursor 0 2))

### printing over its left half blanks its right

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;1HX"))
```
---
    ((0 "X 本") ('cursor 0 1))

### EL from a wide character's right half leaves the character

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;2H^[K"))
```
---
    ((0 "日") ('cursor 0 1))

### EL 1 to a wide character's right half

```tmux
(write (spec-vt "ab\xe6\x97\xa5\xe6\x9c\xac^[1;4H^[1K"))
```
---
    ((0 "    本") ('cursor 0 3))

### DCH 1 on a wide character

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;1H^[1P"))
```
---
    ((0 "本") ('cursor 0 0))

### ICH on a wide character's right half

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;2H^[1@"))
```
---
    ((0 "日 本") ('cursor 0 1))

### ECH on a wide character's right half

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;2H^[1X"))
```
---
    ((0 "日 本") ('cursor 0 1))

### each byte no character starts with is U+FFFD

```tmux
(write (spec-vt "a\xff\xfeb"))
```
---
    ((0 "a��b") ('cursor 0 4))

### a two-byte character cut short is U+FFFD, then the byte that cut it

```tmux
(write (spec-vt "a\xc3xb"))
```
---
    ((0 "a�xb") ('cursor 0 4))

### a three-byte character cut short is one U+FFFD

```tmux
(write (spec-vt "a\xe6\x97xb"))
```
---
    ((0 "a�xb") ('cursor 0 4))

### a lone continuation byte is U+FFFD

```tmux
(write (spec-vt "a\x80b"))
```
---
    ((0 "a�b") ('cursor 0 3))

### backspace over a wide character, then printing over its left half

```tmux
(write (spec-vt "\xe6\x97\xa5\x08\x08X"))
```
---
    ((0 "X") ('cursor 0 1))

### a zero-width space joins the character before it

```tmux
(write (spec-vt "a\xe2\x80\x8bb"))
```
---
    ((0 "a​b") ('cursor 0 2))

### U+FE0F widens a heart to two cells

```tmux
(write (spec-vt "\xe2\x9d\xa4\xef\xb8\x8fx"))
```
---
    ((0 "❤️x") ('cursor 0 3))

### CUF onto a wide character's right half, then printing there

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;1H^[1CX"))
```
---
    ((0 " X本") ('cursor 0 2))

### a wide character after a filled row wraps

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 79 #\a "") "b\xe6\x97\xa5")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab") (1 "日") ('cursor 1 2))

### DCH 1 on a wide character's left half leaves its padding

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;1H^[1P^[1;8H#"))
```
---
    ((0 "本    #") ('cursor 0 8))

### DCH 1 on its right half leaves the character

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;2H^[1P^[1;8H#"))
```
---
    ((0 "日本    #") ('cursor 0 8))

### ICH on its right half moves the padding with the cells

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;2H^[1@^[1;8H#"))
```
---
    ((0 "日 本  #") ('cursor 0 8))

### ICH on its left half moves the whole character

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;1H^[1@^[1;8H#"))
```
---
    ((0 " 日本  #") ('cursor 0 8))

### EL from its right half, the rest of the row blank

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;2H^[K^[1;8H#"))
```
---
    ((0 "日      #") ('cursor 0 8))

### ECH 1 on its right half

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;2H^[1X^[1;8H#"))
```
---
    ((0 "日 本   #") ('cursor 0 8))

### ECH 1 on its left half leaves its padding

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;1H^[1X^[1;8H#"))
```
---
    ((0 " 本   #") ('cursor 0 8))

### EL 1 to a wide character's left half

```tmux
(write (spec-vt "\xe6\x97\xa5\xe6\x9c\xac^[1;3H^[1K^[1;8H#"))
```
---
    ((0 "      #") ('cursor 0 8))

### U+FE0F widens a heart, the next cell its padding

```tmux
(write (spec-vt "\xe2\x9d\xa4\xef\xb8\x8f^[1;8H#"))
```
---
    ((0 "❤️     #") ('cursor 0 8))

### U+FE0F at the last column cannot widen

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 79 #\a "") "\xe2\x9d\xa4\xef\xb8\x8fz")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa❤️") (1 "z") ('cursor 1 1))

### a combining mark after a filled row joins its last character

```tmux
(write (spec-vt (Str8 append (Str8 pad-right 80 #\a "") "\xcc\x81z")))
```
---
    ((0 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaá") (1 "z") ('cursor 1 1))

### a combining mark joins a wide character

```tmux
(write (spec-vt "\xe6\x97\xa5\xcc\x81x"))
```
---
    ((0 "日́x") ('cursor 0 3))

### a render writes a wide character once, its padding as nothing

```tmux
(do (def h (vt-make 24 80))
    (vt-render-pure! h)
    (spec-feed! vt-feed-pure! h "\xe6\x97\xa5a")
    (write (spec-rendered h (vt-render-pure! h))))
```
---
    "^[1;1H^[0m日a                                                                             "

### a wide character with no padding after it is followed by a move to the next cell

```tmux
(do (def h (vt-make 24 80))
    (vt-render-pure! h)
    (spec-feed! vt-feed-pure! h "\xe6\x97\xa5\xe6\x9c\xac^[1;2H^[1X")
    (write (spec-rendered h (vt-render-pure! h))))
```
---
    "^[1;1H^[0m日^[1;2H 本                                                                            "

### padding with no wide character before it is written as a blank

```tmux
(do (def h (vt-make 24 80))
    (vt-render-pure! h)
    (spec-feed! vt-feed-pure! h "\xe6\x97\xa5\xe6\x9c\xac^[1;1H^[1X")
    (write (spec-rendered h (vt-render-pure! h))))
```
---
    "^[1;1H^[0m  本                                                                            "
