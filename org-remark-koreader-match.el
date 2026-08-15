;;; org-remark-koreader-match.el --- Locating annotations in the source  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 jajpater

;; Author: jajpater
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Determines where a KOReader annotation sits in the source buffer.
;;
;; KOReader stores rendered text: markup is gone, and a selection across block
;; boundaries has been run together.  The stored text is therefore not always
;; findable in the source file.  The XPointers predict when it is: if `pos0'
;; and `pos1' lie in the same text node, the text appears verbatim; if they
;; lie in different nodes, it never does.
;;
;; Classifying and resolving are two different things.  Classifying costs two
;; string comparisons.  Resolving to a buffer position needs a block structure
;; that matches the renderer's, and that is the expensive, unproven step.
;;
;; Narrowing is allowed only with hard bounds.  A candidate is ruled out
;; because it demonstrably cannot be right, never because another one looks
;; more likely.  If more than one survives, that is the outcome and the mark is
;; reported rather than placed: a wrongly placed overlay is worse than an
;; unresolved import.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'org-remark-koreader-model)
(require 'org-remark-koreader-dom)

;;;; Finding candidates

(defun org-remark-koreader-match--occurrences (text)
  "Return every verbatim occurrence of TEXT in the current buffer.
Each occurrence is a cons (BEGIN . END).  The search is case sensitive
and literal: the stored text is data, not a pattern."
  (when (and text (not (string-empty-p text)))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let ((hits nil)
              (case-fold-search nil))
          (while (search-forward text nil :noerror)
            (push (cons (match-beginning 0) (match-end 0)) hits)
            ;; Overlapping occurrences count too; step back one character
            ;; rather than jumping to the end of the hit.
            (goto-char (1+ (match-beginning 0))))
          (nreverse hits))))))

;;;; Markdown knowledge
;;
;; This is the only layer that knows anything about Markdown.

(defconst org-remark-koreader-match--heading-rx "^[ \t]*#\\{1,6\\}[ \t]+"
  "What begins an ATX heading in Markdown.")

(defun org-remark-koreader-match--chapter-region (chapter)
  "Return (BEGIN . END) of the section headed CHAPTER, or nil.

Nil when the heading is missing or occurs more than once: a section
that cannot be pointed at unambiguously cannot rule out candidates."
  (when (and chapter (not (string-empty-p chapter)))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (let ((case-fold-search nil)
              (headings nil))
          (while (re-search-forward
                  (concat org-remark-koreader-match--heading-rx
                          (regexp-quote chapter) "[ \t]*$")
                  nil :noerror)
            (push (cons (match-beginning 0) (line-end-position)) headings))
          (when (= (length headings) 1)
            (goto-char (cdr (car headings)))
            (cons (car (car headings))
                  (if (re-search-forward org-remark-koreader-match--heading-rx
                                         nil :noerror)
                      (match-beginning 0)
                    (point-max)))))))))

;;;; Narrowing

(defun org-remark-koreader-match--within (candidate lower upper)
  "Return non-nil when CANDIDATE falls between LOWER and UPPER.
LOWER and UPPER may be nil."
  (and (or (null lower) (>= (car candidate) lower))
       (or (null upper) (<= (cdr candidate) upper))))

