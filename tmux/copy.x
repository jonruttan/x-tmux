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
; cursor stays on a row's characters: its end is the last of them.  A
; line's start and end are those of the rows a wrap joins, its first row's
; start and its last row's end.
;
; A selection runs from where it began to the cursor.  With emacs's keys
; it stops short of the cell the later end is on, and with vi's takes it;
; a row's trailing blanks are left out, and the selection takes a row's
; end, a newline, where it runs past the row's last character; a row that
; wrapped keeps its blanks and goes on into the next.  vi's V selects
; whole lines.
;
; A search finds text, or a regular expression, down the copy from the
; cursor or up it, going on from the other end, as tmux's wrap-search: a
; line, the rows a wrap joins, is searched as one.  Text all in lower case
; matches either case.  The matches on the view are marked, the one the
; cursor is on apart, and the position counts them.
;
; A copy: (SNAP VIEW OFF CX CY LASTCX LASTSX EXIT SEL VI SEARCH COUNT
; ORIGIN LAST), SNAP the copied screen, VIEW what it shows at OFF
; (tmux/vt's vt-view), EXIT whether a page down to the bottom ends the
; mode, as tmux's copy-mode -e, SEL the selection's other end, (LINE COL
; ROWS), or nil, and VI whether the keys are vi's.  LINE counts from the
; history's oldest row, as tmux/vt's vt-line; ROWS is whether whole rows
; are selected.  SEARCH is (TEXT REGEX UP), what a search again looks for
; and which way, or nil; COUNT (N . MORE), the matches the last search
; counted, N -1 when it did not count them, MORE whether it stopped short,
; or nil when the matches are not marked;
; ORIGIN (OFF CX CY), where an incremental search began, or nil; LAST
; (TEXT REGEX DOWN), the search last run, REGEX whether as a regular
; expression, or nil.

(module tmux/copy)

(import x/sys/posix)
(import tmux/vt vt-carry vt-size vt-cursor vt-origin! vt-touch! vt-history vt-view vt-row-length
  vt-line vt-line-length vt-line-marks vt-line-cell)

(import x/core/doors ptr-ref ptr-set! str-make str->ptr int/ int%)
(def %min (fn (_ a b) (if (< a b) a b)))
(def %max (fn (_ a b) (if (< a b) b a)))

(def %snap (fn (_ c) (first (first c))))
(def %view (fn (_ c) (List ref 1 c)))
(def %off (fn (_ c) (List ref 2 c)))
(def %cx (fn (_ c) (List ref 3 c)))
(def %cy (fn (_ c) (List ref 4 c)))
(def %lastcx (fn (_ c) (List ref 5 c)))
(def %lastsx (fn (_ c) (List ref 6 c)))
(def %exit (fn (_ c) (List ref 7 c)))
(def %sel (fn (_ c) (List ref 8 c)))
(def %vi (fn (_ c) (List ref 9 c)))
(def %search (fn (_ c) (List ref 10 c)))
(def %count (fn (_ c) (List ref 11 c)))
(def %origin (fn (_ c) (List ref 12 c)))
(def %last (fn (_ c) (List ref 13 c)))
; The slots from SEARCH on.
(def %found (fn (_ c) ((fn (self xs n) (if (= n 0) xs (self (rest xs) (- n 1)))) c 10)))
; C with slot I V.
(def %with (fn (self c i v) (if (= i 0) (pair v (rest c)) (pair (first c) (self (rest c) (- i 1) v)))))

; A copy of SNAP at OFF, its view made, FOUND its slots from SEARCH on;
; its first slot SNAP with its rows, columns and history, read once.
(def %copy
  (fn (_ snap off cx cy lastcx lastsx exit sel vi found)
    (def size (vt-size snap))
    (List append
      (list (list snap (first size) (rest size) (vt-history snap)) (vt-view snap off) off cx cy lastcx lastsx
            exit sel vi)
      found)))
; C with its cursor's column CX, or row CY too, the view kept.
(def %at-x (fn (_ c cx) (%with c 3 cx)))
(def %moved
  (fn (_ c off cx cy)
    (if (= off (%off c))
      (%with (%with c 3 cx) 4 cy)
      (%copy (%snap c) off cx cy (%lastcx c) (%lastsx c) (%exit c) (%sel c) (%vi c) (%found c)))))

(def %rows (fn (_ c) (first (rest (first c)))))
(def %cols (fn (_ c) (first (rest (rest (first c))))))
(def %history (fn (_ c) (first (rest (rest (rest (first c)))))))
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
    (%copy snap 0 (%min (rest at) (- (rest size) 1)) (first at) 0 0 exit () vi (list () () () ()))))

