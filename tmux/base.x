; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/base.x -- what the entry and the specs reach
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)

(provide tmux/base tmux-version tmux-main
  vt-make vt-feed! vt-render! vt-out vt-cursor vt-size vt-origin! vt-touch! vt-carry vt-row vt-attrs
  vt-compiled? vt-feed-pure! vt-render-pure! vt-jit! vt-jit-make vt-exercise vt-agree vt-same?
  layout-rects layout-borders layout-split layout-remove layout-panes)

(def tmux-version "0.1.0")

(import tmux/vt vt-make vt-feed! vt-render! vt-out vt-cursor vt-size vt-origin! vt-touch! vt-carry
  vt-row vt-attrs vt-compiled? vt-feed-pure! vt-render-pure!)
(import tmux/vt-jit vt-jit! vt-jit-make vt-exercise vt-agree vt-same?)
(import tmux/layout layout-rects layout-borders layout-split layout-remove layout-panes)
(import tmux/cli tmux-main)
