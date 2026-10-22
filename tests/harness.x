; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tests/harness.x -- what the spec harness adds to the dialect
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The lang kit's generator writes tests/lib/harness.gen.x: the dialect
; lang.xon declares, the bundle's root on the import path, then this file.
(import tmux/base)

; What a spec reads of a screen.  TEXT's ^ stands for ESC, so a sequence
; is spelled as it prints: "^[2;3H".
(def %spec-make-str (prim-ref (lit str) (lit make)))
(def %spec-str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %spec-ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %spec-pset (prim-ref (lit ptr) (lit set!)))
(def %spec-pref (prim-ref (lit ptr) (lit ref)))
(def %spec-blen (prim-ref (lit str) (lit byte-len)))

(def spec-bytes
  (fn (_ text)
    (def n (%spec-blen text))
    (def buf (%spec-make-str (+ n 1)))
    (def p (%spec-str->ptr buf))
    (def q (%spec-str->ptr text))
    ((fn (self i)
       (when (< i n)
         (do (def b (%spec-pref q i 1))
             (%spec-pset p i (if (= b 94) 27 b) 1)
             (self (+ i 1)))))
     0)
    (%spec-pset p n 0 1)
    (pair buf n)))

; TEXT fed to the screen H by FEED; H.
(def spec-feed!
  (fn (_ feed h text)
    (def b (spec-bytes text))
    (feed h (%spec-ptr->int (%spec-str->ptr (first b))) (rest b))
    h))

; TEXT fed to a new 24x80 screen by FEED; the screen.
(def spec-screen (fn (_ feed text) (spec-feed! feed (vt-make 24 80) text)))

; A screen's rows that are not blank, as (ROW "TEXT") with the trailing
; blanks dropped, then (cursor ROW COL).
(def spec-rows
  (fn (_ h)
    (def trim
      (fn (_ s)
        ((fn (self n) (if (if (< 0 n) (= (%spec-pref (%spec-str->ptr s) (- n 1) 1) 32) #f) (self (- n 1))
                        ((prim-ref (lit str) (lit byte-sub)) s 0 n)))
         (%spec-blen s))))
    (List append
      (List filter (fn (_ r) (not (str=? (List ref 1 r) "")))
        (List map (fn (_ r) (list r (trim (vt-row h r)))) (List range 0 (first (vt-size h)))))
      (list (list 'cursor (first (vt-cursor h)) (rest (vt-cursor h)))))))

; TEXT's screen by tmux/vt's engine, as spec-rows reads it.
(def spec-vt (fn (_ text) (spec-rows (spec-screen vt-feed-pure! text))))

; ROW's attribute bytes, the first N.
(def spec-attrs
  (fn (_ h row n)
    (def s (vt-attrs h row))
    (List map (fn (_ i) (%spec-pref (%spec-str->ptr s) i 1)) (List range 0 n))))

; What a render of H wrote, N bytes, ESC shown as ^.
(def spec-rendered
  (fn (_ h n)
    (def s (%spec-make-str n))
    (def p (%spec-str->ptr s))
    (def q (vt-out h))
    ((fn (self i)
       (when (< i n)
         (do (def b (%spec-pref q i 1))
             (%spec-pset p i (if (= b 27) 94 b) 1)
             (self (+ i 1)))))
     0)
    s))
