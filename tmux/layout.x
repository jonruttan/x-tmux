; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/layout.x -- a window's panes as tmux lays them out
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A window's layout is tmux's tree of cells, each with its size: a pane,
; (pane COLS ROWS ID), or a row of cells side by side, (h COLS ROWS
; CELLS), or a column of them one above another, (v COLS ROWS CELLS), a
; one-cell border between each two.  A split of S cells gives the new
; pane (S-1)/2, rounded down, the old one the rest; a split the way its
; row or column runs adds the new pane to it, after the old one.  A pane
; killed gives its space to the cell after it, or to the one before it
; when it was the last.  Resizing a pane moves a border, and a window
; resized is spread over its cells, as tmux's layout.c does both.  A
; rectangle is (ROW COL ROWS COLS), each from 0.

(module tmux/layout)

(def %leaf? (fn (_ t) (eq? (first t) (lit pane))))
(def %id (fn (_ t) (List ref 3 t)))
(def %cells (fn (_ t) (List ref 3 t)))
(def %size (fn (_ t type) (if (eq? type (lit h)) (List ref 1 t) (List ref 2 t))))
(def %sized
  (fn (_ t type n)
    (if (eq? type (lit h)) (list (first t) n (List ref 2 t) (List ref 3 t)) (list (first t) (List ref 1 t) n (List ref 3 t)))))
(def %with-cells (fn (_ t cells) (list (first t) (List ref 1 t) (List ref 2 t) cells)))
(def %min (fn (_ a b) (if (< a b) a b)))

; XS with its Kth replaced by V.
(def %put
  (fn (self xs k v) (if (= k 0) (pair v (rest xs)) (pair (first xs) (self (rest xs) (- k 1) v)))))
; XS without its Kth.
(def %drop
  (fn (self xs k) (if (= k 0) (rest xs) (pair (first xs) (self (rest xs) (- k 1))))))
