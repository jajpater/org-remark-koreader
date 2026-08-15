;;; org-remark-koreader-lua.el --- Restricted reader for KOReader sidecars  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 jajpater

;; Author: jajpater
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Reads the subset of Lua data that KOReader writes into
;; `metadata.<extension>.lua'.
;;
;; The sidecar is never executed: no `load', no external interpreter, no shell
;; call.  The grammar below follows what KOReader's serializer actually
;; produces — tables, strings, numbers, booleans — and not the Lua language.
;; Anything outside that is rejected with a message naming the invariant that
;; was violated.
;;
;; Skipping silently is the most dangerous behaviour a reader can show here.
;; A string may contain a backslash followed by a real newline; a reader that
;; looks for fields line by line misses those and produces an incomplete
;; annotation without failing.  This reader therefore parses character by
;; character and fails loudly.
;;
;; Value translation into Elisp:
;;
;;     Lua string   → string
;;     Lua number   → number
;;     true         → t
;;     false        → :false
;;     nil          → :nil
;;     Lua table    → `org-remark-koreader-lua-table', order preserved
;;
;; `false' and `nil' get symbols of their own so they cannot be confused with
;; a missing key; test presence with `org-remark-koreader-lua-has-key-p'.

;;; Code:

(require 'cl-lib)

(defconst org-remark-koreader-lua-target-version
  "KOReader v2026.07 (1e2fa5f1239028ab4b37acae833cdc86a71e5258)"
  "The KOReader version this reader was written against.
Named in error messages, so that a deviating file can be traced back to
a version difference rather than to a mystery.")

(define-error 'org-remark-koreader-lua-error
  "Invalid KOReader sidecar")

;;;; Limits
;;
;; "Do not execute" rules out code execution, not memory exhaustion.  A
;; damaged or hostile file must not be able to hang Emacs.

(defgroup org-remark-koreader nil
  "KOReader annotations through org-remark."
  :group 'org-remark
  :prefix "org-remark-koreader-")

(defcustom org-remark-koreader-lua-max-file-size (* 8 1024 1024)
  "Maximum size in bytes of a sidecar that will be read."
  :type 'natnum)

(defcustom org-remark-koreader-lua-max-depth 32
  "Maximum nesting depth of tables.
The observed sidecars do not go beyond four."
  :type 'natnum)

(defcustom org-remark-koreader-lua-max-entries 200000
  "Maximum number of table fields in one sidecar."
  :type 'natnum)

(defcustom org-remark-koreader-lua-max-string-length (* 1 1024 1024)
  "Maximum length in characters of a single string value."
  :type 'natnum)

;;;; Error reporting

(defvar org-remark-koreader-lua--origin nil
  "Origin of the text being parsed, for error messages.")

(defun org-remark-koreader-lua--fail (format-string &rest args)
  "Signal a parse error from FORMAT-STRING and ARGS.
The message names origin, line number and target version, so that a
deviation can be traced rather than merely reported."
  (signal 'org-remark-koreader-lua-error
          (list (format "%sline %d: %s [expected: %s]"
                        (if org-remark-koreader-lua--origin
                            (format "%s: " org-remark-koreader-lua--origin)
                          "")
                        (line-number-at-pos)
                        (apply #'format format-string args)
                        org-remark-koreader-lua-target-version))))

(defun org-remark-koreader-lua--fail-structure (format-string &rest args)
  "Signal a structural error from FORMAT-STRING and ARGS.
For checks on an already parsed table, where a line number no longer
means anything."
  (signal 'org-remark-koreader-lua-error
          (list (format "%s [expected: %s]"
                        (apply #'format format-string args)
                        org-remark-koreader-lua-target-version))))

;;;; Table representation

(cl-defstruct (org-remark-koreader-lua-table
               (:constructor org-remark-koreader-lua--table-create)
               (:copier nil))
  "A Lua table that keeps the order in which it was written.
ENTRIES is an alist of (KEY . VALUE); KEY is a string or an integer."
  entries)

(defun org-remark-koreader-lua-get (table key &optional default)
  "Return the value of KEY in TABLE, or DEFAULT when KEY is missing."
  (let ((cell (assoc key (org-remark-koreader-lua-table-entries table))))
    (if cell (cdr cell) default)))

(defun org-remark-koreader-lua-has-key-p (table key)
  "Return non-nil when TABLE contains the key KEY.
Distinguishes an absent key from a key whose value is `false' or `nil' —
exactly the distinction on which the kind of an annotation rests."
  (and (assoc key (org-remark-koreader-lua-table-entries table)) t))

