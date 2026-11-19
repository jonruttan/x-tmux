; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/tree.x -- a list to choose from, as tmux 3.8's mode-tree draws one
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A port of the part of tmux's mode-tree.c a flat list uses: the list of
; items, each with the key that picks it, the selected one drawn in
; mode-style, tagged ones in cyan, and under them a box previewing the
; selected item, titled with its name and the sort order.  An item is
; (TAG NAME TEXT): TAG what stays the same of it from one build to the
; next, NAME what it is called, TEXT what is drawn after.
;
; A tree is (ITEMS CURRENT OFFSET TAGGED ORDER REVERSED PREVIEW ROWS
; COLS HEIGHT SCREEN BUILD SHOW ORDERS): CURRENT the selected item's
; place, OFFSET the first shown, TAGGED the tagged items' tags, ORDER the
; sort order and REVERSED whether it is turned about, PREVIEW normal, big
; or off, HEIGHT the rows the list has, SCREEN the screen it is drawn on,
; BUILD (fn (_ order reversed)) answering the items, SHOW (fn (_ tag cols
; rows)) answering the lines that preview one, ORDERS the orders O steps
; through.
;
; tree-key takes a key by tmux's name: (TREE DONE KEY), DONE when the key
; ends the mode, KEY what is left for the mode to do, an item's key
; turned to Enter, or nil when the tree took it.  Searching, filtering,
; help, the menu and the mouse are not here.

(module tmux/tree)

(import tmux/vt vt-make vt-feed!)
(import tmux/width char-width)
(import x/core/doors str-byte-len str-byte-sub str->ptr ptr-ref int/)

(def %min (fn (_ a b) (if (< a b) a b)))
(def %max (fn (_ a b) (if (< a b) b a)))
(def %num (fn (_ n) ((prim-ref (lit convert) (lit to)) n (Type named STRING) 10)))

(def %items (fn (_ t) (first t)))
(def %current (fn (_ t) (List ref 1 t)))
(def %offset (fn (_ t) (List ref 2 t)))
(def %tagged (fn (_ t) (List ref 3 t)))
(def %order (fn (_ t) (List ref 4 t)))
(def %reversed (fn (_ t) (List ref 5 t)))
(def %preview (fn (_ t) (List ref 6 t)))
(def %rows (fn (_ t) (List ref 7 t)))
(def %cols (fn (_ t) (List ref 8 t)))
(def %height (fn (_ t) (List ref 9 t)))
(def %screen (fn (_ t) (List ref 10 t)))
(def %build (fn (_ t) (List ref 11 t)))
(def %show (fn (_ t) (List ref 12 t)))
(def %orders (fn (_ t) (List ref 13 t)))
(def %size (fn (_ t) (List length (%items t))))
(def %with
  (fn (_ t k v) ((fn (self xs i) (if (null? xs) () (pair (if (= i k) v (first xs)) (self (rest xs) (+ i 1))))) t 0)))

(def tree-screen %screen)
(def tree-order %order)
(def tree-reversed? %reversed)

; The selected item's tag, or nil.
(def tree-current
  (fn (_ t) (if (= (%size t) 0) () (first (List ref (%current t) (%items t))))))
; The tagged items' tags, in the list's order.
(def tree-tagged
  (fn (_ t)
    (List map first (List filter (fn (_ it) (%tagged? t (first it))) (%items t)))))
(def %tagged? (fn (_ t tag) (not (null? (List find (fn (_ x) (equal? x tag)) (%tagged t))))))

; A tree of ROWS x COLS built and drawn, ORDER the first of ORDERS unless
; given, PREVIEW normal, or off or big.
(def tree-enter
  (fn (_ build show rows cols orders order reversed preview)
    (tree-build
      (list () 0 0 () (if (null? order) (first orders) order) reversed preview rows cols rows () build show orders))))

