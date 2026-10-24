; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/copy.x -- copy mode: a pane's history, scrolled through
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Copy mode shows a pane as it was when the mode began -- a copy of its
; screen, history and all, which the pane's output goes on past -- OFF
; rows up from the bottom, with a cursor of its own.  A key is a command,
; by tmux's tables for mode-keys emacs or vi, and the commands move as
; tmux's window-copy does: the cursor up and down a row, scrolling at the
; top and bottom; a page up and down, two rows short of the pane; half a
; page; the top of the history and the bottom.  A move to a shorter row
; puts the cursor at the row's end, and back on a longer one at the column
; it left, which LASTCX keeps, from a row LASTSX long.
;
; A copy: (SNAP VIEW OFF CX CY LASTCX LASTSX EXIT), SNAP the copied screen,
; VIEW what it shows at OFF (tmux/vt's vt-view), and EXIT whether a page
; down to the bottom ends the mode, as tmux's copy-mode -e.

(module tmux/copy)

(import x/sys/posix)
(import tmux/vt vt-carry vt-size vt-cursor vt-origin! vt-touch! vt-history vt-view vt-row-length)

(def %pref (prim-ref (lit ptr) (lit ref)))
(def %min (fn (_ a b) (if (< a b) a b)))
(def %max (fn (_ a b) (if (< a b) b a)))

(def %snap (fn (_ c) (first c)))
(def %view (fn (_ c) (List ref 1 c)))
(def %off (fn (_ c) (List ref 2 c)))
(def %cx (fn (_ c) (List ref 3 c)))
(def %cy (fn (_ c) (List ref 4 c)))
(def %lastcx (fn (_ c) (List ref 5 c)))
(def %lastsx (fn (_ c) (List ref 6 c)))
(def %exit (fn (_ c) (List ref 7 c)))

; A copy of SNAP at OFF, its view made.
(def %copy
  (fn (_ snap off cx cy lastcx lastsx exit)
    (list snap (vt-view snap off) off cx cy lastcx lastsx exit)))
; C with its cursor's column CX, or row CY too, the view kept.
(def %at-x (fn (_ c cx) (list (%snap c) (%view c) (%off c) cx (%cy c) (%lastcx c) (%lastsx c) (%exit c))))
(def %moved
  (fn (_ c off cx cy)
    (if (= off (%off c))
      (list (%snap c) (%view c) off cx cy (%lastcx c) (%lastsx c) (%exit c))
      (%copy (%snap c) off cx cy (%lastcx c) (%lastsx c) (%exit c)))))

(def %rows (fn (_ c) (first (vt-size (%snap c)))))
(def %history (fn (_ c) (vt-history (%snap c))))
; The length of the row the cursor is on.
(def %length (fn (_ c) (vt-row-length (%view c) (%cy c))))

; Copy mode begun on SCREEN, EXIT as above: the cursor where the screen's
; is, on its last column at most.
(def copy-enter
  (fn (_ screen exit)
    (def size (vt-size screen))
    (def snap (vt-carry screen (first size) (rest size)))
    (def at (vt-cursor screen))
    (%copy snap 0 (%min (rest at) (- (rest size) 1)) (first at) 0 0 exit)))

; C carried to a pane of ROWS x COLS: its copy too, OFF and the cursor kept
; within it.
(def copy-resize
  (fn (_ c rows cols)
    (def snap (vt-carry (%snap c) rows cols))
    (%copy snap (%min (%off c) (vt-history snap)) (%min (%cx c) (- cols 1)) (%min (%cy c) (- rows 1))
      (%lastcx c) (%lastsx c) (%exit c))))

; What a copy shows, where its cursor is as (ROW . COL), and the position
; tmux shows at the pane's top right.
(def copy-view (fn (_ c) (%view c)))
; C put at terminal row ROW, column COL, as tmux/vt's vt-origin!, and every
; row of its view marked to be drawn.
(def copy-origin! (fn (_ c row col) (vt-origin! (%snap c) row col) (vt-origin! (%view c) row col) c))
(def copy-touch! (fn (_ c) (vt-touch! (%view c)) c))
(def copy-cursor (fn (_ c) (pair (%cy c) (%cx c))))
(def copy-position
  (fn (_ c)
    (Str8 append "[" ((prim-ref (lit convert) (lit to)) (%off c) (Type named STRING) 10) "/"
      ((prim-ref (lit convert) (lit to)) (%history c) (Type named STRING) 10) "]")))

; --- moves ----------------------------------------------------------------

; Before a move up or down: the cursor's column kept as LASTCX, with its
; row's length as LASTSX, unless it is at the row's end; then put back at
; LASTCX.
(def %remember
  (fn (_ c)
    (def ox (%length c))
    (def kept
      (if (= (%cx c) ox) c
        (list (%snap c) (%view c) (%off c) (%cx c) (%cy c) (%cx c) ox (%exit c))))
    (%at-x kept (%lastcx kept))))
; After one: the cursor at the new row's end when it is past it, or when
; it was at the end of the row it left and this one's end is elsewhere.
(def %settle
  (fn (_ c)
    (def px (%length c))
    (if (if (if (< (%cx c) (%lastsx c)) #f (not (= (%cx c) px))) #t (< px (%cx c)))
      (%at-x c px)
      c)))

(def %up
  (fn (_ c)
    (def r (%remember c))
    (%settle
      (if (= (%cy r) 0)
        (%moved r (%min (+ (%off r) 1) (%history r)) (%cx r) 0)
        (%moved r (%off r) (%cx r) (- (%cy r) 1))))))
(def %down
  (fn (_ c)
    (def r (%remember c))
    (%settle
      (if (= (%cy r) (- (%rows r) 1))
        (%moved r (%max (- (%off r) 1) 0) (%cx r) (%cy r))
        (%moved r (%off r) (%cx r) (+ (%cy r) 1))))))

; N rows a page up or down moves, a pane's rows less two or half of them.
(def %page (fn (_ c half) (if (< 2 (%rows c)) (if half (>> (%rows c) 1) (- (%rows c) 2)) 1)))
(def %page-up
  (fn (_ c half)
    (def r (%remember c))
    (def n (%page r half))
    (%settle
      (if (< (%history r) (+ (%off r) n))
        (%moved r (%history r) (%cx r) (%max 0 (- (%cy r) n)))
        (%moved r (+ (%off r) n) (%cx r) (%cy r))))))
; tmux's: short of a page from the bottom, the cursor goes down the page.
(def %page-down
  (fn (_ c half)
    (def r (%remember c))
    (def n (%page r half))
    (def moved
      (%settle
        (if (< (%off r) n)
          (%moved r 0 (%cx r) (%min (+ (%cy r) n) (- (%rows r) 1)))
          (%moved r (- (%off r) n) (%cx r) (%cy r)))))
    (if (if (%exit moved) (= (%off moved) 0) #f) () moved)))

(def %left
  (fn (_ c)
    (if (< 0 (%cx c)) (%at-x c (- (%cx c) 1))
      (if (if (= (%cy c) 0) (= (%off c) (%history c)) #f) c
        ((fn (_ u) (%at-x u (%length u))) (%up c))))))
(def %right
  (fn (_ c)
    (if (< (%cx c) (%length c)) (%at-x c (+ (%cx c) 1))
      (if (if (= (%cy c) (- (%rows c) 1)) (= (%off c) 0) #f) c
        (%at-x (%down c) 0)))))

; C after the command CMD, or nil when CMD ends the mode.
(def copy-do
  (fn (_ c cmd)
    (match
      ((eq? cmd (lit up)) (%up c))
      ((eq? cmd (lit down)) (%down c))
      ((eq? cmd (lit left)) (%left c))
      ((eq? cmd (lit right)) (%right c))
      ((eq? cmd (lit page-up)) (%page-up c #f))
      ((eq? cmd (lit page-down)) (%page-down c #f))
      ((eq? cmd (lit halfpage-up)) (%page-up c #t))
      ((eq? cmd (lit halfpage-down)) (%page-down c #t))
      ((eq? cmd (lit history-top)) (%moved c (%history c) 0 0))
      ((eq? cmd (lit history-bottom))
        ((fn (_ b) (%at-x b (%length b))) (%moved c 0 (%cx c) (- (%rows c) 1))))
      ((eq? cmd (lit start-of-line)) (%at-x c 0))
      ((eq? cmd (lit end-of-line)) (%at-x c (%length c)))
      ((eq? cmd (lit cancel)) ())
      (#t c))))

; --- keys -----------------------------------------------------------------

; Whether the keys are vi's: VISUAL, or else EDITOR, names a program with
; vi in its name, as tmux decides mode-keys.
(def copy-vi?
  (fn (_)
    (def e ((fn (_ v) (if (if (null? v) #t (= (Str8 length v) 0)) (Sys getenv "EDITOR") v)) (Sys getenv "VISUAL")))
    (if (null? e) #f
      ((fn (_ base) (not (null? (Str8 index-of "vi" base))))
       ((fn (_ parts) (List ref (- (List length parts) 1) parts)) (Str8 split "/" e))))))

; tmux's tables, a byte to a command: emacs's, then vi's.  ESC and a key,
; emacs's meta keys, are in the meta table.
(def %emacs
  (list (pair 16 (lit up)) (pair 14 (lit down)) (pair 6 (lit right)) (pair 22 (lit page-down))
        (pair 1 (lit start-of-line)) (pair 5 (lit end-of-line)) (pair 113 (lit cancel)) (pair 3 (lit cancel))))
(def %meta
  (list (pair 118 (lit page-up)) (pair 60 (lit history-top)) (pair 62 (lit history-bottom))))
(def %vi
  (list (pair 107 (lit up)) (pair 106 (lit down)) (pair 104 (lit left)) (pair 108 (lit right))
        (pair 6 (lit page-down)) (pair 21 (lit halfpage-up)) (pair 4 (lit halfpage-down))
        (pair 103 (lit history-top)) (pair 71 (lit history-bottom)) (pair 48 (lit start-of-line))
        (pair 36 (lit end-of-line)) (pair 113 (lit cancel)) (pair 3 (lit cancel))))
; The cursor keys and the paging keys, by a CSI's final, or a ~ sequence's
; number.
(def %finals
  (list (pair 65 (lit up)) (pair 66 (lit down)) (pair 67 (lit right)) (pair 68 (lit left))
        (pair 72 (lit start-of-line)) (pair 70 (lit end-of-line))))
(def %tildes
  (list (pair 1 (lit start-of-line)) (pair 4 (lit end-of-line)) (pair 5 (lit page-up)) (pair 6 (lit page-down))))

(def %lookup (fn (_ k table) ((fn (_ e) (if (null? e) () (rest e))) (List find (fn (_ e) (= (first e) k)) table))))

; The key at byte I of the N at P: (CMD . NEXT), CMD nil for a key with no
; command and NEXT the byte after it.  An ESC alone at the read's end is
; Escape, which cancels with emacs's keys.
(def copy-key
  (fn (_ p i n vi)
    (def b (%pref p i 1))
    (if (= b 27)
      (if (< (+ i 1) n)
        ((fn (_ c)
           (if (if (= c 91) #t (= c 79))
             (%sequence p (+ i 2) n 0)
             (pair (if vi () (%lookup c %meta)) (+ i 2))))
         (%pref p (+ i 1) 1))
        (pair (if vi () (lit cancel)) (+ i 1)))
      (pair (%lookup b (if vi %vi %emacs)) (+ i 1)))))
; A CSI or SS3 sequence's command, its parameter's digits read from I.
(def %sequence
  (fn (self p i n num)
    (if (< i n)
      ((fn (_ b)
         (match
           ((if (< 47 b) (< b 58) #f) (self p (+ i 1) n (+ (* num 10) (- b 48))))
           ((= b 59) (self p (+ i 1) n num))
           ((= b 126) (pair (%lookup num %tildes) (+ i 1)))
           ((if (< 63 b) (< b 127) #f) (pair (%lookup b %finals) (+ i 1)))
           (#t (pair () (+ i 1)))))
       (%pref p i 1))
      (pair () i))))

(provide tmux/copy copy-enter copy-resize copy-view copy-origin! copy-touch! copy-cursor copy-position
  copy-do copy-vi? copy-key)
