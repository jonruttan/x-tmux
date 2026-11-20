; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/paste.x -- the paste buffers, as tmux 3.8 keeps them
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A store of paste buffers, a port of tmux's paste.c: (BUFFERS INDEX
; ORDER), BUFFERS the newest first, INDEX the number the next automatic
; buffer's name tries first, ORDER the order the next buffer takes.  A
; buffer is (NAME DATA AUTOMATIC ORDER CREATED), CREATED in seconds since
; the epoch.  An automatic buffer is named bufferN; one set by name is
; not, and neither is one renamed, nor one copy mode's append sets again
; under its name.  The newest automatic buffer is the one a paste or a
; delete takes when given no name, and only automatic buffers count
; towards the limit.
;
; paste-sample writes a buffer's start as tmux shows it: its first 200
; bytes, a newline, a tab, a backslash and a byte that is not printable
; written as C writes them in a string, an octal escape where C has none,
; "..." after when there was more.

(module tmux/paste)

(import x/core/doors str-byte-len str-byte-sub str->ptr ptr-ref int/ int%)

(import tmux/num tmux-num)

(def %num tmux-num)

(def paste-empty (list () 0 0))

(def paste-buffers (fn (_ store) (first store)))
(def paste-name (fn (_ b) (first b)))
(def paste-data (fn (_ b) (List ref 1 b)))
(def paste-automatic? (fn (_ b) (List ref 2 b)))
(def paste-order (fn (_ b) (List ref 3 b)))
(def paste-created (fn (_ b) (List ref 4 b)))
(def paste-size (fn (_ b) (str-byte-len (paste-data b))))

; The buffer called NAME, or nil.
(def paste-named
  (fn (_ store name)
    (List find (fn (_ b) (str=? (paste-name b) name)) (paste-buffers store))))
; The newest automatic buffer, or nil.
(def paste-top (fn (_ store) (List find paste-automatic? (paste-buffers store))))

; STORE without the buffer called NAME.
(def paste-free
  (fn (_ store name)
    (list (List filter (fn (_ b) (not (str=? (paste-name b) name))) (paste-buffers store))
      (List ref 1 store) (List ref 2 store))))

; STORE with buffer B the newest.
(def %newest
  (fn (_ store b index)
    (list (pair b (paste-buffers store)) index (+ (List ref 2 store) 1))))

