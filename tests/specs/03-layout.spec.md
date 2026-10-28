# A window's layout
# @weight 1

tmux/layout: a window's panes as tmux's tree of sized cells.  Each
case's rectangles are what tmux 3.8 reports for the same splits,
resizes and kills, by list-panes' pane_left, pane_top, pane_width and
pane_height, written here as (ID ROW COL ROWS COLS).

## splitting

### one pane is the whole window

```tmux
(write (layout-rects (layout-new 0 80 24) 0 0))
```
---
    ((0 0 0 24 80))

### a split left and right gives the new pane the smaller half, with a border column between

```tmux
(write (layout-rects (layout-split (layout-new 0 80 24) 0 'h 1) 0 0))
```
---
    ((0 0 0 24 40) (1 0 41 24 39))

### the right pane split top and bottom

```tmux
(write (layout-rects (layout-split (layout-split (layout-new 0 80 24) 0 'h 1) 1 'v 2) 0 0))
```
---
    ((0 0 0 24 40) (1 0 41 12 39) (2 13 41 11 39))

### the left pane split too, the panes in tmux's order

```tmux
(write (layout-rects (layout-split (layout-split (layout-split (layout-new 0 80 24) 0 'h 1) 1 'v 2) 0 'v 3) 0 0))
```
---
    ((0 0 0 12 40) (3 13 0 11 40) (1 0 41 12 39) (2 13 41 11 39))

### an odd size halves evenly

```tmux
(write (layout-rects (layout-split (layout-split (layout-new 0 81 25) 0 'h 1) 1 'v 2) 0 0))
```
---
    ((0 0 0 25 40) (1 0 41 12 40) (2 13 41 12 40))

### a split the way its row runs adds the new pane to the row

```tmux
(write (layout-rects (layout-split (layout-split (layout-new 0 80 23) 0 'h 1) 1 'h 2) 0 0))
```
---
    ((0 0 0 23 40) (1 0 41 23 19) (2 0 61 23 19))

### a pane under 3 cells wide is not split

```tmux
(write (layout-split (layout-new 0 2 23) 0 'h 1))
```
---
    ()

## the borders

### a column between left and right, a row between top and bottom

```tmux
(write (layout-borders (layout-split (layout-split (layout-new 0 80 24) 0 'h 1) 1 'v 2) 0 0))
```
---
    (('v 0 40 24) ('h 12 41 39))

### a row of three has two

```tmux
(write (layout-borders (layout-split (layout-split (layout-new 0 80 23) 0 'h 1) 1 'h 2) 0 0))
```
---
    (('v 0 40 23) ('v 0 60 23))

## removing

### a pane killed gives its space to the cell after it

```tmux
(def t (layout-split (layout-split (layout-new 0 80 23) 0 'h 1) 1 'h 2))
(write (list (layout-rects (layout-remove t 1) 0 0) (layout-rects (layout-remove t 0) 0 0)))
```
---
    (((0 0 0 23 40) (2 0 41 23 39)) ((1 0 0 23 60) (2 0 61 23 19)))

### the last of a column gives it to the one before, and the column goes

