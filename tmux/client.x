; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/client.x -- a command, sent to the server
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; Each command connects to the server's socket and sends one message
; (tmux/proto).  New and attach then show a session on this terminal:
; the terminal raw, what is typed sent to the server, what the server
; sends written out, until the server sends the client away; the line it
; sends with that is printed as the terminal is given back.  New starts
; the server when there is none.

(module tmux/client)

(import x/sys/posix)
(import x/repl/term)
(import x/sys/file)
(import x/sys/socket)
(import x/sys/gc)
(import tmux/proto proto-conn proto-fd proto-send! proto-send-text! proto-fill! proto-each! proto-text
  proto-fields)
(import tmux/server tmux-serve)

(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %pset (prim-ref (lit ptr) (lit set!)))
(def %call (prim-ref (lit ptr) (lit call)))
(def %byte-len (prim-ref (lit str) (lit byte-len)))
(def %num (fn (_ n) ((prim-ref (lit convert) (lit to)) n (Type named STRING) 10)))
(def %to-int (fn (_ s) ((prim-ref (lit convert) (lit to)) s (Type named INTEGER) 10)))
(def %int (fn (_ r) (if (> r 2147483647) (- r 4294967296) r)))
(def %libc (fn (_ name) ((prim-ref (lit ffi) (lit dlsym)) ((prim-ref (lit ffi) (lit dlopen)) () 1) name)))
(def %write (fn (_ fd s) (%call (%libc "write") fd (%str->ptr s) (%byte-len s))))
(def %esc
  (fn (_ text)
    (def e (%make-str 1))
    (%pset (%str->ptr e) 0 27 1)
    (Str8 append e text)))

; A connection to the server at PATH, or nil when none answers.
(def %connect (fn (_ path) (guard (e ()) (proto-conn (Socket unix-connect path)))))

; A server started at PATH, reading FILES as it starts: the socket made
; here, so a client can connect as soon as this returns, and a process
; forked off to serve it, apart from this terminal.
(def %start!
  (fn (_ path files)
    (def parts (Str8 split "/" path))
    (def dir (Str8 join "/" (List take (- (List length parts) 1) parts)))
    (guard (e ()) (File mkdir dir 448))
    (guard (e ()) (File unlink path))
    (def fd (Socket unix-listen path))
    (def pid (Sys fork))
    (if (= pid 0)
      (do (%call (%libc "setsid"))
          (def null (%int (%call (%libc "open") (%str->ptr "/dev/null") 2)))
          (Sys dup2 null 0) (Sys dup2 null 1) (Sys dup2 null 2)
          (when (< 2 null) (Sys close null))
          (Sys exit (tmux-serve fd path files)))
      (Socket close fd))))

; The terminal's size, (COLS . ROWS); 80 x 24 when it is not one.
(def %size (fn (_) (guard (e (pair 80 24)) (if (Term tty? 0) (Term window 0) (pair 80 24)))))

; A message sent (none when TEXT is nil) and the server's answer waited
; for: answers the exit status, the server's line printed.
(def %ask
  (fn (_ c type text)
    (unless (null? text) (proto-send-text! (proto-fd c) type text))
    ((fn (self)
       (if (< 0 (proto-fill! c))
         ((fn (_ out) (if (null? out) (self) (%finish out)))
          (%answer c))
         (%finish (pair 1 "[lost server]")))))))

