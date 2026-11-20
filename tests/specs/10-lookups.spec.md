# Lookups
# @weight 1

A primitive, a type or a libc function is looked up once: as its file
loads, the value of a top-level def, or, for libc, in the file's
%resolve!, which a process runs as it starts -- a handle is a fact of
the process.  A lookup in a function a loop calls costs more than the
call it makes: a number written as text, through a prim-ref fetched for
each one, took a render from 0.6 ms to 4 ms.

Each source file under tmux/ is read as forms.  A def whose value is the
lookup itself is let be, as is the whole of a def of %resolve!; module,
import and provide forms name doors without looking them up.  Any other
prim-ref, ffi-dlopen, ffi-dlsym or (Type named ...) is named here, by
its file and the top-level name it is in.

## the source

### no lookup is made in a call

```tmux
(import x/core/doors tok-read-str)
(do (def lookup?
      (fn (self x)
        (match
          ((pair? x)
            (if (if (eq? (first x) (lit Type)) (if (pair? (rest x)) (eq? (first (rest x)) (lit named)) #f) #f) #t
              (if (self (first x)) #t (self (rest x)))))
          (#t (if (eq? x (lit prim-ref)) #t (if (eq? x (lit ffi-dlopen)) #t (eq? x (lit ffi-dlsym))))))))
    (def bound?
      (fn (_ v) (if (pair? v) (if (lookup? (list (first v))) #t (if (eq? (first v) (lit Type)) #t #f)) #f)))
    (def offences
      (fn (_ file f)
        (match
          ((not (pair? f)) ())
          ((not (null? (List find (fn (_ k) (eq? (first f) k)) (lit (module import provide doc))))) ())
          ((if (eq? (first f) (lit def)) (pair? (rest f)) #f)
            (match
              ((eq? (first (rest f)) (lit %resolve!)) ())
              ((if (pair? (rest (rest f))) (bound? (first (rest (rest f)))) #f) ())
              ((lookup? (rest (rest f))) (list (list file (first (rest f)))))
              (#t ())))
          ((lookup? f) (list (list file (first f))))
          (#t ()))))
    (def files (List filter (fn (_ n) (not (null? (Str8 index-of ".x" n)))) (File list-dir "tmux")))
    (write
      (List fold
        (fn (_ acc n)
          (def forms (tok-read-str (%base) (Str8 append (File read-all (Str8 append "tmux/" n)) " ")))
          (Heap collect)
          (List append acc (List fold (fn (_ a f) (List append a (offences n f))) () forms)))
        () files)))
```
---
    ()

### the check names a lookup in a call, and lets a def's value and %resolve! be

```tmux
(write
  (List fold (fn (_ a f) (List append a (offences "t.x" f))) ()
    (tok-read-str (%base)
      "(def %a (prim-ref (lit x) (lit y))) (def %b (fn (_ n) ((prim-ref (lit convert) (lit to)) n))) (def %resolve! (fn (_) (ffi-dlsym 0 \"w\"))) (def %c (fn (_) (Type named STRING))) (def %d (Type named STRING)) (import x/core/doors ffi-dlsym) ")))
```
---
    (("t.x" '%b) ("t.x" '%c))