```tmux
(def t (layout-split (layout-split (layout-new 0 80 23) 0 'h 1) 1 'v 2))
(write (list (layout-remove t 2) (layout-rects (layout-remove t 2) 0 0)))
```
---
    (('h 80 23 (('pane 40 23 0) ('pane 39 23 1))) ((0 0 0 23 40) (1 0 41 23 39)))

### the last pane killed leaves nothing

```tmux
(write (layout-remove (layout-new 0 80 24) 0))
```
---
    ()

### the panes in order

```tmux
(write (layout-panes (layout-split (layout-split (layout-new 0 80 24) 0 'h 1) 0 'v 2)))
```
---
    (0 2 1)

## resizing a pane

### the first pane's border is its right one, the last pane's its left one

```tmux
(def t (layout-split (layout-new 0 80 23) 0 'h 1))
(def a (layout-resize t 0 'L 1))
(def b (layout-resize a 0 'R 5))
(def c (layout-resize b 1 'L 1))
(write (List map (fn (_ t) (layout-rects t 0 0)) (list a b c (layout-resize c 1 'R 1))))
```
---
    (((0 0 0 23 39) (1 0 40 23 40)) ((0 0 0 23 44) (1 0 45 23 35)) ((0 0 0 23 43) (1 0 44 23 36)) ((0 0 0 23 44) (1 0 45 23 35)))

### a border moves no further than each pane keeping one cell

```tmux
(def t (layout-split (layout-new 0 80 23) 0 'h 1))
(write (list (layout-rects (layout-resize t 1 'L 100) 0 0) (layout-rects (layout-resize t 1 'R 100) 0 0)))
```
---
    (((0 0 0 23 1) (1 0 2 23 78)) ((0 0 0 23 78) (1 0 79 23 1)))

### growing takes from the next cell down to one, then the one after

```tmux
(def t (layout-split (layout-split (layout-new 0 80 23) 0 'h 1) 1 'h 2))
(def a (layout-resize t 0 'R 30))
(def b (layout-resize a 0 'R 30))
(def c (layout-resize b 0 'L 60))
(write (List map (fn (_ t) (layout-rects t 0 0)) (list a b c (layout-resize c 2 'L 70))))
```
---
    (((0 0 0 23 70) (1 0 71 23 1) (2 0 73 23 7)) ((0 0 0 23 76) (1 0 77 23 1) (2 0 79 23 1)) ((0 0 0 23 16) (1 0 17 23 61) (2 0 79 23 1)) ((0 0 0 23 6) (1 0 7 23 1) (2 0 9 23 71)))

### a pane in a column moves the column's border, and its own in the column

```tmux
(def t (layout-split (layout-split (layout-new 0 80 23) 0 'h 1) 1 'v 2))
(def a (layout-resize t 2 'L 5))
(def b (layout-resize a 2 'U 3))
(write (List map (fn (_ t) (layout-rects t 0 0)) (list a b (layout-resize b 0 'U 3) (layout-resize b 1 'D 30))))
```
---
    (((0 0 0 23 35) (1 0 36 11 44) (2 12 36 11 44)) ((0 0 0 23 35) (1 0 36 8 44) (2 9 36 14 44)) ((0 0 0 23 35) (1 0 36 8 44) (2 9 36 14 44)) ((0 0 0 23 35) (1 0 36 21 44) (2 22 36 1 44)))

### a pane in a row moves the border below the row

```tmux
(def t (layout-split (layout-split (layout-new 0 80 23) 0 'v 1) 0 'h 2))
(write (layout-rects (layout-resize t 2 'D 4) 0 0))
```
---
    ((0 0 0 15 40) (2 0 41 15 39) (1 16 0 7 80))

## resizing the window

### the change spread over the cells in turn, never past each pane keeping one

```tmux
(def t (layout-split (layout-split (layout-split (layout-new 0 80 23) 0 'h 1) 1 'h 2) 0 'v 3))
(write
  (List map (fn (_ t) (layout-rects t 0 0))
    (rest (List fold (fn (_ acc s) ((fn (_ t) (pair t (List append (rest acc) (list t)))) (layout-fit (first acc) (first s) (rest s))))
            (pair t ()) (list (pair 100 30) (pair 60 15) (pair 80 23) (pair 6 4) (pair 80 23))))))
```
---
    (((0 0 0 15 47) (3 16 0 14 47) (1 0 48 30 26) (2 0 75 30 25)) ((0 0 0 7 33) (3 8 0 7 33) (1 0 34 15 13) (2 0 48 15 12)) ((0 0 0 11 40) (3 12 0 11 40) (1 0 41 23 20) (2 0 62 23 18)) ((0 0 0 1 2) (3 2 0 2 2) (1 0 3 4 1) (2 0 5 4 1)) ((0 0 0 11 27) (3 12 0 11 27) (1 0 28 23 26) (2 0 55 23 25)))

## the pane beside

### of the panes across the border, the most recently active, wrapping at the window's edges

```tmux
(def t (layout-split (layout-split (layout-split (layout-new 0 80 23) 0 'h 1) 1 'v 2) 2 'v 3))
(write
  (list (layout-beside t 0 'R (list 3 2 1 0)) (layout-beside t 0 'R (list 0 1 3 2))
        (layout-beside t 0 'L (list 0 1 3 2)) (layout-beside t 0 'U (list 0 1 3 2))
        (layout-beside t 1 'U ()) (layout-beside t 3 'D ()) (layout-beside t 2 'R ())))
```
---
    (3 1 1 () 3 1 0)

### only the panes that overlap it

```tmux
(def t (layout-split (layout-split (layout-split (layout-new 0 80 23) 0 'h 1) 1 'v 2) 0 'v 3))
(write
  (List map (fn (_ c) (layout-beside t (first c) (rest c) ()))
    (list (pair 0 'U) (pair 0 'L) (pair 3 'L) (pair 1 'U) (pair 2 'L) (pair 2 'R))))
```
---
    (3 1 2 2 3 3)

## moving panes

### a swap or a rotation moves the panes through the cells, which keep their sizes

```tmux
(def t (layout-resize (layout-split (layout-split (layout-new 0 80 24) 0 'h 1) 1 'v 2) 0 'R 5))
(write
  (list (layout-rects (layout-relabel t '(0 1 2) '(2 1 0)) 0 0)
        (layout-rects (layout-relabel t '(0 1 2) '(1 2 0)) 0 0)))
```
---
    (((2 0 0 24 45) (1 0 46 12 34) (0 13 46 11 34)) ((1 0 0 24 45) (2 0 46 12 34) (0 13 46 11 34)))

## the preset layouts

### three panes in each layout, in next-layout's order

```tmux
(write layout-names)
(List for-each (fn (_ name) (write (layout-rects (layout-arrange name '(0 1 2) 80 24) 0 0))) layout-names)
```
---
    ('even-horizontal 'even-vertical 'main-horizontal 'main-horizontal-mirrored 'main-vertical 'main-vertical-mirrored 'tiled)((0 0 0 24 26) (1 0 27 24 26) (2 0 54 24 26))((0 0 0 8 80) (1 9 0 7 80) (2 17 0 7 80))((0 0 0 22 80) (1 23 0 1 40) (2 23 41 1 39))((1 0 0 1 40) (2 0 41 1 39) (0 2 0 22 80))((0 0 0 24 78) (1 0 79 12 1) (2 13 79 11 1))((1 0 0 12 1) (2 13 0 11 1) (0 0 2 24 78))((0 0 0 11 39) (1 0 40 11 40) (2 12 0 12 80))

### the cells shared evenly, the first ones a cell more for what is left over

```tmux
(def lay (fn (_ name n) (layout-rects (layout-arrange name (List take n '(0 1 2 3 4 5 6)) 80 24) 0 0)))
(List for-each write
  (list (lay 'even-vertical 4) (lay 'even-horizontal 4) (lay 'main-vertical 5) (lay 'main-horizontal 7)))
```
---
    ((0 0 0 6 80) (1 7 0 5 80) (2 13 0 5 80) (3 19 0 5 80))((0 0 0 24 20) (1 0 21 24 19) (2 0 41 24 19) (3 0 61 24 19))((0 0 0 24 78) (1 0 79 6 1) (2 7 79 5 1) (3 13 79 5 1) (4 19 79 5 1))((0 0 0 22 80) (1 23 0 1 13) (2 23 14 1 13) (3 23 28 1 13) (4 23 42 1 12) (5 23 55 1 12) (6 23 68 1 12))

### tiled: a grid, the last of a row and the last row taking what is left, a pane alone in a row the whole of it

```tmux
(def lay (fn (_ n) (layout-rects (layout-arrange 'tiled (List take n '(0 1 2 3 4 5 6)) 80 24) 0 0)))
(List for-each write (list (lay 4) (lay 5) (lay 7)))
```
---
    ((0 0 0 11 39) (1 0 40 11 40) (2 12 0 12 39) (3 12 40 12 40))((0 0 0 7 39) (1 0 40 7 40) (2 8 0 7 39) (3 8 40 7 40) (4 16 0 8 80))((0 0 0 7 26) (1 0 27 7 26) (2 0 54 7 26) (3 8 0 7 26) (4 8 27 7 26) (5 8 54 7 26) (6 16 0 8 80))

### the main pane 80 cells wide or 24 rows high, or all but one cell in a small window

```tmux
(def lay (fn (_ name n cols rows) (layout-rects (layout-arrange name (List take n '(0 1 2)) cols rows) 0 0)))
(List for-each write
  (list (lay 'main-vertical 3 200 50) (lay 'main-horizontal 3 200 50) (lay 'main-vertical-mirrored 3 200 50)
        (lay 'tiled 3 200 50) (lay 'main-vertical 2 10 5) (lay 'main-horizontal 2 10 5)
        (lay 'even-horizontal 2 10 5) (lay 'tiled 2 10 5)))
```
---
    ((0 0 0 50 80) (1 0 81 25 119) (2 26 81 24 119))((0 0 0 24 200) (1 25 0 25 100) (2 25 101 25 99))((1 0 0 25 119) (2 26 0 24 119) (0 0 120 50 80))((0 0 0 24 99) (1 0 100 24 100) (2 25 0 25 200))((0 0 0 5 8) (1 0 9 5 1))((0 0 0 3 10) (1 4 0 1 10))((0 0 0 5 5) (1 0 6 5 4))((0 0 0 2 10) (1 3 0 2 10))

### one pane is left as it is

```tmux
(write (layout-arrange 'tiled '(0) 80 24))
```
---
    ()
