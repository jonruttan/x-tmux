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
