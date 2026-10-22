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
(def %c-strspn ())
(def %resolve!
  (fn (_)
    (def lib (%dlopen () 1))
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
; top-left cell, a row and a column from 0.
(def %ROWS 0) (def %COLS 8) (def %CP 16) (def %AP 24) (def %DP 32) (def %SP 40)
(def %OP 48) (def %ONE 56) (def %ROW 64) (def %COL 72) (def %ATTR 88)
(def %STATE 96) (def %NUM 104) (def %NP 112) (def %PRIVATE 120) (def %TOP 128)
(def %BOTTOM 136) (def %SROW 144) (def %SCOL 152) (def %PARAMS 160)
(def %IN 320) (def %POS 328) (def %END 336)
(def %RR 408) (def %RC 416) (def %RS 424) (def %RO 432)
(def %OROW 448) (def %OCOL 456) (def %WORDS 64)

(def %w (fn (_ s o) (%pref s o 8)))
(def %w! (fn (_ s o x) (%pset s o x 8)))
(def %addr (fn (_ s o) (%int->ptr (%pref s o 8))))

; The bytes a printable run stops at: every control byte and DEL.
(def %stops
  (fn (_)
    (def s (%make-str 33))
    (def p (%str->ptr s))
    ((fn (self i) (if (< i 32) (self (%stop! p i)) ())) 1)
    (%pset p 31 127 1)
    (%pset p 32 0 1)
    s))
(def %stop! (fn (_ p i) (%pset p (- i 1) i 1) (+ i 1)))

(def %buffer
  (fn (_ n fill)
    (def s (%make-str (+ n 1)))
    (%call %c-memset (%str->ptr s) fill n)
    (%pset (%str->ptr s) n 0 1)
    s))

; A screen: (KEEP . S), S the state's pointer, KEEP what holds the
; buffers alive.
(def vt-make
  (fn (_ rows cols)
    (%resolve!)
    (def words (%buffer (* 8 %WORDS) 0))
    (def s (%str->ptr words))
    (def cells (%buffer (* rows cols) 32))
    (def attrs (%buffer (* rows cols) 1))
    (def dirty (%buffer rows 1))
    (def stop (%stops))
    (def out (%make-str (+ 64 (* rows (+ 16 (* cols 12))))))
    (def one (%buffer 1 1))
    (%w! s %ROWS rows) (%w! s %COLS cols)
    (%w! s %CP (%ptr->int (%str->ptr cells))) (%w! s %AP (%ptr->int (%str->ptr attrs)))
    (%w! s %DP (%ptr->int (%str->ptr dirty))) (%w! s %SP (%ptr->int (%str->ptr stop)))
    (%w! s %OP (%ptr->int (%str->ptr out))) (%w! s %ONE (%ptr->int (%str->ptr one)))
    (%w! s %ATTR 1) (%w! s %NUM -1) (%w! s %BOTTOM (- rows 1))
    (pair (list words cells attrs dirty stop out one) s)))

(def %at (fn (_ s base row col) (%int->ptr (+ (%w s base) (+ (* row (%w s %COLS)) col)))))
(def %dirty! (fn (_ s row) (%pset (%addr s %DP) row 1 1)))
(def %dirty-rows! (fn (_ s a b) (%call %c-memset (%at s %DP 0 a) 1 (+ (- b a) 1))))

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

; Rows TOP..BOTTOM moved up N (down when N is negative), the freed rows blanked.
(def %scroll!
  (fn (_ s top bottom n)
    (def cols (%w s %COLS))
    (def k (%min (if (< n 0) (- 0 n) n) (+ (- bottom top) 1)))
    (def keep (* (- (+ (- bottom top) 1) k) cols))
    (def from (if (< n 0) top (+ top k)))
    (def to (if (< n 0) (+ top k) top))
    (if (< 0 keep) (%move-rows! s to from keep) ())
    (if (< n 0) (%blank-rows! s top (+ top k)) (%blank-rows! s (+ (- bottom k) 1) (+ bottom 1)))
    (%dirty-rows! s top bottom)))
(def %move-rows!
  (fn (_ s to from n)
    (%call %c-memmove (%at s %CP to 0) (%at s %CP from 0) n)
    (%call %c-memmove (%at s %AP to 0) (%at s %AP from 0) n)))

(def %linefeed!
  (fn (_ s)
    (def row (%w s %ROW))
    (if (= row (%w s %BOTTOM))
      (%scroll! s (%w s %TOP) row 1)
      (if (< row (- (%w s %ROWS) 1)) (%w! s %ROW (+ row 1)) ()))))

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
    (%call %c-memcpy (%at s %CP row col) (%int->ptr p) k)
    (%call %c-memset (%at s %AP row col) (%w s %ATTR) k)
    (%dirty! s row)
    (%w! s %COL (+ col k))
    k))

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
      ((= f 104) (if (if (= (%w s %PRIVATE) 1) (= (%p s 0) 1049) #f) (%blank-rows! s 0 rows) ()))
      (#t ()))))

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
(def %erase-screen!
  (fn (_ s m row col rows cols)
    (match ((= m 0) (%below! s row col rows cols))
           ((= m 1) (%above! s row col cols))
           (#t (%blank-rows! s 0 rows)))))
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
    (%call %c-memmove (%at s %AP row to) (%at s %AP row from) n)))

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
(def %step!
  (fn (_ s stop i end)
    (if (= (%w s %STATE) 0)
      (%ground-step! s i (%min (%call %c-strcspn (%int->ptr i) stop) (- end i)))
      (%escaped-step! s i))))
(def %ground-step!
  (fn (_ s i run)
    (if (< 0 run)
      (%ran! s i run)
      (%controlled! s i))))
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
    (def at1 (%sgr-bytes! at (%pref (%at s %AP r c) 0 1)))
    (%call %c-memcpy (%int->ptr at1) (%at s %CP r c) k)
    (+ at1 k)))

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
; fit, its cursor, attribute and origin; a pane resized.  The scroll
; region is the whole new screen.
(def vt-carry
  (fn (_ h rows cols)
    (def n (vt-make rows cols))
    (def s (rest h))
    (def t (rest n))
    (def keep-rows (%min rows (%w s %ROWS)))
    (def keep-cols (%min cols (%w s %COLS)))
    ((fn (self r)
       (when (< r keep-rows)
         (do (%call %c-memcpy (%at t %CP r 0) (%at s %CP r 0) keep-cols)
             (%call %c-memcpy (%at t %AP r 0) (%at s %AP r 0) keep-cols)
             (self (+ r 1)))))
     0)
    (%w! t %ROW (%min (%w s %ROW) (- rows 1)))
    (%w! t %COL (%min (%w s %COL) cols))
    (%w! t %ATTR (%w s %ATTR))
    (vt-origin! n (%w s %OROW) (%w s %OCOL))))
(def vt-row
  (fn (_ h r)
    (def s (rest h))
    ((prim-ref (lit str) (lit byte-sub)) (List ref 1 (first h)) (* r (%w s %COLS)) (%w s %COLS))))
(def vt-attrs
  (fn (_ h r)
    (def s (rest h))
    ((prim-ref (lit str) (lit byte-sub)) (List ref 2 (first h)) (* r (%w s %COLS)) (%w s %COLS))))

; The compiled engine's two functions, each (fn (self a)) over a screen's
; words: the feed reads IN from POS to END, the render writes from RO.
(def vt-feed-compiled!
  (fn (_ feed h p len)
    (def s (rest h))
    (%w! s %IN p) (%w! s %POS 0) (%w! s %END len)
    (feed (%ptr->int s))))

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

(provide tmux/vt vt-make vt-feed! vt-render! vt-out vt-cursor vt-size vt-origin! vt-touch! vt-carry
  vt-row vt-attrs vt-feed-pure! vt-render-pure! vt-feed-compiled! vt-render-compiled! vt-adopt!
  vt-compiled?)
