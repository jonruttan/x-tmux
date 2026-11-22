; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/num.x -- numbers to and from text
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)
;
; The conversion and its types are fetched once, as the file loads: a
; fetch in the call costs more than the conversion, and a render writes
; numbers for every cursor move.

(provide tmux/num tmux-num tmux-int)

(def %convert (prim-ref (lit convert) (lit to)))
(def %STRING (Type named STRING))
(def %INTEGER (Type named INTEGER))

; N in decimal.
(def tmux-num (fn (_ n) (%convert n %STRING 10)))
; The integer TEXT spells in BASE; an error when it spells none.
(def tmux-int (fn (_ text base) (%convert text %INTEGER base)))
