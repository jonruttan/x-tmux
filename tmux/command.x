; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/command.x -- a command line, read as tmux reads one
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; A line is commands separated by `;` or a newline, each words: separated
; by spaces, quoted with '...' as they are or "..." with backslash
; escapes, a quote left open running to the end, and a backslash outside
; them taking the next character as it is, so `\;` is a semicolon and not
; a separator, and a backslash before a newline joining the lines.  A `#`
; starting a word starts a comment to the line's end, and `{` as a word
; takes the text to its `}` as one word, newlines and all.  A command's
; first word is its name, tmux's or an alias, or a prefix of only one
; name; then flags, each letter one, a letter that takes a value taking
; the rest of its word or the next; then its arguments.  Text that does
; not read is refused whole, with tmux's message, and none of it runs.
; A command of tmux's that x-tmux does not run reads, its words its
; arguments, and is refused as it runs.  The messages are tmux's, which
; the status line shows with a capital.

(module tmux/command)

; tmux 3.8's commands, in its order: a prefix is looked for among these.
(def %names
  (lit ("attach-session" "bind-key" "break-pane" "capture-pane" "choose-buffer" "choose-client" "choose-tree"
        "clear-history" "clear-prompt-history" "clock-mode" "command-prompt" "confirm-before" "copy-mode"
        "customize-mode" "delete-buffer" "detach-client" "display-menu" "display-message" "display-popup"
        "display-panes" "find-window" "has-session" "if-shell" "join-pane" "kill-pane" "kill-server"
        "kill-session" "kill-window" "last-pane" "last-window" "link-window" "list-buffers" "list-clients"
        "list-commands" "list-keys" "list-panes" "list-sessions" "list-windows" "load-buffer" "lock-client"
        "lock-server" "lock-session" "move-pane" "move-window" "new-pane" "new-session" "new-window"
        "next-layout" "next-window" "paste-buffer" "pipe-pane" "previous-layout" "previous-window"
        "refresh-client" "rename-session" "rename-window" "resize-pane" "resize-window" "respawn-pane"
        "respawn-window" "rotate-window" "run-shell" "save-buffer" "select-layout" "select-pane"
        "select-window" "send-keys" "send-prefix" "server-access" "set-buffer" "set-environment" "set-hook"
        "set-option" "set-window-option" "show-buffer" "show-environment" "show-hooks" "show-messages"
        "show-options" "show-prompt-history" "show-window-options" "source-file" "split-window"
        "start-server" "suspend-client" "swap-pane" "swap-window" "switch-client" "switch-mode" "unbind-key"
        "unlink-window" "wait-for")))

; tmux 3.8's aliases: (ALIAS . NAME).
(def %aliases
  (lit (("attach" . "attach-session") ("bind" . "bind-key") ("breakp" . "break-pane")
        ("capturep" . "capture-pane") ("clearhist" . "clear-history") ("clearphist" . "clear-prompt-history")
        ("confirm" . "confirm-before") ("deleteb" . "delete-buffer") ("detach" . "detach-client")
        ("menu" . "display-menu") ("display" . "display-message") ("popup" . "display-popup")
        ("displayp" . "display-panes") ("findw" . "find-window") ("has" . "has-session") ("if" . "if-shell")
        ("joinp" . "join-pane") ("killp" . "kill-pane") ("killw" . "kill-window") ("lastp" . "last-pane")
        ("last" . "last-window") ("linkw" . "link-window") ("lsb" . "list-buffers") ("lsc" . "list-clients")
        ("lscm" . "list-commands") ("lsk" . "list-keys") ("lsp" . "list-panes") ("ls" . "list-sessions")
        ("lsw" . "list-windows") ("loadb" . "load-buffer") ("lockc" . "lock-client") ("lock" . "lock-server")
        ("locks" . "lock-session") ("movep" . "move-pane") ("movew" . "move-window") ("newp" . "new-pane")
        ("new" . "new-session") ("neww" . "new-window") ("nextl" . "next-layout") ("next" . "next-window")
        ("pasteb" . "paste-buffer") ("pipep" . "pipe-pane") ("prevl" . "previous-layout")
        ("prev" . "previous-window") ("refresh" . "refresh-client") ("rename" . "rename-session")
        ("renamew" . "rename-window") ("resizep" . "resize-pane") ("resizew" . "resize-window")
        ("respawnp" . "respawn-pane") ("respawnw" . "respawn-window") ("rotatew" . "rotate-window")
        ("run" . "run-shell") ("saveb" . "save-buffer") ("selectl" . "select-layout")
        ("selectp" . "select-pane") ("selectw" . "select-window") ("send" . "send-keys")
        ("setb" . "set-buffer") ("setenv" . "set-environment") ("set" . "set-option")
        ("setw" . "set-window-option") ("showb" . "show-buffer") ("showenv" . "show-environment")
        ("showmsgs" . "show-messages") ("show" . "show-options") ("showphist" . "show-prompt-history")
        ("showw" . "show-window-options") ("source" . "source-file") ("splitw" . "split-window")
        ("start" . "start-server") ("suspendc" . "suspend-client") ("swapp" . "swap-pane")
        ("swapw" . "swap-window") ("switchc" . "switch-client") ("unbind" . "unbind-key")
        ("unlinkw" . "unlink-window") ("wait" . "wait-for"))))

