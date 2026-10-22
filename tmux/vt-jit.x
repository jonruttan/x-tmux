; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/vt-jit.x -- the screen's engine, compiled
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; tmux/vt's feed and render as two compiled functions.  vt-jit! builds
; them by x-lang's assembler lane, proves them against tmux/vt's engine
; on an exercise of every sequence the screen reads, and adopts them; a
; host with no JIT, or a disagreement, leaves tmux/vt's engine in place.
; jit-group keeps the machine code, so a later process pours it and skips
; the proof, which passed on these bytes when they were stored.
;
; The feed is one function, (fn (self a) ...), over the screen's state words at a: it
; takes a byte a turn and loops by a tail self-call, which the assembler
; lane compiles as a jump, so a whole read is one call.  Work that spans
; cells -- a scroll, an erase, an SGR list -- is a mode the loop runs a
; cell or a parameter a turn before it reads another byte; a non-tail
; call would cost a consed frame each.  The words are vt.x's, so its
; render and its rows read either engine's screen.
;
; The body is written in a small notation, expanded at generation time:
; a word's name reads it, (set NAME V) writes it, and the capitalised
; forms below (LF, GOTO, ARG, BLANK, ...) are spelled out by %vj-expand.

(module tmux/vt-jit)

(import tmux/vt vt-make vt-origin! vt-row vt-attrs vt-cursor vt-out vt-feed-pure! vt-render-pure!
  vt-feed-compiled! vt-render-compiled! vt-adopt!)
(import x/tool/jit-group jit-group)