; The index of the first of XS that OK? takes, or nil.
(def %index
  (fn (_ xs ok?)
    ((fn (self xs i) (match ((null? xs) ()) ((ok? (first xs)) i) (#t (self (rest xs) (+ i 1))))) xs 0)))

(def layout-new (fn (_ id cols rows) (list (lit pane) cols rows id)))

; The panes in order, their ids.
(def layout-panes
  (fn (self t)
    (if (%leaf? t) (list (%id t))
      (List fold (fn (_ acc c) (List append acc (self c))) () (%cells t)))))

(def %holds? (fn (_ t id) (not (null? (List find (fn (_ x) (= x id)) (layout-panes t))))))

; Each pane's rectangle, T's top left at ROW COL, in tmux's pane order:
; ((ID ROW COL ROWS COLS) ...).
(def layout-rects
  (fn (self t row col)
    (if (%leaf? t) (list (list (%id t) row col (List ref 2 t) (List ref 1 t)))
      (first
        (List fold
          (fn (_ acc c)
            (def at (rest acc))
            (pair (List append (first acc) (if (eq? (first t) (lit h)) (self c row at) (self c at col)))
                  (+ at (+ (%size c (first t)) 1))))
          (pair () (if (eq? (first t) (lit h)) col row)) (%cells t))))))

; The borders, T's top left at ROW COL: (v ROW COL LENGTH) a column of
; LENGTH cells down from ROW, (h ROW COL LENGTH) a row of them.
(def layout-borders
  (fn (self t row col)
    (if (%leaf? t) ()
      ((fn (_ h)
         (def cells (%cells t))
         (def walk
           (fn (walk cs at own inner)
             (if (null? cs) (List append own inner)
               ((fn (_ c next)
                  (walk (rest cs) (+ next 1)
                    (if (null? (rest cs)) own
                      (List append own (list (if h (list (lit v) row next (List ref 2 t)) (list (lit h) next col (List ref 1 t))))))
                    (List append inner (if h (self c row at) (self c at col)))))
                (first cs) (+ at (%size (first cs) (first t)))))))
         (walk cells (if h col row) () ()))
       (eq? (first t) (lit h))))))

; --- splitting and removing ----------------------------------------------

; The leaf of pane ID in T, or nil.
(def %leaf
  (fn (self t id)
    (if (%leaf? t) (if (= (%id t) id) t ())
      (List fold (fn (_ acc c) (if (null? acc) (self c id) acc)) () (%cells t)))))

; T with pane ID split in DIRECTION, h or v, the new pane NEW right of it
; or below it; nil when the pane is too small to split, under 3 cells.
(def layout-split
  (fn (_ t id direction new)
    (def leaf (%leaf t id))
    (def s (%size leaf direction))
    (unless (< s 3)
      ((fn (_ n)
         (def old (%sized leaf direction (- (- s 1) n)))
         (def made (%sized (list (lit pane) (List ref 1 leaf) (List ref 2 leaf) new) direction n))
         ((fn (self t)
            (match
              ((%leaf? t) (if (= (%id t) id) (list direction (List ref 1 t) (List ref 2 t) (list old made)) t))
              ((eq? (first t) direction)
                (%with-cells t
                  (List fold
                    (fn (_ acc c)
                      (List append acc (if (if (%leaf? c) (= (%id c) id) #f) (list old made) (list (self c)))))
                    () (%cells t))))
              (#t (%with-cells t (List map self (%cells t))))))
          t))
       (>> (- s 1) 1)))))

; T without pane ID, its space given to the cell after it, or before it
; when it was the last; a row or column left with one cell replaced by
; it; nil when ID was all of T.
(def layout-remove
  (fn (self t id)
    (if (%leaf? t) (if (= (%id t) id) () t)
      ((fn (_ k)
         (if (null? k) (%with-cells t (List map (fn (_ c) (self c id)) (%cells t)))
           (do (def cells (%cells t))
               (def type (first t))
               (def other (if (= k (- (List length cells) 1)) (- k 1) (+ k 1)))
               (def given (%adjust (List ref other cells) type (+ (%size (List ref k cells) type) 1)))
               (def left (%drop (%put cells other given) k))
               (if (null? (rest left)) (first left) (%with-cells t left)))))
       (%index (%cells t) (fn (_ c) (if (%leaf? c) (= (%id c) id) #f)))))))

; --- resizing ------------------------------------------------------------

; How many cells T can give up the way TYPE runs, each pane keeping one.
(def %check
  (fn (self t type)
    (match
      ((%leaf? t) ((fn (_ n) (if (< 1 n) (- n 1) 0)) (%size t type)))
      ((eq? (first t) type) (List fold (fn (_ acc c) (+ acc (self c type))) 0 (%cells t)))
      (#t (List fold (fn (_ acc c) (%min acc (self c type))) (self (first (%cells t)) type) (rest (%cells t)))))))

; T grown by CHANGE the way TYPE runs, or shrunk when it is negative: a
; row across TYPE grows each cell by all of it, one along it a cell at a
; time to each in turn, as tmux's layout_resize_adjust.
(def %adjust
  (fn (self t type change)
    (def t2 (%sized t type (+ (%size t type) change)))
    (match
      ((%leaf? t) t2)
      ((not (eq? (first t) type)) (%with-cells t2 (List map (fn (_ c) (self c type change)) (%cells t))))
      (#t
        ((fn (turn cells change)
           (if (= change 0) (%with-cells t2 cells)
             ((fn (_ r) (if (= (rest r) change) (%with-cells t2 (first r)) (turn (first r) (rest r))))
              (List fold
                (fn (_ acc c)
                  (def left (rest acc))
                  (match
                    ((= left 0) (pair (List append (first acc) (list c)) left))
                    ((< 0 left) (pair (List append (first acc) (list (self c type 1))) (- left 1)))
                    ((< 0 (%check c type)) (pair (List append (first acc) (list (self c type -1))) (+ left 1)))
                    (#t (pair (List append (first acc) (list c)) left))))
                (pair () change) cells))))
         (%cells t) change)))))

; The first index from I, stepping by STEP, whose cell of CELLS can give
; up cells the way TYPE runs, or nil.
(def %giver
  (fn (self cells i step type)
    (match
      ((if (< i 0) #t (<= (List length cells) i)) ())
      ((< 0 (%check (List ref i cells) type)) i)
      (#t (self cells (+ i step) step type)))))

; CELLS with cell K grown by up to NEEDED, from the first after it that
; can give, or the first before it: (CELLS . GROWN), as tmux's
; layout_resize_pane_grow.
(def %grow
  (fn (_ cells k needed type)
    (def j ((fn (_ j) (if (null? j) (%giver cells (- k 1) -1 type) j)) (%giver cells (+ k 1) 1 type)))
    (if (null? j) (pair cells 0)
      ((fn (_ n)
         (pair (%put (%put cells k (%adjust (List ref k cells) type n)) j (%adjust (List ref j cells) type (- 0 n))) n))
       (%min (%check (List ref j cells) type) needed)))))

; CELLS with up to NEEDED taken from cell K, or the first before it that
; can give, and given to the cell after K: (CELLS . TAKEN), as tmux's
; layout_resize_pane_shrink.
(def %shrink
  (fn (_ cells k needed type)
    (def j (%giver cells k -1 type))
    (if (null? j) (pair cells 0)
      ((fn (_ n)
         (pair (%put (%put cells (+ k 1) (%adjust (List ref (+ k 1) cells) type n)) j (%adjust (List ref j cells) type (- 0 n))) n))
       (%min (%check (List ref j cells) type) needed)))))

; T with pane ID's border moved: the pane's nearest row or column running
; TYPE's way, its cell there grown by CHANGE, or shrunk when it is
; negative, the last cell's change made to the one before it, its
; border; (MOVED . T).
(def %resize
  (fn (self t id type change)
    (if (%leaf? t) (pair #f t)
      ((fn (_ k)
         (def r (self (List ref k (%cells t)) id type change))
         (def at (if (= k (- (List length (%cells t)) 1)) (- k 1) k))
         (match
           ((first r) (pair #t (%with-cells t (%put (%cells t) k (rest r)))))
           ((eq? (first t) type)
             (pair #t
               (%with-cells t
                 ((fn (step cells needed)
                    (if (= needed 0) cells
                      ((fn (_ r) (if (= (rest r) 0) cells (step (first r) (if (< 0 needed) (- needed (rest r)) (+ needed (rest r))))))
                       (if (< 0 needed) (%grow cells at needed type) (%shrink cells at (- 0 needed) type)))))
                  (%cells t) change))))
           (#t (pair #f t))))
       (%index (%cells t) (fn (_ c) (%holds? c id)))))))

; T with pane ID resized by N cells in DIRECTION, L R U or D, as tmux's
; resize-pane -L and the rest move the border beside it.
(def layout-resize
  (fn (_ t id direction n)
    (def type (if (if (eq? direction (lit L)) #t (eq? direction (lit R))) (lit h) (lit v)))
    (rest (%resize t id type (if (if (eq? direction (lit L)) #t (eq? direction (lit U))) (- 0 n) n)))))

; T fitted to COLS x ROWS, the change spread over its cells, as tmux's
; layout_resize: never shrunk past each pane keeping one cell.
(def layout-fit
  (fn (_ t cols rows)
    (def fit
      (fn (_ t type n)
        (def change (- n (%size t type)))
        (def limit (%check t type))
        (def c
          (match
            ((= limit 0) (if (< 0 change) change 0))
            ((< change (- 0 limit)) (- 0 limit))
            (#t change)))
        (if (= c 0) t (%adjust t type c))))
    (fit (fit t (lit h) cols) (lit v) rows)))

; T's size: (COLS . ROWS).
(def layout-size (fn (_ t) (pair (List ref 1 t) (List ref 2 t))))

; --- the pane beside --------------------------------------------------------

; The pane beside pane ID in DIRECTION, L R U or D, as tmux's select-pane
; finds it: of those whose edge meets its across a border, wrapping at
; the window's edges, and that overlap it, the first in RECENT, the ids
; most recently active first, else the first in order; nil for none.
(def layout-beside
  (fn (_ t id direction recent)
    (def rects (layout-rects t 0 0))
    (def me (rest (List find (fn (_ r) (= (first r) id)) rects)))
    (def cols (List ref 1 t))
    (def rows (List ref 2 t))
    (def up-down (if (eq? direction (lit U)) #t (eq? direction (lit D))))
    ; where R starts the way DIRECTION runs and how long it is, and the same across it
    (def start (fn (_ r) (if up-down (first r) (List ref 1 r))))
    (def length (fn (_ r) (if up-down (List ref 2 r) (List ref 3 r))))
    (def from (fn (_ r) (if up-down (List ref 1 r) (first r))))
    (def span (fn (_ r) (if up-down (List ref 3 r) (List ref 2 r))))
    (def edge
      (match
        ((if (eq? direction (lit U)) #t (eq? direction (lit L)))
          ((fn (_ e) (if (= e 0) (+ (if up-down rows cols) 1) e)) (start me)))
        (#t ((fn (_ e) (if (< e (if up-down rows cols)) e 0)) (+ (+ (start me) (length me)) 1)))))
    (def meets?
      (fn (_ r)
        (if (if (eq? direction (lit U)) #t (eq? direction (lit L)))
          (= (+ (+ (start r) (length r)) 1) edge)
          (= (start r) edge))))
    (def lo (from me))
    (def hi (+ (from me) (span me)))
    (def overlaps?
      (fn (_ r)
        (def a (from r))
        (def b (- (+ (from r) (span r)) 1))
        (match
          ((if (< a lo) (< hi b) #f) #t)
          ((if (<= lo a) (<= a hi) #f) #t)
          (#t (if (<= lo b) (<= b hi) #f)))))
    (def found
      (List map first
        (List filter (fn (_ r) (if (= (first r) id) #f (if (meets? (rest r)) (overlaps? (rest r)) #f))) rects)))
    (match
      ((null? found) ())
      (#t ((fn (_ x) (if (null? x) (first found) x))
           (List find (fn (_ x) (not (null? (List find (fn (_ y) (= x y)) found)))) recent))))))

; --- moving panes --------------------------------------------------------

; T with each pane's id the one at its place in NEW of the ids in OLD,
; the cells keeping their sizes, as swap-pane and rotate-window move
; panes.
(def layout-relabel
  (fn (self t old new)
    (if (%leaf? t)
      (list (lit pane) (List ref 1 t) (List ref 2 t) (List ref (%index old (fn (_ x) (= x (%id t)))) new))
      (%with-cells t (List map (fn (_ c) (self c old new)) (%cells t))))))

; --- the preset layouts ---------------------------------------------------

; The preset layouts in tmux's next-layout order.
(def layout-names
  (lit (even-horizontal even-vertical main-horizontal main-horizontal-mirrored main-vertical
        main-vertical-mirrored tiled)))

(def %max (fn (_ a b) (if (< a b) b a)))

; The sizes of N cells sharing SIZE, a border between each two, as tmux's
; layout_spread_cell: each the same, the first ones a cell more for what
; is left over.
(def %spread
  (fn (_ size n)
    (def each (Num quotient (- size (- n 1)) n))
    (def over (Num remainder (- size (- n 1)) n))
    ((fn (self k) (if (= k n) () (pair (if (< k over) (+ each 1) each) (self (+ k 1))))) 0)))

; Panes IDS for a TYPE row of COLS x ROWS, sized the way it runs by SIZES.
(def %leaves
  (fn (self type cols rows ids sizes)
    (if (null? ids) ()
      (pair (if (eq? type (lit h)) (list (lit pane) (first sizes) rows (first ids)) (list (lit pane) cols (first sizes) (first ids)))
            (self type cols rows (rest ids) (rest sizes))))))

; IDS side by side, TYPE h, or one above another, v, the same size each,
; as tmux's even-horizontal and even-vertical.
(def %even
  (fn (_ type ids cols rows)
    (def h (eq? type (lit h)))
    (def least (- (* 2 (List length ids)) 1))
    (def c (if h (%max cols least) cols))
    (def r (if h rows (%max rows least)))
    (list type c r (%leaves type c r ids (%spread (if h c r) (List length ids))))))

; The first of IDS the main pane, 80 cells wide beside the others, TYPE
; h, or 24 rows above them, v, tmux's main-pane-width and
; main-pane-height, the others in a row the other way: main-vertical and
; main-horizontal, the main pane last when MIRRORED.  A window too small
; for it leaves the others one cell.
(def %main
  (fn (_ type ids cols rows mirrored)
    (def h (eq? type (lit h)))
    (def s (- (if h cols rows) 1))
    (def want (if h 80 24))
    (def small (<= s (+ want 1)))
    (def main (match ((not small) want) ((<= s 2) 1) (#t (- s 1))))
    (def other (if small 1 (- s main)))
    (def others (rest ids))
    (def n (List length others))
    (def across (%max (if h rows cols) (- (* 2 n) 1)))
    (def leaf (fn (_ along id) (if h (list (lit pane) along across id) (list (lit pane) across along id))))
    (def main-cell (leaf main (first ids)))
    (def other-cell
      (if (= n 1) (leaf other (first others))
        ((fn (_ type c r) (list type c r (%leaves type c r others (%spread across n))))
         (if h (lit v) (lit h)) (if h other across) (if h across other))))
    (def total (+ (+ main other) 1))
    (list type (if h total across) (if h across total) (if mirrored (list other-cell main-cell) (list main-cell other-cell)))))

; IDS in rows of as many columns, as tmux's tiled: a cell each, the same
; size, the last of a row and the last row taking what is left over, and
; a pane alone in a row the whole of it.
(def %tiled
  (fn (_ ids cols rows)
    (def n (List length ids))
    (def grid
      ((fn (self r c)
         (match ((not (< (* r c) n)) (pair r c)) ((< (* (+ r 1) c) n) (self (+ r 1) (+ c 1))) (#t (self (+ r 1) c))))
       1 1))
    (def down (first grid))
    (def across (rest grid))
    (def width (%max 1 (Num quotient (- cols (- across 1)) across)))
    (def height (%max 1 (Num quotient (- rows (- down 1)) down)))
    (def row
      (fn (_ j ids)
        (if (if (= (- n (* j across)) 1) #t (= across 1)) (list (lit pane) cols height (first ids))
          ((fn (_ cells)
             (def used (- (* (List length cells) (+ width 1)) 1))
             (list (lit h) cols height
               (if (< used cols)
                 (%put cells (- (List length cells) 1) (%adjust (List ref (- (List length cells) 1) cells) (lit h) (- cols used)))
                 cells)))
           (%leaves (lit h) cols height
             ((fn (self xs k) (if (if (null? xs) #t (= k 0)) () (pair (first xs) (self (rest xs) (- k 1))))) ids across)
             ((fn (self k) (if (= k 0) () (pair width (self (- k 1))))) across))))))
    (def rows-of
      ((fn (self j ids)
         (if (null? ids) ()
           ((fn (_ r) (pair r (self (+ j 1) (List drop (List length (layout-panes r)) ids)))) (row j ids))))
       0 ids))
    (def used (- (* down (+ height 1)) 1))
    (def last (- (List length rows-of) 1))
    (list (lit v) (%max cols (- (* across (+ width 1)) 1)) (%max rows used)
      (if (< used rows) (%put rows-of last (%adjust (List ref last rows-of) (lit v) (- rows used))) rows-of))))

; IDS, in tmux's pane order, laid out by the preset layout NAME, one of
; layout-names, in a window of COLS x ROWS, as tmux's select-layout lays
; them; nil for one pane.
(def layout-arrange
  (fn (_ name ids cols rows)
    (unless (null? (rest ids))
      (match
        ((eq? name (lit even-horizontal)) (%even (lit h) ids cols rows))
        ((eq? name (lit even-vertical)) (%even (lit v) ids cols rows))
        ((eq? name (lit main-horizontal)) (%main (lit v) ids cols rows #f))
        ((eq? name (lit main-horizontal-mirrored)) (%main (lit v) ids cols rows #t))
        ((eq? name (lit main-vertical)) (%main (lit h) ids cols rows #f))
        ((eq? name (lit main-vertical-mirrored)) (%main (lit h) ids cols rows #t))
        (#t (%tiled ids cols rows))))))

(provide tmux/layout layout-new layout-rects layout-borders layout-split layout-remove layout-panes
  layout-resize layout-fit layout-size layout-beside layout-relabel layout-names layout-arrange)
