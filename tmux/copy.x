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
; it left, which LASTCX keeps, from a row LASTSX long.  With vi's keys the
; cursor stays on a row's characters: its end is the last of them.
;
; A selection runs from where it began to the cursor.  With emacs's keys
; it stops short of the cell the later end is on, and with vi's takes it;
; a row's trailing blanks are left out, and the selection takes a row's
; end, a newline, where it runs past the row's last character.  vi's V
; selects whole rows.
;
; A copy: (SNAP VIEW OFF CX CY LASTCX LASTSX EXIT SEL VI), SNAP the copied
; screen, VIEW what it shows at OFF (tmux/vt's vt-view), EXIT whether a
; page down to the bottom ends the mode, as tmux's copy-mode -e, SEL the
; selection's other end, (LINE COL ROWS), or nil, and VI whether the keys
; are vi's.  LINE counts from the history's oldest row, as tmux/vt's
; vt-line; ROWS is whether whole rows are selected.

(module tmux/copy)

(import x/sys/posix)
(import tmux/vt vt-carry vt-size vt-cursor vt-origin! vt-touch! vt-history vt-view vt-row-length
  vt-line vt-line-length)

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
(def %sel (fn (_ c) (List ref 8 c)))
(def %vi (fn (_ c) (List ref 9 c)))
; C with slot I V.
(def %with (fn (self c i v) (if (= i 0) (pair v (rest c)) (pair (first c) (self (rest c) (- i 1) v)))))

; A copy of SNAP at OFF, its view made.
(def %copy
  (fn (_ snap off cx cy lastcx lastsx exit sel vi)
    (list snap (vt-view snap off) off cx cy lastcx lastsx exit sel vi)))
; C with its cursor's column CX, or row CY too, the view kept.
(def %at-x (fn (_ c cx) (%with c 3 cx)))
(def %moved
  (fn (_ c off cx cy)
    (if (= off (%off c))
      (%with (%with c 3 cx) 4 cy)
      (%copy (%snap c) off cx cy (%lastcx c) (%lastsx c) (%exit c) (%sel c) (%vi c)))))

(def %rows (fn (_ c) (first (vt-size (%snap c)))))
(def %cols (fn (_ c) (rest (vt-size (%snap c)))))
(def %history (fn (_ c) (vt-history (%snap c))))
; The length of the row the cursor is on, and the column its end is.
(def %length (fn (_ c) (vt-row-length (%view c) (%cy c))))
(def %end (fn (_ c) ((fn (_ n) (if (if (%vi c) (< 0 n) #f) (- n 1) n)) (%length c))))
; The cursor's line, as SEL's.
(def %line (fn (_ c) (+ (- (%history c) (%off c)) (%cy c))))

; Copy mode begun on SCREEN, EXIT as above, with vi's keys or not: the
; cursor where the screen's is, on its last column at most.
(def copy-enter
  (fn (_ screen exit vi)
    (def size (vt-size screen))
    (def snap (vt-carry screen (first size) (rest size)))
    (def at (vt-cursor screen))
    (%copy snap 0 (%min (rest at) (- (rest size) 1)) (first at) 0 0 exit () vi)))

; C carried to a pane of ROWS x COLS: its copy too, OFF and the cursor kept
; within it, and no selection.
(def copy-resize
  (fn (_ c rows cols)
    (def snap (vt-carry (%snap c) rows cols))
    (%copy snap (%min (%off c) (vt-history snap)) (%min (%cx c) (- cols 1)) (%min (%cy c) (- rows 1))
      (%lastcx c) (%lastsx c) (%exit c) () (%vi c))))

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
    (def kept (if (= (%cx c) ox) c (%with (%with c 5 (%cx c)) 6 ox)))
    (%at-x kept (%lastcx kept))))
; After one: the cursor at the new row's end when it is past it, or when
; it was at the end of the row it left and this one's end is elsewhere.
; With whole rows selected, at the row's start above where the selection
; began, else at its end.
(def %settle
  (fn (_ c)
    (def px (%length c))
    (%fit
      (if (if (if (< (%cx c) (%lastsx c)) #f (not (= (%cx c) px))) #t (< px (%cx c)))
        (%at-x c px)
        c))))
(def %fit
  (fn (_ s)
    (def e (%end s))
    (match
      ((if (null? (%sel s)) #f (List ref 2 (%sel s))) (%at-x s (if (< (%line s) (first (%sel s))) 0 e)))
      ((< e (%cx s)) (%at-x s e))
      (#t s))))

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
        ((fn (_ u) (%at-x u (%end u))) (%up c))))))
(def %right
  (fn (_ c)
    (if (< (%cx c) (%end c)) (%at-x c (+ (%cx c) 1))
      (if (if (= (%cy c) (- (%rows c) 1)) (= (%off c) 0) #f) c
        (%at-x (%down c) 0)))))

; C's cursor at line LINE, column COL, the view scrolled to show it.
(def %goto
  (fn (_ c line col)
    (def top (- (%history c) (%off c)))
    (def rows (%rows c))
    (match
      ((< line top) (%moved c (- (%history c) line) col 0))
      ((< (+ top (- rows 1)) line) (%moved c (- (%history c) (- line (- rows 1))) col (- rows 1)))
      (#t (%moved c (%off c) col (- line top))))))

; The cursor to where the selection began, and the selection begun where
; the cursor was.
(def %other-end
  (fn (_ c)
    (def s (%sel c))
    (if (null? s) c
      (%goto (%with c 8 (list (%line c) (%cx c) (List ref 2 s))) (first s) (List ref 1 s)))))

; C after the command CMD, or nil when CMD ends the mode.  The copying
; commands end it; copy-text has what they copy.
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
      ((eq? cmd (lit history-top)) (%fit (%moved c (%history c) 0 0)))
      ((eq? cmd (lit history-bottom))
        ((fn (_ b) (%fit (%at-x b (%end b)))) (%moved c 0 (%cx c) (- (%rows c) 1))))
      ((eq? cmd (lit start-of-line)) (%at-x c 0))
      ((eq? cmd (lit end-of-line)) (%at-x c (%end c)))
      ((eq? cmd (lit begin-selection)) (%with c 8 (list (%line c) (%cx c) #f)))
      ((eq? cmd (lit clear-selection)) (%with c 8 ()))
      ((eq? cmd (lit select-line)) ((fn (_ s) (%at-x s (%end s))) (%with c 8 (list (%line c) 0 #t))))
      ((eq? cmd (lit other-end)) (%other-end c))
      ((eq? cmd (lit cancel)) ())
      ((eq? cmd (lit copy)) ())
      ((eq? cmd (lit append)) ())
      ((eq? cmd (lit copy-end-of-line)) ())
      (#t c))))

; --- the selection --------------------------------------------------------

; Whether C has a selection.
(def copy-selecting? (fn (_ c) (not (null? (%sel c)))))

; The selection's ends, (LINE . COL) each, the earlier first, and the
; column past the later one's last cell, whole rows' past every column.
(def %ends
  (fn (_ c)
    (def s (%sel c))
    (def a (pair (first s) (List ref 1 s)))
    (def b (pair (%line c) (%cx c)))
    (def ab (if (< (first a) (first b)) #t (if (= (first a) (first b)) (< (rest a) (rest b)) #f)))
    (def lo (if ab a b))
    (def hi (if ab b a))
    (if (List ref 2 s)
      (list (pair (first lo) 0) (pair (first hi) (+ (%cols c) 1)))
      (list lo hi (if (%vi c) (+ (rest hi) 1) (rest hi))))))
(def %stop (fn (_ c ends) (if (null? (rest (rest ends))) (rest (List ref 1 ends)) (List ref 2 ends))))

; Line LINE's cells FROM to TO-1, or nothing.
(def %span (fn (_ c line from to) (if (< from to) (vt-line (%snap c) line from to) "")))

; The selection's text, or nil when there is none.
(def %selected
  (fn (_ c)
    (def ends (%ends c))
    (def lo (first ends))
    (def last (first (List ref 1 ends)))
    (def stop (%stop c ends))
    ((fn (self line acc)
       (if (< last line) (Str8 join "" (List reverse acc))
         (do (def n (vt-line-length (%snap c) line))
             (def from (if (= line (first lo)) (rest lo) 0))
             (self (+ line 1)
               (pair (if (< line last) (Str8 append (%span c line from n) "\n")
                       (Str8 append (%span c line from (%min stop n)) (if (< n stop) "\n" "")))
                     acc)))))
     (first lo) ())))

; What the command CMD copies from C: the selection, or the cursor's row
; from the cursor to its end; nil for a command that copies nothing, or a
; selection there is not.
(def copy-text
  (fn (_ c cmd)
    (match
      ((if (eq? cmd (lit copy)) #t (eq? cmd (lit append))) (if (null? (%sel c)) () (%selected c)))
      ((eq? cmd (lit copy-end-of-line)) (%span c (%line c) (%cx c) (%length c)))
      (#t ()))))

; The selection on C's view: (ROW COL TEXT) for each row it is on, from
; the column it starts at, to the pane's edge on every row but its last.
(def copy-marks
  (fn (_ c)
    (if (null? (%sel c)) ()
      (do (def ends (%ends c))
          (def lo (first ends))
          (def last (first (List ref 1 ends)))
          (def stop (%min (%stop c ends) (%cols c)))
          (def top (- (%history c) (%off c)))
          (List fold
            (fn (_ acc r)
              (def line (+ top r))
              (def from (if (= line (first lo)) (rest lo) 0))
              (def to (if (= line last) stop (%cols c)))
              (if (if (< line (first lo)) #t (if (< last line) #t (not (< from to)))) acc
                (List append acc (list (list r from (vt-line (%snap c) line from to))))))
            () (List range 0 (%rows c)))))))

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
        (pair 1 (lit start-of-line)) (pair 5 (lit end-of-line)) (pair 113 (lit cancel)) (pair 3 (lit cancel))
        (pair 0 (lit begin-selection)) (pair 7 (lit clear-selection)) (pair 23 (lit copy))
        (pair 11 (lit copy-end-of-line))))
(def %meta
  (list (pair 118 (lit page-up)) (pair 60 (lit history-top)) (pair 62 (lit history-bottom))
        (pair 119 (lit copy))))
(def %vi-keys
  (list (pair 107 (lit up)) (pair 106 (lit down)) (pair 104 (lit left)) (pair 108 (lit right))
        (pair 6 (lit page-down)) (pair 21 (lit halfpage-up)) (pair 4 (lit halfpage-down))
        (pair 103 (lit history-top)) (pair 71 (lit history-bottom)) (pair 48 (lit start-of-line))
        (pair 36 (lit end-of-line)) (pair 113 (lit cancel)) (pair 3 (lit cancel))
        (pair 32 (lit begin-selection)) (pair 13 (lit copy)) (pair 10 (lit copy)) (pair 86 (lit select-line))
        (pair 111 (lit other-end)) (pair 68 (lit copy-end-of-line)) (pair 65 (lit append))))
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
; Escape, which cancels with emacs's keys and clears the selection with
; vi's.
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
        (pair (if vi (lit clear-selection) (lit cancel)) (+ i 1)))
      (pair (%lookup b (if vi %vi-keys %emacs)) (+ i 1)))))
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
  copy-do copy-selecting? copy-text copy-marks copy-vi? copy-key)
