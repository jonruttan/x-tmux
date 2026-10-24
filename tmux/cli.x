; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/cli.x -- the command line
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; tmux's commands, as far as they are here:
;
;   new-session, new [-d] [-s NAME]      a session made and shown here,
;                                        or with -d only made
;   attach-session, attach, a [-t NAME]  a session shown here
;   list-sessions, ls                    the sessions
;   kill-server                          every session ended, and the server
;
; each led by the socket, as tmux's: -S PATH, or -L NAME for
; $TMUX_TMPDIR/x-tmux-UID/NAME, $TMUX_TMPDIR /tmp when it is not set and
; NAME default when there is no -L;
;
; and the `vt` commands that exercise the screen's engine:
;
;   vt check FILE        FILE fed in 4096-byte reads to a screen by
;                         tmux/vt's engine and to one by the compiled
;                         engine, compared after each read
;   vt bench FILE         FILE fed and rendered by each engine, timed
;   vt dump FILE          FILE fed to a 24x80 screen, its rows and cursor
;   vt exercise SEED N    N random operations as bytes, on standard output

(module tmux/cli)

(import x/sys/posix)
(import x/sys/gc)
(import tmux/vt vt-make vt-feed! vt-render! vt-row vt-cursor vt-feed-pure! vt-render-pure!
  vt-feed-compiled! vt-render-compiled! vt-adopt!)
(import tmux/vt-jit vt-jit-make vt-exercise vt-same?)
(import tmux/client tmux-new tmux-attach tmux-ask)

(def %clock (prim-ref (lit sys) (lit clock)))
(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %pset (prim-ref (lit ptr) (lit set!)))
(def %call (prim-ref (lit ptr) (lit call)))
(def %byte-len (prim-ref (lit str) (lit byte-len)))
(def %libc (fn (_ name) ((prim-ref (lit ffi) (lit dlsym)) ((prim-ref (lit ffi) (lit dlopen)) () 1) name)))
(def %num (fn (_ n) ((prim-ref (lit convert) (lit to)) n (Type named STRING) 10)))
(def %int (fn (_ s) ((prim-ref (lit convert) (lit to)) s (Type named INTEGER) 10)))
(def %write (fn (_ fd s) (%call (%libc "write") fd (%str->ptr s) (%byte-len s))))
(def %say (fn (_ s) (%write 1 s)))

; FILE's reads, each (EACH ADDRESS LENGTH), NUL-terminated.  x collects
; only when asked, and tmux/vt's engine allocates as it goes, so the heap
; is collected every sixteenth read.
(def %reads
  (fn (_ path each)
    (def fd (%call (%libc "open") (%str->ptr path) 0))
    (def buf (%make-str 4097))
    (def p (%str->ptr buf))
    (def rd (%libc "read"))
    ((fn (self i)
       (def got (%call rd fd p 4096))
       (when (< 0 got)
         (do (when (= (& i 15) 15) (Heap collect))
             (%pset p got 0 1) (each (%ptr->int p) got) (self (+ i 1)))))
     0)
    (%call (%libc "close") fd)))

