;;; analyse-fixtures.el --- Measure the resolver against the corpus  -*- lexical-binding: t; -*-

;; Runs the source-position finding on every fixture from the generator and
;; compares the outcome with `expected.json'.
;;
;; The comparison rests on two independent sources of truth:
;;
;; - `source_range' gives zero-based, half-open byte bounds in the source
;;   file.  Those come from the declarative scenario markers and are wholly
;;   independent of our own matching.
;; - where that field is missing, the Nth verbatim occurrence of the stored
;;   text applies, with N from `occurrence'.
;;
;; A bookmark has neither: its `anchor' is the text the generator navigated
;; to, not something KOReader stores.  For bookmarks this script therefore
;; reports what the `page' XPointer yields and how far that is from the
;; anchor, without counting it right or wrong.
;;
;; Usage:
;;
;;     emacs --batch -Q -L . -l test/analyse-fixtures.el \
;;           -f org-remark-koreader-fixtures-main [path-to-corpus]

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'org-remark-koreader-lua)
(require 'org-remark-koreader-model)
(require 'org-remark-koreader-dom)
(require 'org-remark-koreader-match)

(defvar org-remark-koreader-fixtures-default-directory
  (expand-file-name
   "corpus/md-txt"
   (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "Directory holding the generated fixtures.

By default the corpus that comes with this package, so the measurement
runs without a network and without a second checkout.  Refresh it with
`test/sync-corpus.sh\='.")

;;;; Source file and byte position

(defun org-remark-koreader-fixtures--source (dir)
  "Return the source file in DIR, or nil."
  (car (seq-filter #'file-regular-p
                   (directory-files dir :full "\\`source\\.[a-z]+\\'"))))

(defun org-remark-koreader-fixtures--sidecar (source)
  "Return the sidecar path belonging to SOURCE, or nil."
  (let ((path (expand-file-name
               (format "metadata.%s.lua" (file-name-extension source))
               (concat (file-name-sans-extension source) ".sdr"))))
    (and (file-readable-p path) path)))

(defun org-remark-koreader-fixtures--raw (path)
  "Return the raw bytes of PATH as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun org-remark-koreader-fixtures--byte-position (raw byte dos)
  "Return the buffer position for BYTE in RAW.

BYTE is zero-based and counts in the file.  The buffer counts characters
from 1, and with DOS line endings Emacs has already removed every CR
before showing the text."
  (let* ((prefix (decode-coding-string (substring raw 0 byte) 'utf-8))
         (carriage (if dos (cl-count ?\r prefix) 0)))
    (1+ (- (length prefix) carriage))))

;;;; Expected positions

(defun org-remark-koreader-fixtures--occurrence (text nth)
  "Return the range of the NTH occurrence of TEXT in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((found nil)
          (count 0))
      (while (and (not found) (search-forward text nil :noerror))
        (cl-incf count)
        (when (= count nth)
          (setq found (cons (match-beginning 0) (match-end 0))))
        (goto-char (1+ (match-beginning 0))))
      found)))

(defun org-remark-koreader-fixtures--loose-occurrence (text nth)
  "Return the range of the NTH occurrence of TEXT with whitespace free.

KOReader writes down the rendered text: where the source has a newline
or indentation, the sidecar holds a single space.  This search lets any
run of whitespace match any other, and so stays independent of our own
DOM."
  (let ((pattern (mapconcat #'regexp-quote
                            (split-string text "[ \t\n\r]+" t)
                            "[ \t\n\r]+")))
    (save-excursion
      (goto-char (point-min))
      (let ((found nil)
            (count 0))
        (while (and (not found) (re-search-forward pattern nil :noerror))
          (cl-incf count)
          (when (= count nth)
            (setq found (cons (match-beginning 0) (match-end 0))))
          (goto-char (1+ (match-beginning 0))))
        found))))

