;;; analyse-epub.el --- Measure the EPUB family against the corpus  -*- lexical-binding: t; -*-

;; Where `analyse-fixtures.el' puts the source file straight into a buffer,
;; that cannot be done here: an EPUB is an archive.  This script renders every
;; spine document with nov.el, turns our own position finding loose on it, and
;; counts the outcomes.
;;
;; Every annotation belongs to one chapter.  All documents are therefore
;; walked and the best outcome per annotation is kept; whatever lands in no
;; chapter at all counts as lost.
;;
;; Usage:
;;
;;     emacs --batch -Q -L . -L <nov> -L <esxml> -L <dash> \
;;           -l test/analyse-epub.el -f org-remark-koreader-epub-report [map]

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'nov)
(require 'org-remark-koreader-epub)

(defvar org-remark-koreader-epub-report-directory
  (expand-file-name
   "corpus/epub"
   (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "Directory holding the generated EPUB fixtures.")

(defconst org-remark-koreader-epub-report--placed
  '(exact disambiguated joined projected approximate)
  "Outcomes that count as placed.")

(defun org-remark-koreader-epub-report--fixture (dir)
  "Measure fixture DIR and return an alist from outcome to count."
  (let* ((epub (expand-file-name "source.epub" dir))
         (sidecar (expand-file-name "source.sdr/metadata.epub.lua" dir))
         (marks (org-remark-koreader-document-marks
                 (org-remark-koreader-document-from-sidecar sidecar epub)))
         (buffer (find-file-noselect epub))
         (best (make-hash-table :test 'equal))
         (tally nil))
    (unwind-protect
        (with-current-buffer buffer
          (nov-mode)
          (dotimes (index (length nov-documents))
            (nov-goto-document index)
            (org-remark-koreader-match-resolve marks)
            (dolist (mark marks)
              (let ((confidence (org-remark-koreader-mark-confidence mark)))
                (when (memq confidence org-remark-koreader-epub-report--placed)
                  (puthash (org-remark-koreader-mark-id mark) confidence best))))))
      (kill-buffer buffer))
    (dolist (mark marks)
      (let ((key (or (gethash (org-remark-koreader-mark-id mark) best) 'lost)))
        (cl-incf (alist-get key tally 0))))
    tally))

(defun org-remark-koreader-epub-report--line (tally)
  "Return TALLY as a readable line."
  (mapconcat (lambda (cell) (format "%s %d" (car cell) (cdr cell)))
             (sort (copy-sequence tally)
                   (lambda (a b) (string< (symbol-name (car a))
                                          (symbol-name (car b)))))
             "  "))

(defun org-remark-koreader-epub-report (&optional directory)
  "Measure every EPUB fixture under DIRECTORY and print the report."
  (let ((root (or directory
                  (car command-line-args-left)
                  org-remark-koreader-epub-report-directory))
        (total nil))
    (dolist (dir (sort (seq-filter #'file-directory-p
                                   (directory-files root :full "\\`[0-9]"))
                       #'string<))
      (let ((tally (org-remark-koreader-epub-report--fixture dir)))
        (dolist (cell tally)
          (cl-incf (alist-get (car cell) total 0) (cdr cell)))
        (princ (format "%-28s %s\n"
                       (file-name-nondirectory (directory-file-name dir))
                       (org-remark-koreader-epub-report--line tally)))))
    (princ (format "\ntotal: %s\n"
                   (org-remark-koreader-epub-report--line total)))))

(provide 'analyse-epub)
;;; analyse-epub.el ends here
