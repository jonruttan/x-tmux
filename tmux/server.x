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
;   ,   rename the window                         d   detach the client
;   [   copy mode (tmux/copy)                     PgUp  copy mode, a page up
;   ]   paste the newest buffer                   C-b a C-b to the pane
;   z   zoom the active pane, or back             arrows  the pane that way
;   C-arrows  move its border a cell              M-arrows  5 cells
;   ;   the pane active before                    q   the panes' numbers
;   {   swap the pane with the one before         }   with the one after
;   C-o rotate the panes forward                  M-o backward
;   M-1 to M-7  a preset layout                   Space  the next one
;
; An arrow command repeats for half a second: another arrow then needs no
; prefix, as tmux's repeat-time has it.  Splitting, killing, resizing,
; picking, moving or laying out panes puts a zoomed pane back first.  The
; panes' numbers show for a second, a digit then picking that pane and
; any other key putting them away, the prefix going on as the prefix.
; The preset layouts are tmux's: M-1 even-horizontal, M-2 even-vertical,
; M-3 main-horizontal, M-4 main-vertical, M-5 tiled, M-6 and M-7 the
; main ones mirrored.
; In copy mode the active pane shows its history and keys move through
; it; PgUp's ends at the bottom.  What copy mode copies is kept as the
; newest of the server's paste buffers, 50 at most, as tmux keeps them,
; and a paste types it to the active pane, each newline a carriage
; return.  Keys and pastes the pane's program does not take at once wait
; for it, in order.  A question on the status line takes y
; for yes and any other key for no; a name asked for is typed and edited
; there, Enter taking it and Escape leaving it.  A window is named after
; its active pane's program until it is renamed, as tmux's
; automatic-rename names it.
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
(import x/sys/host)
(import x/sys/date)
(import tmux/format format-expand format-time)
(import tmux/vt vt-make vt-make-history vt-feed! vt-render! vt-out vt-cursor vt-size vt-origin! vt-touch! vt-carry
  vt-cursor-shown? vt-cursor-keys? vt-bracketed?)
(import tmux/vt-jit vt-jit!)
(import tmux/copy copy-enter copy-resize copy-view copy-origin! copy-touch! copy-cursor copy-position
  copy-do copy-selecting? copy-text copy-marks copy-vi? copy-key)
(import tmux/layout layout-new layout-rects layout-borders layout-split layout-remove layout-panes
  layout-resize layout-fit layout-size layout-beside layout-relabel layout-names layout-arrange)
(import tmux/command command-parse command-read command-list command-matches command-flag)
(import tmux/keys key-read key-name key-bytes)
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
(def %c-gettimeofday ()) (def %c-tcgetpgrp ())
(def %resolve!
  (fn (_)
    (set! %c-gettimeofday (%libc "gettimeofday"))
    (set! %c-tcgetpgrp (%libc "tcgetpgrp"))
    (set! %c-read (%libc "read"))
    (set! %c-write (%libc "write"))
    (set! %c-waitpid (%libc "waitpid"))
    (set! %c-kill (%libc "kill"))
    (set! %c-memcpy (%libc "memcpy"))
    (def buf (%make-str 256))
    (%call (%libc "gethostname") (%str->ptr buf) 255)
    (set! %host ((fn (self i) (if (= (%pref (%str->ptr buf) i 1) 0) (Str8 sub 0 i buf) (self (+ i 1)))) 0))
    (set! %host-short ((fn (_ parts) (if (null? parts) %host (first parts))) (Str8 split "." %host)))))

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

