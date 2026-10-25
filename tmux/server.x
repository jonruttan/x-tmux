; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/server.x -- the sessions, kept by a server
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The server keeps the sessions and listens on a unix socket for the
; clients (tmux/client) that show them.  A session is a set of windows,
; numbered, one shown at a time; a window is panes laid out by tmux/layout,
; each a shell on a pseudo-terminal whose output a screen keeps.  The
; status line on the bottom row lists the windows.  One loop polls the
; socket, the clients and every pane; a pane's output is fed to its
; screen, and the rows it changed in the shown window are rendered for the
; session's client, if one is attached, at the pane's place.  Keys from
; the client go to the active pane, except after the prefix, C-b, which
; reads one key as a command:
;
;   %   split the active pane left and right      o   the next pane
;   "   split it top and bottom                   x   kill it, asked first
;   c   a new window                              &   kill the window, asked first
;   n   the next window                           p   the previous window
;   l   the window last shown                     0-9 the window numbered so
;   d   detach the client                         C-b a C-b to the pane
;   [   copy mode (tmux/copy)                     PgUp  copy mode, a page up
;
; In copy mode the active pane shows its history and keys move through
; it; PgUp's ends at the bottom.  A question on the status line takes y
; for yes and any other key for no.
; A window ends with its last pane, a session with its last window, and
; the server with its last session.
;
; The session being worked on lives in the module's globals; the others
; are records, and a session is entered (its record loaded into the
; globals, the one there written back to its own) before it is touched.

(module tmux/server)

(import x/sys/posix)
(import x/sys/gc)
(import x/sys/file)
(import x/sys/pty)
(import x/sys/socket)
(import tmux/vt vt-make vt-feed! vt-render! vt-out vt-cursor vt-size vt-origin! vt-touch! vt-carry)
(import tmux/vt-jit vt-jit!)
(import tmux/copy copy-enter copy-resize copy-view copy-origin! copy-touch! copy-cursor copy-position
  copy-do copy-vi? copy-key)
(import tmux/layout layout-rects layout-borders layout-split layout-remove layout-panes)
(import tmux/proto proto-conn proto-fd proto-send! proto-send-text! proto-fill! proto-each! proto-text
  proto-fields)

(def %make-str (prim-ref (lit str) (lit make)))
(def %str->ptr (prim-ref (lit str) (lit ->ptr)))
(def %ptr->str (prim-ref (lit ptr) (lit ->str)))
(def %ptr->int (prim-ref (lit ptr) (lit ->int)))
(def %int->ptr (prim-ref (lit int) (lit ->ptr)))
(def %pref (prim-ref (lit ptr) (lit ref)))
(def %pset (prim-ref (lit ptr) (lit set!)))
(def %call (prim-ref (lit ptr) (lit call)))
(def %byte-len (prim-ref (lit str) (lit byte-len)))
(def %num (fn (_ n) ((prim-ref (lit convert) (lit to)) n (Type named STRING) 10)))
(def %to-int (fn (_ s) ((prim-ref (lit convert) (lit to)) s (Type named INTEGER) 10)))
(def %int (fn (_ r) (if (> r 2147483647) (- r 4294967296) r)))
(def %min (fn (_ a b) (if (< a b) a b)))
(def %max (fn (_ a b) (if (< a b) b a)))
(def %libc (fn (_ name) ((prim-ref (lit ffi) (lit dlsym)) ((prim-ref (lit ffi) (lit dlopen)) () 1) name)))

; libc's doors, looked up as the server starts: a handle is a fact of the
; process, and a state image is written by another
(def %c-read ()) (def %c-write ()) (def %c-waitpid ()) (def %c-kill ()) (def %c-memcpy ())
(def %c-gettimeofday ())
(def %resolve!
  (fn (_)
    (set! %c-gettimeofday (%libc "gettimeofday"))
    (set! %c-read (%libc "read"))
    (set! %c-write (%libc "write"))
    (set! %c-waitpid (%libc "waitpid"))
    (set! %c-kill (%libc "kill"))
    (set! %c-memcpy (%libc "memcpy"))))

(def %esc
  (fn (_ text)
    (def e (%make-str 1))
    (%pset (%str->ptr e) 0 27 1)
    (Str8 append e text)))

; --- output for the client ----------------------------------------------

; Bytes for the attached client gather here and go as one message when the
; session settles, or sooner when the buffer fills.
(def %obuf ()) (def %ofill 0)
(def %ocap 65536)

(def %out (fn (_ s) (%out-bytes (%str->ptr s) (%byte-len s))))
(def %out-bytes
  (fn (_ p n)
    (when (< (- %ocap %ofill) n) (%flush!))
    (if (< %ocap n)
      (unless (null? %client) (proto-send! (proto-fd %client) 79 p n))
      (when (< 0 n)
        (do (%call %c-memcpy (%int->ptr (+ (%ptr->int (%str->ptr %obuf)) %ofill)) p n)
            (set! %ofill (+ %ofill n)))))))
(def %flush!
  (fn (_)
    (when (< 0 %ofill)
      (do (unless (null? %client) (proto-send! (proto-fd %client) 79 (%str->ptr %obuf) %ofill))
          (set! %ofill 0)))))

; --- the session being worked on -----------------------------------------

; A pane: (ID PID FD SCREEN RECT COPY), RECT (ROW COL ROWS COLS), COPY its
; copy mode or nil.
(def %pane-id (fn (_ p) (first p)))
(def %pane-pid (fn (_ p) (List ref 1 p)))
(def %pane-fd (fn (_ p) (List ref 2 p)))
(def %pane-screen (fn (_ p) (List ref 3 p)))
(def %pane-rect (fn (_ p) (List ref 4 p)))
(def %pane-copy (fn (_ p) (List ref 5 p)))
(def %with-copy
  (fn (_ p c) (list (%pane-id p) (%pane-pid p) (%pane-fd p) (%pane-screen p) (%pane-rect p) c)))

; A window: (INDEX TREE ACTIVE), its layout and its active pane's id; the
; shown window's are %tree and %active, written back as it is left.
(def %name "")       ; the session's name
(def %created 0)     ; when it was made, in seconds since the epoch
(def %tree ())       ; the shown window's layout
(def %panes ())      ; every window's panes, by id
(def %active 0)      ; the shown window's active pane's id
(def %next 0)        ; the next pane's id
(def %rows 24) (def %cols 80)
(def %prefix #f)     ; whether C-b has been typed
(def %client ())     ; the attached client's connection
(def %done #f)       ; whether its last window has gone
(def %windows ())    ; the windows, by index
(def %window 0)      ; the shown window's index
(def %last ())       ; the indexes of the windows shown before, the latest first
(def %cwd "")        ; where the session was made, where a new window starts
(def %prompt ())     ; the question on the status line, (TEXT . YES), or nil
(def %message ())    ; the message on the status line, or nil
(def %until 0)       ; when the message goes, in microseconds since the epoch
(def %touched #f)    ; whether there is something to render

; A session: a one-slot list holding its record, the globals above in order.
(def %current ())
(def %stash!
  (fn (_)
    (unless (null? %current)
      (do (%save-window!)
          (%set-first! %current
            (list %name %created %tree %panes %active %next %rows %cols %prefix %client %done
              %windows %window %last %cwd %prompt %message %until))))))
(def %enter!
  (fn (_ s)
    (unless (eq? s %current)
      (do (%stash!)
          (def r (first s))
          (set! %name (first r)) (set! %created (List ref 1 r)) (set! %tree (List ref 2 r))
          (set! %panes (List ref 3 r)) (set! %active (List ref 4 r)) (set! %next (List ref 5 r))
          (set! %rows (List ref 6 r)) (set! %cols (List ref 7 r)) (set! %prefix (List ref 8 r))
          (set! %client (List ref 9 r)) (set! %done (List ref 10 r))
          (set! %windows (List ref 11 r)) (set! %window (List ref 12 r)) (set! %last (List ref 13 r))
          (set! %cwd (List ref 14 r)) (set! %prompt (List ref 15 r)) (set! %message (List ref 16 r))
          (set! %until (List ref 17 r))
          (set! %current s)))))
(def %record-name (fn (_ s) (first (first s))))
(def %record-client (fn (_ s) (if (eq? s %current) %client (List ref 9 (first s)))))

(def %pane (fn (_ id) (List find (fn (_ p) (= (%pane-id p) id)) %panes)))
(def %set-pane!
  (fn (_ p)
    (set! %panes (List map (fn (_ q) (if (= (%pane-id q) (%pane-id p)) p q)) %panes))))

; --- the server's state --------------------------------------------------

(def %sessions ())   ; the sessions, oldest first
(def %conns ())      ; the clients' connections
(def %listen -1)     ; the socket listened on
(def %ids 0)         ; the next unnamed session's name
(def %started #f)    ; whether a session has been made
(def %quit #f)
(def %buf ())        ; a read's bytes, NUL-terminated

; --- panes --------------------------------------------------------------

; Every descriptor a pane's program must not keep: the socket, the
; clients', every pane's master.
(def %inherited
  (fn (_)
    (%stash!)
    (List append (list %listen) (List map proto-fd %conns)
      (List fold (fn (_ acc s) (List append acc (List map %pane-fd (List ref 3 (first s))))) () %sessions))))

; SHELL, or /bin/sh, in CWD on a new pseudo-terminal of COLS x ROWS with
; TERM screen: (PID . MASTER), the master non-blocking, or nil.
(def %shell
  (fn (_ cols rows cwd)
    (def child (Pty fork cols rows (%inherited)))
    (match
      ((null? child) ())
      ((= (first child) 0)
        (do (Sys setenv "TERM" "screen")
            (Sys chdir cwd)
            (def shell ((fn (_ s) (if (if (null? s) #t (= (Str8 length s) 0)) "/bin/sh" s)) (Sys getenv "SHELL")))
            (Sys exec shell ())
            (Sys exit 127)))
      (#t (do (Sys nonblock! (rest child)) child)))))

; A shell in CWD in a new pane of RECT, numbered next.
(def %spawn!
  (fn (_ rect cwd)
    (def id %next)
    (set! %next (+ %next 1))
    (def rows (List ref 2 rect))
    (def cols (List ref 3 rect))
    (def child (%shell cols rows cwd))
    (when (null? child) (Err raise 'io "x-tmux: no pseudo-terminal for a pane" ()))
    (def screen (vt-origin! (vt-make rows cols) (first rect) (List ref 1 rect)))
    (set! %panes (List append %panes (list (list id (first child) (rest child) screen rect ()))))
    id))

; Every pane of TREE placed where it puts it now: a pane whose size has
; changed carried to a screen of the new size, its terminal told, and its
; copy mode carried too; every screen and copy marked to be drawn whole.
(def %place!
  (fn (_ tree)
    (List for-each
      (fn (_ r)
        (def p (%pane (first r)))
        (def rect (rest r))
        (def rows (List ref 2 rect))
        (def cols (List ref 3 rect))
        (def old (%pane-screen p))
        (def same (if (= (first (vt-size old)) rows) (= (rest (vt-size old)) cols) #f))
        (def screen
          (if same old (do (Pty window! (%pane-fd p) cols rows) (vt-carry old rows cols))))
        (vt-origin! screen (first rect) (List ref 1 rect))
        (vt-touch! screen)
        (def c
          (if (null? (%pane-copy p)) ()
            (copy-touch! (copy-origin! (if same (%pane-copy p) (copy-resize (%pane-copy p) rows cols))
                           (first rect) (List ref 1 rect)))))
        (%set-pane! (list (%pane-id p) (%pane-pid p) (%pane-fd p) screen rect c)))
      (layout-rects tree 0 0 (- %rows 1) %cols))))

; A pane gone: its program hung up and reaped, its space in its window
; given back, the window closed with its last pane.
(def %remove!
  (fn (_ id)
    (def p (%pane id))
    (%call %c-kill (%pane-pid p) 1)
    (File close (%pane-fd p))
    (%call %c-waitpid (%pane-pid p) 0 0)
    (set! %panes (List filter (fn (_ q) (not (= (%pane-id q) id))) %panes))
    (%save-window!)
    (def w (List find (fn (_ w) (%holds? (List ref 1 w) id)) %windows))
    (def order (layout-panes (List ref 1 w)))
    (def tree (layout-remove (List ref 1 w) id))
    (match
      ((null? tree) (%close-window! (first w)))
      (#t
        (do (def active (if (= (List ref 2 w) id) (%after order id (layout-panes tree)) (List ref 2 w)))
            (set! %windows (List map (fn (_ x) (if (eq? x w) (list (first w) tree active) x)) %windows))
            (if (= (first w) %window)
              (do (set! %tree tree) (set! %active active) (%redraw!))
              (%place! tree)))))))

; Whether pane ID is in TREE.
(def %holds? (fn (_ tree id) (not (null? (List find (fn (_ x) (= x id)) (layout-panes tree))))))

; The pane after ID in ORDER that is in HERE, wrapping.
(def %after
  (fn (_ order id here)
    (def rest-of ((fn (self xs) (if (null? xs) () (if (= (first xs) id) (rest xs) (self (rest xs))))) order))
    (def next (List find (fn (_ x) (not (null? (List find (fn (_ y) (= x y)) here)))) (List append rest-of order)))
    (if (null? next) (first here) next)))

; The new pane is laid out before it is spawned, so its program starts
; at its own size: the child sets its terminal's window as it attaches,
; and on Darwin a window set on the master before then does not hold.
; It starts where the active pane's program was started.
(def %split!
  (fn (_ direction)
    (def tree (layout-split %tree %active direction %next))
    (def rect (rest (List find (fn (_ r) (= (first r) %next)) (layout-rects tree 0 0 (- %rows 1) %cols))))
    (def id (%spawn! rect (Sys getcwd)))
    (set! %tree tree)
    (set! %active id)
    (%redraw!)))

; Every pane's program hung up and reaped.
(def %hang-up!
  (fn (_)
    (List for-each
      (fn (_ p) (%call %c-kill (%pane-pid p) 1) (File close (%pane-fd p)) (%call %c-waitpid (%pane-pid p) 0 0))
      %panes)
    (set! %panes ())))

; --- windows --------------------------------------------------------------

(def %window-at (fn (_ i) (List find (fn (_ w) (= (first w) i)) %windows)))

; The shown window's layout and active pane written back to its record.
(def %save-window!
  (fn (_)
    (set! %windows (List map (fn (_ w) (if (= (first w) %window) (list %window %tree %active) w)) %windows))))

; Window W shown.
(def %show-window!
  (fn (_ w)
    (set! %window (first w))
    (set! %tree (List ref 1 w))
    (set! %active (List ref 2 w))
    (%redraw!)))

; The window numbered I shown, the one shown now the last.
(def %select!
  (fn (_ i)
    (unless (= i %window)
      (do (%save-window!)
          (set! %last (pair %window (List filter (fn (_ x) (not (= x i))) %last)))
          (%show-window! (%window-at i))))))

; A new window, numbered the lowest free, a shell in the session's
; directory, shown.
(def %new-window!
  (fn (_)
    (def i ((fn (self i) (if (null? (%window-at i)) i (self (+ i 1)))) 0))
    (def id (%spawn! (list 0 0 (- %rows 1) %cols) %cwd))
    (def w (list i (list (lit pane) id) id))
    (unless (null? %windows) (do (%save-window!) (set! %last (pair %window %last))))
    (set! %windows
      ((fn (self ws) (match ((null? ws) (list w)) ((< i (first (first ws))) (pair w ws)) (#t (pair (first ws) (self (rest ws))))))
       %windows))
    (%show-window! w)))

; The window numbered I, empty now, closed: if it was shown, the last
; window shown, or the one before it, or the one after, shown in its
; place.
(def %close-window!
  (fn (_ i)
    (set! %windows (List filter (fn (_ w) (not (= (first w) i))) %windows))
    (set! %last (List filter (fn (_ x) (not (= x i))) %last))
    (match
      ((null? %windows) (set! %done #t))
      ((= i %window)
        (if (null? %last)
          ((fn (_ before) (%show-window! (if (null? before) (first %windows) (first (List reverse before)))))
           (List filter (fn (_ w) (< (first w) i)) %windows))
          ((fn (_ j) (set! %last (rest %last)) (%show-window! (%window-at j))) (first %last))))
      (#t (do (%draw-status) (set! %touched #t))))))

; Every pane of the shown window gone, and the window with them.
(def %kill-window! (fn (_) (List for-each %remove! (layout-panes %tree))))

; The window after the shown one, or before it when BACK, wrapping; nil
; when the shown one is the only one.
(def %beside
  (fn (_ back)
    (def ws (if back (List reverse %windows) %windows))
    (def later ((fn (self xs) (if (null? xs) () (if (= (first (first xs)) %window) (rest xs) (self (rest xs))))) ws))
    (def w (if (null? later) (first ws) (first later)))
    (if (= (first w) %window) () w)))
(def %step!
  (fn (_ back none)
    ((fn (_ w) (if (null? w) (%say! none) (%select! (first w)))) (%beside back))))

; --- the status line's messages and questions -----------------------------

(def %tv ())
(def %micros
  (fn (_)
    (%call %c-gettimeofday (%str->ptr %tv) 0)
    (+ (* (%pref (%str->ptr %tv) 0 8) 1000000) (%pref (%str->ptr %tv) 8 4))))

; TEXT on the status line for 750 ms, tmux's display-time, or until a key.
(def %say!
  (fn (_ text)
    (set! %message text)
    (set! %until (+ (%micros) 750000))
    (%draw-status)))

; TEXT asked on the status line; YES called if the answer is y.
(def %ask!
  (fn (_ text yes)
    (set! %message ())
    (set! %prompt (pair text yes))
    (%draw-status)))

; --- drawing ------------------------------------------------------------

(def %goto (fn (_ row col) (%esc (Str8 append "[" (%num (+ row 1)) ";" (%num (+ col 1)) "H"))))

; The whole terminal drawn again: every window placed, the terminal
; cleared, the shown window's screens and borders, the status line.
(def %redraw!
  (fn (_)
    (%save-window!)
    (List for-each (fn (_ w) (%place! (List ref 1 w))) %windows)
    (%out (%esc "[0m"))
    (%out (%esc "[2J"))
    (List for-each %draw-border (layout-borders %tree 0 0 (- %rows 1) %cols))
    (%draw-status)
    (set! %touched #t)))

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

; The status line, tmux's: a question or a message black on yellow, or
; black on green the session and its windows, the shown one underlined,
; marked * and the last one shown -.
(def %draw-status
  (fn (_)
    (%out (%goto (- %rows 1) 0))
    (match
      ((not (null? %prompt)) (%out (Str8 append (%esc "[0;30;43m") (%fit (first %prompt)) (%esc "[0m"))))
      ((not (null? %message)) (%out (Str8 append (%esc "[0;30;43m") (%fit %message) (%esc "[0m"))))
      (#t (%out (Str8 append (%esc "[0;30;42m") (%window-list) (%esc "[0m")))))))

; TEXT cut or padded to the terminal's width.
(def %fit
  (fn (_ text)
    (if (< %cols (Str8 length text)) (Str8 sub 0 %cols text) (Str8 pad-right %cols #\space text))))

(def %window-list
  (fn (_)
    (def entry
      (fn (_ w)
        (Str8 append (%num (first w)) ":x-tmux"
          (match
            ((= (first w) %window) "*")
            ((if (null? %last) #f (= (first w) (first %last))) "-")
            (#t "")))))
    (def left
      (Str8 append "[" %name "] "
        (Str8 join "" (List map (fn (_ w) (Str8 append (entry w) " ")) (List filter (fn (_ w) (< (first w) %window)) %windows)))))
    (def shown (entry (%window-at %window)))
    (def right
      (Str8 join "" (List map (fn (_ w) (Str8 append " " (entry w))) (List filter (fn (_ w) (< %window (first w))) %windows))))
    (def used (+ (Str8 length left) (Str8 length shown)))
    (if (< %cols (+ used (Str8 length right)))
      (%fit (Str8 append left shown right))
      (Str8 append left (%esc "[4m") shown (%esc "[24m") (Str8 pad-right (- %cols used) #\space right)))))

; Each changed row of the shown window's panes, a pane in copy mode its
; copy's with the position over its top right, then the cursor where the
; active pane has it, or after the question on the status line.
(def %render!
  (fn (_)
    (%out (%esc "[?25l"))
    (List for-each
      (fn (_ id)
        (def p (%pane id))
        (def c (%pane-copy p))
        (def h (if (null? c) (%pane-screen p) (copy-view c)))
        (def n (vt-render! h))
        (%out-bytes (vt-out h) n)
        (when (if (null? c) #f (< 0 n)) (%draw-position p c)))
      (layout-panes %tree))
    (def p (%pane %active))
    (def c (if (null? (%pane-copy p)) (vt-cursor (%pane-screen p)) (copy-cursor (%pane-copy p))))
    (def rect (%pane-rect p))
    (%out (Str8 append (%esc "[0m")
            (if (null? %prompt)
              (%goto (+ (first rect) (first c)) (+ (List ref 1 rect) (%min (rest c) (- (List ref 3 rect) 1))))
              (%goto (- %rows 1) (%min (Str8 length (first %prompt)) (- %cols 1))))
            (%esc "[?25h")))))

; A copy mode's position, black on yellow at the right of its pane's top
; row.
(def %draw-position
  (fn (_ p c)
    (def rect (%pane-rect p))
    (def text (copy-position c))
    (%out (Str8 append (%goto (first rect) (+ (List ref 1 rect) (%max 0 (- (List ref 3 rect) (Str8 length text)))))
            (%esc "[0;30;43m") text (%esc "[0m")))))

; --- keys ---------------------------------------------------------------

; Whether copy mode reads vi's keys, decided as the server starts.
(def %vi #f)

; The key at byte I of the N at P, after the prefix; answers the byte
; after it.  PgUp starts copy mode a page up, one that ends at the bottom.
(def %command!
  (fn (_ p i n fd)
    (set! %touched #t)
    (def b (%pref p i 1))
    (match
      ((= b 27)
        ((fn (_ k) (when (eq? (first k) (lit page-up)) (do (%copy! #t) (%copy-do! (lit page-up)))) (rest k))
         (copy-key p i n #f)))
      (#t
        (do (match
              ((= b 37) (%split! (lit h)))
              ((= b 34) (%split! (lit v)))
              ((= b 111) (set! %active (%after (layout-panes %tree) %active (layout-panes %tree))))
              ((= b 120)
                (%ask! (Str8 append "kill-pane " (%num (%number %active)) "? (y/n) ")
                  (fn (_) (%remove! %active))))
              ((= b 99) (%new-window!))
              ((= b 110) (%step! #f "No next window"))
              ((= b 112) (%step! #t "No previous window"))
              ((= b 108) (if (null? %last) (%say! "No last window") (%select! (first %last))))
              ((if (< 47 b) (< b 58) #f)
                (if (null? (%window-at (- b 48)))
                  (%say! (Str8 append "Can't find window: " (%num (- b 48))))
                  (%select! (- b 48))))
              ((= b 38) (%ask! "kill-window x-tmux? (y/n) " %kill-window!))
              ((= b 100) (%detach! (Str8 append "[detached (from session " %name ")]")))
              ((= b 91) (%copy! #f))
              ((= b 2) (%call %c-write fd (%str->ptr (%byte 2)) 1))
              (#t ()))
            (+ i 1))))))

; Pane ID's number in its window, tmux's pane index: its place in the
; layout's order, from 0.
(def %number
  (fn (_ id)
    ((fn (self xs i) (if (= (first xs) id) i (self (rest xs) (+ i 1)))) (layout-panes %tree) 0)))

; The active pane into copy mode, EXIT as tmux/copy's copy-enter, unless
; it is in it.
(def %copy!
  (fn (_ exit)
    (def p (%pane %active))
    (when (null? (%pane-copy p))
      (%set-pane! (%with-copy p (copy-enter (%pane-screen p) exit))))))
; The active pane's copy mode after CMD: out of it, its screen drawn
; whole, when CMD ends it.
(def %copy-do!
  (fn (_ cmd)
    (def p (%pane %active))
    (set! %touched #t)
    (def c (copy-do (%pane-copy p) cmd))
    (when (null? c) (vt-touch! (%pane-screen p)))
    (%set-pane! (%with-copy p c))))

; N typed bytes at P: runs of keys to the active pane, or each a command
; while it is in copy mode; a prefix and its command handled where they
; fall, and a key while a question is asked its answer.  Keys clear a
; message.
(def %keys!
  (fn (_ p n)
    (unless (null? %message) (do (set! %message ()) (%draw-status) (set! %touched #t)))
    ((fn (self i from)
       (unless (if %done #t (null? %client))
         (do (def pane (%pane %active))
             (def fd (%pane-fd pane))
             (if (= i n)
               (when (< from i) (%call %c-write fd (%int->ptr (+ (%ptr->int p) from)) (- i from)))
               (do (def b (%pref p i 1))
                   (match
                     ((not (null? %prompt))
                       (do (def yes (rest %prompt))
                           (set! %prompt ())
                           (%draw-status)
                           (set! %touched #t)
                           (when (= b 121) (yes))
                           ((fn (_ next) (self next next)) (rest (copy-key p i n #f)))))
                     (%prefix (do (set! %prefix #f) ((fn (_ next) (self next next)) (%command! p i n fd))))
                     ((= b 2)
                       (do (when (< from i) (%call %c-write fd (%int->ptr (+ (%ptr->int p) from)) (- i from)))
                           (set! %prefix #t)
                           (self (+ i 1) (+ i 1))))
                     ((not (null? (%pane-copy pane)))
                       ((fn (_ k) (%copy-do! (first k)) (self (rest k) (rest k))) (copy-key p i n %vi)))
                     (#t (self (+ i 1) from))))))))
     0 0)))

; --- pane output ----------------------------------------------------------

; A pane's output read and fed to its screen, to be rendered if its window
; is shown; its end, or its program's, removes it.
(def %output!
  (fn (_ p)
    (def at (%str->ptr %buf))
    (def got (%int (%call %c-read (%pane-fd p) at 4096)))
    (if (< 0 got)
      (do (%pset at got 0 1) (vt-feed! (%pane-screen p) (%ptr->int at) got) (%moved! got)
          (when (%holds? %tree (%pane-id p)) (set! %touched #t)))
      (when (if (= got 0) #t (%gone? (%pane-pid p))) (%remove! (%pane-id p))))))

; Bytes fed since the heap was last collected, a round of the loop
; counted as 1024: x collects only when asked, and a server runs for as
; long as its sessions do, idle or not.
(def %fed 0)
(def %collect-every 65536)
(def %moved!
  (fn (_ n)
    (set! %fed (+ %fed n))
    (when (< %collect-every %fed) (do (Heap collect) (set! %fed 0)))))

; Whether a pane's program has ended: waitpid with WNOHANG.
(def %gone? (fn (_ pid) (not (= 0 (%int (%call %c-waitpid pid 0 1))))))

; --- sessions and clients ---------------------------------------------------

; The session entered brought up to date: ended when its last pane has
; gone, else what changed rendered for its client.
(def %settle!
  (fn (_)
    (match
      (%done (%end!))
      ((if %touched (not (null? %client)) #f) (do (%render!) (%flush!) (set! %touched #f)))
      (#t (do (set! %ofill 0) (set! %touched #f))))))

; The session entered ended: its client told, its panes hung up.
(def %end!
  (fn (_)
    (%detach! "[exited]")
    (%hang-up!)
    (def s %current)
    (set! %sessions (List filter (fn (_ x) (not (eq? x s))) %sessions))
    (set! %current ())
    (set! %client ())))

; The session entered's client sent away with LINE to print.
(def %detach!
  (fn (_ line)
    (unless (null? %client)
      (do (set! %ofill 0)
          (%leave! %client 0 line)
          (set! %client ())))))

; A client sent away: told to print LINE and exit with STATUS, its
; connection closed.
(def %leave!
  (fn (_ c status line)
    (proto-send-text! (proto-fd c) 88 (Str8 append (%num status) "\t" line))
    (%drop! c)))
(def %drop!
  (fn (_ c)
    (when (%live? c)
      (do (File close (proto-fd c))
          (set! %conns (List filter (fn (_ x) (not (eq? x c))) %conns))))))
(def %live? (fn (_ c) (not (null? (List find (fn (_ x) (eq? x c)) %conns)))))

; The session C is attached to, or nil.
(def %session-of (fn (_ c) (List find (fn (_ s) (eq? (%record-client s) c)) %sessions)))
(def %named (fn (_ name) (List find (fn (_ s) (str=? (%record-name s) name)) %sessions)))

; C attached to the session entered, at COLS x ROWS: a client already
; there sent away.
(def %attach!
  (fn (_ c cols rows)
    (unless (eq? %client c) (%detach! (Str8 append "[detached (from session " %name ")]")))
    (set! %client c)
    (set! %cols cols) (set! %rows rows)
    (%redraw!)
    (%settle!)))

(def %now (fn (_) (%call (%libc "time") 0)))

; A new session: COLS TAB ROWS TAB DETACHED TAB NAME TAB CWD.
(def %new!
  (fn (_ c f)
    (def name (if (= (Str8 length (List ref 3 f)) 0) (%num %ids) (List ref 3 f)))
    (if (not (null? (%named name)))
      (%leave! c 1 (Str8 append "duplicate session: " name))
      (do (when (= (Str8 length (List ref 3 f)) 0) (set! %ids (+ %ids 1)))
          (%stash!)
          (def s (list ()))
          (set! %current s)
          (set! %name name) (set! %created (%now)) (set! %tree ()) (set! %panes ()) (set! %active 0)
          (set! %next 0) (set! %cols (%to-int (first f))) (set! %rows (%to-int (List ref 1 f)))
          (set! %prefix #f) (set! %client ()) (set! %done #f)
          (set! %windows ()) (set! %window 0) (set! %last ()) (set! %cwd (List ref 4 f))
          (set! %prompt ()) (set! %message ()) (set! %until 0)
          (set! %sessions (List append %sessions (list s)))
          (set! %started #t)
          (%new-window!)
          (set! %ofill 0)
          (%stash!)
          (if (str=? (List ref 2 f) "1")
            (%leave! c 0 "")
            (%attach! c (%to-int (first f)) (%to-int (List ref 1 f))))))))

; An attach: COLS TAB ROWS TAB NAME, NAME empty for the newest session
; with no client, or the newest.
(def %attach-to!
  (fn (_ c f)
    (def name (List ref 2 f))
    (def free (List filter (fn (_ s) (null? (%record-client s))) %sessions))
    (def s
      (match
        ((< 0 (Str8 length name)) (%named name))
        ((not (null? free)) (List ref (- (List length free) 1) free))
        ((null? %sessions) ())
        (#t (List ref (- (List length %sessions) 1) %sessions))))
    (match
      ((null? %sessions) (%leave! c 1 "no sessions"))
      ((null? s) (%leave! c 1 (Str8 append "can't find session: " name)))
      ((str=? (first f) "0") (%leave! c 1 "open terminal failed: not a terminal"))
      (#t (do (%enter! s) (%attach! c (%to-int (first f)) (%to-int (List ref 1 f))))))))

; The sessions, a line each in name order, tmux's.
(def %list
  (fn (_ c)
    (%stash!)
    (def strcmp (%libc "strcmp"))
    (def before? (fn (_ a b) (< (%int (%call strcmp (%str->ptr (%record-name a)) (%str->ptr (%record-name b)))) 0)))
    (def sorted
      (List fold
        (fn (_ acc s)
          ((fn (self xs) (match ((null? xs) (list s)) ((before? s (first xs)) (pair s xs)) (#t (pair (first xs) (self (rest xs))))))
           acc))
        () %sessions))
    (def line
      (fn (_ s)
        (def r (first s))
        (Str8 append (first r) ": " (%num (List length (List ref 11 r))) " windows (created " (%ctime (List ref 1 r)) ")"
          (if (null? (List ref 9 r)) "" " (attached)"))))
    (%leave! c 0 (Str8 join "\n" (List map line sorted)))))

; Seconds since the epoch as ctime(3) writes them, without its newline.
(def %ctime
  (fn (_ t)
    (def cell (%make-str 9))
    (%pset (%str->ptr cell) 0 t 8)
    (def s (%ptr->str (%call (%libc "ctime") (%str->ptr cell))))
    (Str8 trim-right s)))

; Every session ended and the server with them.
(def %kill!
  (fn (_ c)
    (List for-each (fn (_ s) (%enter! s) (%detach! "[server exited]") (%hang-up!)) %sessions)
    (set! %sessions ())
    (set! %current ())
    (set! %client ())
    (%leave! c 0 "")
    (set! %quit #t)))

; One message from C.
(def %message!
  (fn (_ c type p n)
    (when (%live? c)
      (match
        ((= type 78) (%new! c (proto-fields (proto-text p n))))
        ((= type 65) (%attach-to! c (proto-fields (proto-text p n))))
        ((= type 76) (%list c))
        ((= type 75) (%kill! c))
        (#t
          ((fn (_ s)
             (unless (null? s)
               (do (%enter! s)
                   (if (= type 73)
                     (%keys! (%int->ptr p) n)
                     (when (= type 83)
                       ((fn (_ f) (set! %cols (%to-int (first f))) (set! %rows (%to-int (List ref 1 f))) (%redraw!))
                        (proto-fields (proto-text p n)))))
                   (%settle!))))
           (%session-of c)))))))

; What a client has sent; its end detaches it.
(def %hear!
  (fn (_ c)
    (if (< 0 (proto-fill! c))
      (proto-each! c
        (fn (_ type p n)
          (guard (e (when (%live? c) (%leave! c 1 (Str8 append "x-tmux: " (%error-text e)))))
            (%message! c type p n))))
      ((fn (_ s)
         (unless (null? s) (do (%enter! s) (set! %client ())))
         (%drop! c))
       (%session-of c)))))

(def %error-text
  (fn (_ e)
    (guard (e2 "an internal error")
      (if (Err engine? e) (Str8 append (Err %str (Err code-of e)) ": " (Err %str (Err subject-of e))) (e msg)))))

; --- the loop -----------------------------------------------------------

(def %ready? (fn (_ ready fd) (not (null? (List find (fn (_ r) (= (first r) fd)) ready)))))

(def %serve
  (fn (self)
    (unless %quit
      (do (%stash!)
          (def fds
            (List append (list (pair %listen (list (lit in))))
              (List map (fn (_ c) (pair (proto-fd c) (list (lit in)))) %conns)
              (List map (fn (_ fd) (pair fd (list (lit in))))
                (List fold (fn (_ acc s) (List append acc (List map %pane-fd (List ref 3 (first s))))) () %sessions))))
          (def saying (List find (fn (_ s) (not (null? (List ref 16 (first s))))) %sessions))
          (def ready (Sys poll fds (if (null? saying) 1000 100)))
          (when (%ready? ready %listen)
            (set! %conns (List append %conns (list (proto-conn (Socket accept %listen))))))
          (List for-each (fn (_ c) (when (if (%live? c) (%ready? ready (proto-fd c)) #f) (%hear! c))) %conns)
          (List for-each
            (fn (_ s)
              (when (not (null? (List find (fn (_ x) (eq? x s)) %sessions)))
                (do (%enter! s)
                    (List for-each (fn (_ p) (unless %done (when (%ready? ready (%pane-fd p)) (%output! p)))) %panes)
                    (when (if (null? %message) #f (< %until (%micros)))
                      (do (set! %message ()) (%draw-status) (set! %touched #t)))
                    (%settle!))))
            %sessions)
          (when (if %started (null? %sessions) #f) (set! %quit #t))
          (%moved! 1024)
          (self)))))

; The server, listening on FD at PATH until its last session ends; the
; socket is removed as it leaves.
(def tmux-serve
  (fn (_ fd path)
    (Sys signal 13 (Sys sig-ign))
    (Sys signal 1 (Sys sig-ign))
    (%resolve!)
    (vt-jit!)
    (set! %vi (copy-vi?))
    (set! %buf (%make-str 4097))
    (set! %tv (%make-str 16))
    (set! %obuf (%make-str (+ %ocap 1)))
    (set! %listen fd)
    (guard (e ()) (%serve))
    (List for-each (fn (_ s) (%enter! s) (%hang-up!)) %sessions)
    (guard (e ()) (File unlink path))
    0))

(provide tmux/server tmux-serve)