; C with the search its pane last ran, (TEXT . REGEX), or nil, to search
; again, up, as tmux's copy mode begins with its pane's.
(def copy-recall
  (fn (_ c search) (if (null? search) c (%with c 10 (list (first search) (rest search) #t)))))
; The search C last ran, (TEXT . REGEX), or nil.
(def copy-searched (fn (_ c) ((fn (_ l) (if (null? l) () (pair (first l) (List ref 1 l)))) (%last c))))

; C carried to a pane of ROWS x COLS: its copy too, OFF and the cursor kept
; within it, and no selection.  Its matches are counted again, and an
; incremental search begins again from the cursor.
(def copy-resize
  (fn (_ c rows cols)
    (def snap (vt-carry (%snap c) rows cols))
    (def r
      (%copy snap (%min (%off c) (vt-history snap)) (%min (%cx c) (- cols 1)) (%min (%cy c) (- rows 1))
        (%lastcx c) (%lastsx c) (%exit c) () (%vi c) (%found c)))
    (def o (%with r 12 (list (%off r) (%cx r) (%cy r))))
    (if (null? (%count o)) o (%with o 11 (%counted o (%asked (%last o)))))))

; What a copy shows, where its cursor is as (ROW . COL), and the position
; tmux shows at the pane's top right.
(def copy-view (fn (_ c) (%view c)))
; C put at terminal row ROW, column COL, as tmux/vt's vt-origin!, and every
; row of its view marked to be drawn.
(def copy-origin! (fn (_ c row col) (vt-origin! (%snap c) row col) (vt-origin! (%view c) row col) c))
(def copy-touch! (fn (_ c) (vt-touch! (%view c)) c))
(def copy-cursor (fn (_ c) (pair (%cy c) (%cx c))))
(def %num (fn (_ n) ((prim-ref (lit convert) (lit to)) n (Type named STRING) 10)))
(def copy-position
  (fn (_ c)
    (Str8 append "[" (%num (%off c)) "/" (%num (%history c)) "]"
      ((fn (_ n) (if (if (null? n) #f (< 0 (first n))) (Str8 append " (" (%num (first n)) (if (rest n) "+" "") " results)") ""))
       (%count c)))))

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

; Whether line LINE of C's copy wrapped into the next, and the cells it
; holds.
(def %wrapped? (fn (_ c line) (List ref 2 (vt-line-marks (%snap c) line))))
(def %held (fn (_ c line) (List ref 1 (vt-line-marks (%snap c) line))))
; The first and the last row of the line LINE is on, the rows a wrap
; joins being one line, as tmux's grid reader takes them.
(def %first-line
  (fn (self c line) (if (if (< 0 line) (%wrapped? c (- line 1)) #f) (self c (- line 1)) line)))
(def %last-line
  (fn (self c line)
    (if (if (< line (+ (%history c) (- (%rows c) 1))) (%wrapped? c line) #f) (self c (+ line 1)) line)))
; The cursor at the end of its line, on the line's last row.
(def %line-end
  (fn (_ c)
    (def last (%last-line c (%line c)))
    (def n (vt-line-length (%snap c) last))
    (%goto c last (if (if (%vi c) (< 0 n) #f) (- n 1) n))))

; The cursor to where the selection began, and the selection begun where
; the cursor was.
(def %other-end
  (fn (_ c)
    (def s (%sel c))
    (if (null? s) c
      (%goto (%with c 8 (list (%line c) (%cx c) (List ref 2 s))) (first s) (List ref 1 s)))))

; C after the command CMD, or nil when CMD ends the mode.  The copying
; commands end it; copy-text has what they copy.  The matches are let go
; by a selection's commands, and with emacs's keys by a move too, and an
; incremental search then begins again where the cursor is.
(def copy-do
  (fn (_ c cmd)
    (def r (%do c cmd))
    (if (if (null? r) #t (null? (%count c))) r
      (if (if (List find (fn (_ x) (eq? x cmd)) (lit (begin-selection clear-selection select-line))) #t
            (if (%vi c) #f (not (null? (List find (fn (_ x) (eq? x cmd)) %moves)))))
        (%with (%with r 11 ()) 12 ())
        r))))
(def %moves
  (lit (up down left right page-up page-down halfpage-up halfpage-down history-top history-bottom
        start-of-line end-of-line other-end)))
(def %do
  (fn (_ c cmd)
    (match
      ((eq? cmd (lit search-again)) (%again c #f))
      ((eq? cmd (lit search-reverse)) (%again c #t))
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
      ((eq? cmd (lit start-of-line)) (%goto c (%first-line c (%line c)) 0))
      ((eq? cmd (lit end-of-line)) (%line-end c))
      ((eq? cmd (lit begin-selection)) (%with c 8 (list (%line c) (%cx c) #f)))
      ((eq? cmd (lit clear-selection)) (%with c 8 ()))
      ((eq? cmd (lit select-line)) (%line-end (%with c 8 (list (%first-line c (%line c)) 0 #t))))
      ((eq? cmd (lit other-end)) (%other-end c))
      ((eq? cmd (lit cancel)) ())
      ((eq? cmd (lit copy)) ())
      ((eq? cmd (lit append)) ())
      ((eq? cmd (lit copy-end-of-line)) ())
      (#t c))))

; --- search ---------------------------------------------------------------

; A place in C's copy as one number: line LINE, column COL.
(def %at (fn (_ c line col) (+ (* line (%cols c)) col)))
; The copy's last line.
(def %final (fn (_ c) (+ (%history c) (- (%rows c) 1))))
; The place after A and the one before, round from the end to the start,
; and back, as WRAP has it.
(def %next
  (fn (_ c a wrap) (if (= a (%at c (%final c) (- (%cols c) 1))) (if wrap 0 a) (+ a 1))))
(def %prev
  (fn (_ c a wrap) (if (= a 0) (if wrap (%at c (%final c) (- (%cols c) 1)) 0) (- a 1))))

; What a search looks for: (TEXT RX CIS), RX TEXT compiled when it is a
; regular expression, #f when it does not read as one, else nil; CIS
; whether TEXT is all in lower case, and either case matches.  TEXT is
; taken as a regular expression only where it has one of its special
; characters, as tmux's.
(def %special? (fn (_ text) (List find (fn (_ ch) (not (null? (Str8 index-of ch text)))) %specials)))
(def %specials (lit ("^" "$" "*" "+" "(" ")" "?" "[" "]" "." "\\")))
; x/type/regex loaded once, at the first regular expression.
(def %regex-loaded #f)
(def %regex! (fn (_) (unless %regex-loaded (do (import x/type/regex) (set! %regex-loaded #t)))))
(def %query
  (fn (_ text regex)
    (list text (if regex (guard (e #f) (do (%regex!) (Regex compile text))) ()) (str=? text (Str8 downcase text)))))
; The search LAST, (TEXT REGEX DOWN), as %query has it.
(def %asked (fn (_ last) (%query (first last) (List ref 1 last))))

; TEXT with its ASCII capitals in lower case, byte by byte.
(def %lower
  (fn (_ text)
    (def n (str-byte-len text))
    (def out (str-make n))
    (def p (str->ptr text))
    (def q (str->ptr out))
    ((fn (self i)
       (when (< i n)
         (do ((fn (_ b) (ptr-set! q i (if (if (< 64 b) (< b 91) #f) (+ b 32) b) 1)) (ptr-ref p i 1))
             (self (+ i 1)))))
     0)
    out))

; Line LINE's cells as text, and the byte each cell's text starts at,
; COLS+1 of them, or nil where every cell is a byte.  A wide character's
; padding cell has no text.
(def %cells
  (fn (_ c line)
    (def cols (%cols c))
    (def snap (%snap c))
    (def text (vt-line snap line 0 cols))
    (pair text
      (if (= (str-byte-len text) cols) ()
        ((fn (self k b acc)
           (if (= k cols) (List reverse (pair b acc))
             (self (+ k 1)
               ((fn (_ x) (match ((< x 128) (+ b 1)) ((= x 128) (+ b (str-byte-len (vt-line snap line k (+ k 1))))) (#t b)))
                (vt-line-cell snap line k))
               (pair b acc))))
         0 0 ())))))
; The line LINE and the lines a wrap joins on to it: (TEXT . ROWS), TEXT
; theirs run together, cased as Q asks, and ROWS (LINE BASE OFFSETS) each,
; the last first, BASE the byte its text starts at in TEXT.
(def %run
  (fn (_ c line q)
    (def final (%final c))
    (def cased (fn (_ t) (if (List ref 2 q) (%lower t) t)))
    (def cs (%cells c line))
    (if (if (< line final) (%wrapped? c line) #f)
      ((fn (self l base texts rows)
         (def more (%cells c l))
         (def texts2 (pair (first more) texts))
         (def rows2 (pair (list l base (rest more)) rows))
         (if (if (< l final) (%wrapped? c l) #f)
           (self (+ l 1) (+ base (str-byte-len (first more))) texts2 rows2)
           (pair (cased (Str8 join "" (List reverse texts2))) rows2)))
       (+ line 1) (str-byte-len (first cs)) (list (first cs)) (list (list line 0 (rest cs))))
      (pair (cased (first cs)) (list (list line 0 (rest cs)))))))
; Byte B of a run's text as a place, its cell's; a byte past a row's last
; cell is the next row's start.
(def %place
  (fn (_ c run b)
    (def row (List find (fn (_ r) (not (< b (List ref 1 r)))) (rest run)))
    (def rel (- b (List ref 1 row)))
    (def offs (List ref 2 row))
    (%at c (first row)
      (if (null? offs) rel
        ((fn (self xs k best) (if (null? xs) best (self (rest xs) (+ k 1) (if (= (first xs) rel) k best))))
         offs 0 0)))))
; The byte column COL of the run's first line starts at.
(def %byte (fn (_ run col) ((fn (_ offs) (if (null? offs) col (List ref col offs))) (List ref 2 (List ref (- (List length (rest run)) 1) (rest run))))))
; Q's first match in TEXT from byte FROM: (START . END), or nil; an empty
; one is none.
(def %hit
  (fn (_ q text from)
    (def rx (List ref 1 q))
    (match
      ((null? rx)
        ((fn (_ i) (if (null? i) () (pair i (+ i (str-byte-len (first q))))))
         (Str8 %find-bytes (first q) from text)))
      ((eq? rx #f) ())
      (#t ((fn (_ m) (if (null? m) () (if (= (first m) (List ref 1 m)) () (pair (first m) (List ref 1 m)))))
           (Regex find-at text from rx))))))

; The first match of Q that starts in line LINE at a column LO to
; HI-1: (A . WIDTH), A its place, or nil.  It may run on into the lines
; a wrap joins.
(def %match-lr
  (fn (_ c line lo hi q)
    (if (< lo hi)
      (do (def run (%run c line q))
          (def h (%hit q (first run) (%byte run lo)))
          (if (null? h) ()
            ((fn (_ a) (if (< a (%at c line hi)) (pair a (- (%place c run (rest h)) a)) ()))
             (%place c run (first h)))))
      ())))
; The match of Q that starts in line LINE nearest before column HI, from
; LO: the last to start there for text; for a regular expression the
; first of its matches one after another that runs to HI or past, else
; the last of them, as tmux's.
(def %match-rl
  (fn (_ c line lo hi q)
    (def run (%run c line q))
    (def end (%at c line hi))
    (def regex (not (null? (List ref 1 q))))
    ((fn (self from best)
       (def h (%hit q (first run) from))
       (if (null? h) best
         ((fn (_ a)
            (if (< a end)
              ((fn (_ m) (if (if regex (not (< (+ a (rest m)) end)) #f) m (self (if regex (rest h) (+ (first h) 1)) m)))
               (pair a (- (%place c run (rest h)) a)))
              best))
          (%place c run (first h)))))
     (%byte run lo) ())))
; A regular expression's match R at the start of line ROW, after LINE-1
; wrapped into it: the match that starts on a line before and ends where
; R does, as tmux's window_copy_search_back_overlap.
(def %overlap
  (fn (self c q r row endline)
    (if (if (List ref 1 q) (if (= (first r) (%at c row 0)) (if (< endline row) (%wrapped? c (- row 1)) #f) #f) #f)
      ((fn (_ up) (if (if (null? up) #f (= (+ (first up) (rest up)) (+ (first r) (rest r)))) (self c q up (- row 1) endline) r))
       (%match-rl c (- row 1) 0 (%cols c) q))
      r)))

; Q's next match from column FX of line FY, DOWN to line ENDLINE or up to
; it, round from the other end as WRAP has it: (A . WIDTH), or nil.
(def %jump
  (fn (self c q fx fy endline down wrap)
    (def cols (%cols c))
    (def found
      (if down
        ((fn (loop i x) (if (< endline i) () ((fn (_ r) (if (null? r) (loop (+ i 1) 0) r)) (%match-lr c i x cols q))))
         fy fx)
        ((fn (loop i x)
           (if (< i endline) ()
             ((fn (_ r) (if (null? r) (loop (- i 1) (- cols 1)) (%overlap c q r i endline))) (%match-rl c i 0 (+ x 1) q))))
         fy fx)))
    (match
      ((not (null? found)) found)
      (wrap (self c q (if down 0 (- cols 1)) (if down 0 (%final c)) fy down #f))
      (#t ()))))

; Q's matches in lines FROM to TO-1, each line's from its start on, one
; after another, (A . WIDTH) each, and whether the clock passed UNTIL, in
; microseconds, 0 for never, first: (MATCHES . STOPPED).
(def %matches
  (fn (_ c q from to until)
    ((fn (self line x acc)
       (match
         ((= line to) (pair (List reverse acc) #f))
         ((if (= x 0) (if (< 0 until) (< until (%micros)) #f) #f) (pair (List reverse acc) #t))
         (#t ((fn (_ r) (if (null? r) (self (+ line 1) 0 acc) (self line (+ (- (first r) (%at c line 0)) (rest r)) (pair r acc))))
              (%match-lr c line x (%cols c) q)))))
     from 0 ())))
; The matches of Q in C counted, (N . MORE), as tmux's: a count that takes
; longer than %count-limit microseconds stops, and is 10, 100 or 1000 and
; more, or -1, none shown, below 10.
(def %count-limit 200000)
(def copy-count-limit! (fn (_ ms) (set! %count-limit (* ms 1000))))
(def %micros (fn (_) ((fn (_ t) (+ (* (first t) 1000000) (rest t))) (Sys time-of-day))))
(def %counted
  (fn (_ c q)
    (def m (%matches c q 0 (+ (%final c) 1) (if (= %count-limit 0) 0 (+ (%micros) %count-limit))))
    (def n (List length (first m)))
    (if (rest m)
      (pair (match ((< 1000 n) 1000) ((< 100 n) 100) ((< 10 n) 10) (#t -1)) #t)
      (pair n #f))))

; The matches on C's view as tmux's window-copy marks them: a byte a cell,
; rows by columns, each match's cells its number, from 1, in order, a
; match's that starts on the view, a cell already marked keeping its own.
(def %marks
  (fn (_ c q)
    (def cols (%cols c))
    (def n (* (%rows c) cols))
    (def top (- (%history c) (%off c)))
    (def m (str-make n))
    (def p (str->ptr m))
    ((fn (self i) (when (< i n) (do (ptr-set! p i 0 1) (self (+ i 1))))) 0)
    (List fold
      (fn (_ gen r)
        (def b (- (first r) (%at c top 0)))
        (if (if (< b 0) #t (not (< b n))) gen
          (do ((fn (self i) (when (< i (%min n (+ b (rest r))))
                              (do (when (= (ptr-ref p i 1) 0) (ptr-set! p i gen 1)) (self (+ i 1)))))
               b)
              (if (= gen 255) 1 (+ gen 1)))))
      1 (first (%matches c q (%first-line c top) (+ top (%rows c)) 0)))
    m))
; The mark at place A, or nil off the view.
(def %mark
  (fn (_ c m a)
    (def b (- a (%at c (- (%history c) (%off c)) 0)))
    (if (if (< b 0) #t (not (< b (* (%rows c) (%cols c))))) () (ptr-ref (str->ptr m) b 1))))
; The place past the match A is in, or A.
(def %past
  (fn (_ c m a wrap)
    (def g (%mark c m a))
    (if (if (null? g) #t (= g 0)) a
      ((fn (self x)
         (if (if (null? (%mark c m x)) #t (not (= (%mark c m x) g))) x
           (if (if wrap #f (= x (%at c (%final c) (- (%cols c) 1)))) x (self (%next c x wrap)))))
       a))))

; C's cursor on place A, the view scrolled to show it as tmux's
; window_copy_scroll_to: a quarter of the rows above it, or at the top or
; the bottom.
(def %scroll-to
  (fn (_ c a)
    (def cols (%cols c))
    (def rows (%rows c))
    (def h (%history c))
    (def px (int% a cols))
    (def py (int/ a cols))
    (def top (- h (%off c)))
    (if (if (< py top) #f (< py (+ top rows))) (%moved c (%off c) px (- py top))
      ((fn (_ t) (%moved c (- h t) px (- py t)))
       (match ((< py rows) 0) ((< (- (+ h rows) (int/ rows 4)) py) h) (#t (- (+ py (int/ rows 4)) rows)))))))

; C after a search for its SEARCH's text, DOWN or up, REGEX as a regular
; expression or not, as tmux's window_copy_search, and whether it found
; it.  With vi's keys a search down starts past the match the cursor is
; on, or the cursor; up, before the cursor.  The cursor goes to the
; match's start, or with emacs's keys down, past its end.  The matches
; are counted, but for the search last run again, which leaves the count.
(def %find
  (fn (_ c down regex)
    (def text (first (%search c)))
    (def eff (if regex (not (null? (%special? text))) #f))
    (def last (%last c))
    (def same (if (null? last) #f (if (str=? (first last) text) (eq? (List ref 1 last) eff) #f)))
    (def c1 (%with (if same c (%with c 11 ())) 13 (list text eff down)))
    (if (= (str-byte-len text) 0) (pair c1 #f)
      (do (def q (%query text eff))
          (def here (%at c1 (%line c1) (%cx c1)))
          (def from
            (if down
              (if (%vi c1) (if (null? (%count c1)) (%next c1 here #t) (%past c1 (%marks c1 q) here #t)) here)
              (%prev c1 here #t)))
          (def endline (if down (%final c1) 0))
          (def hit (%jump c1 q (int% from (%cols c1)) (int/ from (%cols c1)) endline down #t))
          (if (null? hit) (pair c1 #f)
            (do (def at (%scroll-to c1 (first hit)))
                (def counted (%with at 11 (if same (if (null? (%count at)) (pair -1 #f) (%count at)) (%counted at q))))
                (def a (first hit))
                (def m (%marks counted q))
                (def inside
                  (if down (if (null? (%mark counted m a)) #f
                             (if (< 0 (- a (%at counted (- (%history counted) (%off counted)) 0)))
                               (= (%mark counted m a) (%mark counted m (- a 1))) #f)) #f))
                (def again
                  (if inside
                    ((fn (_ x) (if (null? x) counted (%scroll-to counted (first x))))
                     ((fn (_ f) (%jump counted q (int% f (%cols c1)) (int/ f (%cols c1)) endline down #t)) (%past counted m a #t)))
                    counted))
                (def m2 (%marks again q))
                (def b (%at again (%line again) (%cx again)))
                (pair
                  (if down
                    (if (%vi again) again ((fn (_ x) (%goto again (int/ x (%cols c1)) (int% x (%cols c1)))) (%past again m2 b #t)))
                    (%goto again (int/ (%start again m2 b) (%cols c1)) (int% (%start again m2 b) (%cols c1))))
                  #t)))))))
; The start of the match A is in, or A.
(def %start
  (fn (_ c m a)
    (def g (%mark c m a))
    (if (if (null? g) #t (= g 0)) a
      ((fn (self x) (if (= x 0) x (if (eq? (%mark c m (- x 1)) g) (self (- x 1)) x))) a))))

; n and N: C's search again, its way or the other.
(def %again
  (fn (_ c reverse)
    (def s (%search c))
    (if (null? s) c (first (%find c (if reverse (List ref 2 s) (not (List ref 2 s))) (List ref 1 s))))))

; C after a search for TEXT, DOWN or up, as a regular expression or not,
; as tmux's search-forward and search-backward; nothing for no text.
(def copy-search
  (fn (_ c text down regex)
    (if (= (str-byte-len text) 0) c
      (first (%find (%with c 10 (list text regex (not down))) down regex)))))

; C after an incremental search's prompt changed, ARG its text after a
; prefix, as tmux's search-forward-incremental, or with UP its
; search-backward-incremental: = searches the way it began, + down and -
; up.  It begins where the cursor is, and goes back there, to the end of
; its line, for each new text; no text lets the matches go.
(def copy-incremental
  (fn (_ c arg up)
    (def n (str-byte-len arg))
    (def prefix (Str8 sub 0 1 arg))
    (def text (Str8 sub 1 (- n 1) arg))
    (def o (%origin c))
    (def s (%search c))
    (def base
      (match
        ((null? o) (%with c 12 (list (%off c) (%cx c) (%cy c))))
        ((if (null? s) #f (not (str=? text (first s))))
          ((fn (_ r) (%at-x r (%end r))) (%moved c (first o) (List ref 1 o) (List ref 2 o))))
        (#t c)))
    (if (= (str-byte-len text) 0) (%with base 11 ())
      (do (def down (match ((str=? prefix "+") #t) ((str=? prefix "-") #f) (#t (not up))))
          ((fn (_ r) (if (rest r) (first r) (%with (first r) 11 ())))
           (%find (%with base 10 (list text #f (not down))) down #f))))))

; The matches on C's view, as copy-marks has the selection: (ROW COL TEXT
; CURRENT) for each run of a row's marked cells, CURRENT whether it is of
; the match the cursor is on, or with emacs's keys after a search down,
; the one before the cursor.
(def copy-matches
  (fn (_ c)
    (if (null? (%count c)) ()
      (do (def q (%asked (%last c)))
          (def m (%marks c q))
          (def cols (%cols c))
          (def top (- (%history c) (%off c)))
          (def here (%at c (%line c) (%cx c)))
          (def g
            ((fn (_ x) (if (null? x) 0 x))
             (if (if (%vi c) #f (if (List ref 2 (%last c)) (< (%at c top 0) here) #f))
               (%mark c m (- here 1))
               (%mark c m here))))
          (def cell (fn (_ r k) (ptr-ref (str->ptr m) (+ (* r cols) k) 1)))
          (def kind (fn (_ r k) ((fn (_ x) (match ((= x 0) 0) ((= x g) 2) (#t 1))) (cell r k))))
          (List fold
            (fn (_ acc r)
              ((fn (self k acc)
                 (if (= k cols) acc
                   ((fn (_ t)
                      (if (= t 0) (self (+ k 1) acc)
                        ((fn (_ e) (self e (List append acc (list (list r k (vt-line (%snap c) (+ top r) k e) (= t 2))))))
                         ((fn (more j) (if (if (< j cols) (= (kind r j) t) #f) (more (+ j 1)) j)) (+ k 1)))))
                    (kind r k))))
               0 acc))
            () (List range 0 (%rows c)))))))

; --- the selection --------------------------------------------------------

; Whether C has a selection, and whether its matches are marked.
(def copy-selecting? (fn (_ c) (not (null? (%sel c)))))
(def copy-marked? (fn (_ c) (not (null? (%count c)))))

; The selection's ends, (LINE . COL) each, the earlier first, and the
; column past the later one's last cell, whole rows' past every column:
; the line they began on to its last row, and the cursor's row.
(def %ends
  (fn (_ c)
    (def s (%sel c))
    (def a (pair (first s) (List ref 1 s)))
    (def b (pair (%line c) (%cx c)))
    (def ab (if (< (first a) (first b)) #t (if (= (first a) (first b)) (< (rest a) (rest b)) #f)))
    (def lo (if ab a b))
    (def hi (if ab b a))
    (if (List ref 2 s)
      (list (pair (%min (first a) (first b)) 0) (pair (%max (first b) (%last-line c (first a))) (+ (%cols c) 1)))
      (list lo hi (if (%vi c) (+ (rest hi) 1) (rest hi))))))
(def %stop (fn (_ c ends) (if (null? (rest (rest ends))) (rest (List ref 1 ends)) (List ref 2 ends))))

; Line LINE's cells FROM to TO-1, or nothing.
(def %span (fn (_ c line from to) (if (< from to) (vt-line (%snap c) line from to) "")))

; The selection's text, or nil when there is none, as tmux's
; window_copy_get_selection writes it.  A row runs to its last character
; and is followed by a newline; a row that wrapped runs to the cells it
; holds, its spaces kept, and goes on into the next row with no newline
; where the selection takes it to its end.  The last row stops where the
; selection does, its last character at most, past it with vi's keys; its
; newline is left off, but with vi's keys where the selection runs past
; the row's last character, unless the row wrapped and the selection
; stops at it.
(def %selected
  (fn (_ c)
    (def ends (%ends c))
    (def lo (first ends))
    (def last (first (List ref 1 ends)))
    (def tail (vt-line-length (%snap c) last))
    (def stop (%stop c ends))
    (def lastex (if (%vi c) (+ (%min (- stop 1) tail) 1) (%min stop tail)))
    (def bare (if (if (%vi c) (< tail lastex) #f) #f (if (%wrapped? c last) (not (= lastex tail)) #t)))
    ; the row's text from SX to EX, and its newline
    (def row
      (fn (_ line sx ex)
        (def wrapped (%wrapped? c line))
        (def xx (if wrapped (%held c line) (vt-line-length (%snap c) line)))
        (def e (%min ex xx))
        (Str8 append (%span c line (%min sx xx) e)
          (if (if (if wrapped (= e xx) #f) #t (if (= line last) bare #f)) "" "\n"))))
    (if (if (= (first lo) last) (< lastex (rest lo)) #f) ()
      ((fn (self line acc)
         (if (< last line) (Str8 join "" (List reverse acc))
           (self (+ line 1)
             (pair (row line (if (= line (first lo)) (rest lo) 0) (if (= line last) lastex (%cols c))) acc))))
       (first lo) ()))))

; What the command CMD copies from C: the selection, or the cursor's row
; from the cursor to its end; nil for a command that copies nothing, or a
; selection there is not.
(def copy-text
  (fn (_ c cmd)
    (match
      ((if (eq? cmd (lit copy)) #t (eq? cmd (lit append))) (if (null? (%sel c)) () (%selected c)))
      ((eq? cmd (lit copy-end-of-line)) (%selected (%line-end (%with c 8 (list (%line c) (%cx c) #f)))))
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
        (pair 11 (lit copy-end-of-line))
        (pair 19 (lit incremental-down)) (pair 18 (lit incremental-up)) (pair 110 (lit search-again))
        (pair 78 (lit search-reverse))))
(def %meta
  (list (pair 118 (lit page-up)) (pair 60 (lit history-top)) (pair 62 (lit history-bottom))
        (pair 119 (lit copy))))
(def %vi-keys
  (list (pair 107 (lit up)) (pair 106 (lit down)) (pair 104 (lit left)) (pair 108 (lit right))
        (pair 6 (lit page-down)) (pair 21 (lit halfpage-up)) (pair 4 (lit halfpage-down))
        (pair 103 (lit history-top)) (pair 71 (lit history-bottom)) (pair 48 (lit start-of-line))
        (pair 36 (lit end-of-line)) (pair 113 (lit cancel)) (pair 3 (lit cancel))
        (pair 32 (lit begin-selection)) (pair 13 (lit copy)) (pair 10 (lit copy)) (pair 86 (lit select-line))
        (pair 111 (lit other-end)) (pair 68 (lit copy-end-of-line)) (pair 65 (lit append))
        (pair 47 (lit prompt-down)) (pair 63 (lit prompt-up)) (pair 110 (lit search-again)) (pair 78 (lit search-reverse))))
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
    (def b (ptr-ref p i 1))
    (if (= b 27)
      (if (< (+ i 1) n)
        ((fn (_ c)
           (if (if (= c 91) #t (= c 79))
             (%sequence p (+ i 2) n 0)
             (pair (if vi () (%lookup c %meta)) (+ i 2))))
         (ptr-ref p (+ i 1) 1))
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
       (ptr-ref p i 1))
      (pair () i))))

(provide tmux/copy copy-enter copy-resize copy-view copy-origin! copy-touch! copy-cursor copy-position
  copy-do copy-selecting? copy-text copy-marks copy-vi? copy-key copy-recall copy-searched copy-search
  copy-incremental copy-matches copy-marked? copy-count-limit!)
