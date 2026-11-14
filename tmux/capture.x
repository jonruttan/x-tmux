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
; capture-lines writes each line's characters, padding as nothing.  Plain,
; a line's trailing spaces are dropped.  With CODES, a run of cells is led
; by the SGR that takes the cell before it to its style, as tmux's
; grid_string_cells_code writes it: a 0 first when an attribute goes,
; then each attribute that comes, then the foreground and the background
; each when it changes; the line ends with the codes back to the default,
; and only its trailing spaces in the default style are dropped.  With
; ESCAPE, a backslash is written twice and a code's ESC as \033.
;
; Not as tmux's: a tab is spaces, as the screen keeps it; an underscore's
; style (4:3) and colour (58) are not kept, so a curly underscore is
; written 4; -J and -N are not taken, as the screen keeps neither which
; rows wrapped nor how far a row was written.

(module tmux/capture)

(import tmux/vt vt-line vt-line-cell vt-line-attr vt-history vt-size vt-style-word)
(import x/core/doors ptr-ref ptr-set! str-make str->ptr str-byte-len)

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
; ESCAPE backslashes and ESCs written out.
(def capture-lines
  (fn (_ h range codes escape)
    (def cols (rest (vt-size h)))
    (def esc (if escape "\\033" (%esc)))
    (def doubled
      (fn (_ text) (if (if escape (not (null? (Str8 index-of "\\" text))) #f) (Str8 join "\\\\" (Str8 split "\\" text)) text)))
    (def blank?
      (fn (_ line c) (if (= (vt-line-cell h line c) 32) (if codes (= (vt-line-attr h line c) 1) #t) #f)))
    (def end (fn (self line c) (if (if (< 0 c) (blank? line (- c 1)) #f) (self line (- c 1)) c)))
    (def write
      (fn (_ line)
        (def n (end line cols))
        (if (not codes) (doubled (vt-line h line 0 n))
          ; runs of one attribute, each led by its codes
          ((fn (self c last acc)
             (if (= c n)
               (Str8 append acc (%codes esc (vt-style-word h last) (vt-style-word h 1)))
               ((fn (_ a)
                  (def stop ((fn (more k) (if (if (< k n) (= (vt-line-attr h line k) a) #f) (more (+ k 1)) k)) c))
                  (self stop a (Str8 append acc (%codes esc (vt-style-word h last) (vt-style-word h a))
                                 (doubled (vt-line h line c stop)))))
                (vt-line-attr h line c))))
           0 1 ""))))
    ((fn (self line) (if (< (rest range) line) () (pair (write line) (self (+ line 1))))) (first range))))

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
