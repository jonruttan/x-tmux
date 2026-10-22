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
(let ((ops (rest (Sys args (lit program)))))
  (unless (null? ops) (Sys exit (tmux-main ops))))
