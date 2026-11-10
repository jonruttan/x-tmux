; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/keys.x -- keys by tmux's names
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A key is named as tmux names it: a character as it is, or Space, Tab,
; Enter, Escape, BSpace, Up, Down, Left, Right, Home, End, IC, DC, PPage,
; NPage, BTab, F1 to F12, led by C-, M- and S- for Ctrl, Meta and Shift,
; in that order.  A name given to bind is read as tmux reads one: its
; modifiers in any case and order, ^x for C-x, PageUp and PageDown for
; PPage and NPage, and the other names in any case.

(module tmux/keys)

(import x/core/doors ptr-ref str-make str->ptr ptr-set! str-byte-len)
(def %num (fn (_ n) ((prim-ref (lit convert) (lit to)) n (Type named STRING) 10)))

(def %byte
  (fn (_ b)
    (def s (str-make 1))
    (ptr-set! (str->ptr s) 0 b 1)
    s))

; The names of keys with no character, as tmux spells them, then the
; spellings it also takes.
(def %named
  (lit ("Space" "Tab" "BTab" "Enter" "Escape" "BSpace" "Up" "Down" "Left" "Right" "Home" "End" "IC" "DC"
        "PPage" "NPage" "F1" "F2" "F3" "F4" "F5" "F6" "F7" "F8" "F9" "F10" "F11" "F12" "Any")))
(def %spellings (lit (("PageUp" . "PPage") ("PgUp" . "PPage") ("PageDown" . "NPage") ("PgDn" . "NPage"))))

; The keys of a CSI or SS3 sequence's last byte, and of the number before
; a ~.
(def %finals
  (lit ((65 . "Up") (66 . "Down") (67 . "Right") (68 . "Left") (72 . "Home") (70 . "End") (90 . "BTab")
        (80 . "F1") (81 . "F2") (82 . "F3") (83 . "F4"))))
(def %tildes
  (lit ((1 . "Home") (7 . "Home") (4 . "End") (8 . "End") (2 . "IC") (3 . "DC") (5 . "PPage") (6 . "NPage")
        (11 . "F1") (12 . "F2") (13 . "F3") (14 . "F4") (15 . "F5") (17 . "F6") (18 . "F7") (19 . "F8")
        (20 . "F9") (21 . "F10") (23 . "F11") (24 . "F12"))))

(def %lookup (fn (_ k table) ((fn (_ e) (if (null? e) () (rest e))) (List find (fn (_ e) (= (first e) k)) table))))

; NAME led by the modifiers of xterm's parameter M: 2 Shift, 3 Meta, 5
; Ctrl, and their sums less one.
(def %modified
  (fn (_ m name)
    (def bits (- m 1))
    (Str8 append (if (< 0 (& bits 4)) "C-" "") (if (< 0 (& bits 2)) "M-" "") (if (< 0 (& bits 1)) "S-" "") name)))

