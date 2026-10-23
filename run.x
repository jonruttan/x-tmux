; # x-tmux -- a terminal multiplexer on x-lang
;
; ## run.x -- the entry
;
; @description `x -l tmux -- [COMMAND [ARGS]]`.
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
(import tmux/base)

(set! %lang-name "tmux")
(set! %repl-prompt "tmux> ")

; The operands: what follows the "--" after the launcher's own options.
; x-os's launcher passes the engine's own flags ahead of them, with no
; "--" between; they are left out, so `x -l tmux` there is a REPL too.
(def %engine-flag?
  (fn (_ a) (List any? (fn (_ f) (str=? a f)) (list "--batch" "--quiet" "--no-color"))))
(def %operands
  (fn (self l) (if (if (null? l) #f (%engine-flag? (first l))) (self (rest l)) l)))
(let ((ops (%operands (rest (Sys args (lit program))))))
  (unless (null? ops) (Sys exit (tmux-main ops))))
