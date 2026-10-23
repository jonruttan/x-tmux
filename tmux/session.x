; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/session.x -- a window of panes on the terminal
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; One window on the terminal x-tmux runs in: panes laid out by
; tmux/layout, each a shell on a pseudo-terminal whose output a screen
; keeps, and a status line on the bottom row.  The loop polls the
; keyboard and every pane; a pane's output is fed to its screen and the
; rows it changed rendered at the pane's place.  Keys go to the active
; pane, except after the prefix, C-b, which reads one key as a command:
;
;   %   split the active pane left and right      o   the next pane
;   "   split it top and bottom                   x   kill it
;   d   leave (the panes' programs are hung up)   C-b a C-b to the pane
;
; There is no server yet: leaving ends the panes, as detaching will not.

(module tmux/session)

(import x/sys/posix)
(import x/repl/term)
(import tmux/vt vt-make vt-feed! vt-render! vt-out vt-cursor vt-size vt-origin! vt-touch! vt-carry)
(import tmux/vt-jit vt-jit!)
(import tmux/layout layout-rects layout-borders layout-split layout-remove layout-panes)
(import x/sys/file)
(import x/sys/pty)

(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %pset (prim-ref (lit ptr) (lit set!)))
(def %call (prim-ref (lit ptr) (lit call)))
(def %byte-len (prim-ref (lit str) (lit byte-len)))
(def %num (fn (_ n) ((prim-ref (lit convert) (lit to)) n (Type named STRING) 10)))
(def %int (fn (_ r) (if (> r 2147483647) (- r 4294967296) r)))
(def %min (fn (_ a b) (if (< a b) a b)))
(def %libc (fn (_ name) ((prim-ref (lit ffi) (lit dlsym)) ((prim-ref (lit ffi) (lit dlopen)) () 1) name)))

; libc's read, write and waitpid, looked up as the session starts: a
; handle is a fact of the process, and a state image is written by another
(def %c-read ()) (def %c-write ()) (def %c-waitpid ()) (def %c-kill ())
(def %resolve!
  (fn (_)
    (set! %c-read (%libc "read"))
    (set! %c-write (%libc "write"))
    (set! %c-waitpid (%libc "waitpid"))
    (set! %c-kill (%libc "kill"))))

(def %esc
  (fn (_ text)
    (def e (%make-str 1))
    (%pset (%str->ptr e) 0 27 1)
    (Str8 append e text)))

; Bytes to the terminal: a string, or N bytes at a pointer.
(def %out (fn (_ s) (%call %c-write 1 (%str->ptr s) (%byte-len s))))
(def %out-bytes (fn (_ p n) (when (< 0 n) (%call %c-write 1 p n))))

; --- the session's state ---------------------------------------------------

; A pane: (ID PID FD SCREEN RECT), RECT (ROW COL ROWS COLS).
(def %pane-id (fn (_ p) (first p)))
(def %pane-pid (fn (_ p) (List ref 1 p)))
(def %pane-fd (fn (_ p) (List ref 2 p)))
(def %pane-screen (fn (_ p) (List ref 3 p)))
(def %pane-rect (fn (_ p) (List ref 4 p)))

(def %tree ())       ; the layout
(def %panes ())      ; the panes, by id
(def %active 0)      ; the active pane's id
(def %next 0)        ; the next pane's id
(def %rows 24) (def %cols 80)
(def %prefix #f)     ; whether C-b has been typed
(def %done #f)
(def %buf ())        ; a read's bytes, NUL-terminated

(def %pane (fn (_ id) (List find (fn (_ p) (= (%pane-id p) id)) %panes)))
(def %set-pane!
  (fn (_ p)
    (set! %panes (List map (fn (_ q) (if (= (%pane-id q) (%pane-id p)) p q)) %panes))))

; --- panes --------------------------------------------------------------

; SHELL, or /bin/sh, on a new pseudo-terminal of COLS x ROWS with TERM
; screen: (PID . MASTER), the master non-blocking, or nil.  The child
; closes the other panes' masters.
(def %shell
  (fn (_ cols rows)
    (def child (Pty fork cols rows (List map %pane-fd %panes)))
    (match
      ((null? child) ())
      ((= (first child) 0)
        (do (Sys setenv "TERM" "screen")
            (def shell ((fn (_ s) (if (if (null? s) #t (= (Str8 length s) 0)) "/bin/sh" s)) (Sys getenv "SHELL")))
            (Sys exec shell ())
            (Sys exit 127)))
      (#t (do (Sys nonblock! (rest child)) child)))))

; A shell in a new pane of RECT, numbered next.
(def %spawn!
  (fn (_ rect)
    (def id %next)
    (set! %next (+ %next 1))
    (def rows (List ref 2 rect))
    (def cols (List ref 3 rect))
    (def child (%shell cols rows))
    (when (null? child) (Err raise 'io "x-tmux: no pseudo-terminal for a pane" ()))
    (def screen (vt-origin! (vt-make rows cols) (first rect) (List ref 1 rect)))
    (set! %panes (List append %panes (list (list id (first child) (rest child) screen rect))))
    id))

; Every pane placed where the layout puts it now: a pane whose size has
; changed carried to a screen of the new size, its terminal told; every
; screen marked to be drawn whole.
(def %place!
  (fn (_)
    (List for-each
      (fn (_ r)
        (def p (%pane (first r)))
        (def rect (rest r))
        (def rows (List ref 2 rect))
        (def cols (List ref 3 rect))
        (def old (%pane-screen p))
        (def screen
          (if (if (= (first (vt-size old)) rows) (= (rest (vt-size old)) cols) #f)
            old
            (do (Pty window! (%pane-fd p) cols rows) (vt-carry old rows cols))))
        (vt-origin! screen (first rect) (List ref 1 rect))
        (vt-touch! screen)
        (%set-pane! (list (%pane-id p) (%pane-pid p) (%pane-fd p) screen rect)))
      (layout-rects %tree 0 0 (- %rows 1) %cols))))

; A pane gone: its program hung up and reaped, its space given back.
(def %remove!
  (fn (_ id)
    (def p (%pane id))
    (%call %c-kill (%pane-pid p) 1)
    (File close (%pane-fd p))
    (%call %c-waitpid (%pane-pid p) 0 0)
    (def order (layout-panes %tree))
    (set! %tree (layout-remove %tree id))
    (set! %panes (List filter (fn (_ q) (not (= (%pane-id q) id))) %panes))
    (if (null? %tree)
      (set! %done #t)
      (do (when (= %active id) (set! %active (%after order id)))
          (%redraw!)))))

; The pane after ID in ORDER that is still here, wrapping.
(def %after
  (fn (_ order id)
    (def here (layout-panes %tree))
    (def rest-of ((fn (self xs) (if (null? xs) () (if (= (first xs) id) (rest xs) (self (rest xs))))) order))
    (def next (List find (fn (_ x) (not (null? (List find (fn (_ y) (= x y)) here)))) (List append rest-of order)))
    (if (null? next) (first here) next)))

; The new pane is laid out before it is spawned, so its program starts
; at its own size: the child sets its terminal's window as it attaches,
; and on Darwin a window set on the master before then does not hold.
(def %split!
  (fn (_ direction)
    (def tree (layout-split %tree %active direction %next))
    (def rect (rest (List find (fn (_ r) (= (first r) %next)) (layout-rects tree 0 0 (- %rows 1) %cols))))
    (def id (%spawn! rect))
    (set! %tree tree)
    (set! %active id)
    (%redraw!)))

; --- drawing ------------------------------------------------------------

(def %goto (fn (_ row col) (%esc (Str8 append "[" (%num (+ row 1)) ";" (%num (+ col 1)) "H"))))

; The whole terminal drawn again: cleared, every pane's screen, the
; borders, the status line.
(def %redraw!
  (fn (_)
    (%place!)
    (%out (%esc "[0m"))
    (%out (%esc "[2J"))
    (List for-each %draw-border (layout-borders %tree 0 0 (- %rows 1) %cols))
    (%draw-status)))

; A border: a column of U+2502 or a row of U+2500.
(def %vbar (fn (_) (Str8 append (%byte 226) (%byte 148) (%byte 130))))
(def %hbar (fn (_) (Str8 append (%byte 226) (%byte 148) (%byte 128))))
(def %byte (fn (_ b) ((fn (_ s) (%pset (%str->ptr s) 0 b 1) s) (%make-str 1))))
(def %draw-border
  (fn (_ b)
    (if (eq? (first b) (lit v))
      ((fn (self i)
         (when (< i (List ref 3 b))
           (do (%out (Str8 append (%goto (+ (List ref 1 b) i) (List ref 2 b)) (%vbar))) (self (+ i 1)))))
       0)
      (%out (Str8 append (%goto (List ref 1 b) (List ref 2 b))
              ((fn (self i acc) (if (= i 0) acc (self (- i 1) (Str8 append acc (%hbar))))) (List ref 3 b) ""))))))

; The status line, tmux's: black on green, the session and its window.
(def %draw-status
  (fn (_)
    (%out (Str8 append (%goto (- %rows 1) 0) (%esc "[0;30;42m")
            (Str8 pad-right %cols #\space "[0] 0:x-tmux*") (%esc "[0m")))))

; Each pane's changed rows, then the cursor where the active pane has it.
(def %render!
  (fn (_)
    (%out (%esc "[?25l"))
    (List for-each
      (fn (_ p)
        (def h (%pane-screen p))
        (%out-bytes (vt-out h) (vt-render! h)))
      %panes)
    (def p (%pane %active))
    (def c (vt-cursor (%pane-screen p)))
    (def rect (%pane-rect p))
    (%out (Str8 append (%esc "[0m")
            (%goto (+ (first rect) (first c)) (+ (List ref 1 rect) (%min (rest c) (- (List ref 3 rect) 1))))
            (%esc "[?25h")))))

; --- input --------------------------------------------------------------

; One key after the prefix.
(def %command!
  (fn (_ b fd)
    (match
      ((= b 37) (%split! (lit h)))
      ((= b 34) (%split! (lit v)))
      ((= b 111) (set! %active (%after (layout-panes %tree) %active)))
      ((= b 120) (%remove! %active))
      ((= b 100) (set! %done #t))
      ((= b 2) (%call %c-write fd (%str->ptr (%byte 2)) 1))
      (#t ()))))

; The keyboard's N bytes at P: runs of keys to the active pane, a prefix
; and its command handled where they fall.
(def %keys!
  (fn (_ p n)
    ((fn (self i from)
       (def fd (%pane-fd (%pane %active)))
       (if (= i n)
         (when (< from i) (%call %c-write fd (%int->ptr (+ (%ptr->int p) from)) (- i from)))
         (do (def b (%pref p i 1))
             (match
               (%prefix (do (set! %prefix #f) (%command! b fd) (self (+ i 1) (+ i 1))))
               ((= b 2)
                 (do (when (< from i) (%call %c-write fd (%int->ptr (+ (%ptr->int p) from)) (- i from)))
                     (set! %prefix #t)
                     (self (+ i 1) (+ i 1))))
               (#t (self (+ i 1) from))))))
     0 0)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))

; A pane's output read and fed to its screen; its end, or its program's,
; removes it.
(def %output!
  (fn (_ p)
    (def at (%str->ptr %buf))
    (def got (%int (%call %c-read (%pane-fd p) at 4096)))
    (if (< 0 got)
      (do (%pset at got 0 1) (vt-feed! (%pane-screen p) (%ptr->int at) got))
      (when (if (= got 0) #t (%gone? (%pane-pid p))) (%remove! (%pane-id p))))))

; Whether a pane's program has ended: waitpid with WNOHANG.
(def %gone? (fn (_ pid) (not (= 0 (%int (%call %c-waitpid pid 0 1))))))

; --- the loop -----------------------------------------------------------

(def %ready? (fn (_ ready fd) (not (null? (List find (fn (_ r) (= (first r) fd)) ready)))))

(def %loop
  (fn (self)
    (unless %done
      (do (def ready (Sys poll (pair (pair 0 (list (lit in)))
                                     (List map (fn (_ p) (pair (%pane-fd p) (list (lit in)))) %panes))
                       500))
          (when (%ready? ready 0)
            (do (def at (%str->ptr %buf))
                (def got (%int (%call %c-read 0 at 1024)))
                (if (< 0 got) (%keys! at got) (set! %done #t))))
          (List for-each (fn (_ p) (unless %done (when (%ready? ready (%pane-fd p)) (%output! p)))) %panes)
          (unless %done
            (do (def size (Term window 1))
                (if (if (= (first size) %cols) (= (rest size) %rows) #f)
                  ()
                  (do (set! %cols (first size)) (set! %rows (rest size)) (%redraw!)))
                (%render!)))
          (self)))))

; The session, on the terminal at standard input and output; answers the
; exit status.
(def tmux-session
  (fn (_)
    ; the launcher pipes the program to the engine on fd 0 and parks the
    ; user's terminal on fd 3, as x-ash and the REPL reclaim it
    (guard (e ()) (do (Sys dup2 3 0) (Sys close 3)))
    (if (not (Term tty? 0))
      (do (File write 2 "x-tmux: not a terminal\n" 23) 1)
      (do (%resolve!)
          (vt-jit!)
          (set! %buf (%make-str 4097))
          (def size (Term window 1))
          (set! %cols (first size)) (set! %rows (rest size))
          (def token (Term raw! 0))
          (%out (%esc "[?1049h"))
          (def failed
            (guard (e (%message e))
              (do (set! %tree (list (lit pane) (%spawn! (list 0 0 (- %rows 1) %cols))))
                  (set! %active 0)
                  (%redraw!)
                  (%render!)
                  (%loop)
                  ())))
          (%leave! token)
          (if (null? failed) 0
            (do ((fn (_ s) (File write 2 s (%byte-len s))) (Str8 append "x-tmux: " failed "\n")) 1))))))

(def %message
  (fn (_ e)
    (guard (e2 "an internal error")
      (if (Err engine? e) (Str8 append (Err %str (Err code-of e)) ": " (Err %str (Err subject-of e))) (e msg)))))

; The panes hung up and reaped, the terminal given back.
(def %leave!
  (fn (_ token)
    (List for-each (fn (_ p) (%call %c-kill (%pane-pid p) 1) (%call %c-waitpid (%pane-pid p) 0 0)) %panes)
    (set! %panes ())
    (%out (%esc "[0m"))
    (%out (%esc "[?1049l"))
    (Term restore! 0 token)))

(provide tmux/session tmux-session)
