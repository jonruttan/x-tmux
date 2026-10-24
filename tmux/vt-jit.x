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

(import tmux/vt vt-make vt-make-history vt-origin! vt-row vt-attrs vt-history-same? vt-cursor vt-out
  vt-feed-pure! vt-render-pure! vt-feed-compiled! vt-render-compiled! vt-adopt!)
(import x/tool/jit-group jit-group)
(import x/sys/gc)

; Word indices, vt.x's byte offsets over 8, then the compiled loop's own.
(def %vj-words
  (list (pair 'ROWS 0) (pair 'COLS 1) (pair 'CELLS 2) (pair 'ATTRS 3) (pair 'DIRTY 4)
        (pair 'ROW 8) (pair 'COL 9) (pair 'ATTR 11) (pair 'STATE 12)
        (pair 'NUM 13) (pair 'NP 14) (pair 'PRIV 15) (pair 'TOP 16) (pair 'BOT 17)
        (pair 'SROW 18) (pair 'SCOL 19)
        (pair 'IN 40) (pair 'POS 41) (pair 'END 42) (pair 'MODE 43) (pair 'K 44)
        (pair 'J 45) (pair 'X 46) (pair 'NMODE 47) (pair 'NK 48) (pair 'NJ 49) (pair 'B 50)
        (pair 'OUT 6) (pair 'RR 51) (pair 'RC 52) (pair 'RS 53) (pair 'RO 54) (pair 'RA 55)
        (pair 'OROW 56) (pair 'OCOL 57)
        (pair 'SC 36) (pair 'SA 37) (pair 'ALT 38) (pair 'ASAVED 39)
        (pair 'AROW 58) (pair 'ACOL 59) (pair 'AATTR 60)
        (pair 'EXT 10) (pair 'SEXT 61) (pair 'UNEED 63) (pair 'RX 65) (pair 'RN 66)
        (pair 'MAP 67) (pair 'SMAP 68) (pair 'RT 70) (pair 'RE 71) (pair 'RH 72) (pair 'RB 73)
        (pair 'HC 74) (pair 'HA 75) (pair 'HX 76) (pair 'HLIM 77) (pair 'HHEAD 78) (pair 'HCOUNT 79)
        (pair 'HD 80)))
(def %vj-params 20)

; A cell's extended slot copied with it when the cell holds a character
; past ASCII: the slot's two words, the cell at index I of SRC to index J
; of DST.  And whether a word of eight cells holds none.
(def %vj-slot-copy
  (fn (_ dst j src cells i)
    (list 'if (list '= (list '%mem-byte-ref-at cells i) 128)
      (list 'do (list '%mem-set-at! dst (list '* j 2) (list '%mem-ref-at src (list '* i 2)))
                (list '%mem-set-at! dst (list '+ (list '* j 2) 1) (list '%mem-ref-at src (list '+ (list '* i 2) 1))))
      0)))
(def %vj-ascii-word (fn (_ word) (list '= (list '& (list '>> word 7) 72340172838076673) 0)))

(def %vj-word (fn (_ name) (Assoc entry name %vj-words)))

; The modes: 0 reading bytes, 1 blank cells K..J-1, 2 copy X cells up
; (K the destination, J the source, ascending), 3 copy X cells down
; (descending), 5 apply SGR parameter K, 6 save cells K..J-1 to the
; alternate screen's buffers, 7 restore them, 8 look from parameter K for
; one naming an alternate screen, 9 blank cells K..J-1 with the default
; attribute, 11 turn the map's rows K..RE up one X times, 12 down, 13 save
; the map then the cells, 14 restore the map, 15 copy cells K..J-1 to the
; history's from HD.  Modes 1, 2, 3, 7 and 15 chain to NMODE with NK and
; NJ when they end.  An ED is tmux/vt's, handed over as a byte past ASCII
; is.
;
; Cells are found through the row map, (CELL ROW COL), and the dirty
; marks go by the screen's rows: an edit within a row marks it as it
; starts, and the modes that walk cells mark none, except the alternate
; screen's, which cover every row.
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
          ((eq? (first e) 'ROWAT) (self (list '%mem-ref-at 'MAP (List ref 1 e))))
          ((eq? (first e) 'CELL) (self (list '+ (list '* (list 'ROWAT (List ref 1 e)) 'COLS) (List ref 2 e))))
          ((eq? (first e) 'BLANK-IN-ROW)
            ; the cursor's row's columns A..B-1 blanked, the row marked
            (self (list 'do (list 'set 'K (list 'CELL 'ROW (List ref 1 e))) (list 'set 'J (list 'CELL 'ROW (List ref 2 e)))
                    '(%mem-byte-set-at! DIRTY ROW 1) '(set NMODE 0) '(set MODE 1))))
          ((eq? (first e) 'SCROLL-UP)
            ; rows TOP..BOT up N: the map turned, a freed row blanked a turn
            (self (list 'do (list 'set 'X (list 'MIN (List ref 3 e) (list '+ (list '- (List ref 2 e) (List ref 1 e)) 1)))
                    (list 'set 'K (List ref 1 e)) (list 'set 'RE (List ref 2 e)) '(set J 0) '(set MODE 11))))
          ((eq? (first e) 'SCROLL-DOWN)
            (self (list 'do (list 'set 'X (list 'MIN (List ref 3 e) (list '+ (list '- (List ref 2 e) (List ref 1 e)) 1)))
                    (list 'set 'K (List ref 1 e)) (list 'set 'RE (List ref 2 e)) '(set J 0) '(set MODE 12))))
          ((eq? (first e) 'MIN)
            (self (list 'if (list '< (List ref 1 e) (List ref 2 e)) (List ref 1 e) (List ref 2 e))))
          ((eq? (first e) 'LF)
            (self '(if (= ROW BOT)
                     (if (and (= ALT 0) (> HLIM 0)) (KEEP-AND-SCROLL) (SCROLL-UP TOP BOT 1))
                     (if (< ROW (- ROWS 1)) (set ROW (+ ROW 1)) 0))))
          ((eq? (first e) 'KEEP-AND-SCROLL)
            ; the region up one, as tmux/vt's %scroll-up!: its top row copied
            ; to the history's newest slot by mode 15, which chains to the
            ; scroll's mode 11
            (self '(do (SCROLL-UP TOP BOT 1) (set NMODE 11) (set NK K) (set NJ 0)
                       (set HD (+ HHEAD HCOUNT))
                       (if (< HD HLIM) 0 (set HD (- HD HLIM)))
                       (set HD (* HD COLS))
                       (if (< HCOUNT HLIM) (set HCOUNT (+ HCOUNT 1))
                         (set HHEAD (if (< (+ HHEAD 1) HLIM) (+ HHEAD 1) 0)))
                       (set K (CELL TOP 0)) (set J (+ K COLS)) (set MODE 15))))
          ((eq? (first e) 'ALT-SWITCH)
            ; the alternate screen up (h) or down (l) for mode P, as tmux/vt's
            ; %alt-on! and %alt-off!: a save then a clear, or a restore
            (self (list 'if '(= B 104)
                    (list 'if '(= ALT 1) '(set MODE 0)
                      (list 'do (list 'set 'ASAVED (list 'if (list '= (List ref 1 e) 1049) 1 0))
                        '(set AROW ROW) '(set ACOL COL) '(set AATTR ATTR) '(set ALT 1)
                        '(set K 0) '(set MODE 13)))
                    (list 'if '(= ALT 0) '(set MODE 0)
                      (list 'do
                        (list 'if (list 'and (list '= (List ref 1 e) 1049) '(= ASAVED 1))
                          '(do (set ROW AROW) (set COL ACOL) (set ATTR AATTR)) 0)
                        '(set ASAVED 0) '(set ALT 0)
                        '(set K 0) '(set J (* ROWS COLS)) '(set NMODE 14) '(set NK 0) '(set NJ 0)
                        '(set MODE 7))))))
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

; One cell of a mode's walk over the whole buffer: its row marked.
(def %vj-dirty '(%mem-byte-set-at! DIRTY (/ K COLS) 1))
(def %vj-chain '(do (set MODE NMODE) (set K NK) (set J NJ) (set NMODE 0)))

; One turn of blanking cells K..J-1 with ATTR: a word where K is
; word-aligned and eight remain, else a byte.
(def %vj-blank-step
  '(if (and (= (& K 7) 0) (< (+ K 7) J))
     (do (%mem-set-at! CELLS (>> K 3) 2314885530818453536)
         (%mem-set-at! ATTRS (>> K 3) (* ATTR 72340172838076673))
         (set K (+ K 8)))
     (do (%mem-byte-set-at! CELLS K 32) (%mem-byte-set-at! ATTRS K ATTR) (set K (+ K 1)))))

; One turn of a map's turn, up (UP #t) or down: the end row set aside, a
; row moved, and at the far end the set-aside row put back, marked, and
; blanked by mode 1, which comes back here while X turns remain.
(def %vj-turn
  (fn (_ up)
    (def from (if up '(+ RT 1) '(- RT 1)))
    (def far (if up 'RE 'K))
    (list 'if '(= J 0)
      (list 'do (list 'set 'RH (list 'ROWAT (if up 'K 'RE))) (list 'set 'RT (if up 'K 'RE)) '(set J 1))
      (list 'if (if up '(< RT RE) '(> RT K))
        (list 'do (list '%mem-set-at! 'MAP 'RT (list 'ROWAT from)) '(%mem-byte-set-at! DIRTY RT 1)
              (list 'set 'RT from))
        (list 'do (list '%mem-set-at! 'MAP far 'RH) (list '%mem-byte-set-at! 'DIRTY far 1) '(set X (- X 1))
              (list 'set 'NMODE (list 'if '(> X 0) (if up 11 12) 0)) '(set NK K) '(set NJ 0)
              '(set K (* RH COLS)) '(set J (+ K COLS)) '(set MODE 1))))))

(def %vj-modes
  (list 'match
    (list '(= MODE 1) (list 'if '(< K J) %vj-blank-step %vj-chain))
    (list '(= MODE 11) (%vj-turn #t))
    (list '(= MODE 12) (%vj-turn #f))
    (list '(= MODE 13)
      '(if (< K ROWS)
         (do (%mem-set-at! SMAP K (ROWAT K)) (set K (+ K 1)))
         (do (set K 0) (set J (* ROWS COLS)) (set NMODE 9) (set NK 0) (set NJ (* ROWS COLS)) (set MODE 6))))
    (list '(= MODE 15)
      (list 'if '(< K J)
        (list 'if (list 'and '(and (< (+ K 7) J) (and (= (& K 7) 0) (= (& HD 7) 0)))
                         (%vj-ascii-word '(%mem-ref-at CELLS (>> K 3))))
          '(do (%mem-set-at! HC (>> HD 3) (%mem-ref-at CELLS (>> K 3)))
               (%mem-set-at! HA (>> HD 3) (%mem-ref-at ATTRS (>> K 3)))
               (set K (+ K 8)) (set HD (+ HD 8)))
          (list 'do (%vj-slot-copy 'HX 'HD 'EXT 'CELLS 'K)
                '(%mem-byte-set-at! HC HD (%mem-byte-ref-at CELLS K))
                '(%mem-byte-set-at! HA HD (%mem-byte-ref-at ATTRS K))
                '(set K (+ K 1)) '(set HD (+ HD 1))))
        %vj-chain))
    (list '(= MODE 14)
      '(if (< K ROWS) (do (%mem-set-at! MAP K (%mem-ref-at SMAP K)) (set K (+ K 1))) (set MODE 0)))
    ; a word a turn where both ends are word-aligned and eight remain, else a byte
    (list '(= MODE 2)
      (list 'if '(> X 0)
        (list 'if (list 'and '(> X 7) (list 'and '(and (= (& K 7) 0) (= (& J 7) 0))
                                          (%vj-ascii-word '(%mem-ref-at CELLS (>> J 3)))))
          (list 'do '(%mem-set-at! CELLS (>> K 3) (%mem-ref-at CELLS (>> J 3)))
                '(%mem-set-at! ATTRS (>> K 3) (%mem-ref-at ATTRS (>> J 3)))
                '(set K (+ K 8)) '(set J (+ J 8)) '(set X (- X 8)))
          (list 'do (%vj-slot-copy 'EXT 'K 'EXT 'CELLS 'J)
                '(%mem-byte-set-at! CELLS K (%mem-byte-ref-at CELLS J))
                '(%mem-byte-set-at! ATTRS K (%mem-byte-ref-at ATTRS J))
                '(set K (+ K 1)) '(set J (+ J 1)) '(set X (- X 1))))
        %vj-chain))
    (list '(= MODE 3)
      (list 'if '(> X 0)
        (list 'if (list 'and '(> X 7) (list 'and '(and (= (& (+ K 1) 7) 0) (= (& (+ J 1) 7) 0))
                                          (%vj-ascii-word '(%mem-ref-at CELLS (>> (- J 7) 3)))))
          (list 'do '(%mem-set-at! CELLS (>> (- K 7) 3) (%mem-ref-at CELLS (>> (- J 7) 3)))
                '(%mem-set-at! ATTRS (>> (- K 7) 3) (%mem-ref-at ATTRS (>> (- J 7) 3)))
                '(set K (- K 8)) '(set J (- J 8)) '(set X (- X 8)))
          (list 'do (%vj-slot-copy 'EXT 'K 'EXT 'CELLS 'J)
                '(%mem-byte-set-at! CELLS K (%mem-byte-ref-at CELLS J))
                '(%mem-byte-set-at! ATTRS K (%mem-byte-ref-at ATTRS J))
                '(set K (- K 1)) '(set J (- J 1)) '(set X (- X 1))))
        %vj-chain))
    (list '(= MODE 6)
      (list 'if '(< K J)
        (list 'if (list 'and '(< (+ K 7) J) (%vj-ascii-word '(%mem-ref-at CELLS (>> K 3))))
          '(do (%mem-set-at! SC (>> K 3) (%mem-ref-at CELLS (>> K 3)))
               (%mem-set-at! SA (>> K 3) (%mem-ref-at ATTRS (>> K 3)))
               (set K (+ K 8)))
          (list 'do (%vj-slot-copy 'SEXT 'K 'EXT 'CELLS 'K)
                '(%mem-byte-set-at! SC K (%mem-byte-ref-at CELLS K))
                '(%mem-byte-set-at! SA K (%mem-byte-ref-at ATTRS K))
                '(set K (+ K 1))))
        %vj-chain))
    (list '(= MODE 7)
      (list 'if '(< K J)
        (list 'if (list 'and '(< (+ K 7) J) (%vj-ascii-word '(%mem-ref-at SC (>> K 3))))
          (list 'do '(%mem-set-at! CELLS (>> K 3) (%mem-ref-at SC (>> K 3)))
                '(%mem-set-at! ATTRS (>> K 3) (%mem-ref-at SA (>> K 3)))
                %vj-dirty '(%mem-byte-set-at! DIRTY (/ (+ K 7) COLS) 1) '(set K (+ K 8)))
          (list 'do (%vj-slot-copy 'EXT 'K 'SEXT 'SC 'K)
                '(%mem-byte-set-at! CELLS K (%mem-byte-ref-at SC K))
                '(%mem-byte-set-at! ATTRS K (%mem-byte-ref-at SA K))
                %vj-dirty '(set K (+ K 1))))
        %vj-chain))
    (list '(= MODE 8)
      '(if (< K NP)
         (if (or (= (P K) 1049) (or (= (P K) 47) (= (P K) 1047)))
           (ALT-SWITCH (P K))
           (set K (+ K 1)))
         (set MODE 0)))
    (list '(= MODE 9)
      (list 'if '(< K J)
        (list 'if '(< (+ K 7) J)
          (list 'do '(%mem-set-at! CELLS (>> K 3) 2314885530818453536)
                '(%mem-set-at! ATTRS (>> K 3) 72340172838076673)
                %vj-dirty '(%mem-byte-set-at! DIRTY (/ (+ K 7) COLS) 1) '(set K (+ K 8)))
          (list 'do '(%mem-byte-set-at! CELLS K 32) '(%mem-byte-set-at! ATTRS K 1) %vj-dirty '(set K (+ K 1))))
        '(set MODE 0)))
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
; first, and the byte is read again once the wrap's scroll is done.  A
; wide character the byte takes half of has its other half blanked.
(def %vj-print
  '(if (< COL COLS)
     (do (set X (CELL ROW COL))
         (if (and (> COL 0) (= (%mem-byte-ref-at CELLS X) 129)) (%mem-byte-set-at! CELLS (- X 1) 32) 0)
         (if (and (< (+ COL 1) COLS) (= (%mem-byte-ref-at CELLS (+ X 1)) 129)) (%mem-byte-set-at! CELLS (+ X 1) 32) 0)
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
       (match ((= (ARG 0 0) 0) (BLANK-IN-ROW (MIN COL COLS) COLS))
              ((= (ARG 0 0) 1) (BLANK-IN-ROW 0 (MIN (+ COL 1) COLS)))
              (#t (BLANK-IN-ROW 0 COLS))))
     ((= B 114)
       (if (and (< (ARG 0 1) (ARG 1 ROWS)) (< (ARG 1 ROWS) (+ ROWS 1)))
         (do (set TOP (- (ARG 0 1) 1)) (set BOT (- (ARG 1 ROWS) 1)) (GOTO 0 0))
         0))
     ((= B 76) (if (and (< (- TOP 1) ROW) (< ROW (+ BOT 1))) (SCROLL-DOWN ROW BOT (ARG 0 1)) 0))
     ((= B 77) (if (and (< (- TOP 1) ROW) (< ROW (+ BOT 1))) (SCROLL-UP ROW BOT (ARG 0 1)) 0))
     ((= B 88) (BLANK-IN-ROW (MIN COL COLS) (MIN COLS (+ COL (ARG 0 1)))))
     ((= B 80)
       (do (set X (MIN (ARG 0 1) (- COLS COL)))
           (set K (CELL ROW COL)) (set J (+ (CELL ROW COL) X))
           (set NK (- (CELL ROW COLS) X)) (set NJ (CELL ROW COLS))
           (set X (- (- COLS COL) X))
           (%mem-byte-set-at! DIRTY ROW 1)
           (set NMODE 1) (set MODE 2)))
     ((= B 64)
       (do (set X (MIN (ARG 0 1) (- COLS COL)))
           (set NK (CELL ROW COL)) (set NJ (+ (CELL ROW COL) X))
           (set K (- (CELL ROW COLS) 1)) (set J (- (- (CELL ROW COLS) 1) X))
           (set X (- (- COLS COL) X))
           (%mem-byte-set-at! DIRTY ROW 1)
           (set NMODE 1) (set MODE 3)))
     ((= B 104) (if (= PRIV 1) (do (set K 0) (set MODE 8)) 0))
     ((= B 108) (if (= PRIV 1) (do (set K 0) (set MODE 8)) 0))
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
          ; a byte past ASCII, or one where a character is part read, is
          ; tmux/vt's: answer 1, POS at it, for the driver to hand over.
          ; So is an ED's final, as an erase of the screen may scroll it
          ; into the history first.
          (list 'if '(or (or (> UNEED 0) (and (= STATE 0) (> B 127))) (and (= STATE 2) (= B 74)))
            1
            (list 'do
              (list 'if '(> STATE 0)
                %vj-escaped
                (list 'if '(and (> B 31) (not (= B 127))) %vj-print %vj-control))
              '(self a))))
        0))))

(def vt-jit-form (fn (_) (%vj-expand %vj-body)))

; The render, compiled: vt.x's vt-render! as a loop over RR (the row), RC
; (the column) and RS (0 a row to start, 1 a run to start, 2 in a run of
; attribute RA, 3 writing a slot's bytes, RX of RN), writing at OUT + RO.
; RB is the row's first cell, found through the map as the row starts.
; Answers RO, the byte count.
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
               (set RC 0) (set RS 1) (set RB (CELL RR 0))
               (self a)))
         ((= RC COLS)
           (do (%mem-byte-set-at! DIRTY RR 0) (set RR (+ RR 1)) (set RS 0) (self a)))
         ((= RS 1)
           (do (set RA (%mem-byte-ref-at ATTRS (+ RB RC)))
               (set X (- RA 1))
               (EMIT 27) (EMIT 91) (EMIT 48)
               (if (= (& X 1) 1) (do (EMIT 59) (EMIT 49)) 0)
               (if (= (& X 2) 2) (do (EMIT 59) (EMIT 55)) 0)
               (if (> (& (>> X 2) 15) 0) (do (EMIT 59) (EMIT 51) (EMIT (+ 47 (& (>> X 2) 15)))) 0)
               (EMIT 109)
               (set RS 2)
               (self a)))
         ((= RS 3)
           (if (< RX RN)
             (do (EMIT (%mem-byte-ref-at EXT (+ (* (+ RB RC) 16) RX))) (set RX (+ RX 1)) (self a))
             (do (if (and (= (%mem-byte-ref-at EXT (+ (* (+ RB RC) 16) 15)) 2)
                          (not (and (< (+ RC 1) COLS) (= (%mem-byte-ref-at CELLS (+ (+ RB RC) 1)) 129))))
                   (do (EMIT 27) (EMIT 91) (DIGITS (+ RR (+ 1 OROW))) (EMIT 59) (DIGITS (+ RC (+ 2 OCOL))) (EMIT 72))
                   0)
                 (set RC (+ RC 1)) (set RS 2) (self a))))
         ((= (%mem-byte-ref-at ATTRS (+ RB RC)) RA)
           (match
             ((< (%mem-byte-ref-at CELLS (+ RB RC)) 128)
               (do (EMIT (%mem-byte-ref-at CELLS (+ RB RC))) (set RC (+ RC 1)) (self a)))
             ((= (%mem-byte-ref-at CELLS (+ RB RC)) 128)
               (do (set RN (%mem-byte-ref-at EXT (+ (* (+ RB RC) 16) 14))) (set RX 0) (set RS 3) (self a)))
             (#t
               (do (if (and (> RC 0) (and (= (%mem-byte-ref-at CELLS (- (+ RB RC) 1)) 128)
                                          (= (%mem-byte-ref-at EXT (+ (* (- (+ RB RC) 1) 16) 15)) 2)))
                     0
                     (EMIT 32))
                   (set RC (+ RC 1)) (self a)))))
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
; an OSC title, a charset designation, the alternate screen (?1049, ?47,
; ?1047), and characters past ASCII: narrow, wide, an emoji, a combining
; mark, a heart widened by U+FE0F, a zero-width space, a byte no
; character starts with and a character cut short.  Answers (BUF . LEN),
; BUF NUL-terminated.
(def vt-exercise
  (fn (_ seed n)
    (def buf (%make-str (+ (* n 96) 1)))
    (def p (%str->ptr buf))
    (def len ((fn (self i x at) (if (= i n) at (%op self i x at p))) 0 (%lcg seed) 0))
    (%pset p len 0 1)
    (pair buf len)))

(def %op
  (fn (_ loop i x at p)
    (def k (%rem x 24))
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
        ((= k 17) (%alt p at (= (& y 1) 0) (%pick (list 1049 47 1047 1049) (%rem (>> y 1) 4))))
        ((< k 23) (%bytes p at (%pick %chars (%rem y 8))))
        (#t (%put p at 9))))))

(def %chars
  (list (list 195 169) (list 230 151 165) (list 240 159 152 128) (list 204 129)
        (list 226 157 164 239 184 143) (list 226 128 139) (list 255) (list 195)))
(def %bytes (fn (self p at bs) (if (null? bs) at (self p (%put p at (first bs)) (rest bs)))))

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
  (fn (_ p at on mode)
    (def at1 (%put p (%put p (%put p at 27) 91) 63))
    (%put p (if (< mode 100) (%digits p at1 mode) (%digits4 p at1 mode)) (if on 104 108))))
(def %digits4
  (fn (_ p at n)
    (%put p (%put p (%put p (%put p at (+ 48 (%quot n 1000))) (+ 48 (%rem (%quot n 100) 10)))
              (+ 48 (%rem (%quot n 10) 10))) (+ 48 (%rem n 10)))))

; --- agreement -----------------------------------------------------------

; Two screens the same: every row's cells and attributes, the history's,
; and the cursor.
(def vt-same?
  (fn (_ a b)
    (def rows-same
      (if (vt-history-same? a b) (%rows-same? a b) #f))
    (if rows-same
      (if (= (first (vt-cursor a)) (first (vt-cursor b))) (= (rest (vt-cursor a)) (rest (vt-cursor b))) #f)
      #f)))
(def %rows-same?
  (fn (_ a b)
    ((fn (self r)
       (if (= r 24) #t
         (if (if (str=? (vt-row a r) (vt-row b r)) (str=? (vt-attrs a r) (vt-attrs b r)) #f)
           (self (+ r 1))
           #f)))
     0)))

; An exercise fed to two 24x80 screens in reads of CHUNK bytes, one by
; tmux/vt's engine and one by ENGINE, each read rendered by both at
; terminal row 2, column 41, as a pane is.  Answers #t, or the byte
; offset after the first read they disagree on.  x collects only when
; asked, and tmux/vt's engine and render allocate as they go, so the heap
; is collected before every read of 512 bytes or more, and every eighth
; read of fewer: what is live is two screens.
(def vt-agree
  (fn (_ engine ex chunk)
    (def a (vt-origin! (vt-make-history 24 80 40) 2 41))
    (def b (vt-origin! (vt-make-history 24 80 40) 2 41))
    (def base (%ptr->int (%str->ptr (first ex))))
    (def len (rest ex))
    ((fn (self at)
       (if (< at len)
         (do (def n (if (< (- len at) chunk) (- len at) chunk))
             (if (if (< 511 chunk) #t (= (& (%quot at chunk) 7) 0)) (Heap collect) ())
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
    (jit-group "x-tmux-vt-8" (fn (_) (list (vt-jit-form) (vt-render-form)))
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