(defun org-remark-koreader-match--bounds (marks index)
  "Return (LOWER . UPPER) for the mark at INDEX in MARKS.

The bounds come only from marks resolved as `exact'.  A bound taken
from a disambiguated or estimated mark would let a guess propagate as
though it were a fact.

The assumption underneath is that KOReader writes annotations in
document order.  That assumption is checked by
`org-remark-koreader-match-document-order-monotone-p'."
  (let ((lower nil)
        (upper nil))
    (cl-loop for i from (1- index) downto 0
             for mark = (nth i marks)
             when (eq (org-remark-koreader-mark-confidence mark) 'exact)
             do (setq lower (org-remark-koreader-mark-end mark))
             and return nil)
    (cl-loop for i from (1+ index) below (length marks)
             for mark = (nth i marks)
             when (eq (org-remark-koreader-mark-confidence mark) 'exact)
             do (setq upper (org-remark-koreader-mark-beg mark))
             and return nil)
    (cons lower upper)))

;;;; Projection
;;
;; The XPointers point at positions in the rendered DOM.  The reconstructed
;; DOM translates those back to the source file.  That is the only route for
;; marks running across text node boundaries, because there the stored text
;; appears nowhere verbatim in the source.
;;
;; The projection is never taken at its word.  It yields a range, and that
;; range must reproduce the stored text; only then does it count.  So `text'
;; remains the verification here too, exactly as on the text-search route.

(defun org-remark-koreader-match--align (rendered text)
  "Return (LEADING . TRAILING) when RENDERED and TEXT are the same text.

LEADING and TRAILING are the number of whitespace characters RENDERED
has in excess at its start and end.  KOReader keeps the raw selection
bounds in the offsets but trims the stored text; a selection that began
on a space therefore yields a range one character longer than the text.
Nil when the difference is not whitespace at the edges alone."
  (when (and rendered text)
    (if (equal rendered text)
        (cons 0 0)
      (let* ((lead (- (length rendered) (length (string-trim-left rendered))))
             (trail (- (length rendered) (length (string-trim-right rendered))))
             (core (substring rendered lead (- (length rendered) trail))))
        (when (equal core text)
          (cons lead trail))))))

(defun org-remark-koreader-match--project (mark dom)
  "Determine the source range of MARK using DOM, or nil.

Returns (BEGIN . END) only when the projected range yields the stored
text."
  (let* ((from (org-remark-koreader-parse-xpointer
                (org-remark-koreader-mark-pos0 mark)))
         (to (org-remark-koreader-parse-xpointer
              (org-remark-koreader-mark-pos1 mark)))
         (text (org-remark-koreader-mark-text mark)))
    (when (and from to text
               (org-remark-koreader-xpointer-offset from)
               (org-remark-koreader-xpointer-offset to))
      (let* ((path0 (org-remark-koreader-xpointer-path from))
             (path1 (org-remark-koreader-xpointer-path to))
             (offset0 (org-remark-koreader-xpointer-offset from))
             (offset1 (org-remark-koreader-xpointer-offset to))
             (rendered (org-remark-koreader-dom-range-text
                        dom path0 offset0 path1 offset1))
             (align (org-remark-koreader-match--align rendered text)))
        (when align
          (org-remark-koreader-dom-resolve-range
           dom path0 (+ offset0 (car align)) path1 (- offset1 (cdr align))))))))

;;;; The ladder

(defun org-remark-koreader-match--note-anomaly (mark format-string &rest args)
  "Add an observation to MARK from FORMAT-STRING and ARGS."
  (setf (org-remark-koreader-mark-anomalies mark)
        (append (org-remark-koreader-mark-anomalies mark)
                (list (apply #'format format-string args)))))

(defun org-remark-koreader-match--check-offset-span (mark)
  "Compare MARK's offset span with the length of its text.
When they differ, that does not prove which of the two is right; it is
recorded rather than silently resolved.

Only meaningful within one text node.  If the offsets lie in different
nodes they count from different starting points and their difference is
not a length.

In the plain-text tree a difference says nothing at all: there the
offsets count the source untouched while the text has been collapsed,
so two spaces in a row already produce a deviation.  Reporting it would
turn the rule into an exception."
  (let ((span (and (org-remark-koreader-same-node-p mark)
                   (not (org-remark-koreader-match--plain-pointer-p
                         (org-remark-koreader-mark-pos0 mark)))
                   (org-remark-koreader-offset-span mark)))
        (text (org-remark-koreader-mark-text mark)))
    (when (and span text (/= span (length text)))
      (org-remark-koreader-match--note-anomaly
       mark "offset span %d differs from %d characters of text"
       span (length text)))))

(defun org-remark-koreader-match--place (mark candidate confidence)
  "Put MARK at CANDIDATE with CONFIDENCE."
  (setf (org-remark-koreader-mark-beg mark) (car candidate)
        (org-remark-koreader-mark-end mark) (cdr candidate)
        (org-remark-koreader-mark-confidence mark) confidence))

(defun org-remark-koreader-match--verify (mark)
  "Check that the buffer text at MARK's position equals its text.
This closes every route: a position that does not give back its own
text is not a position."
  (let ((beg (org-remark-koreader-mark-beg mark))
        (end (org-remark-koreader-mark-end mark))
        (text (org-remark-koreader-mark-text mark)))
    (and beg end text
         (<= (point-min) beg)
         (<= end (point-max))
         (equal (buffer-substring-no-properties beg end) text))))

(defconst org-remark-koreader-match--plain-root "/FictionBook/"
  "Root of the tree KOReader builds for plain text.")

(defun org-remark-koreader-match--plain-pointer-p (pointer)
  "Return non-nil when POINTER lies in the plain-text tree."
  (and pointer
       (string-prefix-p org-remark-koreader-match--plain-root pointer)))

(defun org-remark-koreader-match-build-dom-for-pointers (pointers)
  "Build, in the current buffer, the tree belonging to POINTERS.

KOReader picks its renderer by file type, and then states in its own
XPointers which tree that produced: `/html/body' for Markdown,
`/FictionBook/body' for plain text.  That is a more reliable signal
than the file name, because it sits in the sidecar itself."
  (if (seq-some #'org-remark-koreader-match--plain-pointer-p pointers)
      (org-remark-koreader-dom-parse-plain)
    (org-remark-koreader-dom-parse)))

(defun org-remark-koreader-match-build-dom (marks)
  "Build, in the current buffer, the tree belonging to MARKS."
  (org-remark-koreader-match-build-dom-for-pointers
   (mapcan (lambda (mark)
             (list (org-remark-koreader-mark-pos0 mark)
                   (org-remark-koreader-mark-page mark)))
           marks)))

(defvar org-remark-koreader-match-families nil
  "Document families that know their own way to a source position.

An alist of (RECOGNISER . RESOLVER), both functions of one argument:
the list of marks.  RECOGNISER says whether this family recognises the
marks, RESOLVER places them and returns them.

This file knows only families that rest on a reconstructed tree.  A
family for which that does not hold — EPUB reads its text from a
rendering made by another program — registers here instead of being
built in here.")

(defun org-remark-koreader-match-resolve (marks)
  "Determine the position of every mark in MARKS in the current buffer.
Modifies the marks in place and returns them.

The order is deliberate: all the unambiguous cases first, the ambiguous
ones only afterwards.  Otherwise a narrowing would rest on bounds that
are not yet settled."
  (or (seq-some (lambda (family)
                  (when (funcall (car family) marks)
                    (funcall (cdr family) marks)))
                org-remark-koreader-match-families)
      (org-remark-koreader-match--resolve-with-dom
       marks (org-remark-koreader-match-build-dom marks))))

(defun org-remark-koreader-match--resolve-with-dom (marks dom)
  "Determine the position of MARKS using the reconstructed DOM."
  (dolist (mark marks)
    (org-remark-koreader-match--check-offset-span mark)
    (setf (org-remark-koreader-mark-confidence mark) 'unresolved
          (org-remark-koreader-mark-beg mark) nil
          (org-remark-koreader-mark-end mark) nil))
  ;; Round 1 — same text node, text unambiguous in the source.
  (dolist (mark marks)
    (when (org-remark-koreader-same-node-p mark)
      (let ((hits (org-remark-koreader-match--occurrences
                   (org-remark-koreader-mark-text mark))))
        (setf (org-remark-koreader-mark-candidates mark) hits)
        (when (= (length hits) 1)
          (org-remark-koreader-match--place mark (car hits) 'exact)
          (unless (org-remark-koreader-match--verify mark)
            (org-remark-koreader-match--place mark nil 'unresolved))))))
  ;; Round 2 — narrow the ambiguous cases with hard bounds.
  (let ((index -1))
    (dolist (mark marks)
      (cl-incf index)
      (when (and (eq (org-remark-koreader-mark-confidence mark) 'unresolved)
                 (> (length (org-remark-koreader-mark-candidates mark)) 1))
        (let* ((bounds (org-remark-koreader-match--bounds marks index))
               (chapter (org-remark-koreader-match--chapter-region
                         (org-remark-koreader-mark-chapter mark)))
               (projected (org-remark-koreader-match--project mark dom))
               (lower (car bounds))
               (upper (cdr bounds))
               (remaining
                (seq-filter
                 (lambda (candidate)
                   (and (org-remark-koreader-match--within candidate lower upper)
                        (or (null chapter)
                            (org-remark-koreader-match--within
                             candidate (car chapter) (cdr chapter)))
                        ;; The projection is an independent signal: it comes
                        ;; from the XPointers, not from the text.  If it points
                        ;; somewhere, the candidate has to be that somewhere.
                        (or (null projected)
                            (equal candidate projected))))
                 (org-remark-koreader-mark-candidates mark))))
          (if (= (length remaining) 1)
              (progn
                (org-remark-koreader-match--place mark (car remaining)
                                                  'disambiguated)
                (unless (org-remark-koreader-match--verify mark)
                  (org-remark-koreader-match--place mark nil 'unresolved)))
            (org-remark-koreader-match--note-anomaly
             mark "%d candidates left after narrowing from %d"
             (length remaining)
             (length (org-remark-koreader-mark-candidates mark))))))))
  ;; Round 3 — across text node boundaries.  Searching for the text
  ;; demonstrably solves nothing here, so only the projection can help, and
  ;; only when the projected range gives back the stored text.  If it cannot,
  ;; the mark stays unresolved; that is the honest answer.
  (dolist (mark marks)
    (when (and (eq (org-remark-koreader-mark-confidence mark) 'unresolved)
               (org-remark-koreader-mark-pos0 mark))
      (let ((range (org-remark-koreader-match--project mark dom)))
        (if range
            (progn
              (org-remark-koreader-match--place mark range 'projected)
              (unless (org-remark-koreader-match--verify-projected mark)
                (org-remark-koreader-match--place mark nil 'unresolved)))
          (org-remark-koreader-match--note-anomaly
           mark "projection does not yield the stored text")))))
  ;; Round 4 — bookmarks.  See `org-remark-koreader-match-page-position' for
  ;; what the outcome means and why there is nothing to verify.
  (dolist (mark marks)
    (when (and (eq (org-remark-koreader-mark-confidence mark) 'unresolved)
               (eq (org-remark-koreader-mark-kind mark) 'bookmark))
      (let ((position (org-remark-koreader-match--page-position mark dom)))
        (if position
            (progn
              (org-remark-koreader-match--place mark (cons position position)
                                                'projected)
              (org-remark-koreader-match--note-anomaly
               mark "bookmark at the start of the rendered page"))
          (org-remark-koreader-match--note-anomaly
           mark "`page' points outside the reconstructed tree")))))
  marks)

(defun org-remark-koreader-match--page-position (mark dom)
  "Return the source position of MARK's `page' XPointer in DOM, or nil."
  (org-remark-koreader-match-page-position
   (org-remark-koreader-mark-page mark) dom))

(defun org-remark-koreader-match-page-position (page dom)
  "Return the source position of XPointer PAGE in DOM, or nil.

For a bookmark `page' is the only anchor.  It is not the spot the
reader pointed at but the first character of the rendered page on which
the bookmark was set: three bookmarks with different anchors on page 1
all yield the same start of the document.  The position is therefore
precise, but it means \"this page\" and not \"this sentence\".

It also depends on the layout settings with which KOReader broke the
document; a different font size puts the page boundary elsewhere.

Verifying is impossible: a bookmark has no stored text to compare the
found spot against.  What the tree gives back is the only answer there
is."
  (when-let* ((pointer (org-remark-koreader-parse-xpointer page))
              (offset (org-remark-koreader-xpointer-offset pointer)))
    (org-remark-koreader-dom-resolve
     dom (org-remark-koreader-xpointer-path pointer) offset)))

(defun org-remark-koreader-match--verify-projected (mark)
  "Check a projected MARK.

The source text at that spot does not equal the stored text — that is
precisely why the projection was needed — so a weaker requirement
applies here: the range must fall inside the buffer and not be empty.
The substantive check has already been done by comparing the rendered
text with the stored text."
  (let ((beg (org-remark-koreader-mark-beg mark))
        (end (org-remark-koreader-mark-end mark)))
    (and beg end (< beg end) (<= (point-min) beg) (<= end (point-max)))))

;;;; Checking the ordering assumption

(defun org-remark-koreader-match-document-order-monotone-p (marks)
  "Return non-nil when the exactly resolved MARKS are in document order.

The narrowing in `org-remark-koreader-match--bounds' rests on KOReader
writing annotations by document position.  This function makes that
assumption testable rather than tacit."
  (let ((positions (delq nil
                         (mapcar (lambda (mark)
                                   (and (eq (org-remark-koreader-mark-confidence
                                             mark)
                                            'exact)
                                        (org-remark-koreader-mark-beg mark)))
                                 marks))))
    (equal positions (sort (copy-sequence positions) #'<))))

;;;; Reporting

(defun org-remark-koreader-match-summary (marks)
  "Return an alist of the number of marks per confidence in MARKS."
  (let ((tally nil))
    (dolist (mark marks)
      (let* ((key (org-remark-koreader-mark-confidence mark))
             (cell (assq key tally)))
        (if cell
            (cl-incf (cdr cell))
          (push (cons key 1) tally))))
    (nreverse tally)))

(provide 'org-remark-koreader-match)
;;; org-remark-koreader-match.el ends here