(defun org-remark-koreader-lua-keys (table)
  "Return the keys of TABLE in the order they were written."
  (mapcar #'car (org-remark-koreader-lua-table-entries table)))

(defun org-remark-koreader-lua-array (table)
  "Return the values of TABLE as a list, ordered by numeric key.
Signals when the keys are not exactly 1 through N: a gap in the
numbering means an element is missing, and that must not pass as a
shorter list."
  (let* ((entries (org-remark-koreader-lua-table-entries table))
         (keys (mapcar #'car entries)))
    (unless (cl-every #'integerp keys)
      (org-remark-koreader-lua--fail-structure
       "table is not a list: it has non-numeric keys"))
    (let ((sorted (sort (copy-sequence keys) #'<)))
      (unless (equal sorted (number-sequence 1 (length keys)))
        (org-remark-koreader-lua--fail-structure
         "list keys are not 1..%d but %S" (length keys) sorted)))
    (mapcar (lambda (n) (org-remark-koreader-lua-get table n))
            (number-sequence 1 (length keys)))))

;;;; Parser state

(defvar org-remark-koreader-lua--entries 0
  "Number of table fields parsed so far.")

;;;; Lexical helpers

(defun org-remark-koreader-lua--skip-blanks ()
  "Skip whitespace and `--' comment lines.
A block comment is refused: KOReader's serializer uses that form to
mark values that are not data."
  (skip-chars-forward " \t\n\r\f")
  (while (looking-at-p "--")
    (when (looking-at-p "--\\[")
      (org-remark-koreader-lua--fail
       "block comment found; that marks data which is not serialisable"))
    (forward-line 1)
    (skip-chars-forward " \t\n\r\f")))

(defun org-remark-koreader-lua--expect (char what)
  "Expect CHAR at point and move past it.
WHAT describes the context in the error message."
  (unless (eq (char-after) char)
    (org-remark-koreader-lua--fail
     "`%c' expected %s, but found %s"
     char what
     (if (eobp) "end of file" (format "`%c'" (char-after)))))
  (forward-char 1))

;;;; Strings

(defconst org-remark-koreader-lua--simple-escapes
  '((?\" . "\"") (?\\ . "\\") (?' . "'")
    (?n . "\n") (?t . "\t") (?r . "\r")
    (?a . "\a") (?b . "\b") (?f . "\f") (?v . "\v"))
  "Escapes that yield one fixed character.")

(defun org-remark-koreader-lua--parse-string ()
  "Parse a string literal; point sits on the opening quote."
  (forward-char 1)
  (let ((parts nil)
        (length 0))
    (catch 'done
      (while t
        ;; Take everything up to the next quote or backslash in one go.
        ;; Newlines are simply part of that: inside an escape they carry
        ;; meaning.
        (let ((start (point)))
          (skip-chars-forward "^\"\\\\")
          (when (> (point) start)
            (push (buffer-substring-no-properties start (point)) parts)
            (cl-incf length (- (point) start))))
        (when (> length org-remark-koreader-lua-max-string-length)
          (org-remark-koreader-lua--fail
           "string value longer than %d characters"
           org-remark-koreader-lua-max-string-length))
        (cond
         ((eobp)
          (org-remark-koreader-lua--fail "unterminated string"))
         ((eq (char-after) ?\")
          (forward-char 1)
          (throw 'done nil))
         (t
          (forward-char 1)              ; the backslash
          (push (org-remark-koreader-lua--parse-escape) parts)
          (cl-incf length)))))
    (apply #'concat (nreverse parts))))

(defun org-remark-koreader-lua--parse-escape ()
  "Parse one escape; point sits on the character after the backslash."
  (when (eobp)
    (org-remark-koreader-lua--fail "backslash at end of file"))
  (let* ((char (char-after))
         (simple (assq char org-remark-koreader-lua--simple-escapes)))
    (cond
     ;; Line continuation: in Lua a backslash followed by a real newline
     ;; stands for a newline inside the string.  This is the form that
     ;; multi-line KOReader notes use.
     ((eq char ?\n)
      (forward-char 1)
      "\n")
     ((eq char ?\r)
      (forward-char 1)
      (when (eq (char-after) ?\n) (forward-char 1))
      "\n")
     (simple
      (forward-char 1)
      (cdr simple))
     ((and (>= char ?0) (<= char ?9))
      (looking-at "[0-9]\\{1,3\\}")
      (let ((code (string-to-number (match-string 0))))
        (goto-char (match-end 0))
        (cond
         ((> code 255)
          (org-remark-koreader-lua--fail
           "byte escape \\%d falls outside 0-255" code))
         ;; Above 127 the escape would be one byte of a multibyte character.
         ;; Assembling that correctly calls for byte-level reassembly of the
         ;; whole string; the serializer produces this form only for control
         ;; characters, so refuse rather than guess.
         ((> code 127)
          (org-remark-koreader-lua--fail
           "byte escape \\%d above 127 is not supported" code))
         (t (char-to-string code)))))
     (t
      (org-remark-koreader-lua--fail "unknown escape `\\%c'" char)))))

;;;; Values

(defconst org-remark-koreader-lua--number-rx
  "-?\\(?:[0-9]+\\(?:\\.[0-9]*\\)?\\|\\.[0-9]+\\)\\(?:[eE][-+]?[0-9]+\\)?"
  "What `tostring' produces for a finite number.")

(defun org-remark-koreader-lua--parse-value (depth)
  "Parse one value at DEPTH levels of nesting."
  (org-remark-koreader-lua--skip-blanks)
  (when (eobp)
    (org-remark-koreader-lua--fail "value expected, end of file"))
  (let ((char (char-after)))
    (cond
     ((eq char ?\") (org-remark-koreader-lua--parse-string))
     ((eq char ?\{) (org-remark-koreader-lua--parse-table depth))
     ((looking-at "[A-Za-z_][A-Za-z0-9_]*")
      (let ((word (match-string 0)))
        (goto-char (match-end 0))
        (pcase word
          ("true" t)
          ("false" :false)
          ("nil" :nil)
          ((or "inf" "nan")
           (org-remark-koreader-lua--fail "non-finite number `%s'" word))
          (_
           (org-remark-koreader-lua--fail
            "`%s' is not allowed as a value; only strings, numbers, booleans, nil and tables"
            word)))))
     ((or (eq char ?-) (eq char ?.) (and (>= char ?0) (<= char ?9)))
      (unless (looking-at org-remark-koreader-lua--number-rx)
        (org-remark-koreader-lua--fail
         "unrecognisable number; non-finite values such as inf and nan are not data"))
      (let ((text (match-string 0)))
        (goto-char (match-end 0))
        (when (looking-at-p "[A-Za-z0-9_.]")
          (org-remark-koreader-lua--fail "unrecognisable number `%s...'" text))
        (string-to-number text)))
     (t
      (org-remark-koreader-lua--fail "unexpected character `%c'" char)))))

(defun org-remark-koreader-lua--parse-key ()
  "Parse a key; point sits on the opening bracket."
  (forward-char 1)
  (org-remark-koreader-lua--skip-blanks)
  (prog1 (cond
          ((eq (char-after) ?\")
           (org-remark-koreader-lua--parse-string))
          ((looking-at "[0-9]+")
           (prog1 (string-to-number (match-string 0))
             (goto-char (match-end 0))))
          (t
           (org-remark-koreader-lua--fail
            "key must be [\"name\"] or [number]")))
    (org-remark-koreader-lua--skip-blanks)
    (org-remark-koreader-lua--expect ?\] "after a key")))

(defun org-remark-koreader-lua--parse-table (depth)
  "Parse a table at DEPTH levels of nesting."
  (when (> depth org-remark-koreader-lua-max-depth)
    (org-remark-koreader-lua--fail
     "nesting deeper than %d" org-remark-koreader-lua-max-depth))
  (forward-char 1)                      ; {
  (let ((entries nil))
    (catch 'done
      (while t
        (org-remark-koreader-lua--skip-blanks)
        (when (eobp)
          (org-remark-koreader-lua--fail "unterminated table"))
        (cond
         ((eq (char-after) ?\})
          (forward-char 1)
          (throw 'done nil))
         ((eq (char-after) ?\[)
          (let ((key (org-remark-koreader-lua--parse-key)))
            (org-remark-koreader-lua--skip-blanks)
            (org-remark-koreader-lua--expect ?= "after a key")
            (let ((value (org-remark-koreader-lua--parse-value (1+ depth))))
              (cl-incf org-remark-koreader-lua--entries)
              (when (> org-remark-koreader-lua--entries
                       org-remark-koreader-lua-max-entries)
                (org-remark-koreader-lua--fail
                 "more than %d table fields" org-remark-koreader-lua-max-entries))
              (when (assoc key entries)
                (org-remark-koreader-lua--fail
                 "key %S occurs twice in the same table" key))
              (push (cons key value) entries))
            (org-remark-koreader-lua--skip-blanks)
            (cond
             ((eq (char-after) ?,) (forward-char 1))
             ((eq (char-after) ?\}) nil)
             (t (org-remark-koreader-lua--fail
                 "`,' or `}' expected after a field")))))
         (t
          (org-remark-koreader-lua--fail
           "field expected of the form [\"name\"] = value")))))
    (org-remark-koreader-lua--table-create :entries (nreverse entries))))

;;;; Public entry points

(defun org-remark-koreader-lua-read-string (string &optional origin)
  "Parse STRING as a KOReader sidecar and return the table.
ORIGIN is named in error messages."
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (let ((org-remark-koreader-lua--origin origin)
          (org-remark-koreader-lua--entries 0)
          (case-fold-search nil))
      (org-remark-koreader-lua--skip-blanks)
      (unless (looking-at "return\\b")
        (org-remark-koreader-lua--fail
         "file must begin with `return'"))
      (goto-char (match-end 0))
      (let ((value (org-remark-koreader-lua--parse-value 0)))
        (unless (org-remark-koreader-lua-table-p value)
          (org-remark-koreader-lua--fail "`return' must yield a table"))
        (org-remark-koreader-lua--skip-blanks)
        (unless (eobp)
          (org-remark-koreader-lua--fail
           "unexpected text after the table; a sidecar holds one `return'"))
        value))))

(defun org-remark-koreader-lua-read-file (path)
  "Read and parse the sidecar PATH.
The file is read, never executed."
  (unless (file-regular-p path)
    (signal 'org-remark-koreader-lua-error
            (list (format "%s: not a regular file" path))))
  (let ((size (file-attribute-size (file-attributes path))))
    (when (> size org-remark-koreader-lua-max-file-size)
      (signal 'org-remark-koreader-lua-error
              (list (format "%s: %d bytes exceeds the limit of %d"
                            path size
                            org-remark-koreader-lua-max-file-size)))))
  (org-remark-koreader-lua-read-string
   (with-temp-buffer
     (let ((coding-system-for-read 'utf-8-unix))
       (insert-file-contents path))
     (buffer-string))
   (file-name-nondirectory path)))

(provide 'org-remark-koreader-lua)
;;; org-remark-koreader-lua.el ends here
