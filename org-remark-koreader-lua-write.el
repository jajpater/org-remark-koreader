;;; org-remark-koreader-lua-write.el --- Write back a KOReader sidecar  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 jajpater

;; Author: jajpater
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Turns a parsed sidecar back into the text KOReader itself would have
;; written.  The requirement is not "valid Lua" but "the same bytes": a
;; sidecar holds far more than annotations -- font size, margins, reading
;; position, and keys this package has never heard of -- and an import that
;; rewrites the file may not disturb any of it.
;;
;; Hence the yardstick this module is held to: read a real sidecar, write it
;; back, and the file is unchanged down to the byte.  Anything that fails
;; that is a defect here, not a detail.
;;
;; What KOReader's serializer does, as read off the files it produces:
;;
;;     -- <path>            one comment line naming the file
;;     return {             then one table
;;         ["key"] = value,     four spaces per level, always a trailing comma
;;         [1] = { ... },       list keys in brackets without quotes
;;         ["empty"] = {},      an empty table stays on its line
;;     }
;;
;; Keys come out in the order they were read, which is the order KOReader
;; wrote them; the reader keeps it.  Nothing here sorts, because sorting
;; would be a guess about a convention rather than a reproduction of it.
;;
;; Strings follow Lua's `%q': a quote and a backslash are escaped with a
;; backslash, a newline becomes a backslash followed by a real newline, and
;; any other control character becomes a decimal escape.
;;
;; Nothing in this file writes to a file.  It produces text; deciding where
;; that text goes, and whether it may go there at all, is a separate matter.

;;; Code:

(require 'cl-lib)
(require 'org-remark-koreader-lua)

(defconst org-remark-koreader-lua-write-indent "    "
  "One level of indentation, as KOReader writes it.")

;;;; Strings

(defconst org-remark-koreader-lua-write--escapes
  '((?\" . "\\\"")
    (?\\ . "\\\\"))
  "Characters that get a backslash of their own.")

(defun org-remark-koreader-lua-write--string (text)
  "Return TEXT as a Lua string literal, quotes included.

A control character becomes a decimal escape.  It is padded to three
digits when a digit follows it, because Lua reads up to three digits and
would otherwise swallow the next character into the escape."
  (let ((out (list "\""))
        (length (length text))
        (index 0))
    (while (< index length)
      (let* ((char (aref text index))
             (simple (assq char org-remark-koreader-lua-write--escapes))
             (next (and (< (1+ index) length) (aref text (1+ index)))))
        (push (cond
               (simple (cdr simple))
               ;; A newline is written as a line continuation, which is what
               ;; makes a multi-line note readable in the file.
               ((eq char ?\n) "\\\n")
               ((or (< char 32) (= char 127))
                (if (and next (>= next ?0) (<= next ?9))
                    (format "\\%03d" char)
                  (format "\\%d" char)))
               (t (char-to-string char)))
              out)
        (setq index (1+ index))))
    (push "\"" out)
    (apply #'concat (nreverse out))))

;;;; Values

(defun org-remark-koreader-lua-write--key (key)
  "Return KEY as it appears in front of the equals sign."
  (cond
   ((integerp key) (format "[%d]" key))
   ((stringp key) (format "[%s]" (org-remark-koreader-lua-write--string key)))
   (t (signal 'org-remark-koreader-lua-error
              (list (format "cannot write key %S" key))))))

(defun org-remark-koreader-lua-write--value (value level)
  "Return VALUE as Lua text, indented for LEVEL."
  (cond
   ((eq value t) "true")
   ((eq value :false) "false")
   ((eq value :nil) "nil")
   ((stringp value) (org-remark-koreader-lua-write--string value))
   ((numberp value) (format "%s" value))
   ((org-remark-koreader-lua-table-p value)
    (org-remark-koreader-lua-write--table value level))
   (t (signal 'org-remark-koreader-lua-error
              (list (format "cannot write value %S" value))))))

(defun org-remark-koreader-lua-write--table (table level)
  "Return TABLE as Lua text, its braces sitting at LEVEL."
  (let ((entries (org-remark-koreader-lua-table-entries table)))
    (if (null entries)
        "{}"
      (let ((inner (mapconcat
                    (lambda (entry)
                      (concat
                       (org-remark-koreader-lua-write--indentation (1+ level))
                       (org-remark-koreader-lua-write--key (car entry))
                       " = "
                       (org-remark-koreader-lua-write--value (cdr entry) (1+ level))
                       ",\n"))
                    entries "")))
        (concat "{\n" inner
                (org-remark-koreader-lua-write--indentation level) "}")))))

(defun org-remark-koreader-lua-write--indentation (level)
  "Return the indentation for LEVEL."
  (apply #'concat (make-list level org-remark-koreader-lua-write-indent)))

;;;; Whole files

(defconst org-remark-koreader-lua-write--preamble-rx
  "\\`\\(\\(?:[ \t]*--[^\n]*\n\\|[ \t]*\n\\)*\\)"
  "What may stand in front of `return': comment lines and blank lines.")

(defun org-remark-koreader-lua-preamble (text)
  "Return the text of TEXT that precedes its `return'.

KOReader opens a sidecar with a comment naming the file's own path.  It
carries no data this package uses, which is exactly why it has to be
kept: a rewrite that drops it changes a file it was asked to leave
alone."
  (if (string-match org-remark-koreader-lua-write--preamble-rx text)
      (match-string 1 text)
    ""))

(defun org-remark-koreader-lua-write-string (table &optional preamble)
  "Return the complete sidecar text for TABLE, with PREAMBLE in front."
  (concat (or preamble "")
          "return "
          (org-remark-koreader-lua-write--table table 0)
          "\n"))

(provide 'org-remark-koreader-lua-write)
;;; org-remark-koreader-lua-write.el ends here
