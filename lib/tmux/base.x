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
  vt-style vt-cursor-shown? vt-cursor-keys? vt-bracketed? vt-alternate
  vt-compiled? vt-feed-pure! vt-render-pure! vt-jit! vt-jit-make vt-exercise vt-agree vt-same?
  copy-enter copy-do copy-key copy-view copy-cursor copy-position copy-text copy-marks copy-selecting?
  copy-recall copy-search copy-incremental copy-matches copy-count-limit! copy-jump
  layout-new layout-rects layout-borders layout-split layout-remove layout-panes layout-resize layout-fit
  layout-size layout-beside layout-relabel layout-names layout-arrange
  command-parse command-read command-list command-words command-find command-matches command-flag
  key-read key-name key-bytes format-expand format-time format-true? capture-range capture-lines)

(import vt/vt vt-make vt-make-history vt-feed! vt-render! vt-out vt-cursor vt-size vt-origin! vt-touch!
  vt-carry vt-history vt-history-row vt-history-attrs vt-view
  vt-row vt-attrs vt-compiled? vt-feed-pure! vt-render-pure!
  vt-style vt-cursor-shown? vt-cursor-keys? vt-bracketed? vt-alternate)
(import vt/jit vt-jit! vt-jit-make vt-exercise vt-agree vt-same?)
(import tmux/copy copy-enter copy-do copy-key copy-view copy-cursor copy-position copy-text copy-marks
  copy-selecting? copy-recall copy-search copy-incremental copy-matches copy-count-limit! copy-jump)
(import tmux/layout layout-new layout-rects layout-borders layout-split layout-remove layout-panes
  layout-resize layout-fit layout-size layout-beside layout-relabel layout-names layout-arrange)
(import tmux/command command-parse command-read command-list command-words command-find command-matches
  command-flag)
(import tmux/keys key-read key-name key-bytes)
(import tmux/format format-expand format-time format-true?)
(import tmux/capture capture-range capture-lines)
(import tmux/cli tmux-main tmux-version)