; T built again: its items asked for, the selected one kept by its tag,
; or its place when it is gone, the list's height set and the offset
; keeping the selected item shown, the tags of items gone dropped.
(def tree-build
  (fn (_ t)
    (def was (tree-current t))
    (def items ((%build t) (%order t) (%reversed t)))
    (def found ((fn (self xs i) (match ((null? xs) -1) ((equal? (first (first xs)) was) i) (#t (self (rest xs) (+ i 1)))))
                items 0))
    (def n (List length items))
    (def current (match ((<= 0 found) found) ((< (%current t) n) (%current t)) (#t (%max 0 (- n 1)))))
    (def tags (List filter (fn (_ tag) (not (null? (List find (fn (_ it) (equal? (first it) tag)) items)))) (%tagged t)))
    (def built (%with (%with (%with t 0 items) 1 current) 3 tags))
    (tree-draw (%check (%with built 9 (%list-height built))))))

; The rows the list has, tmux's mode_tree_set_height.
(def %list-height
  (fn (_ t)
    (def sy (%rows t))
    (def n (%size t))
    (def h
      (match
        ((eq? (%preview t) (lit normal))
          ((fn (_ h) (if (< h 10) sy h)) (if (< n (* (int/ sy 3) 2)) (int/ sy 2) (* (int/ sy 3) 2))))
        ((eq? (%preview t) (lit big)) (%max 2 (%min n (int/ sy 4))))
        (#t sy)))
    (if (< (- sy h) 2) sy h)))

; T with its offset keeping the selected item shown, the list not left
; with empty rows at its bottom.
(def %check
  (fn (_ t)
    (def h (%height t))
    (def n (%size t))
    (def o (if (<= n h) 0 (%min (%offset t) (- n h))))
    (def c (%current t))
    (%with t 2 (match ((< c o) c) ((< (+ o (- h 1)) c) (+ (- c h) 1)) (#t o)))))

; T a row up, or down; at the end, WRAP to the other, else stay.  down
; answers (T . MOVED).
(def tree-up
  (fn (_ t wrap)
    (def n (%size t))
    (def c (%current t))
    (match
      ((= n 0) t)
      ((< 0 c) (%with (%with t 1 (- c 1)) 2 (if (< (- c 1) (%offset t)) (- (%offset t) 1) (%offset t))))
      (wrap (%with (%with t 1 (- n 1)) 2 (if (<= (%height t) n) (- n (%height t)) (%offset t))))
      (#t t))))
(def tree-down
  (fn (_ t wrap)
    (def n (%size t))
    (def c (%current t))
    (match
      ((= n 0) (pair t #f))
      ((< c (- n 1))
        (pair (%with (%with t 1 (+ c 1)) 2 (if (< (+ (%offset t) (- (%height t) 1)) (+ c 1)) (+ (%offset t) 1) (%offset t)))
          #t))
      (wrap (pair (%with (%with t 1 0) 2 0) #t))
      (#t (pair t #f)))))

; T of ROWS x COLS, built and drawn again.
(def tree-resize (fn (_ t rows cols) (tree-build (%with (%with t 7 rows) 8 cols))))

; The key that picks the item at place I, tmux's: 0 to 9, then M-a to
; M-z, or nil.
(def %key
  (fn (_ i) (match ((< i 10) (%num i)) ((< i 36) (Str8 append "M-" (%byte (+ 97 (- i 10))))) (#t ()))))
(def %byte (fn (_ b) ((fn (_ s) ((prim-ref (lit ptr) (lit set!)) (str->ptr s) 0 b 1) s) ((prim-ref (lit str) (lit make)) 1))))

; T after KEY, tmux's mode_tree_key: (T DONE KEY).
(def tree-key
  (fn (_ t key)
    (def n (%size t))
    (def is? (fn (_ names) (not (null? (List find (fn (_ x) (str=? x key)) names)))))
    (def took (fn (_ t2) (list (tree-draw (%check t2)) #f ())))
    (def built (fn (_ t2) (list (tree-build t2) #f ())))
    (def picked ((fn (self i) (match ((<= (%min n 36) i) -1) ((str=? (%key i) key) i) (#t (self (+ i 1))))) 0))
    (match
      ((= n 0) (list t #t ()))
      ((<= 0 picked) (list (%with t 1 picked) #f "Enter"))
      ((is? (lit ("q" "Escape" "C-g"))) (list t #t ()))
      ((is? (lit ("Up" "k" "C-p"))) (took (tree-up t #t)))
      ((is? (lit ("Down" "j" "C-n"))) (took (first (tree-down t #t))))
      ((is? (lit ("PPage" "C-b")))
        (took ((fn (self t2 k) (if (if (= k 0) #t (= (%current t2) 0)) t2 (self (tree-up t2 #t) (- k 1)))) t (%height t))))
      ((is? (lit ("NPage" "C-f")))
        (took ((fn (self t2 k) (if (if (= k 0) #t (= (%current t2) (- n 1))) t2 (self (first (tree-down t2 #t)) (- k 1))))
               t (%height t))))
      ((is? (lit ("g" "Home"))) (took (%with (%with t 1 0) 2 0)))
      ((is? (lit ("G" "End")))
        (took (%with (%with t 1 (- n 1)) 2 (if (< (- (%height t) 1) (- n 1)) (+ (- n (%height t)) 0) 0))))
      ; tmux moves down after a tag, the key's mouse event never nil
      ((str=? key "t")
        ((fn (_ tag) (took (first (tree-down (%with t 3 (if (%tagged? t tag) (List filter (fn (_ x) (not (equal? x tag))) (%tagged t))
                                                         (pair tag (%tagged t))))
                                    #f))))
         (tree-current t)))
      ((str=? key "T") (took (%with t 3 ())))
      ((str=? key "C-t") (took (%with t 3 (List map first (%items t)))))
      ((str=? key "O") (built (%with t 4 (%next-order t))))
      ((str=? key "r") (built (%with t 5 (not (%reversed t)))))
      ((is? (lit ("Left" "h" "-"))) (took (tree-up t #f)))
      ((is? (lit ("Right" "l" "+"))) (took (first (tree-down t #f))))
      ((str=? key "v")
        (built (%with t 6 (match ((eq? (%preview t) (lit off)) (lit big))
                                 ((eq? (%preview t) (lit normal)) (lit off))
                                 (#t (lit normal))))))
      (#t (list t #f key)))))
; The order after T's in its orders, the first after the last.
(def %next-order
  (fn (_ t)
    ((fn (self xs) (match ((null? xs) (first (%orders t)))
                          ((eq? (first xs) (%order t)) (if (null? (rest xs)) (first (%orders t)) (first (rest xs))))
                          (#t (self (rest xs)))))
     (%orders t))))

; --- drawing ------------------------------------------------------------

(def %esc (fn (_ s) (Str8 append (%byte 27) s)))
(def %at (fn (_ row col) (%esc (Str8 append "[" (%num (+ row 1)) ";" (%num (+ col 1)) "H"))))
(def %plain (%esc "[0m"))
(def %grey (%esc "[0;37m"))
(def %chosen (%esc "[0;30;43m"))
(def %border (%esc "[0;37;40m"))

; TEXT's first characters that fit in COLS cells: (TEXT . CELLS).
(def %clip
  (fn (_ text cols)
    (def n (str-byte-len text))
    (def p (str->ptr text))
    ((fn (self i w)
       (if (<= n i) (pair text w)
         ((fn (_ len)
            ((fn (_ cw) (if (< cols (+ w cw)) (pair (str-byte-sub text 0 i) w) (self (+ i len) (+ w cw))))
             (%width p i len)))
          (%len (ptr-ref p i 1)))))
     0 0)))
; The bytes the UTF-8 character led by B takes, and the cells it takes.
(def %len (fn (_ b) (match ((< b 192) 1) ((< b 224) 2) ((< b 240) 3) (#t 4))))
(def %width
  (fn (_ p i len)
    (if (= len 1) 1
      ((fn (self k cp) (if (= k len) (char-width cp) (self (+ k 1) (+ (* cp 64) (- (ptr-ref p (+ i k) 1) 128)))))
       1 (- (ptr-ref p i 1) (match ((= len 2) 192) ((= len 3) 224) (#t 240)))))))
(def %spaces (fn (_ k) (Str8 pad-right (%max 0 k) #\space "")))

; T drawn on a screen of its own, tmux's mode_tree_draw.
(def tree-draw
  (fn (_ t)
    (def w (%cols t))
    (def h (%height t))
    (def sy (%rows t))
    (def items (%items t))
    (def screen (vt-make sy w))
    (def parts ())
    (def out! (fn (_ s) (set! parts (pair s parts))))
    (def keylen (if (= (%size t) 0) 0 (+ 3 (str-byte-len (%key (- (%min (%size t) 36) 1))))))
    (def row!
      (fn (_ i it)
        (def chosen (= i (%current t)))
        (def tagged (%tagged? t (first it)))
        (def key (%key i))
        (def prefix ((fn (_ s) (Str8 append s (%spaces (- keylen (str-byte-len s))))) (if (null? key) "" (Str8 append "(" key ")"))))
        (def pw (%min keylen w))
        (def left (- w pw))
        (def name (Str8 append (List ref 1 it) (if tagged "*" "")))
        (def named (%clip name left))
        (def sep (%clip ": " (- left (rest named))))
        (def used (+ pw (+ (rest named) (rest sep))))
        (def text (%clip (List ref 2 it) (- w used)))
        (def body (if tagged (%esc "[0;36m") %plain))
        (out! (%at (- i (%offset t)) 0))
        (if chosen
          (out! (Str8 append (if tagged (%esc "[0;36;43m") %chosen) (first (%clip prefix pw)) (first named) (first sep)
                  (first text) (%spaces (- w (+ used (rest text)))) %plain))
          (out! (Str8 append %grey (first (%clip prefix pw)) body (first named) %grey (first sep) body (first text) %plain)))))
    ((fn (self xs i)
       (unless (if (null? xs) #t (< (+ (%offset t) (- h 1)) i))
         (do (when (<= (%offset t) i) (row! i (first xs))) (self (rest xs) (+ i 1)))))
     items 0)
    (unless (if (= (%size t) 0) #t
              (if (eq? (%preview t) (lit off)) #t
                (if (<= sy 4) #t (if (< h 2) #t (if (<= (- sy h) 4) #t (<= w 4))))))
      (do (def it (List ref (%current t) items))
          (def bar (fn (_ k) ((fn (self k acc) (if (= k 0) acc (self (- k 1) (Str8 append acc (%hbar))))) k "")))
          (out! (Str8 append %border (%at h 0) (%corner 140) (bar (- w 2)) (%corner 144)))
          ((fn (self r) (when (< r (- sy 1))
                          (do (out! (Str8 append (%at r 0) (%vbar) (%at r (- w 1)) (%vbar))) (self (+ r 1)))))
           (+ h 1))
          (out! (Str8 append (%at (- sy 1) 0) (%corner 148) (bar (- w 2)) (%corner 152)))
          (def title (Str8 append " " (List ref 1 it) " (sort: " (symbol->str (%order t)) (if (%reversed t) ", reversed" "") ")"))
          (when (<= (str-byte-len title) (- w 2)) (out! (Str8 append (%at h 1) title " ")))
          (out! %plain)
          (def bx (- w 4))
          (def by (- sy (+ h 2)))
          (when (if (< 0 bx) (< 0 by) #f)
            ((fn (self lines r)
               (unless (if (null? lines) #t (= r by))
                 (do (unless (= (str-byte-len (first lines)) 0)
                       (out! (Str8 append (%at (+ h (+ 1 r)) 2) (first (%clip (first lines) bx)))))
                     (self (rest lines) (+ r 1)))))
             ((%show t) (first it) bx by) 0))))
    (def text (Str8 join "" (List reverse parts)))
    (vt-feed! screen (str->ptr text) (str-byte-len text))
    (%with t 10 screen)))

; Box drawing: U+2500, U+2502, and the corners U+250C, U+2510, U+2514,
; U+2518 by their last byte.
(def %hbar (fn (_) (Str8 append (%byte 226) (%byte 148) (%byte 128))))
(def %vbar (fn (_) (Str8 append (%byte 226) (%byte 148) (%byte 130))))
(def %corner (fn (_ b) (Str8 append (%byte 226) (%byte 148) (%byte b))))

(provide tmux/tree tree-enter tree-build tree-draw tree-key tree-up tree-down tree-resize tree-current tree-tagged
  tree-screen tree-order tree-reversed?)
