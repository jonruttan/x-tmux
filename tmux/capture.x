; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/capture.x -- a screen's lines as capture-pane writes them
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A screen's lines are numbered as tmux 3.8's capture-pane numbers them:
; 0 the screen's top row, a negative number a row of history, -1 the
; newest.  capture-range reads -S and -E: "-" the history's oldest row or
; the screen's last, a number held to the lines there are, one that does
; not read as a number the screen's top row or its last, the two swapped
; when the end comes first.  The range is answered as lines counted from
; the history's oldest row, as vt-line counts them.
;
; capture-lines writes each line's cells, padding as nothing, to the cells
; the line holds, written or erased, as tmux's grid keeps them, and drops
; the trailing spaces.  With KEEP (-N) the spaces stay; with JOIN (-J) the
; line runs to its last cell written, the spaces stay, and a line that
; wrapped goes on into the next.  With CODES, a run of cells is led by the
; SGR that takes the cell before it, on this line or the one before, to
; its style, as tmux's grid_string_cells_code writes it: a 0 first when an
; attribute goes, then each attribute that comes, then the foreground and
; the background each when it changes.  With ESCAPE, a backslash is
; written twice and a code's ESC as \033.
;
; Not as tmux's: a tab is spaces, as the screen keeps it; an underscore's
; style (4:3) and colour (58) are not kept, so a curly underscore is
; written 4.

(module tmux/capture)

(import tmux/vt vt-line vt-line-attr vt-line-marks vt-history vt-size vt-style-word)
(import x/core/doors ptr-ref ptr-set! str-make str->ptr str-byte-len str-byte-sub)

(def %num (fn (_ n) ((prim-ref (lit convert) (lit to)) n (Type named STRING) 10)))
(def %esc (fn (_) ((fn (_ s) (ptr-set! (str->ptr s) 0 27 1) s) (str-make 1))))

