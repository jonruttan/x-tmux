; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/vt.x -- a terminal's screen, kept from the bytes a program writes
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The screen is two byte buffers of ROWS x COLS: the cells, and each cell's
; attribute (1 + its SGR bits, never 0, so strspn can find a run of one).
; A row written since the last render is marked in the dirty buffer, and a
; render writes those rows alone, as a terminal redraws them.
;
; The rows are kept in no fixed order: the row map, a word a row, gives
; the buffers' row that holds each of the screen's.  A scroll turns the
; region's part of the map and blanks the rows it frees, rather than
; moving the cells.  The dirty buffer goes by the screen's rows.
;
; A line feed that scrolls the main screen's region first copies the
; region's top row to the history, as tmux keeps one: three more buffers
; of LIMIT rows, a ring whose oldest row gives way to a new one once it is
; full.  An erase of the whole screen scrolls it into the history too.  A
; deleted line and the alternate screen keep none.
;
; A cell's byte is its character when that is ASCII.  A character past
; ASCII is kept in the cell's 16-byte slot of the extended buffer -- its
; UTF-8 bytes (up to 14, combining characters appended), their count, and
; its width -- and the cell's byte is 128; the second cell of a wide
; character is 129, a padding cell.  As tmux keeps them: printing over
; either half of a wide character blanks the other, and the edits that
; move cells (insert, delete, erase) move padding as any cell.
;
; This file is the reference engine, in x: printable bytes go in as runs
; (strcspn finds a run's end, memcpy and memset place it), escape sequences
; a byte at a time.  tmux/vt-jit compiles the same engine and, once it
; agrees with this one, vt-adopt! makes it the one vt-feed! and vt-render!
; use.  A host with no JIT keeps this one.
;
; The state is machine words in one buffer, read and written by the C
; pointer doors, and the hot paths sequence in fn bodies, not `do`, which
; rebuilds its body each time it runs.

(module tmux/vt)

(import tmux/width char-width)

(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %pset (prim-ref (lit ptr) (lit set!)))
(def %call (prim-ref (lit ptr) (lit call)))
(def %dlsym (prim-ref (lit ffi) (lit dlsym)))
(def %dlopen (prim-ref (lit ffi) (lit dlopen)))
(def %quot (prim-ref (lit int) (lit /)))
(def %rem (prim-ref (lit int) (lit %)))
(def %min (fn (_ a b) (if (< a b) a b)))
(def %max (fn (_ a b) (if (< a b) b a)))

; libc, looked up when a screen is made: a handle is a fact of the process
(def %c-memcpy ()) (def %c-memmove ()) (def %c-memset ()) (def %c-strcspn ())
(def %c-strspn ()) (def %c-memcmp ()) (def %c-memchr ())
(def %resolve!
  (fn (_)
    (def lib (%dlopen () 1))
    (set! %c-memcmp (%dlsym lib "memcmp"))
    (set! %c-memchr (%dlsym lib "memchr"))
    (set! %c-memcpy (%dlsym lib "memcpy"))
    (set! %c-memmove (%dlsym lib "memmove"))
    (set! %c-memset (%dlsym lib "memset"))
    (set! %c-strcspn (%dlsym lib "strcspn"))
    (set! %c-strspn (%dlsym lib "strspn"))))

; The state words, by byte offset: the buffers' addresses, then the
; cursor and the parser.  PARAMS holds up to 16 CSI parameters.  Words 40
; on are the compiled engine's (tmux/vt-jit names them): IN, POS and END
; its input, 51 to 54 its render's row, column, state and output count.
; Words 56 and 57 are where on the terminal a render puts the screen's
; top-left cell, a row and a column from 0.  The alternate screen's words:
; the saved cells' and attributes' addresses, whether the alternate screen
; is up, whether ?1049 saved the cursor, and the row, column and attribute
; it saved.  UTF-8's: the extended buffer's address and the saved one's,
; a character read in part (its bits so far and the bytes it still
; needs), and the two bytes a render's runs of ASCII stop at.  Then the
; row map's address, the saved screen's map's, and a map's worth of
; scratch; words 70 to 73 are the compiled engine's again.  Words 74 to 79
; are the history's: its cells', attributes' and extended slots'
; addresses, the most rows it keeps, its oldest row's slot, and how many
; rows it holds.  Word 80 is the compiled engine's.
(def %ROWS 0) (def %COLS 8) (def %CP 16) (def %AP 24) (def %DP 32) (def %SP 40)
(def %OP 48) (def %ONE 56) (def %ROW 64) (def %COL 72) (def %EP 80) (def %ATTR 88)
(def %STATE 96) (def %NUM 104) (def %NP 112) (def %PRIVATE 120) (def %TOP 128)
(def %BOTTOM 136) (def %SROW 144) (def %SCOL 152) (def %PARAMS 160)
(def %SCP 288) (def %SAP 296) (def %ALT 304) (def %ASAVED 312)
(def %IN 320) (def %POS 328) (def %END 336)
(def %RR 408) (def %RC 416) (def %RS 424) (def %RO 432)
(def %OROW 448) (def %OCOL 456) (def %AROW 464) (def %ACOL 472) (def %AATTR 480)
(def %SEP 488) (def %UACC 496) (def %UNEED 504) (def %MARKS 512)
(def %MAP 536) (def %SMAP 544) (def %TMAP 552)
(def %HC 592) (def %HA 600) (def %HX 608) (def %HLIM 616) (def %HHEAD 624) (def %HCOUNT 632)
(def %WORDS 81)

; The rows of history a screen keeps, tmux's history-limit.
(def %HISTORY 2000)

; A cell's byte for a character in the extended buffer, and for padding.
(def %WIDE 128) (def %PAD 129)

(def %w (fn (_ s o) (%pref s o 8)))
(def %w! (fn (_ s o x) (%pset s o x 8)))
(def %addr (fn (_ s o) (%int->ptr (%pref s o 8))))

; The bytes a printable run stops at: every control byte, DEL, and every
; byte past ASCII, which the UTF-8 reader takes.
(def %stops
  (fn (_)
    (def s (%make-str 161))
    (def p (%str->ptr s))
    ((fn (self i) (if (< i 32) (self (%stop! p (- i 1) i)) ())) 1)
    (%pset p 31 127 1)
    ((fn (self i) (if (< i 256) (self (%stop! p (- i 96) i)) ())) 128)
    (%pset p 160 0 1)
    s))
(def %stop! (fn (_ p at b) (%pset p at b 1) (+ b 1)))

(def %buffer
  (fn (_ n fill)
    (def s (%make-str (+ n 1)))
    (%call %c-memset (%str->ptr s) fill n)
    (%pset (%str->ptr s) n 0 1)
    s))

; A screen: (KEEP . S), S the state's pointer, KEEP what holds the
; buffers alive.
(def vt-make (fn (_ rows cols) (vt-make-history rows cols %HISTORY)))
; One that keeps LIMIT rows of history.
(def vt-make-history
  (fn (_ rows cols limit)
    (%resolve!)
    (def words (%buffer (* 8 %WORDS) 0))
    (def s (%str->ptr words))
    (def cells (%buffer (* rows cols) 32))
    (def attrs (%buffer (* rows cols) 1))
    (def dirty (%buffer rows 1))
    (def stop (%stops))
    (def out (%make-str (+ 64 (* rows (+ 16 (* cols 12))))))
    (def one (%buffer 1 1))
    (def saved-cells (%buffer (* rows cols) 32))
    (def saved-attrs (%buffer (* rows cols) 1))
    (def ext (%buffer (* 16 (* rows cols)) 0))
    (def saved-ext (%buffer (* 16 (* rows cols)) 0))
    (def marks (%buffer 2 %WIDE))
    (%pset (%str->ptr marks) 1 %PAD 1)
    (def map (%identity rows))
    (def saved-map (%identity rows))
    (def scratch (%buffer (* 8 rows) 0))
    (def history-cells (%buffer (* limit cols) 32))
    (def history-attrs (%buffer (* limit cols) 1))
    (def history-ext (%buffer (* 16 (* limit cols)) 0))
    (%w! s %HC (%ptr->int (%str->ptr history-cells))) (%w! s %HA (%ptr->int (%str->ptr history-attrs)))
    (%w! s %HX (%ptr->int (%str->ptr history-ext))) (%w! s %HLIM limit)
    (%w! s %MAP (%ptr->int (%str->ptr map))) (%w! s %SMAP (%ptr->int (%str->ptr saved-map)))
    (%w! s %TMAP (%ptr->int (%str->ptr scratch)))
    (%w! s %ROWS rows) (%w! s %COLS cols)
    (%w! s %CP (%ptr->int (%str->ptr cells))) (%w! s %AP (%ptr->int (%str->ptr attrs)))
    (%w! s %DP (%ptr->int (%str->ptr dirty))) (%w! s %SP (%ptr->int (%str->ptr stop)))
    (%w! s %OP (%ptr->int (%str->ptr out))) (%w! s %ONE (%ptr->int (%str->ptr one)))
    (%w! s %SCP (%ptr->int (%str->ptr saved-cells))) (%w! s %SAP (%ptr->int (%str->ptr saved-attrs)))
    (%w! s %EP (%ptr->int (%str->ptr ext))) (%w! s %SEP (%ptr->int (%str->ptr saved-ext)))
    (%w! s %MARKS (%ptr->int (%str->ptr marks)))
    (%w! s %ATTR 1) (%w! s %NUM -1) (%w! s %BOTTOM (- rows 1))
    (pair (list words cells attrs dirty stop out one saved-cells saved-attrs ext saved-ext marks
            map saved-map scratch history-cells history-attrs history-ext)
          s)))

; A row map in order: row I in buffer row I.
(def %identity
  (fn (_ rows)
    (def m (%buffer (* 8 rows) 0))
    ((fn (self i) (if (< i rows) (self (%word-at! (%str->ptr m) i)) ())) 0)
    m))
(def %word-at! (fn (_ p i) (%pset p (* 8 i) i 8) (+ i 1)))

; Cell (ROW, COL) of the buffer at BASE, %CP or %AP, through the row map.
; The lookup is written out in each, as these run for nearly every cell.
(def %at
  (fn (_ s base row col)
    (%int->ptr (+ (%pref s base 8) (+ (* (%pref (%int->ptr (+ (%pref s %MAP 8) (* 8 row))) 0 8) (%pref s %COLS 8)) col)))))
(def %row (fn (_ s row) (%pref (%int->ptr (+ (%w s %MAP) (* 8 row))) 0 8)))
; A cell's slot in an extended buffer, BASE %EP.
(def %slot
  (fn (_ s base row col)
    (%int->ptr (+ (%pref s base 8)
                  (* 16 (+ (* (%pref (%int->ptr (+ (%pref s %MAP 8) (* 8 row))) 0 8) (%pref s %COLS 8)) col))))))
(def %cell (fn (_ s row col) (%pref (%at s %CP row col) 0 1)))
(def %cell! (fn (_ s row col b) (%pset (%at s %CP row col) 0 b 1)))
(def %dirty! (fn (_ s row) (%pset (%addr s %DP) row 1 1)))
(def %dirty-rows! (fn (_ s a b) (%call %c-memset (%int->ptr (+ (%w s %DP) a)) 1 (+ (- b a) 1))))

; Cells from (ROW, A) to (ROW, B) inclusive blanked.
(def %blank!
  (fn (_ s row a b)
    (if (< b a) () (%blank-run! s row a (+ (- b a) 1)))))
(def %blank-run!
  (fn (_ s row a n)
    (%call %c-memset (%at s %CP row a) 32 n)
    (%call %c-memset (%at s %AP row a) (%w s %ATTR) n)
    (%dirty! s row)))
(def %blank-rows!
  (fn (self s r e) (if (< r e) (self s (%blank-row! s r) e) ())))
(def %blank-row! (fn (_ s r) (%blank-run! s r 0 (%w s %COLS)) (+ r 1)))

; Rows TOP..BOTTOM moved up N (down when N is negative), the freed rows
; blanked: the region's part of the map turned by N, the buffer rows that
; leave one end coming back at the other.
(def %scroll!
  (fn (_ s top bottom n)
    (def k (%min (if (< n 0) (- 0 n) n) (+ (- bottom top) 1)))
    (def keep (- (+ (- bottom top) 1) k))
    (if (< n 0)
      (%turn! s (+ top keep) top (+ top k) top k keep)
      (%turn! s top (+ top k) top (+ top keep) k keep))
    (if (< n 0) (%blank-rows! s top (+ top k)) (%blank-rows! s (+ (- bottom k) 1) (+ bottom 1)))
    (%dirty-rows! s top bottom)))
; The map's K entries at OUT set aside, its KEEP entries at FROM moved to
; TO, and the K put back at IN.
(def %turn!
  (fn (_ s out from to in k keep)
    (%call %c-memcpy (%addr s %TMAP) (%map-at s out) (* 8 k))
    (%call %c-memmove (%map-at s to) (%map-at s from) (* 8 keep))
    (%call %c-memcpy (%map-at s in) (%addr s %TMAP) (* 8 k))))
(def %map-at (fn (_ s row) (%int->ptr (+ (%w s %MAP) (* 8 row)))))

(def %linefeed!
  (fn (_ s)
    (def row (%w s %ROW))
    (if (= row (%w s %BOTTOM))
      (%scroll-up! s (%w s %TOP) row)
      (if (< row (- (%w s %ROWS) 1)) (%w! s %ROW (+ row 1)) ()))))
(def %scroll-up!
  (fn (_ s top bottom)
    (if (%keeps? s) (%keep-row! s top) ())
    (%scroll! s top bottom 1)))

; Whether the screen keeps what scrolls off: the main screen, with a
; history.
(def %keeps? (fn (_ s) (if (= (%w s %ALT) 0) (< 0 (%w s %HLIM)) #f)))
; Screen row R copied to the history as its newest row, the oldest giving
; way once it is full.
(def %keep-row!
  (fn (_ s r)
    (def cols (%w s %COLS))
    (def count (%w s %HCOUNT))
    (def from (* (%row s r) cols))
    (def to (* (%history-slot s count) cols))
    (%call %c-memcpy (%int->ptr (+ (%w s %HC) to)) (%int->ptr (+ (%w s %CP) from)) cols)
    (%call %c-memcpy (%int->ptr (+ (%w s %HA) to)) (%int->ptr (+ (%w s %AP) from)) cols)
    (%call %c-memcpy (%int->ptr (+ (%w s %HX) (* 16 to))) (%int->ptr (+ (%w s %EP) (* 16 from))) (* 16 cols))
    (if (< count (%w s %HLIM))
      (%w! s %HCOUNT (+ count 1))
      (%w! s %HHEAD (%history-slot s 1)))
    (+ r 1)))
; The slot of history row I, 0 the oldest.
(def %history-slot
  (fn (_ s i)
    (def j (+ (%w s %HHEAD) i))
    (if (< j (%w s %HLIM)) j (- j (%w s %HLIM)))))

(def %newline! (fn (_ s) (%w! s %COL 0) (%linefeed! s)))

; A printable run of N bytes at address P placed at the cursor, wrapping.
; The cursor's column runs to COLS, as tmux's does: a row just filled
; leaves it there, and the next byte printed wraps first.
(def %put!
  (fn (self s p n)
    (if (< 0 n) (%put-rest! self s p n (%place! s p n)) ())))
(def %put-rest! (fn (_ put s p n k) (put s (+ p k) (- n k))))
; Places what fits on the cursor's row and answers how much.
(def %place!
  (fn (_ s p n)
    (def cols (%w s %COLS))
    (if (< (%w s %COL) cols) () (%newline! s))
    (def row (%w s %ROW))
    (def col (%w s %COL))
    (def k (%min n (- cols col)))
    (%unpair! s row col (+ col (- k 1)))
    (%call %c-memcpy (%at s %CP row col) (%int->ptr p) k)
    (%call %c-memset (%at s %AP row col) (%w s %ATTR) k)
    (%dirty! s row)
    (%w! s %COL (+ col k))
    k))

; Cells A..B of ROW about to be printed over: a wide character they take
; only half of has its other half blanked, as tmux blanks it.
(def %unpair!
  (fn (_ s row a b)
    (if (if (< 0 a) (= (%cell s row a) %PAD) #f) (%cell! s row (- a 1) 32) ())
    (if (if (< (+ b 1) (%w s %COLS)) (= (%cell s row (+ b 1)) %PAD) #f) (%cell! s row (+ b 1) 32) ())))

; --- UTF-8 ---------------------------------------------------------------

; One byte past ASCII, or one that ends a character read in part: the
; character's bits gathered, and the character put when it is whole.  A
; byte that cannot start a character, or a character cut short, is put as
; U+FFFD, as tmux puts it; answers #f when B was not taken and is to be
; read again, after a character it cut short.
(def %utf8!
  (fn (_ s b)
    (def need (%w s %UNEED))
    (match
      ((< 0 need)
        (if (if (< 127 b) (< b 192) #f)
          (%utf8-more! s b need)
          (%utf8-cut! s)))
      ((if (< 193 b) (< b 224) #f) (%utf8-start! s (& b 31) 1))
      ((if (< 223 b) (< b 240) #f) (%utf8-start! s (& b 15) 2))
      ((if (< 239 b) (< b 245) #f) (%utf8-start! s (& b 7) 3))
      (#t (%char! s 65533)))))
(def %utf8-start! (fn (_ s bits need) (%w! s %UACC bits) (%w! s %UNEED need) #t))
(def %utf8-more!
  (fn (_ s b need)
    (%w! s %UACC (| (<< (%w s %UACC) 6) (& b 63)))
    (%w! s %UNEED (- need 1))
    (if (= need 1) (%char! s (%w s %UACC)) #t)))
(def %utf8-cut! (fn (_ s) (%w! s %UNEED 0) (%char! s 65533) #f))

; CP's UTF-8 bytes written at P: answers how many.
(def %encode!
  (fn (_ p cp)
    (match
      ((< cp 128) (do (%pset p 0 cp 1) 1))
      ((< cp 2048) (do (%pset p 0 (| 192 (>> cp 6)) 1) (%pset p 1 (| 128 (& cp 63)) 1) 2))
      ((< cp 65536) (do (%pset p 0 (| 224 (>> cp 12)) 1) (%pset p 1 (| 128 (& (>> cp 6) 63)) 1)
                        (%pset p 2 (| 128 (& cp 63)) 1) 3))
      (#t (do (%pset p 0 (| 240 (>> cp 18)) 1) (%pset p 1 (| 128 (& (>> cp 12) 63)) 1)
              (%pset p 2 (| 128 (& (>> cp 6) 63)) 1) (%pset p 3 (| 128 (& cp 63)) 1) 4)))))

; A whole character put at the cursor, by its width: wide or narrow, a
; wrap first when it does not fit; or joined to the character before the
; cursor.  Answers #t.
(def %char!
  (fn (_ s cp)
    (def w (char-width cp))
    (if (= w 0) (%join! s cp) (%put-char! s cp w))
    #t))
(def %put-char!
  (fn (_ s cp w)
    (if (< (%w s %COLS) (+ (%w s %COL) w)) (%newline! s) ())
    (def row (%w s %ROW))
    (def col (%w s %COL))
    (%unpair! s row col (+ col (- w 1)))
    (def slot (%slot s %EP row col))
    (%pset slot 14 (%encode! slot cp) 1)
    (%pset slot 15 w 1)
    (%cell! s row col %WIDE)
    (%pset (%at s %AP row col) 0 (%w s %ATTR) 1)
    (if (= w 2) (%pad! s row (+ col 1) (%w s %ATTR)) ())
    (%dirty! s row)
    (%w! s %COL (+ col w))))
(def %pad! (fn (_ s row col attr) (%cell! s row col %PAD) (%pset (%at s %AP row col) 0 attr 1)))

; A zero-width character joined to the cell before the cursor (the wide
; character it belongs to, when that cell is padding), its bytes appended
; while the slot has room; at the row's start it is dropped.  U+FE0F, the
; emoji presentation selector, widens a narrow character the cursor is
; just past, when the row has room.
(def %join!
  (fn (_ s cp)
    (def col (%w s %COL))
    (if (= col 0) () (%join-at! s cp (%w s %ROW) (%min (- col 1) (- (%w s %COLS) 1))))))
(def %join-at!
  (fn (_ s cp row at)
    (def c (if (if (< 0 at) (= (%cell s row at) %PAD) #f) (- at 1) at))
    (if (= (%cell s row c) %WIDE) () (%to-slot! s row c))
    (def slot (%slot s %EP row c))
    (def n (%pref slot 14 1))
    (def tmp (%make-str 5))
    (def k (%encode! (%str->ptr tmp) cp))
    (if (< (+ n k) 15) (%append! slot n (%str->ptr tmp) k) ())
    (if (if (= cp 65039) (if (= (%pref slot 15 1) 1) (if (= (+ c 1) (%w s %COL)) (< (%w s %COL) (%w s %COLS)) #f) #f) #f)
      (%widen! s row c slot)
      ())
    (%dirty! s row)))
(def %append! (fn (_ slot n p k) (%call %c-memcpy (%int->ptr (+ (%ptr->int slot) n)) p k) (%pset slot 14 (+ n k) 1)))
(def %to-slot!
  (fn (_ s row c)
    (def slot (%slot s %EP row c))
    (%pset slot 0 (%cell s row c) 1)
    (%pset slot 14 1 1)
    (%pset slot 15 1 1)
    (%cell! s row c %WIDE)))
(def %widen!
  (fn (_ s row c slot)
    (%unpair! s row (+ c 1) (+ c 1))
    (%pset slot 15 2 1)
    (%pad! s row (+ c 1) (%pref (%at s %AP row c) 0 1))
    (%w! s %COL (+ c 2))))

; A move to (ROW, COL), each kept on the screen.
(def %goto!
  (fn (_ s row col)
    (%w! s %ROW (%max 0 (%min row (- (%w s %ROWS) 1))))
    (%w! s %COL (%max 0 (%min col (- (%w s %COLS) 1))))))

; The parameters as given: NP of them, the Ith 0 when absent.
(def %p (fn (_ s i) (if (< i (%w s %NP)) (%w s (+ %PARAMS (* 8 i))) 0)))
(def %arg (fn (_ s i dflt) (def x (%p s i)) (if (= x 0) dflt x)))

; The SGR bits: 1 bold, 2 reverse, fg 1..8 times 4, bg 64; 1 + bits keeps
; the byte non-zero.
(def %sgr!
  (fn (self s i)
    (if (< i (%w s %NP))
      (self s (%sgr-one! s (%p s i) i))
      (if (= (%w s %NP) 0) (%w! s %ATTR 1) ()))))
(def %sgr-one!
  (fn (_ s p i)
    (def a (- (%w s %ATTR) 1))
    (%w! s %ATTR
      (+ 1 (match
             ((= p 0) 0)
             ((= p 1) (| a 1))
             ((= p 7) (| a 2))
             ((if (< 29 p) (< p 38) #f) (| (& a 67) (* 4 (+ (- p 30) 1))))
             ((= p 39) (& a 67))
             ((if (< 39 p) (< p 48) #f) (| (& a 63) 64))
             ((= p 49) (& a 63))
             (#t a))))
    (+ i 1)))

; A CSI sequence's final byte F.
(def %csi!
  (fn (_ s f)
    (def row (%w s %ROW)) (def col (%w s %COL))
    (def rows (%w s %ROWS)) (def cols (%w s %COLS))
    (match
      ((= f 109) (%sgr! s 0))
      ((= f 72) (%goto! s (- (%arg s 0 1) 1) (- (%arg s 1 1) 1)))
      ((= f 102) (%goto! s (- (%arg s 0 1) 1) (- (%arg s 1 1) 1)))
      ((= f 65) (%goto! s (- row (%arg s 0 1)) col))
      ((= f 66) (%goto! s (+ row (%arg s 0 1)) col))
      ((= f 67) (%goto! s row (+ col (%arg s 0 1))))
      ((= f 68) (%goto! s row (- col (%arg s 0 1))))
      ((= f 71) (%goto! s row (- (%arg s 0 1) 1)))
      ((= f 100) (%goto! s (- (%arg s 0 1) 1) col))
      ((= f 75) (%erase-line! s (%p s 0) row col cols))
      ((= f 74) (%erase-screen! s (%p s 0) row col rows cols))
      ((= f 114) (%region! s (- (%arg s 0 1) 1) (- (%arg s 1 rows) 1)))
      ((= f 76) (if (%in-region? s row) (%scroll! s row (%w s %BOTTOM) (- 0 (%arg s 0 1))) ()))
      ((= f 77) (if (%in-region? s row) (%scroll! s row (%w s %BOTTOM) (%arg s 0 1)) ()))
      ((= f 88) (%blank! s row col (%min (- cols 1) (- (+ col (%arg s 0 1)) 1))))
      ((= f 80) (%delete-chars! s row col cols (%min (%arg s 0 1) (- cols col))))
      ((= f 64) (%insert-chars! s row col cols (%min (%arg s 0 1) (- cols col))))
      ((= f 104) (if (= (%w s %PRIVATE) 1) (%alt-on! s (%alt-mode s 0)) ()))
      ((= f 108) (if (= (%w s %PRIVATE) 1) (%alt-off! s (%alt-mode s 0)) ()))
      (#t ()))))

; The alternate screen, as tmux keeps it.  ?1049h saves the cursor and its
; attribute, then shows a cleared screen; ?47h and ?1047h show one without
; the save.  Any of them with l brings the main screen back, and ?1049l the
; cursor ?1049h saved.  Up already, an h does nothing, and down, an l.  A
; sequence acts on the first of its parameters that names one of the
; three; the screen it clears takes the default attribute.
(def %alt-mode
  (fn (self s i)
    (if (< i (%w s %NP))
      ((fn (_ p) (if (if (= p 1049) #t (if (= p 47) #t (= p 1047))) p (self s (+ i 1)))) (%p s i))
      0)))
(def %alt-on!
  (fn (_ s mode)
    (if (if (= mode 0) #t (= (%w s %ALT) 1)) () (%alt-save! s (= mode 1049)))))
(def %alt-save!
  (fn (_ s cursor)
    (def n (* (%w s %ROWS) (%w s %COLS)))
    (%call %c-memcpy (%addr s %SCP) (%addr s %CP) n)
    (%call %c-memcpy (%addr s %SAP) (%addr s %AP) n)
    (%call %c-memcpy (%addr s %SEP) (%addr s %EP) (* 16 n))
    (%call %c-memcpy (%addr s %SMAP) (%addr s %MAP) (* 8 (%w s %ROWS)))
    (%call %c-memset (%addr s %CP) 32 n)
    (%call %c-memset (%addr s %AP) 1 n)
    (%dirty-rows! s 0 (- (%w s %ROWS) 1))
    (%w! s %ASAVED (if cursor 1 0))
    (%w! s %AROW (%w s %ROW)) (%w! s %ACOL (%w s %COL)) (%w! s %AATTR (%w s %ATTR))
    (%w! s %ALT 1)))
(def %alt-off!
  (fn (_ s mode)
    (if (if (= mode 0) #t (= (%w s %ALT) 0)) () (%alt-restore! s (= mode 1049)))))
(def %alt-restore!
  (fn (_ s cursor)
    (def n (* (%w s %ROWS) (%w s %COLS)))
    (%call %c-memcpy (%addr s %CP) (%addr s %SCP) n)
    (%call %c-memcpy (%addr s %AP) (%addr s %SAP) n)
    (%call %c-memcpy (%addr s %EP) (%addr s %SEP) (* 16 n))
    (%call %c-memcpy (%addr s %MAP) (%addr s %SMAP) (* 8 (%w s %ROWS)))
    (%dirty-rows! s 0 (- (%w s %ROWS) 1))
    (if (if cursor (= (%w s %ASAVED) 1) #f) (%alt-cursor! s) ())
    (%w! s %ASAVED 0)
    (%w! s %ALT 0)))
(def %alt-cursor!
  (fn (_ s) (%w! s %ROW (%w s %AROW)) (%w! s %COL (%w s %ACOL)) (%w! s %ATTR (%w s %AATTR))))

(def %in-region? (fn (_ s row) (if (< row (%w s %TOP)) #f (< row (+ (%w s %BOTTOM) 1)))))
; A region whose top is not above its bottom, or that leaves the screen,
; is ignored, as terminals ignore it.
(def %region!
  (fn (_ s top bottom)
    (if (if (< top bottom) (< bottom (%w s %ROWS)) #f) (%set-region! s top bottom) ())))
(def %set-region! (fn (_ s top bottom) (%w! s %TOP top) (%w! s %BOTTOM bottom) (%goto! s 0 0)))
(def %erase-line!
  (fn (_ s m row col cols)
    (match ((= m 0) (%blank! s row col (- cols 1)))
           ((= m 1) (%blank! s row 0 (%min col (- cols 1))))
           (#t (%blank! s row 0 (- cols 1))))))
; An erase of the whole screen, 2 or 0 from the top-left cell, scrolls its
; rows to the last one used into the history first, as tmux's
; scroll-on-clear does; 3 empties the history.  A row is used when a cell
; is not blank.
(def %erase-screen!
  (fn (_ s m row col rows cols)
    (match ((= m 0) (do (if (if (= row 0) (= col 0) #f) (%keep-screen! s) ()) (%below! s row col rows cols)))
           ((= m 1) (%above! s row col cols))
           ((= m 2) (do (%keep-screen! s) (%blank-rows! s 0 rows)))
           ((= m 3) (do (%w! s %HCOUNT 0) (%w! s %HHEAD 0)))
           (#t ()))))
(def %keep-screen!
  (fn (_ s)
    (if (%keeps? s)
      ((fn (self r n) (if (< r n) (self (%keep-row! s r) n) ())) 0 (%used s (%w s %ROWS)))
      ())))
; The rows to the last used one, of the first N.
(def %used
  (fn (self s n)
    (if (if (< 0 n) (%blank-row? s (- n 1)) #f) (self s (- n 1)) n)))
(def %blank-row?
  (fn (_ s r) (not (< (%call %c-strspn (%at s %CP r 0) (%str->ptr " ")) (%w s %COLS)))))
(def %below! (fn (_ s row col rows cols) (%blank! s row col (- cols 1)) (%blank-rows! s (+ row 1) rows)))
(def %above! (fn (_ s row col cols) (%blank-rows! s 0 row) (%blank! s row 0 (%min col (- cols 1)))))
(def %delete-chars!
  (fn (_ s row col cols n)
    (def keep (- (- cols col) n))
    (if (< 0 keep) (%shift! s row col (+ col n) keep) ())
    (%blank! s row (- cols n) (- cols 1))))
(def %insert-chars!
  (fn (_ s row col cols n)
    (def keep (- (- cols col) n))
    (if (< 0 keep) (%shift! s row (+ col n) col keep) ())
    (%blank! s row col (- (+ col n) 1))))
(def %shift!
  (fn (_ s row to from n)
    (%call %c-memmove (%at s %CP row to) (%at s %CP row from) n)
    (%call %c-memmove (%at s %AP row to) (%at s %AP row from) n)
    (%call %c-memmove (%slot s %EP row to) (%slot s %EP row from) (* 16 n))))

; The parser's states: 0 ground, 1 after ESC, 2 in a CSI, 3 in an OSC,
; 4 one byte to swallow (a charset designation).
(def %esc-byte!
  (fn (_ s b)
    (match
      ((= b 91) (%csi-start! s))
      ((= b 93) (%w! s %STATE 3))
      ((= b 40) (%w! s %STATE 4))
      ((= b 41) (%w! s %STATE 4))
      ((= b 35) (%w! s %STATE 4))
      ((= b 55) (%save! s))
      ((= b 56) (%restore! s))
      ((= b 77) (%reverse-index! s))
      ((= b 68) (%ground! s (%linefeed! s)))
      ((= b 69) (%ground! s (%newline! s)))
      (#t (%w! s %STATE 0)))))
(def %ground! (fn (_ s _x) (%w! s %STATE 0)))
(def %csi-start! (fn (_ s) (%w! s %STATE 2) (%w! s %NP 0) (%w! s %NUM -1) (%w! s %PRIVATE 0)))
(def %save! (fn (_ s) (%w! s %SROW (%w s %ROW)) (%w! s %SCOL (%w s %COL)) (%w! s %STATE 0)))
(def %restore! (fn (_ s) (%goto! s (%w s %SROW) (%w s %SCOL)) (%w! s %STATE 0)))
(def %reverse-index!
  (fn (_ s)
    (if (= (%w s %ROW) (%w s %TOP))
      (%scroll! s (%w s %TOP) (%w s %BOTTOM) -1)
      (%goto! s (- (%w s %ROW) 1) (%w s %COL)))
    (%w! s %STATE 0)))

(def %csi-byte!
  (fn (_ s b)
    (match
      ((if (< 47 b) (< b 58) #f) (%w! s %NUM (+ (* (%max 0 (%w s %NUM)) 10) (- b 48))))
      ((= b 59) (%param! s (%max 0 (%w s %NUM))))
      ((= b 63) (%w! s %PRIVATE 1))
      ((if (< 63 b) (< b 127) #f) (%csi-end! s b))
      (#t ()))))
(def %param!
  (fn (_ s x)
    (if (< (%w s %NP) 16) (%w! s (+ %PARAMS (* 8 (%w s %NP))) x) ())
    (%w! s %NP (+ (%w s %NP) 1))
    (%w! s %NUM -1)))
(def %csi-end!
  (fn (_ s b)
    (if (< (%w s %NUM) 0) (if (< 0 (%w s %NP)) (%param! s 0) ()) (%param! s (%w s %NUM)))
    (%w! s %STATE 0)
    (%csi! s b)))

(def %control!
  (fn (_ s b)
    (match
      ((= b 27) (%w! s %STATE 1))
      ((= b 10) (%lf! s))
      ((= b 11) (%lf! s))
      ((= b 12) (%lf! s))
      ((= b 13) (%cr! s))
      ((= b 8) (%bs! s))
      ((= b 9) (%tab! s))
      (#t ()))))
(def %lf! (fn (_ s) (%linefeed! s)))
(def %cr! (fn (_ s) (%w! s %COL 0)))
(def %bs! (fn (_ s) (%w! s %COL (%max 0 (- (%w s %COL) 1)))))
; The next tab stop, every eighth column, short of the last; a cursor at
; the last column or past it stays.
(def %tab!
  (fn (_ s)
    (def col (%w s %COL))
    (def last (- (%w s %COLS) 1))
    (if (< col last) (%w! s %COL (%min last (* 8 (+ (>> col 3) 1)))) ())))

; One byte in an escape state.
(def %escaped!
  (fn (_ s b)
    (def st (%w s %STATE))
    (match
      ((= b 27) (%w! s %STATE 1))
      ((= st 1) (%esc-byte! s b))
      ((= st 2) (if (< b 32) (%control! s b) (%csi-byte! s b)))
      ((= st 3) (if (= b 7) (%w! s %STATE 0) ()))
      (#t (%w! s %STATE 0)))))

; LEN bytes at address P fed to the screen.  P must be followed by a NUL,
; which bounds strcspn.
(def vt-feed-pure!
  (fn (_ h p len)
    (def s (rest h))
    (def end (+ p len))
    (def stop (%addr s %SP))
    ((fn (self i) (if (< i end) (self (%step! s stop i end)) ())) p)))

; One step from I: a printable run, a control byte, or an escaped byte;
; answers where the next step starts.
; An ASCII byte where a character was being read cuts it short first.
(def %step!
  (fn (_ s stop i end)
    (def b (%pref (%int->ptr i) 0 1))
    (if (if (< 0 (%w s %UNEED)) (< b 128) #f) (%utf8-cut! s) ())
    (if (= (%w s %STATE) 0)
      (%ground-step! s i b (%min (%call %c-strcspn (%int->ptr i) stop) (- end i)))
      (%escaped-step! s i))))
(def %ground-step!
  (fn (_ s i b run)
    (match
      ((< 0 run) (%ran! s i run))
      ((< b 128) (%controlled! s i))
      (#t (if (%utf8! s b) (+ i 1) i)))))
(def %ran! (fn (_ s i run) (%put! s i run) (+ i run)))
(def %controlled! (fn (_ s i) (%control! s (%pref (%int->ptr i) 0 1)) (+ i 1)))
(def %escaped-step! (fn (_ s i) (%escaped! s (%pref (%int->ptr i) 0 1)) (+ i 1)))

; The rows marked since the last render written to the output buffer as
; a terminal redraws them: a cursor move, then each run of one attribute
; as its SGR and its bytes.  Answers the byte count; the marks are cleared.
(def %b! (fn (_ at b) (%pset (%int->ptr at) 0 b 1) (+ at 1)))

; N, at most three digits, in decimal.
(def %dec!
  (fn (_ at n)
    (if (< n 10) (%b! at (+ 48 n))
      (if (< n 100) (%b! (%b! at (+ 48 (%quot n 10))) (+ 48 (%rem n 10)))
        (%b! (%b! (%b! at (+ 48 (%quot n 100))) (+ 48 (%rem (%quot n 10) 10)))
             (+ 48 (%rem n 10)))))))

; ESC [ 0 ;1 ;7 ;3N ;4N m, for the bits an attribute byte holds.
(def %sgr-bytes!
  (fn (_ at a)
    (def bits (- a 1))
    (def at1 (%b! (%b! (%b! at 27) 91) 48))
    (def at2 (if (= (& bits 1) 1) (%b! (%b! at1 59) 49) at1))
    (def at3 (if (= (& bits 2) 2) (%b! (%b! at2 59) 55) at2))
    (def fg (& (>> bits 2) 15))
    (def at4 (if (< 0 fg) (%b! (%b! (%b! at3 59) 51) (+ 47 fg)) at3))
    (%b! at4 109)))

(def vt-render-pure!
  (fn (_ h)
    (def s (rest h))
    (def rows (%w s %ROWS))
    (def base (%w s %OP))
    (def end ((fn (self r at) (if (= r rows) at (self (+ r 1) (%render-row! s r at)))) 0 base))
    (%call %c-memset (%addr s %DP) 0 rows)
    (- end base)))
(def %render-row!
  (fn (_ s r at)
    (if (= (%pref (%addr s %DP) r 1) 0) at
      (%render-runs! s r 0
        (%b! (%dec! (%b! (%dec! (%b! (%b! at 27) 91) (+ r (+ 1 (%w s %OROW)))) 59) (+ 1 (%w s %OCOL))) 72)))))
(def %render-runs!
  (fn (self s r c at)
    (if (= c (%w s %COLS)) at
      (%render-next! self s r c (%run-length s r c) at))))
(def %render-next! (fn (_ runs s r c k at) (runs s r (+ c k) (%render-run! s r c k at))))
(def %run-length
  (fn (_ s r c)
    (def one (%addr s %ONE))
    (%pset one 0 (%pref (%at s %AP r c) 0 1) 1)
    (%max 1 (%min (%call %c-strspn (%at s %AP r c) one) (- (%w s %COLS) c)))))
(def %render-run!
  (fn (_ s r c k at)
    (%emit-cells! s r c (+ c k) (%sgr-bytes! at (%pref (%at s %AP r c) 0 1)))))

; Cells C..E-1 of row R written from AT: runs of ASCII as they are, a
; character past ASCII as its slot's bytes, padding as nothing after the
; wide character it belongs to.  So that the terminal's cursor stays on
; the cells, padding a wide character no longer has is written as a
; blank, and a wide character with no padding after it is followed by a
; move to the next cell.
(def %emit-cells!
  (fn (self s r c e at)
    (if (= c e) at
      ((fn (_ n)
         (match
           ((< 0 n) (do (%call %c-memcpy (%int->ptr at) (%at s %CP r c) n) (self s r (+ c n) e (+ at n))))
           ((= (%cell s r c) %WIDE) (self s r (+ c 1) e (%emit-wide! s r c at)))
           (#t (self s r (+ c 1) e (if (%padding? s r c) at (%b! at 32))))))
       (%min (%call %c-strcspn (%at s %CP r c) (%addr s %MARKS)) (- e c))))))
(def %emit-wide!
  (fn (_ s r c at)
    (def slot (%slot s %EP r c))
    (def n (%pref slot 14 1))
    (%call %c-memcpy (%int->ptr at) slot n)
    (if (if (= (%pref slot 15 1) 2) (not (%padded? s r c)) #f)
      (%cup! (+ at n) (+ r (+ 1 (%w s %OROW))) (+ c (+ 2 (%w s %OCOL))))
      (+ at n))))
(def %padded? (fn (_ s r c) (if (< (+ c 1) (%w s %COLS)) (= (%cell s r (+ c 1)) %PAD) #f)))
(def %padding?
  (fn (_ s r c)
    (if (< 0 c)
      (if (= (%cell s r (- c 1)) %WIDE) (= (%pref (%slot s %EP r (- c 1)) 15 1) 2) #f)
      #f)))
(def %cup! (fn (_ at row col) (%b! (%dec! (%b! (%dec! (%b! (%b! at 27) 91) row) 59) col) 72)))

(def vt-out (fn (_ h) (%addr (rest h) %OP)))
(def vt-cursor (fn (_ h) (pair (%w (rest h) %ROW) (%w (rest h) %COL))))
(def vt-size (fn (_ h) (pair (%w (rest h) %ROWS) (%w (rest h) %COLS))))

; Where a render puts the screen: its top-left cell at terminal row ROW,
; column COL, each from 0.
(def vt-origin!
  (fn (_ h row col)
    (%w! (rest h) %OROW row)
    (%w! (rest h) %OCOL col)
    h))

; Every row marked, so the next render writes the whole screen.
(def vt-touch!
  (fn (_ h)
    (def s (rest h))
    (%call %c-memset (%addr s %DP) 1 (%w s %ROWS))
    h))

; A new screen of ROWS x COLS with H's cells and attributes where they
; fit, the main screen's too while the alternate one is up, its cursor,
; attribute, alternate-screen state, history and origin; a pane resized.
; The scroll region is the whole new screen.
(def vt-carry
  (fn (_ h rows cols)
    (def s (rest h))
    (def n (vt-make-history rows cols (%w s %HLIM)))
    (def t (rest n))
    (%carry-cells! s t %MAP %CP %AP %EP rows cols)
    (%carry-cells! s t %SMAP %SCP %SAP %SEP rows cols)
    (%carry-history! s t cols)
    (%w! t %ROW (%min (%w s %ROW) (- rows 1)))
    (%w! t %COL (%min (%w s %COL) cols))
    (%w! t %ATTR (%w s %ATTR))
    (%w! t %ALT (%w s %ALT)) (%w! t %ASAVED (%w s %ASAVED))
    (%w! t %AROW (%min (%w s %AROW) (- rows 1))) (%w! t %ACOL (%min (%w s %ACOL) cols))
    (%w! t %AATTR (%w s %AATTR))
    (vt-origin! n (%w s %OROW) (%w s %OCOL))))
; One screen's rows of S, by its map at MAP, copied to T's in order: T is
; new, and its maps are in order.
(def %carry-cells!
  (fn (_ s t map cells attrs ext rows cols)
    (def keep-rows (%min rows (%w s %ROWS)))
    (def keep-cols (%min cols (%w s %COLS)))
    ((fn (self r)
       (when (< r keep-rows)
         (do (def from (* (%pref (%int->ptr (+ (%w s map) (* 8 r))) 0 8) (%w s %COLS)))
             (def to (* r cols))
             (%call %c-memcpy (%int->ptr (+ (%w t cells) to)) (%int->ptr (+ (%w s cells) from)) keep-cols)
             (%call %c-memcpy (%int->ptr (+ (%w t attrs) to)) (%int->ptr (+ (%w s attrs) from)) keep-cols)
             (%call %c-memcpy (%int->ptr (+ (%w t ext) (* 16 to))) (%int->ptr (+ (%w s ext) (* 16 from)))
               (* 16 keep-cols))
             (self (+ r 1)))))
     0)))
; S's history copied to T's, which is new and empty: its newest rows, as
; many as T keeps, oldest first.
(def %carry-history!
  (fn (_ s t cols)
    (def n (%min (%w s %HCOUNT) (%w t %HLIM)))
    (def skip (- (%w s %HCOUNT) n))
    ((fn (self i)
       (when (< i n)
         (do (%copy-row! t i %HC %HA %HX (%w s %HC) (%w s %HA) (%w s %HX)
               (* (%history-slot s (+ skip i)) (%w s %COLS)) (%min cols (%w s %COLS)))
             (self (+ i 1)))))
     0)
    (%w! t %HCOUNT n)))
; KEEP-COLS cells from cell FROM of the buffers at CELLS, ATTRS and EXT to
; buffer row R of T's buffers at words TC, TA and TX.
(def %copy-row!
  (fn (_ t r tc ta tx cells attrs ext from keep-cols)
    (def to (* r (%w t %COLS)))
    (%call %c-memcpy (%int->ptr (+ (%w t tc) to)) (%int->ptr (+ cells from)) keep-cols)
    (%call %c-memcpy (%int->ptr (+ (%w t ta) to)) (%int->ptr (+ attrs from)) keep-cols)
    (%call %c-memcpy (%int->ptr (+ (%w t tx) (* 16 to))) (%int->ptr (+ ext (* 16 from))) (* 16 keep-cols))))

; Row R's text: its characters in UTF-8, padding as nothing, as tmux's
; capture-pane writes a row.
(def vt-row
  (fn (_ h r)
    (def s (rest h))
    (def at (* (%row s r) (%w s %COLS)))
    (%text s (+ (%w s %CP) at) (+ (%w s %EP) (* 16 at)))))
; The text of the row whose cells start at address CELLS, their slots at EXT.
(def %text (fn (_ s cells ext) (%text-span cells ext 0 (%w s %COLS))))
; Its cells FROM to TO-1.
(def %text-span
  (fn (_ cells ext from to)
    (def buf (%make-str (+ 1 (* 14 (- to from)))))
    (def p (%ptr->int (%str->ptr buf)))
    (def n ((fn (self c at) (if (= c to) at (self (+ c 1) (%text-cell! cells ext c at)))) from p))
    ((prim-ref (lit str) (lit byte-sub)) buf 0 (- n p))))
(def %text-cell!
  (fn (_ cells ext c at)
    (def b (%pref (%int->ptr cells) c 1))
    (match
      ((< b 128) (%b! at b))
      ((= b %WIDE) ((fn (_ slot) (do (%call %c-memcpy (%int->ptr at) slot (%pref slot 14 1)) (+ at (%pref slot 14 1))))
                     (%int->ptr (+ ext (* 16 c)))))
      (#t at))))
; Row R's length: its cells to the last one not blank.
(def vt-row-length
  (fn (_ h r)
    (def s (rest h))
    ((fn (loop c) (if (if (< 0 c) (= (%cell s r (- c 1)) 32) #f) (loop (- c 1)) c)) (%w s %COLS))))
(def vt-attrs
  (fn (_ h r)
    (def s (rest h))
    ((prim-ref (lit str) (lit byte-sub)) (List ref 2 (first h)) (* (%row s r) (%w s %COLS)) (%w s %COLS))))

; The rows of history the screen holds.  The alternate screen adds none,
; but shows the main screen's above it, as tmux's does.
(def vt-history (fn (_ h) (%w (rest h) %HCOUNT)))
; History row I's text and attributes, 0 the oldest.
(def vt-history-row
  (fn (_ h i)
    (def s (rest h))
    (def at (* (%history-slot s i) (%w s %COLS)))
    (%text s (+ (%w s %HC) at) (+ (%w s %HX) (* 16 at)))))
(def vt-history-attrs
  (fn (_ h i)
    (def s (rest h))
    ((prim-ref (lit str) (lit byte-sub)) (List ref 16 (first h)) (* (%history-slot s i) (%w s %COLS)) (%w s %COLS))))

; Whether A's and B's histories, of one width, hold the same rows: each
; row's cells and attributes, and its text where a character is past
; ASCII, since a slot no cell uses may hold anything.
(def vt-history-same?
  (fn (_ a b)
    (def s (rest a))
    (def t (rest b))
    (def n (%w s %HCOUNT))
    (if (= n (%w t %HCOUNT))
      ((fn (self i) (if (= i n) #t (if (%history-row-same? a b i) (self (+ i 1)) #f))) 0)
      #f)))
(def %history-row-same?
  (fn (_ a b i)
    (def s (rest a))
    (def t (rest b))
    (def cols (%w s %COLS))
    (def p (%int->ptr (+ (%w s %HC) (* (%history-slot s i) cols))))
    (def q (%int->ptr (+ (%w t %HC) (* (%history-slot t i) cols))))
    (if (= 0 (%call %c-memcmp p q cols))
      (if (= 0 (%call %c-memcmp (%int->ptr (+ (%w s %HA) (* (%history-slot s i) cols)))
                 (%int->ptr (+ (%w t %HA) (* (%history-slot t i) cols))) cols))
        (if (= 0 (%call %c-memchr p %WIDE cols))
          #t
          (str=? (vt-history-row a i) (vt-history-row b i)))
        #f)
      #f)))

; A line of H counted from its oldest history row, 0, through its screen's
; rows: the address of its first cell and of its first cell's slot.
(def %line
  (fn (_ s line)
    (def count (%w s %HCOUNT))
    (def cols (%w s %COLS))
    (def at (* cols (if (< line count) (%history-slot s line) (%row s (- line count)))))
    (if (< line count)
      (pair (+ (%w s %HC) at) (+ (%w s %HX) (* 16 at)))
      (pair (+ (%w s %CP) at) (+ (%w s %EP) (* 16 at))))))
; Line LINE's cells FROM to TO-1 as text, as vt-row writes a row.
(def vt-line
  (fn (_ h line from to)
    ((fn (_ l) (%text-span (first l) (rest l) from to)) (%line (rest h) line))))
; Its length: its cells to the last one not blank.
(def vt-line-length
  (fn (_ h line)
    (def cells (first (%line (rest h) line)))
    ((fn (loop c) (if (if (< 0 c) (= (%pref (%int->ptr cells) (- c 1) 1) 32) #f) (loop (- c 1)) c))
     (%w (rest h) %COLS))))

; A screen the size of H showing its rows OFF up from the bottom: history
; row COUNT - OFF on, then the screen's rows, COUNT the history's rows it
; shows.  A copy mode's view; it keeps no history of its own.
(def vt-view
  (fn (_ h off)
    (def s (rest h))
    (def rows (%w s %ROWS))
    (def cols (%w s %COLS))
    (def count (vt-history h))
    (def v (vt-make-history rows cols 0))
    (def t (rest v))
    ((fn (self r)
       (when (< r rows)
         (do (def line (+ r (- count off)))
             (if (< line count)
               (%copy-row! t r %CP %AP %EP (%w s %HC) (%w s %HA) (%w s %HX) (* (%history-slot s line) cols) cols)
               (%copy-row! t r %CP %AP %EP (%w s %CP) (%w s %AP) (%w s %EP) (* (%row s (- line count)) cols) cols))
             (self (+ r 1)))))
     0)
    (vt-origin! v (%w s %OROW) (%w s %OCOL))))

; The compiled engine's two functions, each (fn (self a)) over a screen's
; words: the feed reads IN from POS to END, the render writes from RO.
; The feed answers 1 at a byte it leaves to this file's engine -- one past
; ASCII, or one where a character is part read -- with POS at it: that
; byte is fed here, over the same words, and the compiled feed goes on.
(def vt-feed-compiled!
  (fn (_ feed h p len)
    (def s (rest h))
    (%w! s %IN p) (%w! s %POS 0) (%w! s %END len)
    ((fn (self)
       (when (= (feed (%ptr->int s)) 1)
         (do (vt-feed-pure! h (+ p (%w s %POS)) 1)
             (%w! s %POS (+ (%w s %POS) 1))
             (self)))))))

(def vt-render-compiled!
  (fn (_ render h)
    (def s (rest h))
    (%w! s %RR 0) (%w! s %RC 0) (%w! s %RS 0) (%w! s %RO 0)
    (render (%ptr->int s))))

; The engine every screen uses: () for this file's, else the compiled
; (FEED . RENDER) vt-adopt! was given.
(def %engine ())
(def vt-adopt! (fn (_ engine) (set! %engine engine) #t))
(def vt-compiled? (fn (_) (not (null? %engine))))

(def vt-feed!
  (fn (_ h p len)
    (if (null? %engine) (vt-feed-pure! h p len) (vt-feed-compiled! (first %engine) h p len))))

; The rows marked since the last render written at vt-out; answers the
; byte count and clears the marks.
(def vt-render!
  (fn (_ h)
    (if (null? %engine) (vt-render-pure! h) (vt-render-compiled! (rest %engine) h))))

(provide tmux/vt vt-make vt-make-history vt-feed! vt-render! vt-out vt-cursor vt-size vt-origin!
  vt-touch! vt-carry vt-row vt-row-length vt-attrs vt-history vt-history-row vt-history-attrs
  vt-history-same? vt-view vt-line vt-line-length
  vt-feed-pure! vt-render-pure! vt-feed-compiled! vt-render-compiled! vt-adopt!
  vt-compiled?)