; Word indices, vt.x's byte offsets over 8, then the compiled loop's own.
(def %vj-words
  (list (pair 'ROWS 0) (pair 'COLS 1) (pair 'CELLS 2) (pair 'ATTRS 3) (pair 'DIRTY 4)
        (pair 'ROW 8) (pair 'COL 9) (pair 'ATTR 11) (pair 'STATE 12)
        (pair 'NUM 13) (pair 'NP 14) (pair 'PRIV 15) (pair 'TOP 16) (pair 'BOT 17)
        (pair 'SROW 18) (pair 'SCOL 19)
        (pair 'IN 40) (pair 'POS 41) (pair 'END 42) (pair 'MODE 43) (pair 'K 44)
        (pair 'J 45) (pair 'X 46) (pair 'NMODE 47) (pair 'NK 48) (pair 'NJ 49) (pair 'B 50)
        (pair 'OUT 6) (pair 'RR 51) (pair 'RC 52) (pair 'RS 53) (pair 'RO 54) (pair 'RA 55)
        (pair 'OROW 56) (pair 'OCOL 57)))
(def %vj-params 20)

(def %vj-word (fn (_ name) (Assoc entry name %vj-words)))

; The modes: 0 reading bytes, 1 blank cells K..J-1, 2 copy X cells up
; (K the destination, J the source, ascending), 3 copy X cells down
; (descending), 5 apply SGR parameter K.  A copy chains to NMODE with
; NK and NJ when it ends.
(def %vj-expand
  (fn (self e)
    (if (symbol? e)
      ((fn (_ w) (if (null? w) e (list '%mem-ref-at 'a (rest w)))) (%vj-word e))
      (if (not (pair? e)) e
        (match
          ((eq? (first e) 'set)
            (list '%mem-set-at! 'a (rest (%vj-word (List ref 1 e))) (self (List ref 2 e))))
          ((eq? (first e) 'P)
            (list '%mem-ref-at 'a (list '+ %vj-params (self (List ref 1 e)))))
          ((eq? (first e) 'ARG)
            (self (list 'if (list '< (List ref 1 e) 'NP)
                    (list 'if (list '= (list 'P (List ref 1 e)) 0) (List ref 2 e) (list 'P (List ref 1 e)))
                    (List ref 2 e))))
          ((eq? (first e) 'CLAMP)
            (self (list 'if (list '< (List ref 1 e) 0) 0
                    (list 'if (list '> (List ref 1 e) (List ref 2 e)) (List ref 2 e) (List ref 1 e)))))
          ((eq? (first e) 'GOTO)
            (self (list 'do
                    (list 'set 'ROW (list 'CLAMP (List ref 1 e) '(- ROWS 1)))
                    (list 'set 'COL (list 'CLAMP (List ref 2 e) '(- COLS 1))))))
          ((eq? (first e) 'BLANK)
            (self (list 'do (list 'set 'K (List ref 1 e)) (list 'set 'J (List ref 2 e))
                    '(set NMODE 0) '(set MODE 1))))
          ((eq? (first e) 'SCROLL-UP)
            ; rows TOP..BOT up N: copy, then blank the freed rows
            (self (list 'do (list 'set 'X (list 'MIN (List ref 3 e) (list '+ (list '- (List ref 2 e) (List ref 1 e)) 1)))
                    (list 'set 'K (list '* (List ref 1 e) 'COLS))
                    (list 'set 'J (list '* (list '+ (List ref 1 e) 'X) 'COLS))
                    (list 'set 'NK (list '* (list '+ (list '- (List ref 2 e) 'X) 1) 'COLS))
                    (list 'set 'NJ (list '* (list '+ (List ref 2 e) 1) 'COLS))
                    (list 'set 'X (list '* (list '- (list '+ (list '- (List ref 2 e) (List ref 1 e)) 1) 'X) 'COLS))
                    '(set NMODE 1) '(set MODE 2))))
          ((eq? (first e) 'SCROLL-DOWN)
            (self (list 'do (list 'set 'X (list 'MIN (List ref 3 e) (list '+ (list '- (List ref 2 e) (List ref 1 e)) 1)))
                    (list 'set 'NK (list '* (List ref 1 e) 'COLS))
                    (list 'set 'NJ (list '* (list '+ (List ref 1 e) 'X) 'COLS))
                    (list 'set 'K (list '- (list '* (list '+ (List ref 2 e) 1) 'COLS) 1))
                    (list 'set 'J (list '- (list '* (list '+ (list '- (List ref 2 e) 'X) 1) 'COLS) 1))
                    (list 'set 'X (list '* (list '- (list '+ (list '- (List ref 2 e) (List ref 1 e)) 1) 'X) 'COLS))
                    '(set NMODE 1) '(set MODE 3))))
          ((eq? (first e) 'MIN)
            (self (list 'if (list '< (List ref 1 e) (List ref 2 e)) (List ref 1 e) (List ref 2 e))))
          ((eq? (first e) 'LF)
            (self '(if (= ROW BOT) (SCROLL-UP TOP BOT 1) (if (< ROW (- ROWS 1)) (set ROW (+ ROW 1)) 0))))
          ((eq? (first e) 'DIGITS)
            ; a number of at most three digits, in decimal
            (self (list 'do (list 'set 'X (List ref 1 e))
                    '(if (< X 10) (EMIT (+ 48 X))
                       (if (< X 100) (do (EMIT (+ 48 (/ X 10))) (EMIT (+ 48 (% X 10))))
                         (do (EMIT (+ 48 (/ X 100))) (EMIT (+ 48 (% (/ X 10) 10))) (EMIT (+ 48 (% X 10)))))))))
          ((eq? (first e) 'EMIT)
            (self (list 'do (list '%mem-byte-set-at! 'OUT 'RO (List ref 1 e)) '(set RO (+ RO 1)))))
          ((eq? (first e) 'PUSH)
            (self (list 'do (list 'if '(< NP 16) (list '%mem-set-at! 'a (list '+ %vj-params 'NP) (List ref 1 e)) 0)
                    '(set NP (+ NP 1)) '(set NUM -1))))
          (#t (List map self e)))))))

; One cell of a mode's walk: its dirty row marked.
(def %vj-dirty '(%mem-byte-set-at! DIRTY (/ K COLS) 1))
(def %vj-chain '(do (set MODE NMODE) (set K NK) (set J NJ) (set NMODE 0)))

(def %vj-modes
  (list 'match
    ; a word a turn where both ends are word-aligned and eight remain,
    ; else a byte; a word's two ends mark their rows
    (list '(= MODE 1)
      (list 'if '(< K J)
        (list 'if '(and (= (& K 7) 0) (< (+ K 7) J))
          (list 'do '(%mem-set-at! CELLS (>> K 3) 2314885530818453536)
                '(%mem-set-at! ATTRS (>> K 3) (* ATTR 72340172838076673))
                %vj-dirty '(%mem-byte-set-at! DIRTY (/ (+ K 7) COLS) 1) '(set K (+ K 8)))
          (list 'do '(%mem-byte-set-at! CELLS K 32) '(%mem-byte-set-at! ATTRS K ATTR) %vj-dirty '(set K (+ K 1))))
        '(set MODE 0)))
    (list '(= MODE 2)
      (list 'if '(> X 0)
        (list 'if '(and (> X 7) (and (= (& K 7) 0) (= (& J 7) 0)))
          (list 'do '(%mem-set-at! CELLS (>> K 3) (%mem-ref-at CELLS (>> J 3)))
                '(%mem-set-at! ATTRS (>> K 3) (%mem-ref-at ATTRS (>> J 3)))
                %vj-dirty '(%mem-byte-set-at! DIRTY (/ (+ K 7) COLS) 1)
                '(set K (+ K 8)) '(set J (+ J 8)) '(set X (- X 8)))
          (list 'do '(%mem-byte-set-at! CELLS K (%mem-byte-ref-at CELLS J))
                '(%mem-byte-set-at! ATTRS K (%mem-byte-ref-at ATTRS J)) %vj-dirty
                '(set K (+ K 1)) '(set J (+ J 1)) '(set X (- X 1))))
        %vj-chain))
    (list '(= MODE 3)
      (list 'if '(> X 0)
        (list 'if '(and (> X 7) (and (= (& (+ K 1) 7) 0) (= (& (+ J 1) 7) 0)))
          (list 'do '(%mem-set-at! CELLS (>> (- K 7) 3) (%mem-ref-at CELLS (>> (- J 7) 3)))
                '(%mem-set-at! ATTRS (>> (- K 7) 3) (%mem-ref-at ATTRS (>> (- J 7) 3)))
                %vj-dirty '(%mem-byte-set-at! DIRTY (/ (- K 7) COLS) 1)
                '(set K (- K 8)) '(set J (- J 8)) '(set X (- X 8)))
          (list 'do '(%mem-byte-set-at! CELLS K (%mem-byte-ref-at CELLS J))
                '(%mem-byte-set-at! ATTRS K (%mem-byte-ref-at ATTRS J)) %vj-dirty
                '(set K (- K 1)) '(set J (- J 1)) '(set X (- X 1))))
        %vj-chain))
    (list #t
      (list 'if '(< K NP)
        '(do (set X (- ATTR 1))
             (set ATTR (+ 1 (match
               ((= (P K) 0) 0)
               ((= (P K) 1) (| X 1))
               ((= (P K) 7) (| X 2))
               ((and (> (P K) 29) (< (P K) 38)) (| (& X 67) (* 4 (- (P K) 29))))
               ((= (P K) 39) (& X 67))
               ((and (> (P K) 39) (< (P K) 48)) (| (& X 63) 64))
               ((= (P K) 49) (& X 63))
               (#t X))))
             (set K (+ K 1)))
        '(set MODE 0)))))

; A printable byte at the cursor.  A cursor past the last column wraps
; first, and the byte is read again once the wrap's scroll is done.
(def %vj-print
  '(if (< COL COLS)
     (do (set X (+ (* ROW COLS) COL))
         (%mem-byte-set-at! CELLS X B)
         (%mem-byte-set-at! ATTRS X ATTR)
         (%mem-byte-set-at! DIRTY ROW 1)
         (set COL (+ COL 1))
         (set POS (+ POS 1)))
     (do (set COL 0) (LF))))

(def %vj-control
  '(do (set POS (+ POS 1))
       (match
         ((= B 27) (set STATE 1))
         ((= B 10) (LF))
         ((= B 11) (LF))
         ((= B 12) (LF))
         ((= B 13) (set COL 0))
         ((= B 8) (if (> COL 0) (set COL (- COL 1)) 0))
         ((= B 9) (if (< COL (- COLS 1)) (set COL (MIN (- COLS 1) (* 8 (+ (>> COL 3) 1)))) 0))
         (#t 0))))

(def %vj-esc
  '(match
     ((= B 91) (do (set STATE 2) (set NP 0) (set NUM -1) (set PRIV 0)))
     ((= B 93) (set STATE 3))
     ((= B 40) (set STATE 4))
     ((= B 41) (set STATE 4))
     ((= B 35) (set STATE 4))
     ((= B 55) (do (set SROW ROW) (set SCOL COL) (set STATE 0)))
     ((= B 56) (do (GOTO SROW SCOL) (set STATE 0)))
     ((= B 77) (do (set STATE 0) (if (= ROW TOP) (SCROLL-DOWN TOP BOT 1) (GOTO (- ROW 1) COL))))
     ((= B 68) (do (set STATE 0) (LF)))
     ((= B 69) (do (set STATE 0) (set COL 0) (LF)))
     (#t (set STATE 0))))

(def %vj-final
  '(match
     ((= B 109) (if (= NP 0) (set ATTR 1) (do (set K 0) (set MODE 5))))
     ((= B 72) (GOTO (- (ARG 0 1) 1) (- (ARG 1 1) 1)))
     ((= B 102) (GOTO (- (ARG 0 1) 1) (- (ARG 1 1) 1)))
     ((= B 65) (GOTO (- ROW (ARG 0 1)) COL))
     ((= B 66) (GOTO (+ ROW (ARG 0 1)) COL))
     ((= B 67) (GOTO ROW (+ COL (ARG 0 1))))
     ((= B 68) (GOTO ROW (- COL (ARG 0 1))))
     ((= B 71) (GOTO ROW (- (ARG 0 1) 1)))
     ((= B 100) (GOTO (- (ARG 0 1) 1) COL))
     ((= B 75)
       (match ((= (ARG 0 0) 0) (BLANK (+ (* ROW COLS) COL) (* (+ ROW 1) COLS)))
              ((= (ARG 0 0) 1) (BLANK (* ROW COLS) (+ (* ROW COLS) (MIN (+ COL 1) COLS))))
              (#t (BLANK (* ROW COLS) (* (+ ROW 1) COLS)))))
     ((= B 74)
       (match ((= (ARG 0 0) 0) (BLANK (+ (* ROW COLS) COL) (* ROWS COLS)))
              ((= (ARG 0 0) 1) (BLANK 0 (+ (* ROW COLS) (MIN (+ COL 1) COLS))))
              (#t (BLANK 0 (* ROWS COLS)))))
     ((= B 114)
       (if (and (< (ARG 0 1) (ARG 1 ROWS)) (< (ARG 1 ROWS) (+ ROWS 1)))
         (do (set TOP (- (ARG 0 1) 1)) (set BOT (- (ARG 1 ROWS) 1)) (GOTO 0 0))
         0))
     ((= B 76) (if (and (< (- TOP 1) ROW) (< ROW (+ BOT 1))) (SCROLL-DOWN ROW BOT (ARG 0 1)) 0))
     ((= B 77) (if (and (< (- TOP 1) ROW) (< ROW (+ BOT 1))) (SCROLL-UP ROW BOT (ARG 0 1)) 0))
     ((= B 88) (BLANK (+ (* ROW COLS) COL) (+ (* ROW COLS) (MIN COLS (+ COL (ARG 0 1))))))
     ((= B 80)
       (do (set X (MIN (ARG 0 1) (- COLS COL)))
           (set K (+ (* ROW COLS) COL)) (set J (+ (+ (* ROW COLS) COL) X))
           (set NK (- (* (+ ROW 1) COLS) X)) (set NJ (* (+ ROW 1) COLS))
           (set X (- (- COLS COL) X))
           (set NMODE 1) (set MODE 2)))
     ((= B 64)
       (do (set X (MIN (ARG 0 1) (- COLS COL)))
           (set NK (+ (* ROW COLS) COL)) (set NJ (+ (+ (* ROW COLS) COL) X))
           (set K (- (* (+ ROW 1) COLS) 1)) (set J (- (- (* (+ ROW 1) COLS) 1) X))
           (set X (- (- COLS COL) X))
           (set NMODE 1) (set MODE 3)))
     ((= B 104) (if (and (= PRIV 1) (= (ARG 0 0) 1049)) (BLANK 0 (* ROWS COLS)) 0))
     (#t 0)))

(def %vj-csi
  (list 'match
    '((and (> B 47) (< B 58)) (set NUM (+ (* (if (< NUM 0) 0 NUM) 10) (- B 48))))
    '((= B 59) (PUSH (if (< NUM 0) 0 NUM)))
    '((= B 63) (set PRIV 1))
    (list '(and (> B 63) (< B 127))
      (list 'do '(if (< NUM 0) (if (> NP 0) (PUSH 0) 0) (PUSH NUM)) '(set STATE 0) %vj-final))
    '(#t 0)))

; A byte in an escape state: ESC restarts a sequence from anywhere; a
; control byte inside a CSI is obeyed where it stands.
(def %vj-escaped
  (list 'do '(set POS (+ POS 1))
    (list 'match
      '((= B 27) (set STATE 1))
      (list '(= STATE 1) %vj-esc)
      (list '(= STATE 2)
        (list 'if '(and (< B 32) (> B 0))
          (list 'do '(set POS (- POS 1)) %vj-control)
          %vj-csi))
      '((= STATE 3) (if (= B 7) (set STATE 0) 0))
      '(#t (set STATE 0)))))

(def %vj-body
  (list 'fn '(self a)
    (list 'if '(> MODE 0)
      (list 'do %vj-modes '(self a))
      (list 'if '(< POS END)
        (list 'do '(set B (%mem-byte-ref-at IN POS))
          (list 'if '(> STATE 0)
            %vj-escaped
            (list 'if '(and (> B 31) (not (= B 127))) %vj-print %vj-control))
          '(self a))
        0))))

(def vt-jit-form (fn (_) (%vj-expand %vj-body)))

; The render, compiled: vt.x's vt-render! as a loop over RR (the row), RC
; (the column) and RS (0 a row to start, 1 a run to start, 2 in a run of
; attribute RA), writing at OUT + RO.  Answers RO, the byte count.
(def %vr-body
  '(fn (self a)
     (if (< RR ROWS)
       (match
         ((= (%mem-byte-ref-at DIRTY RR) 0) (do (set RR (+ RR 1)) (self a)))
         ((= RS 0)
           (do (EMIT 27) (EMIT 91)
               (DIGITS (+ RR (+ 1 OROW)))
               (EMIT 59)
               (DIGITS (+ 1 OCOL))
               (EMIT 72)
               (set RC 0) (set RS 1)
               (self a)))
         ((= RC COLS)
           (do (%mem-byte-set-at! DIRTY RR 0) (set RR (+ RR 1)) (set RS 0) (self a)))
         ((= RS 1)
           (do (set RA (%mem-byte-ref-at ATTRS (+ (* RR COLS) RC)))
               (set X (- RA 1))
               (EMIT 27) (EMIT 91) (EMIT 48)
               (if (= (& X 1) 1) (do (EMIT 59) (EMIT 49)) 0)
               (if (= (& X 2) 2) (do (EMIT 59) (EMIT 55)) 0)
               (if (> (& (>> X 2) 15) 0) (do (EMIT 59) (EMIT 51) (EMIT (+ 47 (& (>> X 2) 15)))) 0)
               (EMIT 109)
               (set RS 2)
               (self a)))
         ((= (%mem-byte-ref-at ATTRS (+ (* RR COLS) RC)) RA)
           (do (EMIT (%mem-byte-ref-at CELLS (+ (* RR COLS) RC))) (set RC (+ RC 1)) (self a)))
         (#t (do (set RS 1) (self a))))
       RO)))

(def vt-render-form (fn (_) (%vj-expand %vr-body)))

; --- the exercise: every sequence the screen reads, at random ------------

(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %pset (prim-ref (lit ptr) (lit set!)))
(def %call (prim-ref (lit ptr) (lit call)))
(def %rem (prim-ref (lit int) (lit %)))

; The generator's next state, a 31-bit linear congruence.
(def %lcg (fn (_ x) (& (+ (* x 1103515245) 12345) 2147483647)))

; Writes at P from AT: one byte, or a number's decimal digits.
(def %put (fn (_ p at b) (%pset p at b 1) (+ at 1)))
(def %digits
  (fn (_ p at n)
    (if (< n 10) (%put p at (+ 48 n))
      (%put p (%put p at (+ 48 (%quot n 10))) (+ 48 (%rem n 10))))))
(def %quot (prim-ref (lit int) (lit /)))

; The CSI finals the screen reads, and the SGR codes it keeps.
(def %finals (list 72 102 65 66 67 68 71 100 75 74 114 76 77 88 80 64 109))
(def %sgrs (list 0 1 7 31 32 33 39 41 44 49))
(def %pick (fn (self xs i) (if (= i 0) (first xs) (self (rest xs) (- i 1)))))

; N operations from SEED as bytes: printable runs, CR and LF, backspace and
; tab, CSI sequences with up to two parameters (some empty), ESC 7 8 M D E,
; an OSC title, a charset designation, the alternate screen, a two-byte
; UTF-8 character.  Answers (BUF . LEN), BUF NUL-terminated.
(def vt-exercise
  (fn (_ seed n)
    (def buf (%make-str (+ (* n 96) 1)))
    (def p (%str->ptr buf))
    (def len ((fn (self i x at) (if (= i n) at (%op self i x at p))) 0 (%lcg seed) 0))
    (%pset p len 0 1)
    (pair buf len)))

(def %op
  (fn (_ loop i x at p)
    (def k (%rem x 20))
    (def y (%lcg x))
    (loop (+ i 1) (%lcg y)
      (match
        ((< k 6) (%run p at (+ 1 (%rem y 90)) y))
        ((= k 6) (%put p (%put p at 13) 10))
        ((= k 7) (%put p at 10))
        ((= k 8) (%put p at (if (= (& y 1) 0) 8 9)))
        ((< k 14) (%csi p at y))
        ((= k 14) (%put p (%put p at 27) (%pick (list 55 56 77 68 69) (%rem y 5))))
        ((= k 15) (%put p (%put p (%put p (%put p (%put p at 27) 93) 48) 59) 7))
        ((= k 16) (%put p (%put p (%put p at 27) 40) 66))
        ((= k 17) (%alt p at (= (& y 1) 0)))
        ((= k 18) (%put p (%put p at 195) 169))
        (#t (%put p at 9))))))

(def %run
  (fn (self p at n y)
    (if (= n 0) at (self p (%put p at (+ 33 (%rem y 94))) (- n 1) (%lcg y)))))

(def %csi
  (fn (_ p at y)
    (def f (%pick %finals (%rem y 17)))
    (def z (%lcg y))
    (def at1 (%put p (%put p at 27) 91))
    (def at2
      (if (= f 109)
        (%digits p at1 (%pick %sgrs (%rem z 10)))
        (match
          ((= (%rem z 3) 0) at1)
          ((= (%rem z 3) 1) (%digits p at1 (%rem (>> z 4) 30)))
          (#t (%digits p (%put p (%digits p at1 (%rem (>> z 4) 30)) 59) (%rem (>> z 9) 30))))))
    (%put p at2 f)))

(def %alt
  (fn (_ p at on)
    (def at1 (%put p (%put p (%put p at 27) 91) 63))
    (%put p (%digits4 p at1 1049) (if on 104 108))))
(def %digits4
  (fn (_ p at n)
    (%put p (%put p (%put p (%put p at (+ 48 (%quot n 1000))) (+ 48 (%rem (%quot n 100) 10)))
              (+ 48 (%rem (%quot n 10) 10))) (+ 48 (%rem n 10)))))

; --- agreement -----------------------------------------------------------

; Two screens the same: every row's cells and attributes, and the cursor.
(def vt-same?
  (fn (_ a b)
    (def rows-same
      ((fn (self r)
         (if (= r 24) #t
           (if (if (str=? (vt-row a r) (vt-row b r)) (str=? (vt-attrs a r) (vt-attrs b r)) #f)
             (self (+ r 1))
             #f)))
       0))
    (if rows-same
      (if (= (first (vt-cursor a)) (first (vt-cursor b))) (= (rest (vt-cursor a)) (rest (vt-cursor b))) #f)
      #f)))

; An exercise fed to two 24x80 screens in reads of CHUNK bytes, one by
; tmux/vt's engine and one by ENGINE, each read rendered by both at
; terminal row 2, column 41, as a pane is.  Answers #t, or the byte
; offset after the first read they disagree on.
(def vt-agree
  (fn (_ engine ex chunk)
    (def a (vt-origin! (vt-make 24 80) 2 41))
    (def b (vt-origin! (vt-make 24 80) 2 41))
    (def base (%ptr->int (%str->ptr (first ex))))
    (def len (rest ex))
    ((fn (self at)
       (if (< at len)
         (do (def n (if (< (- len at) chunk) (- len at) chunk))
             (vt-feed-pure! a (+ base at) n)
             (vt-feed-compiled! (first engine) b (+ base at) n)
             (def na (vt-render-pure! a))
             (def nb (vt-render-compiled! (rest engine) b))
             (if (if (vt-same? a b) (if (= na nb) (= 0 (%call (%memcmp) (vt-out a) (vt-out b) na)) #f) #f)
               (self (+ at n))
               (+ at n)))
         #t))
     0)))
; libc's memcmp, looked up when it is asked for: a handle is a fact of the
; process, and a state image is written by another one
(def %memcmp (fn (_) ((prim-ref (lit ffi) (lit dlsym)) ((prim-ref (lit ffi) (lit dlopen)) () 1) "memcmp")))

; --- the build -----------------------------------------------------------

; The compiled engine, (FEED . RENDER), built or poured, proven against
; tmux/vt's on two exercises fed in reads that end mid-sequence; raises on
; a disagreement or where there is no JIT.  The group pours by its key
; alone, without making the forms, so the key's number moves with every
; change to them.
(def vt-jit-make
  (fn (_)
    (jit-group "x-tmux-vt-3" (fn (_) (list (vt-jit-form) (vt-render-form)))
      (fn (_ fns replayed?)
        (def engine (pair (first fns) (first (rest fns))))
        (unless replayed?
          (do (def a (vt-agree engine (vt-exercise 1 600) 777))
              (def b (vt-agree engine (vt-exercise 2 600) 4096))
              (unless (if (eq? a #t) (eq? b #t) #f)
                (Err raise 'state "x-tmux: the compiled screen disagrees with tmux/vt's" ()))))
        engine))))

; The compiled engine adopted when it builds and agrees; #f, and tmux/vt's
; engine kept, otherwise.
(def vt-jit!
  (fn (_)
    (guard (e #f) (vt-adopt! (vt-jit-make)))))

(provide tmux/vt-jit vt-jit! vt-jit-make vt-exercise vt-agree vt-same? vt-jit-form vt-render-form)
