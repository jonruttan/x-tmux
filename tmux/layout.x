; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/layout.x -- a window's panes as tmux lays them out
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A window's layout is a tree: a leaf (pane ID), or a split (h A B), A
; left of B, or (v A B), A above B.  A split of S cells gives B (S-1)/2,
; rounded down, A the rest, with a one-cell border between, as tmux splits.
; A pane killed gives its space to its sibling.  A rectangle is (ROW COL
; ROWS COLS), each from 0.

(module tmux/layout)

(def %leaf? (fn (_ t) (eq? (first t) (lit pane))))
(def %part (fn (_ size) (pair (- (- size 1) (>> (- size 1) 1)) (>> (- size 1) 1))))

; Each pane's rectangle within ROW COL ROWS COLS, in tmux's pane order
; (left before right, top before bottom): ((ID ROW COL ROWS COLS) ...).
(def layout-rects
  (fn (self t row col rows cols)
    (match
      ((%leaf? t) (list (list (List ref 1 t) row col rows cols)))
      ((eq? (first t) (lit h))
        ((fn (_ p)
           (List append (self (List ref 1 t) row col rows (first p))
                        (self (List ref 2 t) row (+ col (+ (first p) 1)) rows (rest p))))
         (%part cols)))
      (#t
        ((fn (_ p)
           (List append (self (List ref 1 t) row col (first p) cols)
                        (self (List ref 2 t) (+ row (+ (first p) 1)) col (rest p) cols)))
         (%part rows))))))

; The borders between panes within ROW COL ROWS COLS: (v ROW COL LENGTH)
; a column of LENGTH cells down from ROW, (h ROW COL LENGTH) a row of them.
(def layout-borders
  (fn (self t row col rows cols)
    (match
      ((%leaf? t) ())
      ((eq? (first t) (lit h))
        ((fn (_ p)
           (List append
             (list (list (lit v) row (+ col (first p)) rows))
             (self (List ref 1 t) row col rows (first p))
             (self (List ref 2 t) row (+ col (+ (first p) 1)) rows (rest p))))
         (%part cols)))
      (#t
        ((fn (_ p)
           (List append
             (list (list (lit h) (+ row (first p)) col cols))
             (self (List ref 1 t) row col (first p) cols)
             (self (List ref 2 t) (+ row (+ (first p) 1)) col (rest p) cols)))
         (%part rows))))))

; T with pane ID split in DIRECTION, h or v, the new pane NEW right of it
; or below it.
(def layout-split
  (fn (self t id direction new)
    (match
      ((%leaf? t) (if (= (List ref 1 t) id) (list direction t (list (lit pane) new)) t))
      (#t (list (first t) (self (List ref 1 t) id direction new) (self (List ref 2 t) id direction new))))))

; T without pane ID, its sibling in its place; () when ID was all of T.
(def layout-remove
  (fn (self t id)
    (match
      ((%leaf? t) (if (= (List ref 1 t) id) () t))
      (#t ((fn (_ a b)
             (match ((null? a) b)
                    ((null? b) a)
                    (#t (list (first t) a b))))
           (self (List ref 1 t) id) (self (List ref 2 t) id))))))

; The panes in order, their ids.
(def layout-panes
  (fn (self t)
    (if (%leaf? t) (list (List ref 1 t))
      (List append (self (List ref 1 t)) (self (List ref 2 t))))))

(provide tmux/layout layout-rects layout-borders layout-split layout-remove layout-panes)
