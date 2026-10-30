; # x-tmux -- a terminal multiplexer on x-lang
;
; ## tmux/base.x -- what the entry and the specs reach
;
; @author [Jon Ruttan](jonruttan@gmail.com)
; @copyright 2026 Jon Ruttan
; @license MIT No Attribution (MIT-0)

(provide tmux/base tmux-version tmux-main
  vt-make vt-make-history vt-feed! vt-render! vt-out vt-cursor vt-size vt-origin! vt-touch! vt-carry
  vt-row vt-attrs vt-history vt-history-row vt-history-attrs vt-view
  vt-compiled? vt-feed-pure! vt-render-pure! vt-jit! vt-jit-make vt-exercise vt-agree vt-same?
  copy-enter copy-do copy-key copy-view copy-cursor copy-position copy-text copy-marks copy-selecting?
  layout-new layout-rects layout-borders layout-split layout-remove layout-panes layout-resize layout-fit
  layout-size layout-beside layout-relabel layout-names layout-arrange
  command-parse command-read command-list command-find command-matches command-flag key-read key-name key-bytes)

(def tmux-version "0.1.0")

(import tmux/vt vt-make vt-make-history vt-feed! vt-render! vt-out vt-cursor vt-size vt-origin! vt-touch!
  vt-carry vt-history vt-history-row vt-history-attrs vt-view
  vt-row vt-attrs vt-compiled? vt-feed-pure! vt-render-pure!)
(import tmux/vt-jit vt-jit! vt-jit-make vt-exercise vt-agree vt-same?)
(import tmux/copy copy-enter copy-do copy-key copy-view copy-cursor copy-position copy-text copy-marks
  copy-selecting?)
(import tmux/layout layout-new layout-rects layout-borders layout-split layout-remove layout-panes
  layout-resize layout-fit layout-size layout-beside layout-relabel layout-names layout-arrange)
(import tmux/command command-parse command-read command-list command-find command-matches command-flag)
(import tmux/keys key-read key-name key-bytes)
(import tmux/cli tmux-main)