(def %check
  (fn (_ path)
    (def engine (vt-jit-make))
    (def a (vt-make 24 80))
    (def b (vt-make 24 80))
    (def seen (list 0 #t))
    (%reads path
      (fn (_ p got)
        (when (List ref 1 seen)
          (do (vt-feed-pure! a p got)
              (vt-feed-compiled! (first engine) b p got)
              (vt-render-pure! a)
              (vt-render-compiled! (rest engine) b)
              (set! seen (list (+ (first seen) got) (vt-same? a b)))))))
    (%say (if (List ref 1 seen)
            (Str8 append "agree over " (%num (first seen)) " bytes\n")
            (Str8 append "disagree after byte " (%num (first seen)) "\n")))
    (if (List ref 1 seen) 0 1)))

(def %bench-one
  (fn (_ what feed render path)
    (def h (vt-make 24 80))
    (def tally (list 0 0 0))
    (%reads path
      (fn (_ p got)
        (def t0 (%clock))
        (feed h p got)
        (def t1 (%clock))
        (render h)
        (def t2 (%clock))
        (set! tally (list (+ (first tally) got) (+ (List ref 1 tally) (- t1 t0))
                          (+ (List ref 2 tally) (- t2 t1))))))
    (%say (Str8 append what " bytes " (%num (first tally)) " feed-us " (%num (List ref 1 tally))
            " render-us " (%num (List ref 2 tally)) "\n"))))

(def %bench
  (fn (_ path)
    (def engine (vt-jit-make))
    (%bench-one "x" vt-feed-pure! vt-render-pure! path)
    (%bench-one "compiled"
      (fn (_ h p n) (vt-feed-compiled! (first engine) h p n))
      (fn (_ h) (vt-render-compiled! (rest engine) h))
      path)
    0))

(def %dump
  (fn (_ path)
    (def h (vt-make 24 80))
    (%reads path (fn (_ p got) (vt-feed! h p got)))
    ((fn (self r) (when (< r 24) (do (%say (Str8 append (vt-row h r) "|\n")) (self (+ r 1))))) 0)
    (%say (Str8 append "cursor " (%num (first (vt-cursor h))) " " (%num (rest (vt-cursor h))) "\n"))
    0))

(def %exercise
  (fn (_ seed n)
    (def ex (vt-exercise seed n))
    (%call (%libc "write") 1 (%str->ptr (first ex)) (rest ex))
    0))

(def %usage
  (fn (_)
    (%write 2 (Str8 append "usage: x -l tmux -- [-L NAME | -S PATH] new-session [-d] [-s NAME] |"
                " attach-session [-t NAME] | list-sessions | kill-server\n"
                "       x -l tmux -- vt check|bench|dump FILE | vt exercise SEED N\n"))
    2))

(def %one-of? (fn (_ s names) (List any? (fn (_ n) (str=? s n)) names)))

; The socket's path for -L NAME.
(def %socket
  (fn (_ name)
    (def dir ((fn (_ d) (if (if (null? d) #t (= (Str8 length d) 0)) "/tmp" d)) (Sys getenv "TMUX_TMPDIR")))
    (Str8 append dir "/x-tmux-" (%num (Sys getuid)) "/" name)))

; The value of FLAG among a command's OPS, or nil; with no value, whether
; it is there.
(def %flag
  (fn (self ops flag valued)
    (match
      ((null? ops) (if valued () #f))
      ((str=? (first ops) flag) (if valued (if (null? (rest ops)) () (first (rest ops))) #t))
      (#t (self (rest ops) flag valued)))))
(def %or-empty (fn (_ s) (if (null? s) "" s)))

; A tmux command at the socket PATH.
(def %command
  (fn (_ path ops)
    (def cmd (first ops))
    (match
      ((%one-of? cmd (list "new-session" "new"))
        (tmux-new path (%flag ops "-d" #f) (%or-empty (%flag ops "-s" #t))))
      ((%one-of? cmd (list "attach-session" "attach" "a"))
        (tmux-attach path (%or-empty (%flag ops "-t" #t))))
      ((%one-of? cmd (list "list-sessions" "ls")) (tmux-ask path 76))
      ((str=? cmd "kill-server") (tmux-ask path 75))
      (#t (%usage)))))

; The command line run; answers the exit status.
(def tmux-main
  (fn (_ ops)
    (def arg (fn (_ i) (if (< i (List length ops)) (List ref i ops) ())))
    ; the launcher pipes the program to the engine on fd 0 and parks the
    ; user's terminal on fd 3, as x-ash and the REPL reclaim it
    (guard (e ()) (do (Sys dup2 3 0) (Sys close 3)))
    (match
      ((if (str=? (first ops) "-S") (not (null? (arg 2))) #f) (%command (arg 1) (rest (rest ops))))
      ((if (str=? (first ops) "-L") (not (null? (arg 2))) #f) (%command (%socket (arg 1)) (rest (rest ops))))
      ((if (str=? (first ops) "vt") (not (null? (arg 2))) #f)
        (match
          ((str=? (arg 1) "check") (%check (arg 2)))
          ((str=? (arg 1) "bench") (%bench (arg 2)))
          ((str=? (arg 1) "dump") (%dump (arg 2)))
          ((if (str=? (arg 1) "exercise") (not (null? (arg 3))) #f) (%exercise (%int (arg 2)) (%int (arg 3))))
          (#t (%usage))))
      (#t (%command (%socket "default") ops)))))

(provide tmux/cli tmux-main)
