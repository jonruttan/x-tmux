; # x-tmux -- a terminal multiplexer on x-lang
;
; ## lib/tmux/run.x -- the entry
;
; @description `x -l tmux -- [OPTIONS] [COMMAND [ARGS]]`; with no command, a new session.
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
(module tmux/run)
(import tmux/base)

(set! %lang-name "tmux")
(set! %repl-prompt "tmux> ")

; The flags x-os's launcher passes ahead of the operands, the engine's
; and not the program's.
(def %engine-flag?
  (fn (_ a) (List any? (fn (_ f) (str=? a f)) (list "--batch" "--quiet" "--no-color"))))
(def %operands
  (fn (self l) (if (if (null? l) #f (%engine-flag? (first l))) (self (rest l)) l)))

; The operands: what follows the "--" after the launcher's own options.
; With none, a new session, as tmux's.
(def main
  (fn (_)
    (Sys exit (tmux-main (%operands (rest (Sys args (lit program))))))))

(provide tmux/run main)
