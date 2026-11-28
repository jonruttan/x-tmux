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
;   any other command x-tmux runs        sent to the server and run there
;
; each led by the socket, as tmux's: -S PATH, or -L NAME for
; $TMUX_TMPDIR/x-tmux-UID/NAME, $TMUX_TMPDIR /tmp when it is not set and
; NAME default when there is no -L, and by -f FILE, the file of commands
; a server started reads in place of tmux.conf's;
;
; and the `vt` commands that exercise the screen's engine:
;
;   vt check FILE        FILE fed in 4096-byte reads to a screen by
;                         vt/vt's engine and to one by the compiled
;                         engine, compared after each read
;   vt bench FILE         FILE fed and rendered by each engine, timed
;   vt dump FILE          FILE fed to a 24x80 screen, its rows and cursor
;   vt exercise SEED N    N random operations as bytes, on standard output

(module tmux/cli)

(import x/sys/posix)
(import x/sys/opts)
(import x/sys/gc)
(import vt/vt vt-make vt-feed! vt-render! vt-row vt-cursor vt-feed-pure! vt-render-pure!
  vt-feed-compiled! vt-render-compiled! vt-adopt!)
(import vt/jit vt-jit-make vt-exercise vt-same?)
(import tmux/client tmux-new tmux-attach tmux-ask tmux-command)

(def %clock (prim-ref (lit sys) (lit clock)))
(import x/core/doors str-make str->ptr ptr->int ptr-set! ptr-call str-byte-len ffi-dlopen ffi-dlsym)
(import tmux/num tmux-num tmux-int)
; libc, looked up as tmux-main starts: a handle is a fact of the process.
(def %c-open ()) (def %c-read ()) (def %c-write ()) (def %c-close ())
(def %resolve!
  (fn (_)
    (def lib (ffi-dlopen () 1))
    (set! %c-open (ffi-dlsym lib "open"))
    (set! %c-read (ffi-dlsym lib "read"))
    (set! %c-write (ffi-dlsym lib "write"))
    (set! %c-close (ffi-dlsym lib "close"))))
(def %num tmux-num)
(def %int (fn (_ s) (tmux-int s 10)))
(def %write (fn (_ fd s) (ptr-call %c-write fd (str->ptr s) (str-byte-len s))))
(def %say (fn (_ s) (%write 1 s)))

; FILE's reads, each (EACH ADDRESS LENGTH), NUL-terminated.  x collects
; only when asked, and vt/vt's engine allocates as it goes, so the heap
; is collected every sixteenth read.
(def %reads
  (fn (_ path each)
    (def fd (ptr-call %c-open (str->ptr path) 0))
    (def buf (str-make 4097))
    (def p (str->ptr buf))
    ((fn (self i)
       (def got (ptr-call %c-read fd p 4096))
       (when (< 0 got)
         (do (when (= (& i 15) 15) (Heap collect))
             (ptr-set! p got 0 1) (each (ptr->int p) got) (self (+ i 1)))))
     0)
    (ptr-call %c-close fd)))

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
    (ptr-call %c-write 1 (str->ptr (first ex)) (rest ex))
    0))

(def tmux-version "0.1.0")

; The options before the command, and the help: one declaration, so an
; option cannot be taken and left out of the help.  The command's own
; flags follow it and are the command's, so the parse stops at the first
; operand.
(def tmux-options
  (Opts declare "x -l tmux --" "[OPTIONS] [COMMAND [FLAGS] [ARGUMENTS]]"
    "A terminal multiplexer, after tmux: sessions of windows of panes, each a\nshell, kept by a server while no terminal shows them.\n\nWith no command, a new session.  In a session the prefix is C-b: C-b d\ndetaches, C-b : asks for a command; the README lists the keys."
    (list (Opts arg "-L" "NAME" "Socket $TMUX_TMPDIR/x-tmux-UID/NAME; NAME is default")
          (Opts arg "-S" "PATH" "The socket by its path, in place of -L's")
          (Opts arg "-f" "FILE" "Commands a new server reads, not tmux.conf's; repeatable")
          (Opts flag "-V" "--version" "Print the version and exit")
          (Opts flag "-h" "--help" "Print this help and exit")
          (Opts text "")
          (Opts text "Commands, as tmux's:")
          (Opts text "\tnew-session, new [-d] [-s NAME]\t\tMade and shown; -d: made only")
          (Opts text "\tattach-session, attach, a [-t NAME]\tA session shown here")
          (Opts text "\tlist-sessions, ls\t\t\tThe sessions the server keeps")
          (Opts text "\tkill-server\t\t\t\tEnd the sessions and the server")
          (Opts text "\tany other command x-tmux runs\t\tSent to the server and run there")
          (Opts text "")
          (Opts text "The screen engine's tools:")
          (Opts text "\tvt check FILE\t\tFeed FILE to both engines, compared each read")
          (Opts text "\tvt bench FILE\t\tFeed and render FILE with each engine, timed")
          (Opts text "\tvt dump FILE\t\tFILE on a 24x80 screen: its rows and cursor")
          (Opts text "\tvt exercise SEED N\tN random operations as bytes, on standard output"))))