(defun org-remark-koreader-fixtures--expected-range (op raw dos)
  "Return the expected source range of OP, or nil.

Returns (BEGIN END . SOURCE), where SOURCE tells which truth gave the
answer: `bytes' for the scenario markers, `verbatim' for a word-for-word
hit, `loose' for a hit with whitespace free.  RAW and DOS describe the
source file; see `org-remark-koreader-fixtures--byte-position'."
  (let ((range (alist-get 'source_range op))
        (text (alist-get 'text op))
        (nth (or (alist-get 'occurrence op) 1)))
    (cond
     (range
      (list (org-remark-koreader-fixtures--byte-position
             raw (alist-get 'start_byte range) dos)
            (org-remark-koreader-fixtures--byte-position
             raw (alist-get 'end_byte range) dos)
            'bytes))
     ((not (stringp text)) nil)
     ((org-remark-koreader-fixtures--occurrence text nth)
      (let ((hit (org-remark-koreader-fixtures--occurrence text nth)))
        (list (car hit) (cdr hit) 'verbatim)))
     ((org-remark-koreader-fixtures--loose-occurrence text nth)
      (let ((hit (org-remark-koreader-fixtures--loose-occurrence text nth)))
        (list (car hit) (cdr hit) 'loose))))))

;;;; Pairing expectation with mark

(defun org-remark-koreader-fixtures--kind (op)
  "Return the kind of OP as a symbol."
  (intern (alist-get 'kind op)))

(defun org-remark-koreader-fixtures--pair (ops marks raw dos)
  "Pair OPS with MARKS per kind, in document order.

The generator writes its operations in scenario order; KOReader writes
its annotations by document position.  Both lists are therefore laid out
by position per kind before they are put side by side.  For a bookmark
there is no position to sort on; those keep their own order, which is
right because the generator creates them at ascending anchor positions."
  (let ((pairs nil))
    (dolist (kind '(highlight annotation bookmark))
      (let* ((subset (seq-filter (lambda (op)
                                   (eq (org-remark-koreader-fixtures--kind op)
                                       kind))
                                 ops))
             (ranged (mapcar (lambda (op)
                               (cons op (org-remark-koreader-fixtures--expected-range
                                         op raw dos)))
                             subset))
             (sorted (if (eq kind 'bookmark)
                         ranged
                       (sort ranged
                             (lambda (a b)
                               (< (or (car-safe (cdr a)) most-positive-fixnum)
                                  (or (car-safe (cdr b)) most-positive-fixnum))))))
             (same (seq-filter (lambda (mark)
                                 (eq (org-remark-koreader-mark-kind mark) kind))
                               marks)))
        (cl-loop for cell in sorted
                 for index from 0
                 do (push (list (car cell) (cdr cell) (nth index same)) pairs))))
    (nreverse pairs)))

;;;; Bookmarks

(defun org-remark-koreader-fixtures--page-position (mark dom)
  "Return the source position MARK's `page' XPointer arrives at, or nil."
  (when-let* ((pointer (org-remark-koreader-parse-xpointer
                        (org-remark-koreader-mark-page mark)))
              (offset (org-remark-koreader-xpointer-offset pointer)))
    (org-remark-koreader-dom-resolve
     dom (org-remark-koreader-xpointer-path pointer) offset)))

;;;; Report

(defun org-remark-koreader-fixtures--verdict (expected mark)
  "Compare EXPECTED with the placement of MARK.
Returns `right', `wrong', `lost' or `unknown'."
  (let ((beg (and mark (org-remark-koreader-mark-beg mark)))
        (end (and mark (org-remark-koreader-mark-end mark))))
    (cond
     ((null expected) 'unknown)
     ((null beg) 'lost)
     ((and (= beg (nth 0 expected)) (= end (nth 1 expected))) 'right)
     (t 'wrong))))

(defun org-remark-koreader-fixtures--context (position)
  "Return a short piece of buffer text around POSITION."
  (if (null position)
      "—"
    (let ((beg (max (point-min) position))
          (end (min (point-max) (+ position 40))))
      (replace-regexp-in-string
       "\n" "⏎" (buffer-substring-no-properties beg end)))))

(defun org-remark-koreader-fixtures--fixture (dir)
  "Measure one fixture in DIR and return an alist with the outcome."
  (let* ((source (org-remark-koreader-fixtures--source dir))
         (sidecar (and source (org-remark-koreader-fixtures--sidecar source)))
         (expected-file (expand-file-name "expected.json" dir)))
    (unless (and source sidecar (file-readable-p expected-file))
      (error "%s: source, sidecar or expected.json missing" dir))
    (let* ((json (with-temp-buffer
                   (insert-file-contents expected-file)
                   (json-parse-buffer :object-type 'alist :array-type 'list)))
           (ops (alist-get 'operations json))
           (raw (org-remark-koreader-fixtures--raw source))
           (document (org-remark-koreader-document-from-sidecar sidecar source))
           (marks (org-remark-koreader-document-marks document))
           (lines nil)
           (tally nil))
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents source))
        (let* ((dos (eq (coding-system-eol-type buffer-file-coding-system) 1))
               (dom (org-remark-koreader-match-build-dom marks)))
          (org-remark-koreader-match--resolve-with-dom marks dom)
          (dolist (pair (org-remark-koreader-fixtures--pair ops marks raw dos))
            (cl-destructuring-bind (op expected mark) pair
              (let* ((kind (org-remark-koreader-fixtures--kind op))
                     (verdict (cond
                               ((not (eq kind 'bookmark))
                                (org-remark-koreader-fixtures--verdict
                                 expected mark))
                               ((and mark (org-remark-koreader-mark-beg mark))
                                'bookmark)
                               (t 'bookmark-lost)))
                     (page (and (eq kind 'bookmark) mark
                                (org-remark-koreader-fixtures--page-position
                                 mark dom))))
                (cl-incf (alist-get verdict tally 0))
                (unless (eq verdict 'right)
                  (push (list :fixture (file-name-nondirectory
                                        (directory-file-name dir))
                              :kind kind
                              :verdict verdict
                              :confidence (and mark (org-remark-koreader-mark-confidence
                                                     mark))
                              :expected expected
                              :oracle (nth 2 expected)
                              :got (and mark (org-remark-koreader-mark-beg mark))
                              :page page
                              :page-context (org-remark-koreader-fixtures--context page)
                              :anchor (alist-get 'anchor op)
                              :anchor-position (car-safe expected)
                              :text (or (alist-get 'text op) "")
                              :anomalies (and mark (org-remark-koreader-mark-anomalies
                                                    mark)))
                        lines)))))))
      (list (cons 'fixture (file-name-nondirectory (directory-file-name dir)))
            (cons 'ops (length ops))
            (cons 'tally tally)
            (cons 'details (nreverse lines))
            (cons 'rejections (org-remark-koreader-document-rejections document))))))

(defun org-remark-koreader-fixtures-report (&optional directory)
  "Measure every fixture under DIRECTORY and print the report."
  (let* ((root (or directory org-remark-koreader-fixtures-default-directory))
         (dirs (seq-filter #'file-directory-p (directory-files root :full "\\`[0-9]")))
         (total nil)
         (details nil))
    (princ (format "%-24s %5s  %s\n" "fixture" "ops" "outcome"))
    (dolist (dir (sort dirs #'string<))
      (let* ((result (org-remark-koreader-fixtures--fixture dir))
             (tally (alist-get 'tally result)))
        (dolist (cell tally)
          (cl-incf (alist-get (car cell) total 0) (cdr cell)))
        (setq details (append details (alist-get 'details result)))
        (princ (format "%-24s %5d  %s\n"
                       (alist-get 'fixture result)
                       (alist-get 'ops result)
                       (mapconcat (lambda (cell)
                                    (format "%s %d" (car cell) (cdr cell)))
                                  (sort (copy-sequence tally)
                                        (lambda (a b) (string< (car a) (car b))))
                                  "  ")))
        (when (alist-get 'rejections result)
          (princ (format "%-24s        rejected: %S\n" ""
                         (alist-get 'rejections result))))))
    (princ (format "\ntotal: %s\n"
                   (mapconcat (lambda (cell) (format "%s %d" (car cell) (cdr cell)))
                              (sort (copy-sequence total)
                                    (lambda (a b) (string< (car a) (car b))))
                              "  ")))
    (when details
      (princ "\ndetails\n")
      (dolist (line details)
        (if (memq (plist-get line :verdict) '(bookmark bookmark-lost))
            (princ (format "  %s bookmark at %s, anchor was at %s\n     %s\n"
                           (plist-get line :fixture)
                           (or (plist-get line :page) "no place")
                           (or (plist-get line :anchor-position) "?")
                           (plist-get line :page-context)))
          (princ (format "  %s %s %s: expected %s (%s), got %s (%s) %S\n     %S\n"
                         (plist-get line :fixture)
                         (plist-get line :kind)
                         (plist-get line :verdict)
                         (and (plist-get line :expected)
                              (cons (nth 0 (plist-get line :expected))
                                    (nth 1 (plist-get line :expected))))
                         (plist-get line :oracle)
                         (plist-get line :got)
                         (plist-get line :confidence)
                         (plist-get line :anomalies)
                         (plist-get line :text))))))))

(defun org-remark-koreader-fixtures-main ()
  "Entry point for batch use."
  (org-remark-koreader-fixtures-report (car command-line-args-left)))

(provide 'analyse-fixtures)
;;; analyse-fixtures.el ends here
