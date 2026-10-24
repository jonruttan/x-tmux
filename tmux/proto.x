; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/proto.x -- the messages between a client and the server
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A message on the unix socket is a type byte, its payload's length as four
; bytes, high byte first, then the payload.  A payload is bytes and is
; handed over as an address and a count, never a string: typed keys carry
; NULs.  The types:
;
;   client to server   N new session   COLS TAB ROWS TAB DETACHED TAB NAME TAB CWD
;                      A attach        COLS TAB ROWS TAB NAME, COLS 0 from a
;                                      client not on a terminal
;                      L list sessions
;                      K kill the server
;                      I input         the keys typed
;                      S size          COLS TAB ROWS
;   server to client   O output        bytes for the terminal
;                      X exit          STATUS TAB LINES: printed as the client
;                                      leaves with the status
;
; A connection keeps what it has read in a buffer of its own until a whole
; message is there.  Its descriptor blocks: it is read when poll says
; there is something to read.

(module tmux/proto)


(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %pset (prim-ref (lit ptr) (lit set!)))
(def %call (prim-ref (lit ptr) (lit call)))
(def %byte-len (prim-ref (lit str) (lit byte-len)))
(def %byte-sub (prim-ref (lit str) (lit byte-sub)))
(def %libc (fn (_ name) ((prim-ref (lit ffi) (lit dlsym)) ((prim-ref (lit ffi) (lit dlopen)) () 1) name)))
(def %int (fn (_ r) (if (> r 2147483647) (- r 4294967296) r)))

; The most a connection holds unread.
(def %capacity 262144)

; A connection: (FD BUFFER FILL), FILL a one-slot list.
(def proto-conn (fn (_ fd) (list fd (%make-str (+ %capacity 1)) (list 0))))
(def proto-fd (fn (_ c) (first c)))

; N bytes at pointer P sent as a message of TYPE (a character code): the
; whole of it, a short write written on.  Answers #f when the peer has gone.
(def proto-send!
  (fn (_ fd type p n)
    (def head (%make-str 6))
    (def at (%str->ptr head))
    (%pset at 0 type 1)
    (%pset at 1 (& (>> n 24) 255) 1) (%pset at 2 (& (>> n 16) 255) 1)
    (%pset at 3 (& (>> n 8) 255) 1) (%pset at 4 (& n 255) 1)
    (if (%write-all fd (%ptr->int at) 5) (%write-all fd (%ptr->int p) n) #f)))
(def %write-all
  (fn (self fd p n)
    (if (= n 0) #t
      ((fn (_ w) (if (< w 1) #f (self fd (+ p w) (- n w))))
       (%int (%call (%libc "write") fd (%int->ptr p) n))))))

(def proto-send-text! (fn (_ fd type s) (proto-send! fd type (%str->ptr s) (%byte-len s))))

; Whatever the socket has read into the connection: answers the count, 0
; at the peer's end, below 0 on an error or with the buffer full.
(def proto-fill!
  (fn (_ c)
    (def fill (first (List ref 2 c)))
    (def room (- %capacity fill))
    (if (= room 0) -1
      ((fn (_ got) (if (< 0 got) (%set-first! (List ref 2 c) (+ fill got)) ()) got)
       (%int (%call (%libc "read") (first c) (%int->ptr (+ (%ptr->int (%str->ptr (List ref 1 c))) fill)) room))))))

; Each whole message the connection holds handed to (F TYPE ADDRESS COUNT),
; in order, and dropped; a message read in part is kept.
(def proto-each!
  (fn (_ c f)
    (def buf (%str->ptr (List ref 1 c)))
    (def fill (first (List ref 2 c)))
    (def used
      ((fn (self at)
         (if (< (- fill at) 5) at
           ((fn (_ n)
              (if (< (- fill at) (+ n 5)) at
                (do (f (%pref buf at 1) (+ (%ptr->int buf) (+ at 5)) n)
                    (self (+ at (+ n 5))))))
            (| (<< (%pref buf (+ at 1) 1) 24) (| (<< (%pref buf (+ at 2) 1) 16)
               (| (<< (%pref buf (+ at 3) 1) 8) (%pref buf (+ at 4) 1)))))))
       0))
    (if (< 0 used)
      (do (%call (%libc "memmove") buf (%int->ptr (+ (%ptr->int buf) used)) (- fill used))
          (%set-first! (List ref 2 c) (- fill used)))
      ())))

; A payload's bytes as a string, for the payloads that are text.
(def proto-text
  (fn (_ p n)
    (def s (%make-str (+ n 1)))
    (%call (%libc "memcpy") (%str->ptr s) (%int->ptr p) n)
    (%pset (%str->ptr s) n 0 1)
    (%byte-sub s 0 n)))

; A text payload's fields, split at its tabs.
(def proto-fields (fn (_ text) (Str8 split "\t" text)))

(provide tmux/proto proto-conn proto-fd proto-send! proto-send-text! proto-fill! proto-each!
  proto-text proto-fields)