; The commands x-tmux runs: (NAME FLAGS VALUED LEAST MOST), the letters
; of its flags, those of its flags that take a value, and how few and how
; many arguments it takes, -1 for no limit.
(def %commands
  (lit (("bind-key" "nr" "NT" 1 -1) ("command-prompt" "" "Ip" 0 1) ("confirm-before" "" "p" 1 1)
        ("copy-mode" "eu" "" 0 0) ("detach-client" "" "" 0 0) ("display-panes" "" "" 0 0)
        ("kill-pane" "" "t" 0 0) ("kill-session" "" "" 0 0) ("kill-window" "" "t" 0 0)
        ("last-pane" "" "" 0 0) ("last-window" "" "" 0 0) ("new-window" "" "n" 0 0)
        ("next-layout" "" "" 0 0) ("next-window" "" "" 0 0) ("paste-buffer" "p" "" 0 0)
        ("previous-layout" "" "" 0 0) ("previous-window" "" "" 0 0) ("rename-window" "" "" 1 1)
        ("resize-pane" "DLRUZ" "" 0 1) ("rotate-window" "DU" "" 0 0) ("select-layout" "np" "" 0 1)
        ("select-pane" "DLRUl" "t" 0 0) ("select-window" "lnp" "t" 0 0) ("send-prefix" "" "" 0 0)
        ("set-option" "gqsuw" "" 1 2) ("source-file" "q" "" 1 -1) ("split-window" "hv" "" 0 0)
        ("swap-pane" "DU" "" 0 0) ("unbind-key" "anq" "T" 0 1))))