(def %usage (fn (_) (%write 2 (Opts usage tmux-options)) 2))

(def %one-of? (fn (_ s names) (List any? (fn (_ n) (str=? s n)) names)))

; The socket's path for -L NAME.
(def %socket
  (fn (_ name)
    (def dir ((fn (_ d) (if (if (null? d) #t (= (Str8 length d) 0)) "/tmp" d)) (Sys getenv "TMUX_TMPDIR")))
    (Str8 append dir "/x-tmux-" (%num (Sys getuid)) "/" name)))

; The socket the options name: -S PATH, else -L NAME, NAME default.
(def %path
  (fn (_ o)
    (def given (Opts value o "-S"))
    (if (null? given) (%socket (Opts value o "-L" "default")) given)))

; The value of FLAG among a command's OPS, or nil; with no value, whether
; it is there.
(def %flag
  (fn (self ops flag valued)
    (match
      ((null? ops) (if valued () #f))
      ((str=? (first ops) flag) (if valued (if (null? (rest ops)) () (first (rest ops))) #t))
      (#t (self (rest ops) flag valued)))))
(def %or-empty (fn (_ s) (if (null? s) "" s)))

; A tmux command at the socket PATH, a server it starts reading FILES.
(def %command
  (fn (_ path files ops)
    (def cmd (first ops))
    (match
      ((%one-of? cmd (list "new-session" "new"))
        (tmux-new path files (%flag ops "-d" #f) (%or-empty (%flag ops "-s" #t))))
      ((%one-of? cmd (list "attach-session" "attach" "a"))
        (tmux-attach path (%or-empty (%flag ops "-t" #t))))
      ((%one-of? cmd (list "list-sessions" "ls")) (tmux-ask path 76))
      ((str=? cmd "kill-server") (tmux-ask path 75))
      (#t (tmux-command path ops)))))

; The files a server reads as it starts, each (PATH . QUIET), as tmux's:
; -f FILE's, else those of tmux's own places that are there.
(def %config-files
  (fn (_ given)
    (if (null? given)
      (List map (fn (_ f) (pair f #t))
        (List append
          (list "/etc/tmux.conf" "~/.tmux.conf")
          ((fn (_ x) (if (if (null? x) #t (= (Str8 length x) 0)) () (list (Str8 append x "/tmux/tmux.conf"))))
           (Sys getenv "XDG_CONFIG_HOME"))
          (list "~/.config/tmux/tmux.conf")))
      (List map (fn (_ f) (pair f #f)) given))))

; The command line run; answers the exit status.  The options lead, and
; the parse stops at the command, whose own flags are its own.
(def tmux-main
  (fn (_ argv)
    (%resolve!)
    ; the launcher pipes the program to the engine on fd 0 and parks the
    ; user's terminal on fd 3, as x-ash and the REPL reclaim it
    (guard (e ()) (do (Sys dup2 3 0) (Sys close 3)))
    (def o (Opts parse-leading tmux-options argv))
    (def ops (Opts operands o))
    (def arg (fn (_ i) (if (< i (List length ops)) (List ref i ops) ())))
    (match
      ((Opts on? o "-h") (do (%write 1 (Opts usage tmux-options)) 0))
      ((Opts on? o "-V") (do (%write 1 (Str8 append "x-tmux " tmux-version "\n")) 0))
      ((not (null? (Opts unknown o)))
        (do (%write 2 (Str8 append "tmux: unknown option " (Opts unknown o) "\n"))
            (%usage)))
      ((null? ops) (%command (%path o) (%config-files (Opts values o "-f")) (list "new-session")))
      ((str=? (first ops) "vt")
        (match
          ((null? (arg 2)) (%usage))
          ((str=? (arg 1) "check") (%check (arg 2)))
          ((str=? (arg 1) "bench") (%bench (arg 2)))
          ((str=? (arg 1) "dump") (%dump (arg 2)))
          ((if (str=? (arg 1) "exercise") (not (null? (arg 3))) #f) (%exercise (%int (arg 2)) (%int (arg 3))))
          (#t (%usage))))
      (#t (%command (%path o) (%config-files (Opts values o "-f")) ops)))))

(provide tmux/cli tmux-main tmux-version)
