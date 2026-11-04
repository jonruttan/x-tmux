; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/format.x -- tmux's formats, expanded
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A format is text with #{NAME} for a value, as tmux expands it:
;
;   #{NAME}            the value, empty when there is none
;   #{?C,A,B}          A when C is true, else B: C a name or a format,
;                      true when not empty and not 0
;   #{==:A,B}          1 when A and B are the same, else 0; != < > <= >=
;                      compare too, || and && join
;   #{=N:X} #{=-N:X}   X's first N characters, or its last N
;   #{l:X}             X as it is, not expanded
;   #{b:X} #{d:X}      X's last path part, or the rest
;   #X                 a one-letter name: H host, h host short, D pane id,
;                      P pane index, T pane title, S session name,
;                      I window index, W window name, F window flags
;   ## #, #}           # , and }
;   #[STYLE]           kept as it is, for the status line to read
;   #(COMMAND)         empty: no command is run
;
; A value comes from LOOKUP, (fn (_ name)) answering a string or nil.
; format-time writes the strftime conversions in a text, as tmux writes
; them in the status line, from a local time.  A format is read a byte at
; a time; the values are not, so they may hold any character.

(module tmux/format)

(import x/sys/date)

(def %ptr (prim-ref (lit str) (lit ->ptr)))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %blen (prim-ref (lit str) (lit byte-len)))
(def %bsub (prim-ref (lit str) (lit byte-sub)))
(def %num (fn (_ n) ((prim-ref (lit convert) (lit to)) n (Type named STRING) 10)))
(def %int (fn (_ s) (guard (e ()) ((prim-ref (lit convert) (lit to)) s (Type named INTEGER) 10))))