; STORE with DATA the newest automatic buffer, made at TIME, the oldest
; automatic ones let go while LIMIT are kept; empty DATA adds none.
(def paste-add
  (fn (_ store data limit time)
    (if (= (str-byte-len data) 0) store
      (do (def kept
            ((fn (self bs n)
               (match
                 ((null? bs) ())
                 ((not (paste-automatic? (first bs))) (pair (first bs) (self (rest bs) n)))
                 ((< n limit) (pair (first bs) (self (rest bs) (+ n 1))))
                 (#t (self (rest bs) n))))
             (paste-buffers store) 1))
          (def trimmed (list kept (List ref 1 store) (List ref 2 store)))
          ((fn (self k)
             (def name (Str8 append "buffer" (%num k)))
             (if (null? (paste-named trimmed name))
               (%newest trimmed (list name data #t (List ref 2 trimmed) time) (+ k 1))
               (self (+ k 1))))
           (List ref 1 store))))))

; NAME as tmux takes it for a buffer, or nil when it is not one: each
; character printable ASCII or whole UTF-8, a backslash written twice.
(def paste-clean-name
  (fn (_ name)
    (def n (str-byte-len name))
    (def p (str->ptr name))
    (def valid?
      (fn (self i)
        (if (= i n) #t
          ((fn (_ w) (if (= w 0) #f (self (+ i w)))) (%char-at p i n)))))
    (if (valid? 0) (%vis name n #t) ())))

; How many bytes the character at I of the N at P takes: a printable ASCII
; byte 1, a whole UTF-8 character its length, else 0.
(def %char-at
  (fn (_ p i n)
    (def b (ptr-ref p i 1))
    (if (< b 128) (if (if (< 31 b) (< b 127) #f) 1 0) (%utf8-at p i n))))
; The length of the UTF-8 character at I, or 0 when it is not whole.
(def %utf8-at
  (fn (_ p i n)
    (def b (ptr-ref p i 1))
    (def w (match ((< b 194) 0) ((< b 224) 2) ((< b 240) 3) ((< b 245) 4) (#t 0)))
    (if (if (= w 0) #t (< n (+ i w))) 0
      ((fn (self k) (match ((= k w) w) ((= (int/ (ptr-ref p (+ i k) 1) 64) 2) (self (+ k 1))) (#t 0))) 1))))

; STORE with DATA set as the buffer called NAME, made at TIME, the newest,
; replacing one of that name: (STORE . MESSAGE), MESSAGE nil or what went
; wrong, tmux's.  Without NAME it is added as an automatic buffer.
(def paste-set
  (fn (_ store data name limit time)
    (match
      ((= (str-byte-len data) 0) (pair store ()))
      ((null? name) (pair (paste-add store data limit time) ()))
      ((= (str-byte-len name) 0) (pair store "empty buffer name"))
      (#t ((fn (_ clean)
             (if (null? clean) (pair store (Str8 append "invalid buffer name: " name))
               (pair (%newest (paste-free store clean) (list clean data #f (List ref 2 store) time) (List ref 1 store))
                 ())))
           (paste-clean-name name))))))

; STORE with the buffer called OLD called NEW, no longer automatic, in
; its place; one called NEW let go: (STORE . MESSAGE).
(def paste-rename
  (fn (_ store old new)
    (def clean (if (null? new) () (if (= (str-byte-len new) 0) () (paste-clean-name new))))
    (def b (if (null? old) () (paste-named store old)))
    (match
      ((if (null? old) #t (= (str-byte-len old) 0)) (pair store "no buffer"))
      ((if (null? new) #t (= (str-byte-len new) 0)) (pair store "new name is empty"))
      ((null? clean) (pair store (Str8 append "invalid buffer name: " new)))
      ((null? b) (pair store (Str8 append "no buffer " old)))
      ((str=? clean old) (pair store ()))
      (#t (pair (list (List map
                        (fn (_ x) (if (str=? (paste-name x) old) (list clean (paste-data x) #f (paste-order x) (paste-created x)) x))
                        (List filter (fn (_ x) (not (str=? (paste-name x) clean))) (paste-buffers store)))
                  (List ref 1 store) (List ref 2 store))
            ())))))

; The buffers in ORDER, creation (the newest first), name or size, a tie
; broken by name, REVERSED turning it about, as tmux's sort.c sorts them.
(def paste-sorted
  (fn (_ store order reversed)
    (def cmp
      (fn (_ a b)
        (def by
          (match
            ((eq? order (lit name)) (%strcmp (paste-name a) (paste-name b)))
            ((eq? order (lit size)) (%compare (paste-size a) (paste-size b)))
            (#t (%compare (paste-order b) (paste-order a)))))
        (def r (if (= by 0) (%strcmp (paste-name a) (paste-name b)) by))
        (if reversed (- 0 r) r)))
    (List sort (fn (_ a b) (< (cmp a b) 0)) (paste-buffers store))))
(def %compare (fn (_ a b) (match ((< a b) -1) ((< b a) 1) (#t 0))))
; Byte by byte, as strcmp compares.
(def %strcmp
  (fn (_ a b)
    (def na (str-byte-len a))
    (def nb (str-byte-len b))
    ((fn (self i)
       (match
         ((if (= i na) (= i nb) #f) 0)
         ((= i na) -1)
         ((= i nb) 1)
         (#t ((fn (_ x y) (if (= x y) (self (+ i 1)) (if (< x y) -1 1)))
              (ptr-ref (str->ptr a) i 1) (ptr-ref (str->ptr b) i 1)))))
     0)))

; Buffer B's start as tmux shows it.
(def paste-sample
  (fn (_ b)
    (def n (paste-size b))
    (def shown (%vis (paste-data b) (if (< 200 n) 200 n) #t))
    (if (if (< 200 n) #t (< 200 (str-byte-len shown))) (Str8 append (str-byte-sub shown 0 200) "...") shown)))

; LINE as tmux's preview shows it: as a sample is written, but the whole
; of it, and it holds no newline.
(def paste-shown (fn (_ line) (%vis line (str-byte-len line) #f)))

; The first N bytes of TEXT written as tmux's vis writes them: a whole
; UTF-8 character as it is, a printable byte as it is but a backslash
; twice, a tab, a newline when NL, and C's other escapes with a backslash,
; any other byte in octal.
(def %vis
  (fn (_ text n nl)
    (def p (str->ptr text))
    (def esc
      (fn (_ b next)
        (match
          ((= b 92) "\\\\")
          ((if nl (= b 10) #f) "\\n")
          ((= b 10) "\n")
          ((= b 9) "\\t")
          ((= b 13) "\\r")
          ((= b 8) "\\b")
          ((= b 7) "\\a")
          ((= b 11) "\\v")
          ((= b 12) "\\f")
          ((= b 0) (if (if (< 47 next) (< next 56) #f) "\\000" "\\0"))
          (#t (Str8 append "\\" (%num (int/ b 64)) (%num (int% (int/ b 8) 8)) (%num (int% b 8)))))))
    ((fn (self i from acc)
       (def held (fn (_) (if (< from i) (pair (str-byte-sub text from (- i from)) acc) acc)))
       (if (<= n i) (Str8 join "" (List reverse (held)))
         (do (def b (ptr-ref p i 1))
             (def w (if (< b 128) 0 (%utf8-at p i n)))
             (match
               ((< 0 w) (self (+ i w) from acc))
               ((if (< 31 b) (if (< b 127) (not (= b 92)) #f) #f) (self (+ i 1) from acc))
               (#t (self (+ i 1) (+ i 1)
                     (pair (esc b (if (< (+ i 1) n) (ptr-ref p (+ i 1) 1) 0)) (held))))))))
     0 0 ())))

(provide tmux/paste paste-empty paste-buffers paste-name paste-data paste-automatic? paste-order paste-created
  paste-size paste-named paste-top paste-free paste-add paste-clean-name paste-set paste-rename paste-sorted
  paste-sample paste-shown)