; A window: (INDEX TREE ACTIVE NAME AUTO CHECKED DUE ZOOMED ORDER LAYOUT),
; its layout, its active pane's id, its name, whether the name follows
; the active pane's program, when that was last looked at, in
; microseconds since the epoch, whether it is to be looked at again,
; whether its active pane is zoomed to fill it, its panes' ids in tmux's
; pane order, which numbers them, and the place in layout-names of the
; preset layout last given it, -1 for none; the shown window's TREE and
; ACTIVE are %tree and %active, written back as it is left.
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
(def %prompt ())     ; the question on the status line, (LABEL TEXT AT YES TYPED COMMAND), or nil
(def %message ())    ; the message on the status line, or nil
(def %until 0)       ; when the message goes, in microseconds since the epoch
(def %recent ())     ; the panes' ids, the most recently active first
(def %repeat 0)      ; until when an arrow repeats its command, in microseconds since the epoch
(def %numbers 0)     ; until when the panes' numbers show, in microseconds since the epoch, or 0
(def %touched #f)    ; whether there is something to render

; A session: a one-slot list holding its record, the globals above in order.
(def %current ())
(def %stash!
  (fn (_)
    (unless (null? %current)
      (do (%save-window!)
          (%set-first! %current
            (list %name %created %tree %panes %active %next %rows %cols %prefix %client %done
              %windows %window %last %cwd %prompt %message %until %recent %repeat %numbers))))))
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
          (set! %until (List ref 17 r)) (set! %recent (List ref 18 r)) (set! %repeat (List ref 19 r))
          (set! %numbers (List ref 20 r))
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

; A shell in CWD in a new pane of RECT, numbered next, keeping
; history-limit rows of history.
(def %spawn!
  (fn (_ rect cwd)
    (def id %next)
    (set! %next (+ %next 1))
    (def rows (List ref 2 rect))
    (def cols (List ref 3 rect))
    (def child (%shell cols rows cwd))
    (when (null? child) (Err raise 'io "x-tmux: no pseudo-terminal for a pane" ()))
    (def screen (vt-origin! (vt-make-history rows cols (%option "history-limit")) (first rect) (List ref 1 rect)))
    (set! %panes (List append %panes (list (list id (first child) (rest child) screen rect ()))))
    (set! %recent (pair id %recent))
    id))

; Pane ID made the active one.
(def %activate!
  (fn (_ id)
    (set! %active id)
    (set! %recent (pair id (List filter (fn (_ x) (not (= x id))) %recent)))))

; Every pane of window W placed where its layout puts it now, its zoomed
; pane over the whole window: a pane whose size has changed carried to a
; screen of the new size, its terminal told, and its copy mode carried
; too; every screen and copy marked to be drawn whole.
(def %place!
  (fn (_ w)
    (def whole (list 0 0 (%pane-rows) %cols))
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
      (List map (fn (_ r) (if (if (List ref 7 w) (= (first r) (List ref 2 w)) #f) (pair (first r) whole) r))
        (layout-rects (List ref 1 w) 0 0)))))

; A pane gone: its program hung up and reaped, its space in its window
; given back, the window closed with its last pane.
(def %remove!
  (fn (_ id)
    (def p (%pane id))
    (%call %c-kill (%pane-pid p) 1)
    (File close (%pane-fd p))
    (%call %c-waitpid (%pane-pid p) 0 0)
    (set! %pending (List filter (fn (_ w) (not (= (first w) (%pane-fd p)))) %pending))
    (set! %panes (List filter (fn (_ q) (not (= (%pane-id q) id))) %panes))
    (set! %recent (List filter (fn (_ x) (not (= x id))) %recent))
    (%save-window!)
    (def w (List find (fn (_ w) (%holds? (List ref 1 w) id)) %windows))
    (def order (List ref 8 w))
    (def tree (layout-remove (List ref 1 w) id))
    (match
      ((null? tree) (%close-window! (first w)))
      (#t
        (do (def active (if (= (List ref 2 w) id) (%successor order id (layout-panes tree)) (List ref 2 w)))
            (set! %windows (List map (fn (_ x) (if (eq? x w) (%laid w tree active) x)) %windows))
            (%window-set! (first w) 7 #f)
            (%window-set! (first w) 8 (List filter (fn (_ x) (not (= x id))) order))
            (if (= (first w) %window)
              (do (set! %tree tree) (set! %active active) (%redraw!))
              (%place! (%window-at (first w)))))))))

; Whether pane ID is in TREE.
(def %holds? (fn (_ tree id) (not (null? (List find (fn (_ x) (= x id)) (layout-panes tree))))))

; The pane after ID in ORDER that is in HERE, wrapping.
(def %after
  (fn (_ order id here)
    (def rest-of ((fn (self xs) (if (null? xs) () (if (= (first xs) id) (rest xs) (self (rest xs))))) order))
    (def next (List find (fn (_ x) (not (null? (List find (fn (_ y) (= x y)) here)))) (List append rest-of order)))
    (if (null? next) (first here) next)))

; The pane to be active after ID has gone, of the panes in HERE: the most
; recently active, tmux's last pane, else the one after it in ORDER.
(def %successor
  (fn (_ order id here)
    ((fn (_ x) (if (null? x) (%after order id here) x))
     (List find (fn (_ x) (not (null? (List find (fn (_ y) (= x y)) here)))) %recent))))

; The new pane is laid out before it is spawned, so its program starts
; at its own size: the child sets its terminal's window as it attaches,
; and on Darwin a window set on the master before then does not hold.
; It starts where the active pane's program was started.  A pane under 3
; cells the way it is split is refused, as tmux refuses it: answers nil,
; or tmux's message.
(def %split!
  (fn (_ direction)
    (%unzoom!)
    (def tree (layout-split %tree %active direction %next))
    (if (null? tree) "no space for new pane"
      (do (def rect (rest (List find (fn (_ r) (= (first r) %next)) (layout-rects tree 0 0))))
          (def id (%spawn! rect (Sys getcwd)))
          (set! %tree tree)
          (%window-set! %window 8
            ((fn (self xs) (if (= (first xs) %active) (pair %active (pair id (rest xs))) (pair (first xs) (self (rest xs)))))
             (%order)))
          (%activate! id)
          (%redraw!)
          ()))))

; --- zoom, the pane beside, resizing ------------------------------------

(def %zoomed? (fn (_) (List ref 7 (%window-at %window))))

; The shown window's active pane zoomed to fill it, or back in its place
; when it is; a window of one pane is left as it is.
(def %zoom!
  (fn (_)
    (match
      ((%zoomed?) (%unzoom!))
      ((null? (rest (layout-panes %tree))) ())
      (#t (do (%window-set! %window 7 #t) (%name-due! %window) (%redraw!))))))
(def %unzoom!
  (fn (_) (when (%zoomed?) (do (%window-set! %window 7 #f) (%redraw!)))))

; The pane beside the active one in DIRECTION, L R U or D, made active,
; the window unzoomed first.
(def %beside!
  (fn (_ direction)
    (%unzoom!)
    ((fn (_ id) (unless (null? id) (do (%activate! id) (%name-due! %window))))
     (layout-beside %tree %active direction %recent))))

; The active pane resized N cells in DIRECTION, its border moved, the
; window unzoomed first.
(def %resize!
  (fn (_ direction n)
    (%unzoom!)
    (set! %tree (layout-resize %tree %active direction n))
    (%redraw!)))

; The shown window's panes that are drawn: the zoomed one alone.
(def %shown (fn (_) (if (%zoomed?) (list %active) (layout-panes %tree))))

; --- the last pane, moving panes, the preset layouts ----------------------

; The shown window's panes in tmux's pane order.
(def %order (fn (_) (List ref 8 (%window-at %window))))

; The pane active before the active one in its window made active again,
; tmux's last-pane, the window unzoomed first: nil, or tmux's message.
(def %last-pane!
  (fn (_)
    ((fn (_ id)
       (if (null? id) "no last pane"
         (do (%unzoom!) (%activate! id) (%name-due! %window) ())))
     (List find (fn (_ x) (if (= x %active) #f (%holds? %tree x))) %recent))))

; The shown window's panes put in the order NEW, each taking the cell of
; the pane at its place in the order now, the window unzoomed first.
(def %reorder!
  (fn (_ new)
    (%unzoom!)
    (set! %tree (layout-relabel %tree (%order) new))
    (%window-set! %window 8 new)
    (%redraw!)))

; The active pane swapped with the one before it in order, or after it
; when FORWARD, wrapping, as swap-pane -U and -D; it stays active.
(def %swap!
  (fn (_ forward)
    (def order (%order))
    (def other (%after (if forward order (List reverse order)) %active order))
    (unless (= other %active)
      (%reorder! (List map (fn (_ x) (match ((= x %active) other) ((= x other) %active) (#t x))) order)))))

; The panes moved a cell back in order, the first to the last, or, BACK,
; a cell on, the last to the first, as rotate-window and its -D: the
; pane moved into the active one's cell made active.
(def %rotate!
  (fn (_ back)
    (def order (%order))
    (unless (null? (rest order))
      (do (def k (%number %active))
          (def new
            (if back
              ((fn (_ r) (pair (first r) (List reverse (rest r)))) (List reverse order))
              (List append (rest order) (list (first order)))))
          (%reorder! new)
          (%activate! (List ref k new))
          (%name-due! %window)))))

; The shown window laid out by the preset layout at K in layout-names, as
; select-layout, the window unzoomed first, and K kept for the next.  A
; layout bigger than the window is not taken.
(def %arrange!
  (fn (_ k)
    (%unzoom!)
    (%window-set! %window 9 k)
    (def t (layout-arrange (List ref k layout-names) (%order) %cols (%pane-rows)))
    (unless (null? t)
      ((fn (_ size)
         (when (if (<= (first size) %cols) (<= (rest size) (%pane-rows)) #f) (do (set! %tree t) (%redraw!))))
       (layout-size (layout-fit t %cols (%pane-rows)))))))

; The preset layout after the one last given the shown window, as
; next-layout, the first when none was.
(def %next-layout!
  (fn (_)
    (%arrange! (Num remainder (+ (List ref 9 (%window-at %window)) 1) (List length layout-names)))))

; The preset layout before the one last given the shown window, as
; previous-layout, the last when none was or the first was.
(def %previous-layout!
  (fn (_)
    ((fn (_ k) (%arrange! (if (< 0 k) (- k 1) (- (List length layout-names) 1))))
     (List ref 9 (%window-at %window)))))


; --- the panes' numbers ---------------------------------------------------

; The panes' numbers shown for display-panes-time.
(def %show-numbers!
  (fn (_) (set! %numbers (+ (%micros) (* 1000 (%option "display-panes-time")))) (set! %touched #t)))

; The panes' numbers put away, the panes under them drawn again.
(def %hide-numbers! (fn (_) (set! %numbers 0) (%redraw!)))

; The pane numbered K made active, as a digit does while the numbers
; show, the window unzoomed first; nothing when there is none.
(def %pick!
  (fn (_ k)
    (def order (%order))
    (when (< k (List length order))
      (do (%unzoom!) (%activate! (List ref k order)) (%name-due! %window)))))

; Each digit as tmux's clock draws it, a letter a row: F all 5 cells, S
; the first and the last, L the first, R the last.
(def %digits (lit ("FSSSF" "RRRRR" "FRFLF" "FRFRF" "SSFRR" "FLFRF" "FLFSF" "FRRRR" "FSFSF" "FSFRF")))
(def %runs
  (fn (_ letter)
    (match
      ((str=? letter "F") (lit ((0 5))))
      ((str=? letter "S") (lit ((0 1) (4 1))))
      ((str=? letter "L") (lit ((0 1))))
      (#t (lit ((4 1)))))))

; Each shown pane's number over it, as tmux's display-panes draws it, red
; for the active pane and blue for the others: in tmux's clock digits in
; a pane 5 cells a digit wide and 7 rows high, else as text in its
; middle; and its size at its top right.
(def %draw-numbers
  (fn (_)
    (def rects (layout-rects %tree 0 0))
    (List for-each
      (fn (_ id)
        (def rect (%pane-rect (%pane id)))
        (def row (first rect))
        (def col (List ref 1 rect))
        (def rows (List ref 2 rect))
        (def cols (List ref 3 rect))
        (def colour (if (= id %active) "1" "4"))
        (def text (%num (%number id)))
        (def len (Str8 length text))
        (def own (rest (List find (fn (_ r) (= (first r) id)) rects)))
        (def size (Str8 append (%num (List ref 3 own)) "x" (%num (List ref 2 own))))
        (%out (Str8 append (%goto row (+ col (%max 0 (- cols (Str8 length size))))) (%esc (Str8 append "[0;3" colour "m"))
                (if (< cols (Str8 length size)) (Str8 sub 0 cols size) size) (%esc "[0m")))
        (if (if (< cols (- (* len 6) 1)) #t (< rows 7))
          (unless (< cols len)
            (%out (Str8 append (%goto (+ row (Num quotient rows 2)) (+ col (Num quotient (- cols len) 2)))
                    (%esc (Str8 append "[0;3" colour "m")) text (%esc "[0m"))))
          (do (def top (+ row (Num quotient (- rows 5) 2)))
              (def left (+ col (Num quotient (- cols (- (* len 6) 1)) 2)))
              ((fn (self d)
                 (when (< d len)
                   (do (def shape (List ref (%to-int (Str8 sub d 1 text)) %digits))
                       ((fn (self j)
                          (when (< j 5)
                            (do (List for-each
                                  (fn (_ run)
                                    (%out (Str8 append (%goto (+ top j) (+ (+ left (* d 6)) (first run)))
                                            (%esc (Str8 append "[0;4" colour "m")) (Str8 pad-right (List ref 1 run) #\space "")
                                            (%esc "[0m"))))
                                  (%runs (Str8 sub j 1 shape)))
                                (self (+ j 1)))))
                        0)
                       (self (+ d 1)))))
               0))))
      (%shown))))

; Every pane's program hung up and reaped.
(def %hang-up!
  (fn (_)
    (List for-each
      (fn (_ p)
        (%call %c-kill (%pane-pid p) 1) (File close (%pane-fd p)) (%call %c-waitpid (%pane-pid p) 0 0)
        (set! %pending (List filter (fn (_ w) (not (= (first w) (%pane-fd p)))) %pending)))
      %panes)
    (set! %panes ())))

; --- windows --------------------------------------------------------------

(def %window-at (fn (_ i) (List find (fn (_ w) (= (first w) i)) %windows)))

; Window W with TREE and ACTIVE.
(def %laid (fn (_ w tree active) (pair (first w) (pair tree (pair active (rest (rest (rest w))))))))

; The shown window's layout and active pane written back to its record.
(def %save-window!
  (fn (_)
    (set! %windows (List map (fn (_ w) (if (= (first w) %window) (%laid w %tree %active) w)) %windows))))

; Field K of window I's record set to V.
(def %window-set!
  (fn (_ i k v)
    (def put (fn (self xs j) (if (= j k) (pair v (rest xs)) (pair (first xs) (self (rest xs) (+ j 1))))))
    (set! %windows (List map (fn (_ w) (if (= (first w) i) (put w 0) w)) %windows))))

; The window holding pane ID.
(def %window-of
  (fn (_ id)
    (%save-window!)
    (List find (fn (_ w) (%holds? (List ref 1 w) id)) %windows)))

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
    (def id (%spawn! (list 0 0 (%pane-rows) %cols) %cwd))
    (def w (list i (layout-new id %cols (%pane-rows)) id "x-tmux" #t 0 #f #f (list id) -1))
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

; --- window names -----------------------------------------------------------

; Window I's name looked at now, as tmux's automatic-rename looks: its
; active pane's foreground program, or [tmux] while the pane is in copy
; mode; the status line drawn again when it changes.
(def %check-name!
  (fn (_ i)
    (%save-window!)
    (def w (%window-at i))
    (%window-set! i 5 (%micros))
    (%window-set! i 6 #f)
    (when (List ref 4 w)
      (do (def p (%pane (List ref 2 w)))
          (def name (if (null? (%pane-copy p)) (%program (%pane-fd p)) "[tmux]"))
          (unless (if (null? name) #t (str=? name (List ref 3 w)))
            (do (%window-set! i 3 name) (%draw-status) (set! %touched #t)))))))

; Window I's name to be looked at: now, or once 500 ms have passed since
; it last was, tmux's NAME_INTERVAL.
(def %name-due!
  (fn (_ i)
    (if (< (+ (List ref 5 (%window-at i)) 500000) (%micros)) (%check-name! i) (%window-set! i 6 #t))))

; The name of the foreground program on the terminal whose master is FD,
; the kernel's name for its process group's leader, or nil.
(def %program
  (fn (_ fd)
    (def pgrp (%int (%call %c-tcgetpgrp fd)))
    (if (< pgrp 1) ()
      ((fn (_ e) (if (null? e) () (rest e)))
       (List find (fn (_ e) (eq? (first e) (lit comm))) (Host process pgrp))))))

; The shown window renamed NAME, its name no longer following its program.
(def %rename!
  (fn (_ name)
    (%window-set! %window 3 name)
    (%window-set! %window 4 #f)
    (%draw-status)))

; --- the status line's messages and questions -----------------------------

(def %tv ())
(def %micros
  (fn (_)
    (%call %c-gettimeofday (%str->ptr %tv) 0)
    (+ (* (%pref (%str->ptr %tv) 0 8) 1000000) (%pref (%str->ptr %tv) 8 4))))

; TEXT on the status line for display-time, or until a key, its first
; letter a capital, as tmux shows a command's message.
(def %say!
  (fn (_ text)
    (%show! (if (= (Str8 length text) 0) text (Str8 append (Str8 upcase (Str8 sub 0 1 text)) (Str8 sub 1 (- (Str8 length text) 1) text)))
      ())))

; TEXT on the status line for MS milliseconds, display-time's for nil, or
; until a key for 0, as display-message shows it.
(def %show!
  (fn (_ text ms)
    (def wait (if (null? ms) (%option "display-time") ms))
    (set! %message text)
    (set! %until (+ (%micros) (if (= wait 0) 315360000000000 (* 1000 wait))))
    (%draw-status)))

; Whether status-interval's seconds have passed since the status lines
; were last drawn for it, the next time set when they have; never for 0.
(def %status-next 0)
(def %status-tick!
  (fn (_)
    (def every (* 1000000 (%option "status-interval")))
    (def now (%micros))
    (if (if (< 0 every) (<= %status-next now) #f) (do (set! %status-next (+ now every)) #t) #f)))

; What display-message shows without a format, tmux's.
(def %display-template
  "[#{session_name}] #{window_index}:#{window_name}, current pane #{pane_index} - (%H:%M %d-%b-%y)")

; TEXT asked on the status line; YES called if the answer is y.
(def %ask!
  (fn (_ text yes)
    (set! %message ())
    (set! %prompt (list text "" 0 yes #f #f))
    (%draw-status)))

; LABEL on the status line and TEXT after it to be edited, the cursor at
; its end; YES called with the text Enter takes.  A COMMAND prompt keeps
; a history and completes commands' names.
(def %ask-for!
  (fn (_ label text yes command)
    (set! %message ())
    (set! %prompt (list label text (%byte-len text) yes #t command))
    (set! %back -1)
    (set! %choices "")
    (%draw-status)))

; The lines run from the command prompt, the latest first, 100 at most,
; tmux's prompt-history-limit; which of them the prompt shows, -1 for
; none; and the names Tab offers, shown after the text until the next key.
(def %history ())
(def %back -1)
(def %choices "")

; Where a question's text is shown from: as far along as keeps its cursor
; on the terminal after its label, tmux's.
(def %scrolled
  (fn (_)
    (%max 0 (- (+ (List ref 2 %prompt) 1) (%max 1 (- %cols (Str8 length (first %prompt))))))))


; TEXT read and run: text that does not read runs none of its commands.
(def %run-text!
  (fn (_ text)
    ((fn (_ parsed) (if (first parsed) (%run-all! (List ref 1 parsed)) (%say! (List ref 1 parsed))))
     (command-parse text))))

; COMMANDS run in turn, a command that fails stopping the ones after it,
; its message said.
(def %run-all!
  (fn (self commands)
    (unless (if (null? commands) #t %done)
      ((fn (_ wrong) (if (null? wrong) (self (rest commands)) (%say! wrong))) (%run! (first commands))))))

; TEXT's digits as a number, or nil when it is empty or holds another
; character; with SIGNED, a leading - too.
(def %count
  (fn (_ text)
    (def n (Str8 length text))
    ((fn (self i acc)
       (match
         ((= i n) (if (= n 0) () acc))
         (((fn (_ c) (if (< 47 c) (< c 58) #f)) (%pref (%str->ptr text) i 1))
           (self (+ i 1) (+ (* acc 10) (- (%pref (%str->ptr text) i 1) 48))))
         (#t ())))
     0 0)))
(def %signed
  (fn (_ text)
    (if (if (< 1 (Str8 length text)) (str=? (Str8 sub 0 1 text) "-") #f)
      ((fn (_ k) (if (null? k) () (- 0 k))) (%count (Str8 sub 1 (- (Str8 length text) 1) text)))
      (%count text))))

; TEXT less PREFIX when it starts with it.
(def %less
  (fn (_ prefix text)
    (if (if (<= (Str8 length prefix) (Str8 length text)) (str=? prefix (Str8 sub 0 (Str8 length prefix) text)) #f)
      (Str8 sub (Str8 length prefix) (- (Str8 length text) (Str8 length prefix)) text)
      text)))

; A target as its messages name it: less a leading : . or =.
(def %bare (fn (_ target) (%less "=" (%less "." (%less ":" target)))))

; The pane a target names in the shown window, N, .N or :.N its number,
; + and - the panes after and before the active one; the active pane for
; none; nil for one not there.
(def %pane-target
  (fn (_ target)
    (def order (%order))
    (if (null? target) %active
      ((fn (_ t)
         (match
           ((str=? t "+") (%after order %active order))
           ((str=? t "-") (%after (List reverse order) %active order))
           (#t ((fn (_ k) (if (if (null? k) #t (<= (List length order) k)) () (List ref k order))) (%count t)))))
       (%bare target)))))

; The window a target names, N, :N or :=N its number; the shown one for
; none; nil for one not there.
(def %window-target
  (fn (_ target)
    (if (null? target) %window
      ((fn (_ k) (if (if (null? k) #t (null? (%window-at k))) () k)) (%count (%bare target))))))

; The directions of the flags D L R U, as layout-beside names them.
(def %direction
  (fn (_ flags)
    ((fn (_ d) (if (null? d) () (%symbol (first d))))
     (List filter (fn (_ d) (not (null? (command-flag flags d)))) (lit ("D" "L" "R" "U"))))))
(def %symbol
  (fn (_ d) (match ((str=? d "D") (lit D)) ((str=? d "L") (lit L)) ((str=? d "R") (lit R)) (#t (lit U)))))

; TEMPLATE with each %% and %1 in it the ANSWER, as command-prompt fills
; its template.
(def %fill
  (fn (_ template answer)
    (def n (Str8 length template))
    ((fn (self i acc)
       (match
         ((= i n) acc)
         ((if (str=? (Str8 sub i 1 template) "%") (< (+ i 1) n) #f)
           ((fn (_ c) (if (if (str=? c "%") #t (str=? c "1")) (self (+ i 2) (Str8 append acc answer)) (self (+ i 1) (Str8 append acc "%"))))
            (Str8 sub (+ i 1) 1 template)))
         (#t (self (+ i 1) (Str8 append acc (Str8 sub i 1 template))))))
     0 "")))

; The first word of TEXT.
(def %first-word
  (fn (_ text) ((fn (_ ws) (if (null? ws) "" (first ws))) (List filter (fn (_ w) (< 0 (Str8 length w))) (Str8 split " " (Str8 trim text))))))

; The command prompt, as command-prompt asks: LABEL, or (NAME) for a
; TEMPLATE's first command, or : for none; INITIAL to edit; the answer
; run, put in the template.
(def %command-prompt!
  (fn (_ label initial template)
    (%ask-for!
      (match
        ((not (null? label)) (Str8 append (%format label) " "))
        ((null? template) ":")
        (#t (Str8 append "(" (%first-word template) ") ")))
      (if (null? initial) "" (%format initial))
      (fn (_ answer)
        (%remember! answer)
        (%run-text! (if (null? template) answer (%fill template answer))))
      #t)))

; --- key tables ---------------------------------------------------------

; The key tables, (TABLE . BINDINGS), each binding (KEY REPEAT COMMANDS),
; REPEAT whether it was bound with -r, COMMANDS as command-parse reads
; them; the server's, as its options are.
(def %tables ())

; KEY's binding in TABLE, or nil.
(def %bound
  (fn (_ table key)
    ((fn (_ t) (if (null? t) () (List find (fn (_ b) (str=? (first b) key)) (rest t))))
     (List find (fn (_ t) (str=? (first t) table)) %tables))))

; TABLE's bindings made BINDINGS.
(def %table!
  (fn (_ table bindings)
    (set! %tables
      (pair (pair table bindings) (List filter (fn (_ t) (not (str=? (first t) table))) %tables)))))

; KEY in TABLE bound to COMMANDS, repeating or not, or unbound for nil.
(def %bind!
  (fn (_ table key repeat commands)
    ((fn (_ t)
       (%table! table
         ((fn (_ others) (if (null? commands) others (List append others (list (list key repeat commands)))))
          (List filter (fn (_ b) (not (str=? (first b) key))) (if (null? t) () (rest t))))))
     (List find (fn (_ t) (str=? (first t) table)) %tables))))

; tmux's bindings of the keys x-tmux has.
(def %defaults
  (Str8 join "\n"
    (list "bind C-b send-prefix" "bind C-o rotate-window" "bind Space next-layout" "bind '\"' split-window"
      "bind % split-window -h" "bind & confirm-before -p \"kill-window #W? (y/n)\" kill-window"
      "bind , command-prompt -I \"#W\" { rename-window -- \"%%\" }"
      "bind 0 select-window -t :=0" "bind 1 select-window -t :=1" "bind 2 select-window -t :=2"
      "bind 3 select-window -t :=3" "bind 4 select-window -t :=4" "bind 5 select-window -t :=5"
      "bind 6 select-window -t :=6" "bind 7 select-window -t :=7" "bind 8 select-window -t :=8"
      "bind 9 select-window -t :=9" "bind : command-prompt" "bind \; last-pane" "bind [ copy-mode"
      "bind ] paste-buffer -p" "bind c new-window" "bind d detach-client" "bind l last-window"
      "bind n next-window" "bind o select-pane -t :.+" "bind p previous-window" "bind q display-panes"
      "bind x confirm-before -p \"kill-pane #P? (y/n)\" kill-pane" "bind z resize-pane -Z"
      "bind \\{ swap-pane -U" "bind \\} swap-pane -D" "bind M-1 select-layout even-horizontal"
      "bind M-2 select-layout even-vertical" "bind M-3 select-layout main-horizontal"
      "bind M-4 select-layout main-vertical" "bind M-5 select-layout tiled"
      "bind M-6 select-layout main-horizontal-mirrored" "bind M-7 select-layout main-vertical-mirrored"
      "bind M-o rotate-window -D" "bind PPage copy-mode -u"
      "bind -r Up select-pane -U" "bind -r Down select-pane -D" "bind -r Left select-pane -L"
      "bind -r Right select-pane -R" "bind -r M-Up resize-pane -U 5" "bind -r M-Down resize-pane -D 5"
      "bind -r M-Left resize-pane -L 5" "bind -r M-Right resize-pane -R 5" "bind -r C-Up resize-pane -U"
      "bind -r C-Down resize-pane -D" "bind -r C-Left resize-pane -L" "bind -r C-Right resize-pane -R")))

; --- options --------------------------------------------------------------

; The options x-tmux has: (NAME KIND DEFAULT LOW HIGH), KIND key, number
; (DEFAULT LOW and HIGH numbers), choice (LOW the choices), string or
; style.  A choice of off and on without a value is turned over.
(def %window-format "#I:#W#{?window_flags,#{window_flags}, }")
(def %option-specs
  (list (list "display-panes-time" (lit number) 1000 1 2147483647)
    (list "display-time" (lit number) 750 0 2147483647)
    (list "history-limit" (lit number) 2000 0 2147483647)
    (list "message-style" (lit style) "bg=yellow,fg=black" () ())
    (list "mode-keys" (lit choice) "emacs" (lit ("emacs" "vi")) ())
    (list "prefix" (lit key) "C-b" () ())
    (list "repeat-time" (lit number) 500 0 2000000)
    (list "status" (lit choice) "on" (lit ("off" "on")) ())
    (list "status-interval" (lit number) 15 0 2147483647)
    (list "status-justify" (lit choice) "left" (lit ("left" "centre" "right" "absolute-centre")) ())
    (list "status-left" (lit string) "[#{session_name}] " () ())
    (list "status-left-length" (lit number) 10 0 32767)
    (list "status-left-style" (lit style) "default" () ())
    (list "status-right" (lit string)
      "#{?window_bigger,[#{window_offset_x}#,#{window_offset_y}] ,}\"#{=21:pane_title}\" %H:%M %d-%b-%y" () ())
    (list "status-right-length" (lit number) 40 0 32767)
    (list "status-right-style" (lit style) "default" () ())
    (list "status-style" (lit style) "bg=green,fg=black" () ())
    (list "window-status-current-format" (lit string) %window-format () ())
    (list "window-status-current-style" (lit style) "underscore" () ())
    (list "window-status-format" (lit string) %window-format () ())
    (list "window-status-last-style" (lit style) "default" () ())
    (list "window-status-separator" (lit string) " " () ())
    (list "window-status-style" (lit style) "default" () ())))

; The options' values, (NAME . VALUE).
(def %options ())
(def %option (fn (_ name) (rest (List find (fn (_ o) (str=? (first o) name)) %options))))

; Every option and key at its default; mode-keys vi when VISUAL or EDITOR
; is vi's, as tmux decides.
(def %defaults!
  (fn (_)
    (set! %options (List map (fn (_ s) (pair (first s) (List ref 2 s))) %option-specs))
    (%set-option! "mode-keys" (if (copy-vi?) "vi" "emacs"))
    (set! %tables ())
    (List for-each (fn (_ c) (%run! (rest c))) (List ref 1 (command-read %defaults)))))

; NAME set to VALUE, as set-option sets it: nil, or tmux's message.  The
; panes are placed again when the status line comes or goes.
(def %set-option!
  (fn (_ name value)
    (def spec (List find (fn (_ s) (str=? (first s) name)) %option-specs))
    (def kind (if (null? spec) () (List ref 1 spec)))
    (def put!
      (fn (_ v)
        (set! %options (List map (fn (_ o) (if (str=? (first o) name) (pair name v) o)) %options))
        (unless (null? %current) (if (str=? name "status") (%redraw!) (%draw-status)))
        ()))
    (match
      ((null? spec) (Str8 append "invalid option: " name))
      ((if (null? value) (eq? kind (lit choice)) #f)
        (if (equal? (List ref 3 spec) (lit ("off" "on"))) (put! (if (str=? (%option name) "on") "off" "on"))
          "empty value"))
      ((null? value) "empty value")
      ((eq? kind (lit string)) (put! value))
      ((eq? kind (lit number))
        ((fn (_ k)
           (match
             ((null? k) (Str8 append "value is invalid: " value))
             ((< k (List ref 3 spec)) (Str8 append "value is too small: " value))
             ((< (List ref 4 spec) k) (Str8 append "value is too large: " value))
             (#t (put! k))))
         (%signed value)))
      ((eq? kind (lit choice))
        (if (null? (List find (fn (_ c) (str=? c value)) (List ref 3 spec))) (Str8 append "unknown value: " value)
          (do (when (str=? name "mode-keys") (set! %vi (str=? value "vi"))) (put! value))))
      ((eq? kind (lit key)) ((fn (_ k) (if (null? k) (Str8 append "bad key: " value) (put! k))) (key-name value)))
      (#t (if (null? (%style-on %plain value %plain)) (Str8 append "invalid style: " value) (put! value))))))

; --- styles -------------------------------------------------------------------

; A style as SGR draws it: (FG BG ATTRIBUTES), FG and BG SGR's parameters
; for a colour, ATTRIBUTES the parameters of those it has, in order.  The
; terminal's own is plain.
(def %plain (lit ("39" "49" ())))
(def %attributes
  (lit (("bold" . "1") ("bright" . "1") ("dim" . "2") ("italics" . "3") ("underscore" . "4") ("blink" . "5")
        ("reverse" . "7") ("hidden" . "8") ("strikethrough" . "9"))))
(def %attribute-order (lit ("1" "2" "3" "4" "5" "7" "8" "9")))
(def %sgr
  (fn (_ s) (Str8 append "0" (Str8 join "" (List map (fn (_ a) (Str8 append ";" a)) (List ref 2 s))) ";" (first s) ";" (List ref 1 s))))

; STATE with STYLE laid over it, as tmux lays one: fg= and bg= a colour's
; name, bright name, colourN or #RRGGBB, or default for BASE's; an
; attribute added, noATTRIBUTE taken away, none every one taken away;
; default BASE again.  The parts go by commas or spaces; nil for a style
; that does not read.  fill=, align=, list, range and the like draw
; nothing here and are passed over.
(def %style-on
  (fn (_ state style base)
    (def names (lit ("black" "red" "green" "yellow" "blue" "magenta" "cyan" "white")))
    (def at (fn (self xs k c) (match ((null? xs) ()) ((str=? (first xs) c) k) (#t (self (rest xs) (+ k 1) c)))))
    (def hex (fn (_ s) (guard (e ()) ((prim-ref (lit convert) (lit to)) s (Type named INTEGER) 16))))
    ; colour C as SGR's parameter, FROM 30 for the foreground, 40 the
    ; background, OWN BASE's
    (def colour
      (fn (_ c from own)
        (match
          ((str=? c "default") own)
          ((not (null? (at names 0 c))) (%num (+ from (at names 0 c))))
          ((if (%prefix? "bright" c) (not (null? (at names 0 (%less "bright" c)))) #f)
            (%num (+ from 60 (at names 0 (%less "bright" c)))))
          ((if (%prefix? "colour" c) #t (%prefix? "color" c))
            ((fn (_ k) (if (if (null? k) #t (< 255 k)) () (Str8 append (%num (+ from 8)) ";5;" (%num k))))
             (%count (%less "color" (%less "colour" c)))))
          ((if (%prefix? "#" c) (= (Str8 length c) 7) #f)
            ((fn (_ r g b)
               (if (if (null? r) #t (if (null? g) #t (null? b))) ()
                 (Str8 append (%num (+ from 8)) ";2;" (%num r) ";" (%num g) ";" (%num b))))
             (hex (Str8 sub 1 2 c)) (hex (Str8 sub 3 2 c)) (hex (Str8 sub 5 2 c))))
          (#t ()))))
    (def with
      (fn (_ attrs a keep)
        (List filter (fn (_ x) (if (str=? x a) keep (not (null? (List find (fn (_ y) (str=? y x)) attrs)))))
          %attribute-order)))
    (def passed (lit ("fill=" "align=" "list" "nolist" "range" "norange" "push-default" "pop-default" "width=")))
    ((fn (self parts st)
       (if (null? parts) st
         ((fn (_ p)
            (def attr (List find (fn (_ a) (str=? (first a) p)) %attributes))
            (def off (if (%prefix? "no" p) (List find (fn (_ a) (str=? (first a) (%less "no" p))) %attributes) ()))
            (def next (fn (_ s) (if (null? s) () (self (rest parts) s))))
            (match
              ((= (Str8 length p) 0) (self (rest parts) st))
              ((%prefix? "fg=" p)
                (next ((fn (_ c) (if (null? c) () (list c (List ref 1 st) (List ref 2 st)))) (colour (%less "fg=" p) 30 (first base)))))
              ((%prefix? "bg=" p)
                (next ((fn (_ c) (if (null? c) () (list (first st) c (List ref 2 st)))) (colour (%less "bg=" p) 40 (List ref 1 base)))))
              ((str=? p "default") (self (rest parts) base))
              ((str=? p "none") (self (rest parts) (list (first st) (List ref 1 st) ())))
              ((not (null? attr)) (self (rest parts) (list (first st) (List ref 1 st) (with (List ref 2 st) (rest attr) #t))))
              ((not (null? off)) (self (rest parts) (list (first st) (List ref 1 st) (with (List ref 2 st) (rest off) #f))))
              ((not (null? (List find (fn (_ x) (%prefix? x p)) passed))) (self (rest parts) st))
              (#t ())))
          (first parts))))
     (List flat-map (fn (_ w) (Str8 split " " w)) (Str8 split "," style)) state)))

; The style of the option NAME laid over STATE, default its own base.
(def %option-style (fn (_ name state) ((fn (_ s) (if (null? s) state s)) (%style-on state (%option name) state))))
(def %prefix? (fn (_ p s) (if (<= (Str8 length p) (Str8 length s)) (str=? p (Str8 sub 0 (Str8 length p) s)) #f)))

; --- files of commands -----------------------------------------------------

; PATH with a leading ~ made the home directory.
(def %home
  (fn (_ path)
    (if (%prefix? "~/" path) (Str8 append ((fn (_ h) (if (null? h) "" h)) (Sys getenv "HOME")) (%less "~" path)) path)))

; The file at PATH read and its commands run, as source-file runs them:
; (KIND . MESSAGES), KIND missing for a file that is not there, parse for
; one that does not read, which runs none of it, or run for what its
; commands said, each (LINE . MESSAGE).
(def %source
  (fn (_ path)
    (def text (guard (e ()) (File read-all path)))
    (if (null? text) (list (lit missing) (Str8 append "no such file or directory: " path))
      ((fn (_ parsed)
         (if (not (first parsed)) (list (lit parse) (pair (List ref 1 parsed) (List ref 2 parsed)))
           (pair (lit run)
             (List fold
               (fn (_ acc c)
                 ((fn (_ wrong) (if (null? wrong) acc (List append acc (list (pair (first c) wrong)))))
                  (%run! (rest c))))
               () (List ref 1 parsed)))))
       (command-read text)))))

; What a file's commands said, as tmux shows them after its path: one a
; line, PATH:LINE: MESSAGE.
(def %where
  (fn (_ path said) (List map (fn (_ m) (Str8 append path ":" (%num (first m)) ": " (rest m))) said)))

; The errors of the files read as the server started, to show once the
; first session is made.
(def %config-errors ())

; FILES, each (PATH . QUIET), read and run as the server starts, as tmux
; reads its configuration: a quiet one that is not there is passed over.
(def %configure!
  (fn (_ files)
    (List for-each
      (fn (_ f)
        ((fn (_ r)
           (match
             ((eq? (first r) (lit missing)) (unless (rest f) (set! %config-errors (List append %config-errors (rest r)))))
             (#t (set! %config-errors (List append %config-errors (%where (first f) (rest r)))))))
         (%source (%home (first f)))))
      files)))

; LINES shown over the active pane in a view of them, as tmux shows a
; file's errors: copy mode on a screen holding them.
(def %show-lines!
  (fn (_ lines)
    (def p (%pane %active))
    (def rect (%pane-rect p))
    (def screen (vt-origin! (vt-make (List ref 2 rect) (List ref 3 rect)) (first rect) (List ref 1 rect)))
    (def text (Str8 join "\r\n" lines))
    (vt-feed! screen (%str->ptr text) (%byte-len text))
    (vt-feed! screen (%str->ptr (%esc "[H")) 3)
    (%set-pane! (%with-copy p (copy-enter screen #f %vi)))
    (%name-due! %window)
    (set! %touched #t)))

; --- running a command -------------------------------------------------

; COMMAND, (NAME FLAGS ARGS) as command-parse reads it, run as tmux runs
; it: nil, or the message of what went wrong, tmux's, which the status
; line shows with a capital.  Without a session only the commands of a
; file of them run.
(def %run!
  (fn (_ command)
    (def name (first command))
    (def flags (List ref 1 command))
    (def args (List ref 2 command))
    (def on? (fn (_ letter) (not (null? (command-flag flags letter)))))
    (def target (fn (_) ((fn (_ t) (if (eq? t #t) () t)) (command-flag flags "t"))))
    (def is? (fn (_ n) (str=? name n)))
    (def table (fn (_) (if (on? "n") "root" ((fn (_ t) (if (null? t) "prefix" t)) (command-flag flags "T")))))
    (def pane!
      (fn (_ then)
        ((fn (_ id) (if (null? id) (Str8 append "can't find pane: " (%bare (target))) (do (then id) ())))
         (%pane-target (target)))))
    (def window!
      (fn (_ then)
        ((fn (_ i) (if (null? i) (Str8 append "can't find window: " (%bare (target))) (do (then i) ())))
         (%window-target (target)))))
    (def done (fn (_ x) ()))
    (unless (null? %current) (%save-window!))
    (match
      ((eq? flags #f) (Str8 append "command " name ": not in x-tmux"))
      ((is? "bind-key")
        ((fn (_ key)
           (if (null? key) (Str8 append "unknown key: " (first args))
             (if (null? (rest args)) (done (%bind! (table) key (on? "r") ()))
               ((fn (_ cs) (if (first cs) (done (%bind! (table) key (on? "r") (List ref 1 cs))) (List ref 1 cs)))
                (command-list (rest args))))))
         (key-name (first args))))
      ((is? "unbind-key")
        (match
          ((on? "a") (done (%table! (table) ())))
          ((null? args) "command unbind-key: missing key")
          (#t ((fn (_ key) (if (null? key) (Str8 append "unknown key: " (first args)) (done (%bind! (table) key #f ()))))
               (key-name (first args))))))
      ((is? "set-option")
        ((fn (_ wrong) (if (if (on? "q") (%prefix? "invalid option" (if (null? wrong) "" wrong)) #f) () wrong))
         (if (on? "u")
           ((fn (_ s) (if (null? s) (Str8 append "invalid option: " (first args)) (%set-option! (first args) (List ref 2 s))))
            (List find (fn (_ s) (str=? (first s) (first args))) %option-specs))
           (%set-option! (first args) (if (null? (rest args)) () (first (rest args)))))))
      ((is? "source-file")
        ((fn (self paths)
           (if (null? paths) ()
             ((fn (_ r)
                (match
                  ((eq? (first r) (lit missing)) (if (on? "q") (self (rest paths)) (List ref 1 r)))
                  ((eq? (first r) (lit parse))
                    ((fn (_ lines)
                       (if (null? %current) (set! %config-errors (List append %config-errors lines)) (%show-lines! lines))
                       ())
                     (%where (%home (first paths)) (rest r))))
                  ((null? (rest r)) (self (rest paths)))
                  (#t (rest (List ref (- (List length (rest r)) 1) (rest r))))))
              (%source (%home (first paths))))))
         args))
      ((null? %current) "no current session")
      ((is? "command-prompt")
        (done (%command-prompt! (command-flag flags "p") (command-flag flags "I") (if (null? args) () (first args)))))
      ((is? "confirm-before")
        (done (%ask! (if (on? "p") (Str8 append (%format (command-flag flags "p")) " ")
                       (Str8 append "Confirm '" (first args) "'? (y/n) "))
                (fn (_) (%run-text! (first args))))))
      ((is? "split-window") (%split! (if (on? "h") (lit h) (lit v))))
      ((is? "new-window")
        (done (do (%new-window!) (unless (null? (command-flag flags "n")) (%rename! (command-flag flags "n"))))))
      ((is? "kill-pane") (pane! %remove!))
      ((is? "kill-window")
        (window! (fn (_ i) (List for-each %remove! (layout-panes (if (= i %window) %tree (List ref 1 (%window-at i))))))))
      ((is? "kill-session")
        (done (List for-each (fn (_ w) (List for-each %remove! (layout-panes (List ref 1 w)))) %windows)))
      ((is? "last-pane") (%last-pane!))
      ((is? "last-window") (if (null? %last) "no last window" (done (%select! (first %last)))))
      ((is? "next-window") (if (null? (%beside #f)) "no next window" (done (%step! #f ""))))
      ((is? "previous-window") (if (null? (%beside #t)) "no previous window" (done (%step! #t ""))))
      ((is? "select-window")
        (match
          ((on? "l") (if (null? %last) "no last window" (done (%select! (first %last)))))
          ((on? "n") (if (null? (%beside #f)) "no next window" (done (%step! #f ""))))
          ((on? "p") (if (null? (%beside #t)) "no previous window" (done (%step! #t ""))))
          (#t (window! %select!))))
      ((is? "select-pane")
        (match
          ((on? "l") (%last-pane!))
          ((not (null? (%direction flags))) (done (%beside! (%direction flags))))
          (#t (pane! (fn (_ id) (unless (= id %active) (do (%unzoom!) (%activate! id) (%name-due! %window))))))))
      ((is? "display-message")
        ((fn (_ given delay)
           (def ms (if (null? delay) () (%signed delay)))
           (match
             ((if (on? "F") (not (null? args)) #f) "only one of -F or argument must be given")
             ((if (null? delay) #f (null? ms)) "delay invalid")
             ((if (null? ms) #f (< ms 0)) "delay too small")
             (#t
               (pane!
                 (fn (_ id)
                   ((fn (_ text) (if (on? "p") (%show-lines! (list text)) (%show! text ms)))
                    (if (on? "l") given (%expand given id #t))))))))
         (match ((not (null? args)) (first args)) ((on? "F") (command-flag flags "F")) (#t %display-template))
         ((fn (_ d) (if (eq? d #t) () d)) (command-flag flags "d"))))
      ((is? "rename-window") (done (%rename! (first args))))
      ((is? "resize-pane")
        (if (on? "Z") (done (%zoom!))
          ((fn (_ n)
             (match
               ((null? n) "adjustment invalid")
               ((null? (%direction flags)) ())
               (#t (done (%resize! (%direction flags) n)))))
           (if (null? args) 1 (%count (first args))))))
      ((is? "swap-pane") (done (%swap! (on? "D"))))
      ((is? "rotate-window") (done (%rotate! (on? "D"))))
      ((is? "select-layout")
        (match
          ((on? "n") (done (%next-layout!)))
          ((on? "p") (done (%previous-layout!)))
          ((null? args) (done (%arrange! (%max 0 (List ref 9 (%window-at %window))))))
          (#t ((fn (self names k)
                 (match
                   ((null? names) (Str8 append "malformed layout header: " (first args)))
                   ((str=? (symbol->str (first names)) (first args)) (done (%arrange! k)))
                   (#t (self (rest names) (+ k 1)))))
               layout-names 0))))
      ((is? "next-layout") (done (%next-layout!)))
      ((is? "previous-layout") (done (%previous-layout!)))
      ((is? "display-panes") (done (%show-numbers!)))
      ((is? "copy-mode") (done (do (%copy! (if (on? "u") #t (on? "e"))) (when (on? "u") (%copy-do! (lit page-up))))))
      ((is? "paste-buffer")
        (done (unless (null? %buffers)
                (do (def fd (%pane-fd (%pane %active)))
                    (def send! (fn (_ t) (%send! fd (%str->ptr t) (%byte-len t))))
                    (def bracket (if (on? "p") (vt-bracketed? (%pane-screen (%pane %active))) #f))
                    (when bracket (send! (%esc "[200~")))
                    (send! (%typed (first %buffers)))
                    (when bracket (send! (%esc "[201~")))))))
      ((is? "send-prefix")
        (done ((fn (_ b) (%send! (%pane-fd (%pane %active)) (%str->ptr b) (%byte-len b))) (key-bytes (%option "prefix")))))
      ((is? "detach-client") (done (%detach! (Str8 append "[detached (from session " %name ")]"))))
      (#t ()))))

; LINE kept as the latest in the history, unless it is empty or the same
; as the latest.
(def %remember!
  (fn (_ line)
    (unless (if (= (%byte-len line) 0) #t (if (null? %history) #f (str=? line (first %history))))
      (set! %history
        ((fn (self xs k) (if (if (null? xs) #t (= k 0)) () (pair (first xs) (self (rest xs) (- k 1)))))
         (pair line %history) 100)))))

; TEXT, the cursor at AT, with its first word completed as tmux completes
; a command's name: the one name it starts, and a space; else what the
; names it starts share, or, when that adds nothing, the names offered.
; Answers (TEXT . AT).
(def %complete
  (fn (_ text at)
    (def word (Str8 sub 0 at text))
    (def names (command-matches word))
    (def shared
      (List fold
        (fn (_ acc name)
          ((fn (self k) (if (if (< k (Str8 length acc)) (str=? (Str8 sub k 1 acc) (Str8 sub k 1 name)) #f) (self (+ k 1)) (Str8 sub 0 k acc)))
           0))
        (if (null? names) "" (first names)) names))
    (def after (Str8 sub at (- (%byte-len text) at) text))
    (match
      ((if (null? names) #t (not (null? (List find (fn (_ c) (if (str=? c " ") #t (str=? c "\t"))) (%chars word))))) (pair text at))
      ((null? (rest names)) (pair (Str8 append (first names) " " after) (+ (Str8 length (first names)) 1)))
      ((< (Str8 length word) (Str8 length shared)) (pair (Str8 append shared after) (Str8 length shared)))
      (#t (do (set! %choices (Str8 join "" (List map (fn (_ name) (Str8 append " " name)) names))) (pair text at))))))
(def %chars (fn (_ s) ((fn (self i) (if (= i (Str8 length s)) () (pair (Str8 sub i 1 s) (self (+ i 1))))) 0)))

; The key at byte I of the N at P put to the text being typed, as tmux's
; prompt takes emacs's keys: answers the byte after it.  The command
; prompt takes Up and Down through its history and Tab to complete.
(def %edit!
  (fn (_ p i n)
    (def b (%pref p i 1))
    (def label (first %prompt))
    (def text (List ref 1 %prompt))
    (def at (List ref 2 %prompt))
    (def yes (List ref 3 %prompt))
    (def command (List ref 5 %prompt))
    (def len (%byte-len text))
    (set! %choices "")
    (def put! (fn (_ t a) (set! %prompt (list label t a yes #t command)) (%draw-status) (set! %touched #t)))
    (def stop! (fn (_) (set! %prompt ()) (%draw-status) (set! %touched #t)))
    (def recall!
      (fn (_ k)
        (when (if command (if (< k (List length %history)) (<= -1 k) #f) #f)
          (do (set! %back k)
              ((fn (_ t) (put! t (%byte-len t))) (if (= k -1) "" (List ref k %history)))))))
    (def move!
      (fn (_ k)
        (match
          ((eq? k (lit cancel)) (stop!))
          ((eq? k (lit left)) (put! text (%max 0 (- at 1))))
          ((eq? k (lit right)) (put! text (%min len (+ at 1))))
          ((eq? k (lit start-of-line)) (put! text 0))
          ((eq? k (lit end-of-line)) (put! text len))
          ((eq? k (lit up)) (recall! (+ %back 1)))
          ((eq? k (lit down)) (recall! (- %back 1)))
          (#t ()))))
    (if (= b 27)
      ((fn (_ k) (move! (first k)) (rest k)) (copy-key p i n #f))
      (do (match
            ((= b 13) (do (stop!) (yes text)))
            ((if command (= b 9) #f) ((fn (_ c) (put! (first c) (rest c))) (%complete text at)))
            ((if (= b 3) #t (= b 7)) (stop!))
            ((= b 1) (move! (lit start-of-line)))
            ((= b 5) (move! (lit end-of-line)))
            ((= b 2) (move! (lit left)))
            ((= b 6) (move! (lit right)))
            ((= b 21) (put! "" 0))
            ((= b 11) (put! (Str8 sub 0 at text) at))
            ((if (= b 127) #t (= b 8))
              (when (< 0 at) (put! (Str8 append (Str8 sub 0 (- at 1) text) (Str8 sub at (- len at) text)) (- at 1))))
            ((< 31 b) (put! (Str8 append (Str8 sub 0 at text) (%byte b) (Str8 sub at (- len at) text)) (+ at 1)))
            (#t ()))
          (+ i 1)))))

; --- drawing ------------------------------------------------------------

(def %goto (fn (_ row col) (%esc (Str8 append "[" (%num (+ row 1)) ";" (%num (+ col 1)) "H"))))

; The whole terminal drawn again: every window's layout fitted to the
; terminal and its panes placed, the terminal cleared, the shown window's
; screens and borders, the status line.
(def %redraw!
  (fn (_)
    (%save-window!)
    (set! %windows
      (List map (fn (_ w) (%laid w (layout-fit (List ref 1 w) %cols (%pane-rows)) (List ref 2 w))) %windows))
    (set! %tree (List ref 1 (%window-at %window)))
    (List for-each %place! %windows)
    (%out (%esc "[0m"))
    (%out (%esc "[2J"))
    (unless (%zoomed?) (List for-each %draw-border (layout-borders %tree 0 0)))
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

; The status line, tmux's: a question or a message in message-style, or
; status-left, the windows and status-right as their options draw them.
; A question's text scrolls so its cursor shows, the names Tab offers
; underlined after it.  With status off a question or a message shows
; over the panes' bottom row, which is drawn again once it goes.
(def %overlaid #f)
(def %draw-status
  (fn (_)
    (def say (%sgr (%option-style "message-style" %plain)))
    (def bottom (fn (_ s) (%out (Str8 append (%goto (- %rows 1) 0) s (%esc "[0m")))))
    (match
      ((not (null? %prompt))
        (do (def label ((fn (_ l) (Str8 sub 0 (%min %cols (Str8 length l)) l)) (first %prompt)))
            (def text (List ref 1 %prompt))
            (def from (%scrolled))
            (def shown (Str8 sub from (%min (- (%byte-len text) from) (%max 0 (- %cols (Str8 length label)))) text))
            (def room (%max 0 (- %cols (+ (Str8 length label) (Str8 length shown)))))
            (def choices (Str8 sub 0 (%min room (Str8 length %choices)) %choices))
            (set! %overlaid (not (%status?)))
            (bottom (Str8 append (%esc (Str8 append "[" say "m")) label shown (%esc "[4m") choices (%esc "[24m")
                      (Str8 pad-right (- room (Str8 length choices)) #\space "")))))
      ((not (null? %message))
        (do (set! %overlaid (not (%status?)))
            (bottom (Str8 append (%esc (Str8 append "[" say "m")) (%fit %message)))))
      ((%status?) (bottom (%emit (%status-cells))))
      (%overlaid (do (set! %overlaid #f) (List for-each (fn (_ id) (%touch-pane! (%pane id))) (%shown)))))))

; Whether the status line shows, and the rows the panes have.
(def %status? (fn (_) (str=? (%option "status") "on")))
(def %pane-rows (fn (_) (if (%status?) (- %rows 1) %rows)))

; Pane P's screen, or its copy, to be drawn whole.
(def %touch-pane!
  (fn (_ p) (if (null? (%pane-copy p)) (vt-touch! (%pane-screen p)) (copy-touch! (%pane-copy p)))))

; TEXT cut or padded to the terminal's width.
(def %fit
  (fn (_ text)
    (if (< %cols (Str8 length text)) (Str8 sub 0 %cols text) (Str8 pad-right %cols #\space text))))

; --- the status line's parts ------------------------------------------------

; A part of the status line is a list of cells, each (SGR . CHARACTER).
; TEXT's characters in STATE's style, each #[STYLE] in it laid over the
; style, its default BASE.
(def %cells
  (fn (_ text state base)
    (def n (%byte-len text))
    (def at (fn (_ i) (if (< i n) (%pref (%str->ptr text) i 1) 0)))
    (def close (fn (self i) (match ((<= n i) -1) ((= (at i) 93) i) (#t (self (+ i 1))))))
    ((fn (self i st acc)
       (match
         ((<= n i) (List reverse acc))
         ((if (= (at i) 35) (= (at (+ i 1)) 91) #f)
           ((fn (_ j)
              (if (< j 0) (List reverse acc)
                (self (+ j 1) ((fn (_ s) (if (null? s) st s)) (%style-on st (Str8 sub (+ i 2) (- j (+ i 2)) text) base)) acc)))
            (close (+ i 2))))
         (#t
           ((fn (_ k) (self (+ i k) st (pair (pair (%sgr st) (Str8 sub i k text)) acc)))
            ((fn (_ b) (%min (- n i) (match ((< b 192) 1) ((< b 224) 2) ((< b 240) 3) (#t 4)))) (at i))))))
     0 state ())))
(def %blank (fn (_ k sgr) (if (< k 1) () (pair (pair sgr " ") (%blank (- k 1) sgr)))))
(def %take (fn (_ cells k) (if (if (null? cells) #t (< k 1)) () (pair (first cells) (%take (rest cells) (- k 1))))))
(def %drop (fn (_ cells k) (if (if (null? cells) #t (< k 1)) cells (%drop (rest cells) (- k 1)))))

; CELLS as the terminal draws them, each run's SGR before it.
(def %emit
  (fn (_ cells)
    ((fn (self cs sgr acc)
       (if (null? cs) (Str8 join "" (List reverse acc))
         (self (rest cs) (first (first cs))
           (pair (rest (first cs))
             (if (str=? (first (first cs)) sgr) acc (pair (%esc (Str8 append "[" (first (first cs)) "m")) acc))))))
     cells "" ())))

; What a format's names are for window W and pane ID: the session's, the
; window's, the pane's, the client's and the machine's, and an option's
; value by its name.
(def %host "") (def %host-short "")
(def %look
  (fn (_ w id)
    (def p (%pane id))
    (def rect (%pane-rect p))
    (def last? (if (null? %last) #f (= (first w) (first %last))))
    (def yes (fn (_ b) (if b "1" "0")))
    (def flags
      (fn (_)
        (Str8 append (match ((= (first w) %window) "*") (last? "-") (#t "")) (if (List ref 7 w) "Z" ""))))
    (def option
      (fn (_ name)
        ((fn (_ spec)
           (match
             ((null? spec) ())
             ((eq? (List ref 1 spec) (lit number)) (%num (%option name)))
             ((eq? (List ref 1 spec) (lit key)) ())
             (#t (%option name))))
         (List find (fn (_ s) (str=? (first s) name)) %option-specs))))
    (fn (_ name)
      (match
        ((str=? name "session_name") %name)
        ((str=? name "session_windows") (%num (List length %windows)))
        ((str=? name "session_attached") (yes (not (null? %client))))
        ((str=? name "session_created") (%num %created))
        ((str=? name "window_index") (%num (first w)))
        ((str=? name "window_name") (List ref 3 w))
        ((str=? name "window_flags") (flags))
        ((str=? name "window_active") (yes (= (first w) %window)))
        ((str=? name "window_last_flag") (yes last?))
        ((str=? name "window_zoomed_flag") (yes (List ref 7 w)))
        ((str=? name "window_panes") (%num (List length (layout-panes (List ref 1 w)))))
        ((str=? name "window_width") (%num %cols))
        ((str=? name "window_height") (%num (%pane-rows)))
        ((str=? name "window_bigger") "0")
        ((str=? name "window_offset_x") "0")
        ((str=? name "window_offset_y") "0")
        ((str=? name "pane_id") (Str8 append "%" (%num id)))
        ((str=? name "pane_index") (%num (%number id)))
        ((str=? name "pane_title") %host)
        ((str=? name "pane_current_command") ((fn (_ c) (if (null? c) "" c)) (%program (%pane-fd p))))
        ((str=? name "pane_pid") (%num (%pane-pid p)))
        ((str=? name "pane_width") (%num (List ref 3 rect)))
        ((str=? name "pane_height") (%num (List ref 2 rect)))
        ((str=? name "pane_active") (yes (= id (List ref 2 w))))
        ((str=? name "pane_in_mode") (yes (not (null? (%pane-copy p)))))
        ((str=? name "client_width") (%num %cols))
        ((str=? name "client_height") (%num %rows))
        ((str=? name "client_prefix") (yes %prefix))
        ((str=? name "host") %host)
        ((str=? name "host_short") %host-short)
        ((str=? name "pid") (%num (Sys getpid)))
        (#t (option name))))))

; TEXT expanded for the shown window and pane ID, the time written in it
; first when TIME, as tmux writes it.
(def %expand
  (fn (_ text id time)
    (format-expand (if time (format-time text (Date local (Sys now))) text) (%look (%window-at %window) id))))
(def %format (fn (_ text) (%expand text %active #f)))

; The status line's cells: status-left, the windows, status-right, laid
; out as tmux lays them for status-justify, the windows cut about the
; shown one, < and > where they are cut, when there is no room for all.
(def %status-cells
  (fn (_)
    (%save-window!)
    (def base (%option-style "status-style" %plain))
    (def sgr (%sgr base))
    (def now (Date local (Sys now)))
    (def expand (fn (_ name w) (format-expand (format-time (%option name) now) (%look w (List ref 2 w)))))
    (def side
      (fn (_ name)
        ((fn (_ st) (%take (%cells (expand name (%window-at %window)) st st) (%option (Str8 append name "-length"))))
         (%option-style (Str8 append name "-style") base))))
    (def style-of
      (fn (_ w)
        (def current (%style-on base (%option "window-status-current-style") base))
        (match
          ((= (first w) %window)
            (if (if (null? current) #t (str=? (%option "window-status-current-style") "default"))
              (%option-style "window-status-style" base) current))
          ((if (null? %last) #f (= (first w) (first %last)))
            (%option-style "window-status-last-style" (%option-style "window-status-style" base)))
          (#t (%option-style "window-status-style" base)))))
    (def entry
      (fn (_ w)
        ((fn (_ st)
           (%cells (expand (if (= (first w) %window) "window-status-current-format" "window-status-format") w) st st))
         (style-of w))))
    (def separator (%cells (%option "window-status-separator") base base))
    ; the windows' cells, and where the shown one's start and end
    (def laid
      ((fn (self ws acc focus)
         (if (null? ws) (pair acc focus)
           ((fn (_ cells)
              (def start (List length acc))
              (def with (List append acc cells (if (null? (rest ws)) () separator)))
              (self (rest ws) with
                (if (= (first (first ws)) %window) (pair start (+ start (List length cells))) focus)))
            (entry (first ws)))))
       %windows () (pair 0 0)))
    (def left (side "status-left"))
    (def right (side "status-right"))
    (def cells (first laid))
    (def total (List length cells))
    ; the list cut first, then the right, then the left
    (def wl (%max 0 (%min total (- %cols (+ (List length left) (List length right))))))
    (def right-cut (%take right (%max 0 (- %cols (List length left)))))
    (def left-cut (%take left %cols))
    (def lw (List length left-cut))
    (def rw (List length right-cut))
    (def shown
      (if (<= total wl) cells
        ((fn (_ centre)
           (def from (%max 0 (%min (- centre (/ wl 2)) (- total wl))))
           (def l? (if (< 0 from) (< 1 wl) #f))
           (def from2 (if l? (+ from 1) from))
           (def w2 (if l? (- wl 1) wl))
           (def r? (if (< (+ from2 w2) total) (< 1 w2) #f))
           (def w3 (if r? (- w2 1) w2))
           (List append (if l? (list (pair sgr "<")) ()) (%take (%drop cells from2) w3) (if r? (list (pair sgr ">")) ())))
         ((fn (_ f) (+ (first f) (/ (- (rest f) (first f)) 2))) (rest laid)))))
    (def justify (%option "status-justify"))
    (def space (- %cols (+ lw rw wl)))
    (def at
      (match
        ((str=? justify "right") (+ lw space))
        ((str=? justify "centre") (+ lw (/ space 2)))
        ((str=? justify "absolute-centre") (%max lw (%min (+ lw space) (/ (- %cols wl) 2))))
        (#t lw)))
    (List append left-cut (%blank (- at lw) sgr) shown (%blank (- (+ lw space) at) sgr) right-cut)))

; Each changed row of the shown window's panes, a pane in copy mode its
; copy's with the position over its top right, the panes' numbers over
; them while they show, then the cursor where the active pane has it, or
; after the question on the status line.  The cursor is shown unless the
; active pane's program hid it, outside copy mode and the prompt.
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
        (when (if (null? c) #f (< 0 n)) (do (%draw-selection p c) (%draw-position p c))))
      (%shown))
    (when (< 0 %numbers) (%draw-numbers))
    (def p (%pane %active))
    (def c (if (null? (%pane-copy p)) (vt-cursor (%pane-screen p)) (copy-cursor (%pane-copy p))))
    (def rect (%pane-rect p))
    (%out (Str8 append (%esc "[0m")
            (if (null? %prompt)
              (%goto (+ (first rect) (first c)) (+ (List ref 1 rect) (%min (rest c) (- (List ref 3 rect) 1))))
              (%goto (- %rows 1) (%min (+ (%byte-len (first %prompt)) (- (List ref 2 %prompt) (%scrolled))) (- %cols 1))))
            (if (if (null? %prompt) (if (null? (%pane-copy p)) (not (vt-cursor-shown? (%pane-screen p))) #f) #f)
              ""
              (%esc "[?25h"))))))

; A copy mode's position, black on yellow at the right of its pane's top
; row.
(def %draw-position
  (fn (_ p c)
    (def rect (%pane-rect p))
    (def text (copy-position c))
    (%out (Str8 append (%goto (first rect) (+ (List ref 1 rect) (%max 0 (- (List ref 3 rect) (Str8 length text)))))
            (%esc "[0;30;43m") text (%esc "[0m")))))
; A copy mode's selection, black on yellow, tmux's mode-style.
(def %draw-selection
  (fn (_ p c)
    (def rect (%pane-rect p))
    (List for-each
      (fn (_ m)
        (%out (Str8 append (%goto (+ (first rect) (first m)) (+ (List ref 1 rect) (List ref 1 m)))
                (%esc "[0;30;43m") (List ref 2 m) (%esc "[0m"))))
      (copy-marks c))))

; --- keys ---------------------------------------------------------------

; Whether copy mode reads vi's keys, mode-keys.
(def %vi #f)

; The key at byte I of the N at P run as the prefix table binds it, after
; the prefix or while a binding repeats; answers the byte after it.  A key
; bound with -r lets another so bound run without the prefix for
; repeat-time after it.
(def %command!
  (fn (_ p i n)
    (set! %touched #t)
    (set! %repeat 0)
    (def k (key-read p i n))
    ((fn (_ b)
       (unless (null? b)
         (do (when (List ref 1 b) (set! %repeat (+ (%micros) (* 1000 (%option "repeat-time")))))
             (%run-all! (List ref 2 b)))))
     (%bound "prefix" (first k)))
    (rest k)))

; Pane ID's number in the shown window, tmux's pane index: its place in
; the window's pane order, from 0.
(def %number
  (fn (_ id)
    ((fn (self xs i) (if (= (first xs) id) i (self (rest xs) (+ i 1)))) (%order) 0)))

; The active pane into copy mode, EXIT as tmux/copy's copy-enter, unless
; it is in it.
(def %copy!
  (fn (_ exit)
    (def p (%pane %active))
    (when (null? (%pane-copy p))
      (do (%set-pane! (%with-copy p (copy-enter (%pane-screen p) exit %vi)))
          (%name-due! %window)))))
; The active pane's copy mode after CMD: what CMD copies kept, out of the
; mode, its screen drawn whole, when CMD ends it, and the view drawn whole
; while there is a selection to draw over it or there was one.
(def %copy-do!
  (fn (_ cmd)
    (def p (%pane %active))
    (set! %touched #t)
    (def was (%pane-copy p))
    (def text (copy-text was cmd))
    (unless (if (null? text) #t (= (%byte-len text) 0)) (%keep! text (eq? cmd (lit append))))
    (def c (copy-do was cmd))
    (%set-pane! (%with-copy p c))
    (if (null? c)
      (do (vt-touch! (%pane-screen p)) (%name-due! %window))
      (when (if (copy-selecting? was) #t (copy-selecting? c)) (copy-touch! c)))))

; --- paste buffers ------------------------------------------------------

(def %buffers ())    ; the paste buffers, the newest first
(def %buffer-limit 50)

; TEXT kept as the newest buffer, or, APPEND, added to its end; the oldest
; let go past the limit.
(def %keep!
  (fn (_ text append)
    (set! %buffers
      (if (if append (not (null? %buffers)) #f)
        (pair (Str8 append (first %buffers) text) (rest %buffers))
        ((fn (self xs n) (if (if (null? xs) #t (= n 0)) () (pair (first xs) (self (rest xs) (- n 1)))))
         (pair text %buffers) %buffer-limit)))))

; TEXT as a paste types it: each newline a carriage return.
(def %typed
  (fn (_ text)
    (def n (%byte-len text))
    (def s (%make-str (+ n 1)))
    (def p (%str->ptr s))
    (%call %c-memcpy p (%str->ptr text) n)
    (%pset p n 0 1)
    ((fn (self i) (when (< i n) (do (when (= (%pref p i 1) 10) (%pset p i 13 1)) (self (+ i 1))))) 0)
    s))

; --- input for the panes ------------------------------------------------

; Bytes for a pane's program that it has not taken: (FD BUF AT N) each,
; BUF's bytes AT to N-1 still to go, in the order they came.
(def %pending ())

; N bytes at P for the program on FD, after what it has not yet taken: as
; much as it takes now goes at once, and the rest waits for a poll to say
; it can take more.
(def %send!
  (fn (_ fd p n)
    (if (null? (List find (fn (_ w) (= (first w) fd)) %pending))
      ((fn (_ k) (when (< k n) (%wait! fd p k n))) (%put fd p n))
      (%wait! fd p 0 n))))
(def %wait!
  (fn (_ fd p from n)
    (def s (%make-str (+ (- n from) 1)))
    (%call %c-memcpy (%str->ptr s) (%int->ptr (+ (%ptr->int p) from)) (- n from))
    (set! %pending (List append %pending (list (list fd s 0 (- n from)))))))
; How many of N bytes at P the program on FD takes without waiting.
(def %put
  (fn (_ fd p n)
    (Sys nonblock! fd)
    (def k (%int (%call %c-write fd p n)))
    (Sys nonblock! fd #f)
    (%max k 0)))

; What waits written to each program READY says can take more, the oldest
; first.
(def %drain!
  (fn (_ ready)
    (set! %pending
      (List fold
        (fn (_ acc w)
          (def fd (first w))
          (if (if (null? (List find (fn (_ x) (= (first x) fd)) acc)) (%ready-for? ready fd (lit out)) #f)
            ((fn (_ at)
               (if (= at (List ref 3 w)) acc (List append acc (list (list fd (List ref 1 w) at (List ref 3 w))))))
             (+ (List ref 2 w)
                (%put fd (%int->ptr (+ (%ptr->int (%str->ptr (List ref 1 w))) (List ref 2 w))) (- (List ref 3 w) (List ref 2 w)))))
            (List append acc (list w))))
        () %pending))))

; N typed bytes at P: runs of keys to the active pane, or each a command
; while it is in copy mode; the prefix and its command handled where they
; fall, a key while a question is asked its answer, a key while the
; panes' numbers show taken by them, and a key the root table binds run.
; Keys clear a message.
(def %keys!
  (fn (_ p n)
    (unless (null? %message) (do (set! %message ()) (%draw-status) (set! %touched #t)))
    ((fn (self i from)
       (unless (if %done #t (null? %client))
         (do (def pane (%pane %active))
             (def fd (%pane-fd pane))
             (def flush! (fn (_) (when (< from i) (%send! fd (%int->ptr (+ (%ptr->int p) from)) (- i from)))))
             (if (= i n)
               (flush!)
               (do (def b (%pref p i 1))
                   (def k (key-read p i n))
                   (def key (first k))
                   (def on (fn (_ next) (self next next)))
                   (def repeats
                     (if (if (= %repeat 0) #t (< %repeat (%micros))) #f
                       ((fn (_ x) (if (null? x) #f (List ref 1 x))) (%bound "prefix" key))))
                   (unless repeats (set! %repeat 0))
                   (match
                     ((if (null? %prompt) #f (List ref 4 %prompt)) (on (%edit! p i n)))
                     ((not (null? %prompt))
                       (do (def yes (List ref 3 %prompt))
                           (set! %prompt ())
                           (%draw-status)
                           (set! %touched #t)
                           (when (= b 121) (yes))
                           (on (rest k))))
                     ((< 0 %numbers)
                       (do (%hide-numbers!)
                           (match
                             ((str=? key (%option "prefix")) (self i i))
                             ((if (< 47 b) (< b 58) #f) (do (%pick! (- b 48)) (on (+ i 1))))
                             (#t (on (rest k))))))
                     (%prefix (do (set! %prefix #f) (on (%command! p i n))))
                     (repeats (do (flush!) (on (%command! p i n))))
                     ((str=? key (%option "prefix")) (do (flush!) (set! %prefix #t) (on (rest k))))
                     ((not (null? (%pane-copy pane)))
                       ((fn (_ c) (%copy-do! (first c)) (on (rest c))) (copy-key p i n %vi)))
                     ((not (null? (%bound "root" key)))
                       (do (flush!) (set! %touched #t) (%run-all! (List ref 2 (%bound "root" key))) (on (rest k))))
                     ((%cursor-key? p i (rest k) (vt-cursor-keys? (%pane-screen pane)))
                       (do (flush!) (%send! fd (%str->ptr (%cursor-key p i (vt-cursor-keys? (%pane-screen pane)))) 3)
                           (on (rest k))))
                     (#t (self (rest k) from))))))))
     0 0)))

; Whether the key at I to NEXT is an arrow, Home or End as the pane's
; program does not read it: ESC [ X when it asked for ESC O X (?1h), or
; ESC O X when it did not.  %cursor-key spells it as it reads it.
(def %cursor-key?
  (fn (_ p i next ss3)
    (if (if (= (- next i) 3) (= (%pref p i 1) 27) #f)
      (if (not (null? (List find (fn (_ x) (= x (%pref p (+ i 2) 1))) (lit (65 66 67 68 72 70)))))
        (if ss3 (= (%pref p (+ i 1) 1) 91) (= (%pref p (+ i 1) 1) 79))
        #f)
      #f)))
(def %cursor-key
  (fn (_ p i ss3)
    (def s (%make-str 4))
    (%pset (%str->ptr s) 0 27 1)
    (%pset (%str->ptr s) 1 (if ss3 79 91) 1)
    (%pset (%str->ptr s) 2 (%pref p (+ i 2) 1) 1)
    (%pset (%str->ptr s) 3 0 1)
    s))

; --- pane output ----------------------------------------------------------

; A pane's output read and fed to its screen, to be rendered if its window
; is shown; its end, or its program's, removes it.
(def %output!
  (fn (_ p)
    (def at (%str->ptr %buf))
    (def got (%int (%call %c-read (%pane-fd p) at 4096)))
    (if (< 0 got)
      (do (%pset at got 0 1) (vt-feed! (%pane-screen p) (%ptr->int at) got) (%moved! got)
          (when (%holds? %tree (%pane-id p)) (set! %touched #t))
          (%name-due! (first (%window-of (%pane-id p)))))
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
          (set! %prompt ()) (set! %message ()) (set! %until 0) (set! %recent ()) (set! %repeat 0)
          (set! %numbers 0)
          (set! %sessions (List append %sessions (list s)))
          (set! %started #t)
          (%new-window!)
          (unless (null? %config-errors) (do (%show-lines! %config-errors) (set! %config-errors ())))
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
; Whether READY has FD ready for EVENT, or, for in, for anything but out:
; a hang-up or an error is read as an end.
(def %ready-for?
  (fn (_ ready fd event)
    ((fn (_ r)
       (if (null? r) #f
         (not (null? (List find (fn (_ e) (if (eq? event (lit out)) (eq? e event) (not (eq? e (lit out))))) (rest r))))))
     (List find (fn (_ r) (= (first r) fd)) ready))))
; What a pane's descriptor is polled for: out too while bytes wait for it.
(def %wants
  (fn (_ fd)
    (pair fd (if (null? (List find (fn (_ w) (= (first w) fd)) %pending)) (list (lit in)) (list (lit in) (lit out))))))

(def %serve
  (fn (self)
    (unless %quit
      (do (%stash!)
          (def fds
            (List append (list (pair %listen (list (lit in))))
              (List map (fn (_ c) (pair (proto-fd c) (list (lit in)))) %conns)
              (List map %wants
                (List fold (fn (_ acc s) (List append acc (List map %pane-fd (List ref 3 (first s))))) () %sessions))))
          ; a message or the panes' numbers to take down or a name to look at
          ; keeps the poll short
          (def saying
            (List find
              (fn (_ s)
                (def r (first s))
                (match
                  ((not (null? (List ref 16 r))) #t)
                  ((< 0 (List ref 20 r)) #t)
                  (#t (not (null? (List find (fn (_ w) (List ref 6 w)) (List ref 11 r)))))))
              %sessions))
          (def ready (Sys poll fds (if (null? saying) 1000 100)))
          (when (%ready? ready %listen)
            (set! %conns (List append %conns (list (proto-conn (Socket accept %listen))))))
          (List for-each (fn (_ c) (when (if (%live? c) (%ready? ready (proto-fd c)) #f) (%hear! c))) %conns)
          (%drain! ready)
          (def tick (%status-tick!))
          (List for-each
            (fn (_ s)
              (when (not (null? (List find (fn (_ x) (eq? x s)) %sessions)))
                (do (%enter! s)
                    (when (if tick (if %done #f (not (null? %client))) #f) (do (%draw-status) (set! %touched #t)))
                    (List for-each (fn (_ p) (unless %done (when (%ready-for? ready (%pane-fd p) (lit in)) (%output! p)))) %panes)
                    (when (if (null? %message) #f (< %until (%micros)))
                      (do (set! %message ()) (%draw-status) (set! %touched #t)))
                    (when (if (< 0 %numbers) (< %numbers (%micros)) #f) (%hide-numbers!))
                    (unless %done (List for-each (fn (_ w) (when (List ref 6 w) (%name-due! (first w)))) %windows))
                    (%settle!))))
            %sessions)
          (when (if %started (null? %sessions) #f) (set! %quit #t))
          (%moved! 1024)
          (self)))))

; The server, listening on FD at PATH until its last session ends, FILES
; read as it starts; the socket is removed as it leaves.
(def tmux-serve
  (fn (_ fd path files)
    (Sys signal 13 (Sys sig-ign))
    (Sys signal 1 (Sys sig-ign))
    (%resolve!)
    (vt-jit!)
    (%defaults!)
    (%configure! files)
    (set! %buf (%make-str 4097))
    (set! %tv (%make-str 16))
    (set! %obuf (%make-str (+ %ocap 1)))
    (set! %listen fd)
    (guard (e ()) (%serve))
    (List for-each (fn (_ s) (%enter! s) (%hang-up!)) %sessions)
    (guard (e ()) (File unlink path))
    0))

(provide tmux/server tmux-serve)