; TEXT as a number, a leading - let be; nil when it is not one.
(def %number
  (fn (_ text)
    (def n (str-byte-len text))
    (def at (fn (_ i) (ptr-ref (str->ptr text) i 1)))
    (def from (if (< 1 n) (if (= (at 0) 45) 1 0) 0))
    ((fn (self i acc)
       (match
         ((= i n) (if (= n from) () (if (= from 1) (- 0 acc) acc)))
         ((if (< 47 (at i)) (< (at i) 58) #f) (self (+ i 1) (+ (* acc 10) (- (at i) 48))))
         (#t ())))
     from 0)))

; The lines -S START and -E END name in screen H, each nil when not
; given: (FIRST . LAST), counted from the history's oldest row.
(def capture-range
  (fn (_ h start end)
    (def count (vt-history h))
    (def last (+ count (- (first (vt-size h)) 1)))
    (def read
      (fn (_ text missing whole)
        ((fn (_ n)
           (match
             ((if (null? text) #f (str=? text "-")) whole)
             ((null? n) missing)
             ((if (< n 0) (< count (- 0 n)) #f) 0)
             (#t (if (< last (+ count n)) last (+ count n)))))
         (if (null? text) () (%number text)))))
    (def top (read start count 0))
    (def bottom (read end last last))
    (if (< bottom top) (pair bottom top) (pair top bottom))))

; Screen H's lines FIRST to LAST, each its text, with CODES their SGR, with
; ESCAPE backslashes and ESCs written out, with JOIN to the last cell
; written and wrapped lines joined, with KEEP their trailing spaces kept.
(def capture-lines
  (fn (_ h range codes escape join keep)
    (def esc (if escape "\\033" (%esc)))
    (def doubled
      (fn (_ text) (if (if escape (not (null? (Str8 index-of "\\" text))) #f) (Str8 join "\\\\" (Str8 split "\\" text)) text)))
    ; LINE's cells to N, the cell before them in style LAST: (TEXT . STYLE),
    ; STYLE the last cell's
    (def write
      (fn (_ line n last)
        (if (not codes) (pair (doubled (vt-line h line 0 n)) last)
          ; runs of one attribute, each led by its codes
          ((fn (self c last acc)
             (if (= c n) (pair acc last)
               ((fn (_ a)
                  (def stop ((fn (more k) (if (if (< k n) (= (vt-line-attr h line k) a) #f) (more (+ k 1)) k)) c))
                  (self stop a (Str8 append acc (%codes esc (vt-style-word h last) (vt-style-word h a))
                                 (doubled (vt-line h line c stop)))))
                (vt-line-attr h line c))))
           0 last ""))))
    (def trimmed (fn (_ text) (if (if join #t keep) text (%trimmed text))))
    ; from LINE, the style LAST before it, the text of the lines that
    ; wrapped into it AHEAD
    ((fn (self line last ahead)
       (if (< (rest range) line) (if (null? ahead) () (list ahead))
         ((fn (_ marks)
            ((fn (_ w)
               ((fn (_ text)
                  (if (if join (List ref 2 marks) #f) (self (+ line 1) (rest w) text)
                    (pair text (self (+ line 1) (rest w) ()))))
                (if (null? ahead) (trimmed (first w)) (Str8 append ahead (first w)))))
             (write line (if join (first marks) (List ref 1 marks)) last)))
          (vt-line-marks h line))))
     (first range) 1 ())))

; TEXT without its trailing spaces.
(def %trimmed
  (fn (_ text)
    ((fn (self n) (if (if (< 0 n) (= (ptr-ref (str->ptr text) (- n 1) 1) 32) #f) (self (- n 1)) (str-byte-sub text 0 n)))
     (str-byte-len text))))

; The attribute bits by their SGR parameter, in tmux's order.
(def %attributes (lit ((1 . 1) (2 . 2) (4 . 3) (8 . 4) (16 . 5) (32 . 7) (64 . 8) (128 . 9))))

; What takes a cell in style LAST to style NEXT, both style words: ESC is
; ESC's text.
(def %codes
  (fn (_ esc last next)
    (def lost (not (null? (List find (fn (_ a) (if (= 0 (& last (first a))) #f (= 0 (& next (first a))))) %attributes))))
    (def had (if lost 0 last))
    (def gained (List filter (fn (_ a) (if (= 0 (& next (first a))) #f (= 0 (& had (first a))))) %attributes))
    (def params (List append (if lost (list 0) ()) (List map rest gained)))
    (def sgr (fn (_ ps) (Str8 append esc "[" (Str8 join ";" (List map %num ps)) "m")))
    (def colour
      (fn (_ shift base bright ext)
        (def new (%colour (& (>> next shift) 67108863) base bright ext))
        (def old (%colour (& (>> last shift) 67108863) base bright ext))
        (match
          ((if lost (= (first new) (+ ext 1)) #f) "")
          ((if (not lost) (%same? new old) #f) "")
          (#t (sgr new)))))
    (Str8 append (if (null? params) "" (sgr params)) (colour 8 30 90 38) (colour 34 40 100 48))))
(def %same?
  (fn (self a b) (if (null? a) (null? b) (if (null? b) #f (if (= (first a) (first b)) (self (rest a) (rest b)) #f)))))

; Colour C's parameters: BASE+N for one of the first 8 named, BRIGHT+N for
; the next 8, EXT;5;N for one of 256, EXT;2;R;G;B, and EXT+1 the default.
(def %colour
  (fn (_ c base bright ext)
    (def v (& c 16777215))
    (def form (>> c 24))
    (match
      ((= form 0) (list (+ ext 1)))
      ((if (= form 1) (< v 8) #f) (list (+ base v)))
      ((= form 1) (list (+ bright (- v 8))))
      ((= form 2) (list ext 5 v))
      (#t (list ext 2 (>> v 16) (& (>> v 8) 255) (& v 255))))))

(provide tmux/capture capture-range capture-lines)