; The server's exit message in what C holds, as (STATUS . LINE), or nil;
; output for the terminal written out.
(def %answer
  (fn (_ c)
    (def out (list ()))
    (proto-each! c
      (fn (_ type p n)
        (match
          ((= type 79) (%call (%libc "write") 1 (%int->ptr p) n))
          ((= type 88)
            ((fn (_ text)
               (def tab (Str8 index-of "\t" text))
               (%set-first! out (pair (%to-int (Str8 sub 0 tab text)) (Str8 sub (+ tab 1) (- (%byte-len text) (+ tab 1)) text))))
             (proto-text p n)))
          (#t ()))))
    (first out)))

(def %finish
  (fn (_ out)
    (unless (= (Str8 length (rest out)) 0)
      (%write (if (= (first out) 0) 1 2) (Str8 append (rest out) "\n")))
    (first out)))

; A session shown on this terminal: TYPE and TEXT the message that asks
; for it.  Answers the exit status.
; The terminal is taken only once the server's first message is output: a
; refusal comes as an exit message first, and is printed as any other.
(def %show
  (fn (_ c type text)
    (proto-send-text! (proto-fd c) type text)
    (Sys poll (list (pair (proto-fd c) (list (lit in)))) -1)
    (if (= (%first-type c) 88)
      (%ask c 0 ())
      (do (def token (Term raw! 0))
          (%write 1 (%esc "[?1049h"))
          (def out (guard (e (pair 1 "[lost server]")) (%relay c (%size))))
          (%write 1 (Str8 append (%esc "[0m") (%esc "[?1049l")))
          (Term restore! 0 token)
          (%finish out)))))

; The type of the next message from the server, left unread: recv with
; MSG_PEEK.
(def %first-type
  (fn (_ c)
    (def b (%make-str 2))
    (if (< 0 (%int (%call (%libc "recv") (proto-fd c) (%str->ptr b) 1 2)))
      ((prim-ref (lit ptr) (lit ref)) (%str->ptr b) 0 1)
      0)))

; Keys to the server, its output to the terminal, a change of size told,
; until the server sends this client away.  The heap is collected every
; 64 rounds: x collects only when asked, and a client stays as long as
; it is attached.
(def %relay
  (fn (_ c size)
    (def buf (%make-str 4097))
    (def fd (proto-fd c))
    (def rounds (list 0))
    ((fn (self size)
       (%set-first! rounds (+ (first rounds) 1))
       (when (= (first rounds) 64) (do (Heap collect) (%set-first! rounds 0)))
       (def ready (Sys poll (list (pair 0 (list (lit in))) (pair fd (list (lit in)))) 500))
       (def keys (List find (fn (_ r) (= (first r) 0)) ready))
       (def now (%size))
       (unless (if (= (first now) (first size)) (= (rest now) (rest size)) #f)
         (proto-send-text! fd 83 (Str8 append (%num (first now)) "\t" (%num (rest now)))))
       (def typed (if (null? keys) 1 (%int (%call (%libc "read") 0 (%str->ptr buf) 4096))))
       (when (if (null? keys) #f (< 0 typed)) (proto-send! fd 73 (%str->ptr buf) typed))
       (match
         ((< typed 1) (pair 1 "[lost tty]"))
         ((null? (List find (fn (_ r) (= (first r) fd)) ready)) (self now))
         ((< (proto-fill! c) 1) (pair 1 "[lost server]"))
         (#t ((fn (_ out) (if (null? out) (self now) out)) (%answer c)))))
     size)))

(def %size-text (fn (_) ((fn (_ s) (Str8 append (%num (first s)) "\t" (%num (rest s)))) (%size))))

; new-session: a session NAME (empty for the next number) made, shown
; unless DETACHED; a server started for it reads FILES.
(def tmux-new
  (fn (_ path files detached name)
    (when (if (not detached) (not (Term tty? 0)) #f)
      (do (%write 2 "open terminal failed: not a terminal\n") (Sys exit 1)))
    (def c ((fn (_ c) (if (null? c) (do (%start! path files) (%connect path)) c)) (%connect path)))
    (def text (Str8 append (%size-text) "\t" (if detached "1" "0") "\t" name "\t" (Sys getcwd)))
    (match
      ((null? c) (do (%write 2 (Str8 append "error connecting to " path "\n")) 1))
      (detached (%ask c 78 text))
      (#t (%show c 78 text)))))

; attach-session: the session NAME, or the newest, shown.  Not on a
; terminal, the size sent is 0 x 0, and the server answers whether the
; session is there before it refuses.
(def tmux-attach
  (fn (_ path name)
    (def c (%connect path))
    (match
      ((null? c) (do (%write 2 "no sessions\n") 1))
      ((Term tty? 0) (%show c 65 (Str8 append (%size-text) "\t" name)))
      (#t (%ask c 65 (Str8 append "0\t0\t" name))))))

; list-sessions and kill-server: TYPE asked of the server.
(def tmux-ask
  (fn (_ path type)
    (def c (%connect path))
    (if (null? c)
      (do (%write 2 (Str8 append "no server running on " path "\n")) 1)
      (%ask c type ""))))

(provide tmux/client tmux-new tmux-attach tmux-ask)
