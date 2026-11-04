# Formats
# @weight 1

tmux/format: a format expanded as tmux expands one, and the time
conversions its status line writes.  Each expansion is the one tmux 3.8's
display-message -p gives for the same format and values.

## values

### a name's value, a one-letter name's, and nothing for a name with none

```tmux
(def vars (list (pair "session_name" "abcdef") (pair "window_index" "0") (pair "window_name" "sh")
                (pair "window_flags" "*") (pair "path" "/usr/local/bin")))
(def look (fn (_ n) ((fn (_ e) (if (null? e) () (rest e))) (Assoc find n vars))))
(write (list (format-expand "[#{session_name}] #I:#W#F" look) (format-expand "[#{nosuch}]#X" look)))
```
---
    ("[abcdef] 0:sh*" "[]#X")

### ## #, and #} for # , and }, a #[style] kept, and a #(command) empty

```tmux
(def look (fn (_ n) ()))
(write (list (format-expand "a##b#,c#}d" look) (format-expand "#[fg=red]x#(true)y" look)
             (format-expand "a#" look) (format-expand "a#{session_name" look)))
```
---
    ("a#b,c}d" "#[fg=red]xy" "a" "a")

## conditions

### a name's value or a format's, true when not empty and not 0, and no else empty

```tmux
(def vars (list (pair "session_name" "abcdef") (pair "window_flags" "") (pair "zero" "0")))
(def look (fn (_ n) ((fn (_ e) (if (null? e) () (rest e))) (Assoc find n vars))))
(write (List map (fn (_ f) (format-expand f look))
            (list "#{?#{==:a,a},yes,no}" "#{?nosuch,yes,no}" "#{?session_name,yes}|" "#{?zero,yes,no}"
                  "#I:#W#{?window_flags,#{window_flags}, }|")))
```
---
    ("yes" "no" "yes|" "no" ": |")

### a comparison 1 or 0, strings in order, || and && joining

```tmux
(def look (fn (_ n) ()))
(write (format-expand "#{==:a,a} #{!=:a,b} #{<:2,10} #{>:2,10} #{<=:a,a} #{||:0,} #{&&:1,x} #{||:,}" look))
```
---
    "1 1 0 1 1 0 1 0"

## modifiers

### a value's first characters, its last, all of a short one, and a format's

```tmux
(def look (fn (_ n) (if (str=? n "session_name") "abcdef" ())))
(write (format-expand "#{=3:session_name}|#{=-3:session_name}|#{=9:session_name}|#{=2:#{session_name}}|#{=2:abc}" look))
```
---
    "abc|def|abcdef|ab|"

### a path's last part and the rest, and a literal

```tmux
(def look (fn (_ n) (if (str=? n "path") "/usr/local/bin" ())))
(write (format-expand "#{b:path}|#{d:path}|#{d:nosuch}#{b:nosuch}|#{l:#{x}}" look))
```
---
    "bin|/usr/local||#{x}"

## time

### the status line's conversions, others as they are

```tmux
(import x/sys/date)
(write (format-time "%H:%M %d-%b-%y|%a %A %B %e %j|%I%p %T %D %F|%% %q" (Date from-unix 1234567890)))
```
---
    "23:31 13-Feb-09|Fri Friday February 13 044|11PM 23:31:30 02/13/09 2009-02-13|% %q"