; NAME with Meta: C-M-x for C-x, as tmux orders them.
(def %meta
  (fn (_ name)
    (if (if (< 2 (Str8 length name)) (str=? (Str8 sub 0 2 name) "C-") #f)
      (Str8 append "C-M-" (Str8 sub 2 (- (Str8 length name) 2) name))
      (Str8 append "M-" name))))

; The key at byte I of the N at P: (NAME . NEXT), NEXT the byte after it.
; An ESC with nothing after it in the read is Escape; an ESC before
; another key is Meta on it.
(def key-read
  (fn (self p i n)
    (def b (ptr-ref p i 1))
    (def at (fn (_ k) (if (< (+ i k) n) (ptr-ref p (+ i k) 1) -1)))
    (match
      ((= b 27)
        (match
          ((= (at 1) -1) (pair "Escape" (+ i 1)))
          ((if (if (= (at 1) 91) #t (= (at 1) 79)) (< 0 (at 2)) #f) (%sequence p (+ i 2) n 0 ()))
          (#t ((fn (_ k) (pair (%meta (first k)) (rest k))) (self p (+ i 1) n)))))
      ((= b 0) (pair "C-Space" (+ i 1)))
      ((= b 9) (pair "Tab" (+ i 1)))
      ((= b 13) (pair "Enter" (+ i 1)))
      ((< b 27) (pair (Str8 append "C-" (%byte (+ b 96))) (+ i 1)))
      ((< b 32) (pair (Str8 append "C-" (%byte (+ b 64))) (+ i 1)))
      ((= b 32) (pair "Space" (+ i 1)))
      ((= b 127) (pair "BSpace" (+ i 1)))
      ((< b 128) (pair (%byte b) (+ i 1)))
      (#t ((fn (_ j) (pair ((fn (self k acc) (if (= k j) acc (self (+ k 1) (Str8 append acc (%byte (ptr-ref p k 1)))))) i "") j))
           ((fn (self j) (if (if (< j n) (= (& (ptr-ref p j 1) 192) 128) #f) (self (+ j 1)) j)) (+ i 1)))))))

; A CSI or SS3 sequence's key, its parameters read from I: NUM the one
; being read, BEFORE those before it, the latest first.  The first
; parameter is a ~ key's number, the second the modifier.  A sequence
; with no key here is Escape.
(def %sequence
  (fn (self p i n num before)
    (if (< i n)
      ((fn (_ b)
         (def ps (List reverse (pair num before)))
         (def m (if (null? (rest ps)) 1 (List ref 1 ps)))
         (def named (fn (_ k) (pair (if (null? k) "Escape" (%modified m k)) (+ i 1))))
         (match
           ((if (< 47 b) (< b 58) #f) (self p (+ i 1) n (+ (* num 10) (- b 48)) before))
           ((= b 59) (self p (+ i 1) n 0 (pair num before)))
           ((= b 126) (named (%lookup (first ps) %tildes)))
           ((if (< 63 b) (< b 127) #f) (named (%lookup b %finals)))
           (#t (pair "Escape" (+ i 1)))))
       (ptr-ref p i 1))
      (pair "Escape" i))))

; NAME as tmux reads a key's name, or nil when it names none.
(def key-name
  (fn (_ name)
    (def n (Str8 length name))
    ; the modifiers C M S seen, then the rest of NAME from I
    ((fn (self i c m s)
       (def rest-of (Str8 sub i (- n i) name))
       (def two (if (< (+ i 1) n) (Str8 sub i 2 name) ""))
       (match
         ((if (< (+ i 2) n) (if (str=? (Str8 sub (+ i 1) 1 name) "-") #t #f) #f)
           ((fn (_ x)
              (match
                ((if (str=? x "C") #t (str=? x "c")) (self (+ i 2) #t m s))
                ((if (str=? x "M") #t (str=? x "m")) (self (+ i 2) c #t s))
                ((if (str=? x "S") #t (str=? x "s")) (self (+ i 2) c m #t))
                (#t (%base rest-of c m s))))
            (Str8 sub i 1 name)))
         ((if (str=? (Str8 sub i 1 name) "^") (= (+ i 2) n) #f) (%base (Str8 sub (+ i 1) 1 name) #t m s))
         (#t (%base rest-of c m s))))
     0 #f #f #f)))

; The key BASE with the modifiers C M S, or nil when BASE names none.
(def %base
  (fn (_ base c m s)
    (def named
      (match
        ((= (Str8 length base) 0) ())
        ((= (str-byte-len base) 1)
          (if (if c ((fn (_ b) (if (< 64 b) (< b 91) #f)) (ptr-ref (str->ptr base) 0 1)) #f) (Str8 downcase base) base))
        (#t ((fn (_ e)
               (if (null? e)
                 ((fn (_ x) (if (null? x) (%character base) x))
                  (List find (fn (_ k) (str=? (Str8 downcase k) (Str8 downcase base))) %named))
                 (rest e)))
             (List find (fn (_ e) (str=? (Str8 downcase (first e)) (Str8 downcase base))) %spellings)))))
    (if (null? named) () (Str8 append (if c "C-" "") (if m "M-" "") (if s "S-" "") named))))

; BASE when it is one UTF-8 character, else nil.
(def %character
  (fn (_ base)
    (if (< 127 (ptr-ref (str->ptr base) 0 1))
      ((fn (_ lead)
         (def len (match ((< 239 lead) 4) ((< 223 lead) 3) (#t 2)))
         (if (= (str-byte-len base) len) base ()))
       (ptr-ref (str->ptr base) 0 1))
      ())))

; The bytes tmux sends a pane's program for the key NAME, as key-name
; spells it: a character, C- one as its control byte, M- led by ESC; an
; arrow, Home or End as CSI and its final, F1 to F4 as SS3, the others as
; CSI N ~; a modified one with xterm's parameter, 1 + Shift 1 + Meta 2 +
; Ctrl 4, as CSI 1;M and the final or CSI N;M ~.  The bytes are a list
; of numbers, a NUL among them: C-Space's is one.  Empty for a key with
; no bytes.
(def key-bytes
  (fn (_ name)
    (def n (Str8 length name))
    ; the modifiers' bits, the name after them from AT
    ((fn (self bits at)
       (def led? (fn (_ s) (if (< (+ at 2) n) (str=? (Str8 sub at 2 name) s) #f)))
       (match
         ((led? "C-") (self (| bits 4) (+ at 2)))
         ((led? "M-") (self (| bits 2) (+ at 2)))
         ((led? "S-") (self (| bits 1) (+ at 2)))
         (#t
           (do (def base (Str8 sub at (- n at) name))
               (def csi (fn (_ text) (pair 27 (pair 91 (key-text-bytes text)))))
               (def m (%num (+ bits 1)))
               (def final (%named-lookup base %cursor-finals))
               (def fn-key (%named-lookup base %function-finals))
               (def tilde (%named-lookup base %tilde-numbers))
               (match
                 ((not (null? final))
                   (match
                     ((< 0 bits) (csi (Str8 append "1;" m final)))
                     ((str=? base "Home") (csi "1~"))
                     ((str=? base "End") (csi "4~"))
                     (#t (csi final))))
                 ((not (null? fn-key)) (if (< 0 bits) (csi (Str8 append "1;" m fn-key)) (pair 27 (pair 79 (key-text-bytes fn-key)))))
                 ((not (null? tilde)) (csi (Str8 append tilde (if (< 0 bits) (Str8 append ";" m) "") "~")))
                 ((str=? base "BTab") (csi "Z"))
                 (#t (%character-bytes (Str8 append (if (< 0 (& bits 4)) "C-" "") (if (< 0 (& bits 2)) "M-" "") base))))))))
     0 0)))

; TEXT's bytes, a list of numbers: send-keys -l's for its text.
(def key-text-bytes
  (fn (_ text)
    (def n (str-byte-len text))
    ((fn (self i) (if (= i n) () (pair (ptr-ref (str->ptr text) i 1) (self (+ i 1))))) 0)))

; The finals of the keys CSI sends, by name.
(def %cursor-finals (lit (("Up" . "A") ("Down" . "B") ("Right" . "C") ("Left" . "D") ("Home" . "H") ("End" . "F"))))
(def %function-finals (lit (("F1" . "P") ("F2" . "Q") ("F3" . "R") ("F4" . "S"))))
(def %tilde-numbers
  (lit (("IC" . "2") ("DC" . "3") ("PPage" . "5") ("NPage" . "6") ("F5" . "15") ("F6" . "17") ("F7" . "18")
        ("F8" . "19") ("F9" . "20") ("F10" . "21") ("F11" . "23") ("F12" . "24"))))
(def %named-lookup
  (fn (_ name table) ((fn (_ e) (if (null? e) () (rest e))) (List find (fn (_ e) (str=? (first e) name)) table))))

; A character key's bytes, with its modifiers: M- led by ESC, C- as the
; control byte.
(def %character-bytes
  (fn (self name)
    (def n (Str8 length name))
    (match
      ((if (< 2 n) (str=? (Str8 sub 0 2 name) "M-") #f) (pair 27 (self (Str8 sub 2 (- n 2) name))))
      ((if (< 4 n) (str=? (Str8 sub 0 4 name) "C-M-") #f) (pair 27 (self (Str8 append "C-" (Str8 sub 4 (- n 4) name)))))
      ((str=? name "C-Space") (list 0))
      ((if (= n 3) (str=? (Str8 sub 0 2 name) "C-") #f)
        ((fn (_ c) (list (if (if (< 96 c) (< c 123) #f) (- c 96) (& c 31)))) (ptr-ref (str->ptr name) 2 1)))
      ((str=? name "Space") (list 32))
      ((str=? name "Tab") (list 9))
      ((str=? name "Enter") (list 13))
      ((str=? name "Escape") (list 27))
      ((str=? name "BSpace") (list 127))
      ((null? (List find (fn (_ k) (str=? k name)) %named)) (key-text-bytes name))
      (#t ()))))

(provide tmux/keys key-read key-name key-bytes key-text-bytes)