; Byte I of S, or 0 past its end.
(def %at (fn (_ s i) (if (< i (%blen s)) (%pref (%ptr s) i 1) 0)))
(def %from (fn (_ s i) (%bsub s i (- (%blen s) i))))
(def %starts? (fn (_ p s) (if (<= (%blen p) (%blen s)) (str=? p (%bsub s 0 (%blen p))) #f)))

(def %letters
  (lit ((72 . "host") (104 . "host_short") (68 . "pane_id") (80 . "pane_index") (84 . "pane_title")
        (83 . "session_name") (73 . "window_index") (87 . "window_name") (70 . "window_flags"))))

; Where the } closing a #{ opened before I is, nested #{ } counted; -1
; when there is none.  A # escapes the byte after it.
(def %close
  (fn (self s i depth)
    (def b (%at s i))
    (match
      ((<= (%blen s) i) -1)
      ((if (= b 35) (= (%at s (+ i 1)) 123) #f) (self s (+ i 2) (+ depth 1)))
      ((= b 35) (self s (+ i 2) depth))
      ((= b 125) (if (= depth 0) i (self s (+ i 1) (- depth 1))))
      (#t (self s (+ i 1) depth)))))
; Where the byte B closing what opened before I is, or -1.
(def %find (fn (self s i b) (match ((<= (%blen s) i) -1) ((= (%at s i) b) i) (#t (self s (+ i 1) b)))))

; TEXT with its formats expanded.
(def format-expand
  (fn (_ text lookup)
    (def n (%blen text))
    ((fn (self i from acc)
       (def held (fn (_) (if (< from i) (pair (%bsub text from (- i from)) acc) acc)))
       (match
         ((<= n i) (Str8 join "" (List reverse (held))))
         ((not (= (%at text i) 35)) (self (+ i 1) from acc))
         (#t
           ((fn (_ c)
              (match
                ((= c 35) (self (+ i 2) (+ i 2) (pair "#" (held))))
                ((= c 44) (self (+ i 2) (+ i 2) (pair "," (held))))
                ((= c 125) (self (+ i 2) (+ i 2) (pair "}" (held))))
                ((= c 123)
                  ((fn (_ j)
                     (if (< j 0) (Str8 join "" (List reverse (held)))
                       (self (+ j 1) (+ j 1) (pair (%expr (%bsub text (+ i 2) (- j (+ i 2))) lookup) (held)))))
                   (%close text (+ i 2) 0)))
                ((= c 91) ((fn (_ j) (if (< j 0) (self n i acc) (self (+ j 1) i acc))) (%find text i 93)))
                ((= c 40) ((fn (_ j) (if (< j 0) (self n i acc) (self (+ j 1) (+ j 1) (held)))) (%find text i 41)))
                ((not (null? (Assoc find c %letters)))
                  (self (+ i 2) (+ i 2) (pair (%value (rest (Assoc find c %letters)) lookup) (held))))
                ((<= n (+ i 1)) (Str8 join "" (List reverse (held))))
                (#t (self (+ i 1) from acc))))
            (%at text (+ i 1))))))
     0 0 ())))

(def %value (fn (_ name lookup) ((fn (_ v) (if (null? v) "" v)) (lookup name))))
(def format-true? (fn (_ v) (if (= (%blen v) 0) #f (not (str=? v "0")))))

; A #{ }'s inside, E: a condition, a comparison, a modifier, or a name.
(def %expr
  (fn (_ e lookup)
    (def args (fn (_ at) (%split (%from e at))))
    (def compare
      (fn (_ at test)
        ((fn (_ xs) (if (test (format-expand (first xs) lookup) (format-expand (%second xs) lookup)) "1" "0"))
         (args at))))
    (match
      ((%starts? "?" e)
        ((fn (_ xs)
           (if (format-true? (%cond (first xs) lookup))
             (format-expand (%second xs) lookup)
             (format-expand (if (null? (rest xs)) "" (%second (rest xs))) lookup)))
         (args 1)))
      ((%starts? "==:" e) (compare 3 (fn (_ a b) (str=? a b))))
      ((%starts? "!=:" e) (compare 3 (fn (_ a b) (not (str=? a b)))))
      ((%starts? "<=:" e) (compare 3 (fn (_ a b) (not (%less? b a)))))
      ((%starts? ">=:" e) (compare 3 (fn (_ a b) (not (%less? a b)))))
      ((%starts? "<:" e) (compare 2 (fn (_ a b) (%less? a b))))
      ((%starts? ">:" e) (compare 2 (fn (_ a b) (%less? b a))))
      ((%starts? "||:" e) (compare 3 (fn (_ a b) (if (format-true? a) #t (format-true? b)))))
      ((%starts? "&&:" e) (compare 3 (fn (_ a b) (if (format-true? a) (format-true? b) #f))))
      ((%starts? "l:" e) (%from e 2))
      ((%starts? "b:" e) (%last-part (%inner (%from e 2) lookup)))
      ((%starts? "d:" e) (%dir (%inner (%from e 2) lookup)))
      ((%starts? "=" e)
        ((fn (_ colon)
           ((fn (_ k)
              (if (if (< colon 0) #t (null? k)) (%value e lookup) (%trim (%inner (%from e (+ colon 1)) lookup) k)))
            (if (< colon 0) () (%int (%bsub e 1 (- colon 1))))))
         (%find e 1 58)))
      (#t (%value e lookup)))))
(def %second (fn (_ xs) (if (null? (rest xs)) "" (first (rest xs)))))
; A condition's value: a format's expansion, or a name's value.
(def %cond (fn (_ c lookup) (if (%starts? "#" c) (format-expand c lookup) (%value c lookup))))
; A modifier's subject: a format, or a name.
(def %inner (fn (_ x lookup) (%cond x lookup)))

; The strings' order, as tmux compares: "10" before "2".
(def %less? (fn (_ a b) (Str8 <? a b)))

; V's first K characters, or its last -K.
(def %trim
  (fn (_ v k)
    (def n (Str8 length v))
    (if (< k 0)
      (if (< n (- 0 k)) v (Str8 sub (+ n k) (- 0 k) v))
      (if (< n k) v (Str8 sub 0 k v)))))
; A path's last part, and the rest: nothing for no value.
(def %last-part (fn (_ v) (if (= (%blen v) 0) v (List last (Str8 split "/" v)))))
(def %dir
  (fn (_ v)
    ((fn (_ parts)
       (match
         ((= (%blen v) 0) v)
         ((null? (rest parts)) ".")
         (#t (Str8 join "/" (List reverse (rest (List reverse parts)))))))
     (Str8 split "/" v))))

; S split at its commas outside #{ }, a #, kept for its expansion.
(def %split
  (fn (_ s)
    (def n (%blen s))
    ((fn (self i from depth acc)
       (def b (%at s i))
       (match
         ((<= n i) (List reverse (pair (%bsub s from (- n from)) acc)))
         ((if (= b 35) (= (%at s (+ i 1)) 123) #f) (self (+ i 2) from (+ depth 1) acc))
         ((= b 35) (self (+ i 2) from depth acc))
         ((if (= b 125) (< 0 depth) #f) (self (+ i 1) from (- depth 1) acc))
         ((if (= b 44) (= depth 0) #f) (self (+ i 1) (+ i 1) depth (pair (%bsub s from (- i from)) acc)))
         (#t (self (+ i 1) from depth acc))))
     0 0 0 ())))

; --- strftime ---------------------------------------------------------------

(def %days (lit ("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat")))
(def %day-names (lit ("Sunday" "Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday")))
(def %months (lit ("Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")))
(def %month-names
  (lit ("January" "February" "March" "April" "May" "June" "July" "August" "September" "October" "November"
        "December")))
(def %two (fn (_ n) (if (< n 10) (Str8 append "0" (%num n)) (%num n))))
(def %pad (fn (_ n) (if (< n 10) (Str8 append " " (%num n)) (%num n))))

; TEXT with strftime's %H %M %S %d %e %m %y %Y %b %h %B %a %A %I %p %R %T
; %D %F %j and %% written for date D, an alist as Date local gives one;
; any other conversion as it is.
(def format-time
  (fn (_ text d)
    (def f (fn (_ k) (Assoc get k d)))
    (def hour12 (fn (_) ((fn (_ h) (if (= h 0) 12 h)) (- (f 'hour) (* 12 (if (< 11 (f 'hour)) 1 0))))))
    (def yday
      (fn (_) (+ 1 (/ (- (Date to-unix (list (pair 'year (f 'year)) (pair 'month (f 'month)) (pair 'day (f 'day))))
                         (Date to-unix (list (pair 'year (f 'year)) (pair 'month 1) (pair 'day 1))))
                      86400))))
    (def conv
      (fn (self c)
        (match
          ((= c 72) (%two (f 'hour)))
          ((= c 77) (%two (f 'minute)))
          ((= c 83) (%two (f 'second)))
          ((= c 100) (%two (f 'day)))
          ((= c 101) (%pad (f 'day)))
          ((= c 109) (%two (f 'month)))
          ((= c 121) (%two (- (f 'year) (* 100 (/ (f 'year) 100)))))
          ((= c 89) (%num (f 'year)))
          ((if (= c 98) #t (= c 104)) (List ref (- (f 'month) 1) %months))
          ((= c 66) (List ref (- (f 'month) 1) %month-names))
          ((= c 97) (List ref (f 'wday) %days))
          ((= c 65) (List ref (f 'wday) %day-names))
          ((= c 73) (%two (hour12)))
          ((= c 112) (if (< (f 'hour) 12) "AM" "PM"))
          ((= c 82) (Str8 append (self 72) ":" (self 77)))
          ((= c 84) (Str8 append (self 72) ":" (self 77) ":" (self 83)))
          ((= c 68) (Str8 append (self 109) "/" (self 100) "/" (self 121)))
          ((= c 70) (Str8 append (self 89) "-" (self 109) "-" (self 100)))
          ((= c 106) ((fn (_ j) (Str8 append (if (< j 100) "0" "") (%two j))) (yday)))
          ((= c 37) "%")
          (#t ()))))
    (def n (%blen text))
    ((fn (self i from acc)
       (def held (fn (_) (if (< from i) (pair (%bsub text from (- i from)) acc) acc)))
       (match
         ((<= n i) (Str8 join "" (List reverse (held))))
         ((if (= (%at text i) 37) (< (+ i 1) n) #f)
           ((fn (_ v) (if (null? v) (self (+ i 2) from acc) (self (+ i 2) (+ i 2) (pair v (held)))))
            (conv (%at text (+ i 1)))))
         (#t (self (+ i 1) from acc))))
     0 0 ())))

(provide tmux/format format-expand format-time format-true?)
