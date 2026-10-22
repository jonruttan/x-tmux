# A window's layout
# @weight 1

tmux/layout: a window's panes as a tree of splits, laid out as tmux lays
them out.  Each case's rectangles are what tmux 3.8 reports for the same
splits, by list-panes' pane_left, pane_top, pane_width and pane_height,
written here as (ID ROW COL ROWS COLS).

## splitting

### one pane is the whole window

```tmux
(write (layout-rects (list 'pane 0) 0 0 24 80))
```
---
    ((0 0 0 24 80))

### a split left and right gives the new pane the smaller half, with a border column between

```tmux
(write (layout-rects (layout-split (list 'pane 0) 0 'h 1) 0 0 24 80))
```
---
    ((0 0 0 24 40) (1 0 41 24 39))

### the right pane split top and bottom

```tmux
(write (layout-rects (layout-split (layout-split (list 'pane 0) 0 'h 1) 1 'v 2) 0 0 24 80))
```
---
    ((0 0 0 24 40) (1 0 41 12 39) (2 13 41 11 39))

### the left pane split too, the panes in tmux's order

```tmux
(write (layout-rects (layout-split (layout-split (layout-split (list 'pane 0) 0 'h 1) 1 'v 2) 0 'v 3) 0 0 24 80))
```
---
    ((0 0 0 12 40) (3 13 0 11 40) (1 0 41 12 39) (2 13 41 11 39))

### an odd size halves evenly

```tmux
(write (layout-rects (layout-split (layout-split (list 'pane 0) 0 'h 1) 1 'v 2) 0 0 25 81))
```
---
    ((0 0 0 25 40) (1 0 41 12 40) (2 13 41 12 40))

## the borders

### a column between left and right, a row between top and bottom

```tmux
(write (layout-borders (layout-split (layout-split (list 'pane 0) 0 'h 1) 1 'v 2) 0 0 24 80))
```
---
    (('v 0 40 24) ('h 12 41 39))

## removing

### a pane killed gives its space to its sibling

```tmux
(def t (layout-split (layout-split (layout-split (list 'pane 0) 0 'h 1) 1 'v 2) 0 'v 3))
(write (layout-rects (layout-remove t 3) 0 0 24 80))
```
---
    ((0 0 0 24 40) (1 0 41 12 39) (2 13 41 11 39))

### the last pane killed leaves nothing

```tmux
(write (layout-remove (list 'pane 0) 0))
```
---
    ()

### the panes in order

```tmux
(write (layout-panes (layout-split (layout-split (list 'pane 0) 0 'h 1) 0 'v 2)))
```
---
    (0 2 1)