(def %char (fn (_ s i) (Str8 sub i 1 s)))
(def %prefix? (fn (_ p s) (if (<= (Str8 length p) (Str8 length s)) (str=? p (Str8 sub 0 (Str8 length p) s)) #f)))
(def %has? (fn (_ letters c) (not (null? (List find (fn (_ x) (str=? x c)) (%letters letters))))))
(def %letters
  (fn (_ s) ((fn (self i) (if (= i (Str8 length s)) () (pair (%char s i) (self (+ i 1))))) 0)))

; --- words --------------------------------------------------------------

; TEXT as commands, each (LINE . WORDS), LINE where it starts, from 1:
; (#t COMMANDS), or (#f LINE MESSAGE) for a backslash that ends the text
; or a `{` that no `}` closes.
(def %words
  (fn (_ text)
    (def n (Str8 length text))
    (def end-word (fn (_ word words) (if (null? word) words (pair word words))))
    (def end-command (fn (_ at words done) (if (null? words) done (pair (pair at (List reverse words)) done))))
    (def add (fn (_ word s) (Str8 append (if (null? word) "" word) s)))
    ; at I on LINE: WORD the word so far, nil for none; WORDS this
    ; command's, the latest first, the command started on AT; DONE the
    ; commands before, the latest first
    ((fn (self i line at word words done)
       (def start (if (if (null? word) (null? words) #f) line at))
       (if (= i n)
         (list #t (List reverse (end-command at (end-word word words) done)))
         ((fn (_ c)
            (match
              ((if (str=? c " ") #t (str=? c "\t")) (self (+ i 1) line at () (end-word word words) done))
              ((str=? c "\n") (self (+ i 1) (+ line 1) at () () (end-command at (end-word word words) done)))
              ((str=? c ";") (self (+ i 1) line at () () (end-command at (end-word word words) done)))
              ((if (str=? c "#") (null? word) #f) (self (%line-end text i) line at word words done))
              ((str=? c "\\")
                (match
                  ((= (+ i 1) n) (list #f line "syntax error"))
                  ((str=? (%char text (+ i 1)) "\n") (self (+ i 2) (+ line 1) at word words done))
                  (#t (self (+ i 2) line start (add word (%char text (+ i 1))) words done))))
              ((if (str=? c "{") (null? word) #f)
                ((fn (_ b)
                   (if (null? b) (list #f (+ 1 (%newlines text 0 n)) "syntax error")
                     (self (first b) (+ line (%newlines text i (first b))) start (rest b) words done)))
                 (%block text (+ i 1))))
              ((if (str=? c "'") #t (str=? c "\""))
                ((fn (_ q) (self (first q) (+ line (%newlines text i (first q))) start (add word (rest q)) words done))
                 (%quoted text (+ i 1) c)))
              (#t (self (+ i 1) line start (add word c) words done))))
          (%char text i))))
     0 1 1 () () ())))

; The quoted text from I of TEXT to the quote Q that closes it, or to the
; end when none does: (NEXT . TEXT), NEXT the index after it.  Inside
; "...", a backslash takes the next character as it is.
(def %quoted
  (fn (_ line i q)
    (def n (Str8 length line))
    ((fn (self i text)
       (match
         ((= i n) (pair n text))
         ((str=? (%char line i) q) (pair (+ i 1) text))
         ((if (str=? q "\"") (if (str=? (%char line i) "\\") (< (+ i 1) n) #f) #f)
           (self (+ i 2) (Str8 append text (%char line (+ i 1)))))
         (#t (self (+ i 1) (Str8 append text (%char line i))))))
     i "")))

; The text from I of TEXT to the `}` that closes the `{` before it,
; quotes skipped and blocks inside counted: (NEXT . TEXT), or nil when
; none closes it.
(def %block
  (fn (_ text i)
    (def n (Str8 length text))
    ((fn (self j depth)
       (if (= j n) ()
         ((fn (_ c)
            (match
              ((if (str=? c "'") #t (str=? c "\"")) (self (first (%quoted text (+ j 1) c)) depth))
              ((str=? c "\\") (self (%min n (+ j 2)) depth))
              ((str=? c "{") (self (+ j 1) (+ depth 1)))
              ((str=? c "}") (if (= depth 0) (pair (+ j 1) (Str8 sub i (- j i) text)) (self (+ j 1) (- depth 1))))
              (#t (self (+ j 1) depth))))
          (%char text j))))
     i 0)))

; The index of the newline after I in TEXT, or its end.
(def %line-end
  (fn (_ text i)
    ((fn (self j) (if (if (< j (Str8 length text)) (not (str=? (%char text j) "\n")) #f) (self (+ j 1)) j)) i)))

; How many newlines TEXT holds from I up to J.
(def %newlines
  (fn (_ text i j)
    ((fn (self k acc) (if (< k j) (self (+ k 1) (if (str=? (%char text k) "\n") (+ acc 1) acc)) acc)) i 0)))
(def %min (fn (_ a b) (if (< a b) a b)))

; --- names --------------------------------------------------------------

; The tmux commands whose names start with WORD, in tmux's order.
(def command-matches (fn (_ word) (List filter (fn (_ name) (%prefix? word name)) %names)))

; The command WORD names, as tmux finds it: an alias, a whole name, or a
; prefix of only one name; (#t NAME) or (#f MESSAGE).
(def command-find
  (fn (_ word)
    (def alias (List find (fn (_ a) (str=? (first a) word)) %aliases))
    (def matches (command-matches word))
    (match
      ((not (null? alias)) (list #t (rest alias)))
      ((not (null? (List find (fn (_ x) (str=? x word)) %names))) (list #t word))
      ((null? matches) (list #f (Str8 append "unknown command: " word)))
      ((null? (rest matches)) (list #t (first matches)))
      (#t (list #f (Str8 append "ambiguous command: " word ", could be: " (Str8 join ", " matches)))))))

; --- commands -----------------------------------------------------------

; WORDS read as a command: (#t (NAME FLAGS ARGS)), FLAGS ((LETTER .
; VALUE) ...), VALUE #t for a flag that takes none, or (#f MESSAGE).
(def %command
  (fn (_ words)
    (def found (command-find (first words)))
    (def name (List ref 1 found))
    (def spec (if (first found) (List find (fn (_ c) (str=? (first c) name)) %commands) ()))
    (def say (fn (_ text) (list #f (Str8 append "command " name ": " text))))
    (match
      ((not (first found)) found)
      ((null? spec) (list #t (list name #f (rest words))))
      (#t
        ((fn (self ws flags)
           (match
             ((if (null? ws) #f (str=? (first ws) "--")) (%arguments spec name (List reverse flags) (rest ws)))
             ((if (null? ws) #t (if (< (Str8 length (first ws)) 2) #t (not (str=? (%char (first ws) 0) "-"))))
               (%arguments spec name (List reverse flags) ws))
             (#t
               ((fn (each letters flags-of)
                  (match
                    ((null? letters) (self (rest ws) flags-of))
                    ((%has? (List ref 1 spec) (first letters)) (each (rest letters) (pair (pair (first letters) #t) flags-of)))
                    ((%has? (List ref 2 spec) (first letters))
                      (do (def tail (Str8 join "" (rest letters)))
                          (match
                            ((< 0 (Str8 length tail)) (self (rest ws) (pair (pair (first letters) tail) flags-of)))
                            ((null? (rest ws)) (say (Str8 append "-" (first letters) " expects an argument")))
                            (#t (self (rest (rest ws)) (pair (pair (first letters) (first (rest ws))) flags-of))))))
                    (#t (say (Str8 append "unknown flag -" (first letters))))))
                (rest (%letters (first ws))) flags))))
         (rest words) ())))))

; NAME's arguments ARGS checked against SPEC's counts.
(def %arguments
  (fn (_ spec name flags args)
    (def n (List length args))
    (match
      ((< n (List ref 3 spec))
        (list #f (Str8 append "command " name ": too few arguments (need at least " (%str (List ref 3 spec)) ")")))
      ((if (< -1 (List ref 4 spec)) (< (List ref 4 spec) n) #f)
        (list #f (Str8 append "command " name ": too many arguments (need at most " (%str (List ref 4 spec)) ")")))
      (#t (list #t (list name flags args))))))

(def %str (fn (_ n) ((prim-ref (lit convert) (lit to)) n (Type named STRING) 10)))

; LINE read as tmux reads a command line: (#t ((NAME FLAGS ARGS) ...)),
; or (#f MESSAGE) for the first thing that does not read.  A command of
; tmux's that x-tmux does not run has #f for its flags.
(def command-parse
  (fn (_ line)
    ((fn (_ r) (if (first r) (list #t (List map rest (List ref 1 r))) (list #f (List ref 2 r))))
     (command-read line))))

; TEXT read as tmux reads a file of commands: (#t ((LINE NAME FLAGS ARGS)
; ...)), LINE where each starts, or (#f LINE MESSAGE) for the first thing
; that does not read.
(def command-read
  (fn (_ text)
    (def w (%words text))
    (if (not (first w)) w
      ((fn (self cs done)
         (if (null? cs) (list #t (List reverse done))
           ((fn (_ c) (if (first c) (self (rest cs) (pair (pair (first (first cs)) (List ref 1 c)) done)) (list #f (first (first cs)) (List ref 1 c))))
            (%command (rest (first cs))))))
       (List ref 1 w) ()))))

; ARGS, the words after a key bound to them, read as commands: one word
; read as a line, else the words themselves, a `;` word between commands.
(def command-list
  (fn (_ args)
    (if (null? (rest args)) (command-parse (first args))
      ((fn (self ws words done)
         (def finish
           (fn (_ done)
             ((fn (each cs acc)
                (if (null? cs) (list #t (List reverse acc))
                  ((fn (_ c) (if (first c) (each (rest cs) (pair (List ref 1 c) acc)) c)) (%command (first cs)))))
              (List reverse done) ())))
         (match
           ((null? ws) (finish (if (null? words) done (pair (List reverse words) done))))
           ((str=? (first ws) ";") (self (rest ws) () (if (null? words) done (pair (List reverse words) done))))
           (#t (self (rest ws) (pair (first ws) words) done))))
       args () ()))))

; The value of flag LETTER in FLAGS, #t for one that takes none, or nil
; when it was not given.
(def command-flag
  (fn (_ flags letter)
    ((fn (_ f) (if (null? f) () (rest f))) (List find (fn (_ f) (str=? (first f) letter)) flags))))

(provide tmux/command command-parse command-read command-list command-find command-matches command-flag)
