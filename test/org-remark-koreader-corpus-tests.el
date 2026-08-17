;;; org-remark-koreader-corpus-tests.el --- The corpus as a yardstick  -*- lexical-binding: t; -*-

;; The other test files put a single rule under a magnifying glass.  These
;; hold the whole resolver against the fixtures that a real KOReader wrote,
;; and pin down the outcome in numbers.
;;
;; The numbers belong to the corpus in `test/corpus'.  They are a
;; measurement, not a preference: when one of them changes, something has
;; changed in the reader, in the classification or in the search -- and not
;; in the data.  Refresh them in the same commit that refreshes the corpus
;; with `test/sync-corpus.sh'.
;;
;; The decisive test is `nothing-lands-on-the-wrong-text'.  Its expectation
;; does not come from us but from the generator: `expected.json' holds the
;; source bounds the scenario asked for, measured independently of anything
;; this package does.
;;
;; Running them:
;;
;;     emacs --batch -Q -L . -l ert -l test/org-remark-koreader-corpus-tests.el \
;;           -f ert-run-tests-batch-and-exit 2>&1 | grep -E '^Ran |FAILED'

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'org-remark-koreader-lua)
(require 'org-remark-koreader-model)
(require 'org-remark-koreader-dom)
(require 'org-remark-koreader-match)

(defconst org-remark-koreader-corpus-tests--dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory holding this test file.")

;; The measuring script lives beside this file and is not on the load path.
(load (expand-file-name "analyse-fixtures.el"
                        org-remark-koreader-corpus-tests--dir)
      nil :nomessage)

(defconst org-remark-koreader-corpus-tests--md-txt
  (expand-file-name "corpus/md-txt" org-remark-koreader-corpus-tests--dir)
  "The fixtures KOReader rendered as Markdown or plain text.")

(defun org-remark-koreader-corpus-tests--fixtures ()
  "Return the fixture directories under the Markdown and plain-text corpus."
  (sort (seq-filter #'file-directory-p
                    (directory-files org-remark-koreader-corpus-tests--md-txt
                                     :full "\\`[0-9]"))
        #'string<))

(defun org-remark-koreader-corpus-tests--cases ()
  "Return a list of (SOURCE . SIDECAR) for every fixture."
  (delq nil
        (mapcar (lambda (dir)
                  (when-let* ((source (org-remark-koreader-fixtures--source dir))
                              (sidecar (org-remark-koreader-fixtures--sidecar
                                        source)))
                    (cons source sidecar)))
                (org-remark-koreader-corpus-tests--fixtures))))

(defun org-remark-koreader-corpus-tests--resolve (source sidecar)
  "Read SIDECAR, resolve it against SOURCE and return the marks.

The source is read as Emacs shows it to a reader: the line endings are
recognised, so a file with CRLF carries no carriage returns in the
buffer.  The positions the resolver hands back are buffer positions and
have to mean the same thing there."
  (let ((document (org-remark-koreader-document-from-sidecar sidecar source)))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents source))
      (org-remark-koreader-match-resolve
       (org-remark-koreader-document-marks document)))))

;;;; The reader

(ert-deftest org-remark-koreader-corpus/every-sidecar-parses ()
  "Every sidecar in the corpus is read, and the annotation count is fixed.

Both families count here, EPUB included: reading a sidecar needs nothing
but the reader itself.  If the count differs the reader is skipping
annotations or finding too many."
  (let ((files (directory-files-recursively
                (expand-file-name "corpus" org-remark-koreader-corpus-tests--dir)
                "\\`metadata\\..*\\.lua\\'"))
        (total 0))
    (should (= (length files) 22))
    (dolist (file files)
      (let* ((data (org-remark-koreader-lua-read-file file))
             (annotations (org-remark-koreader-lua-get data "annotations")))
        (when annotations
          (cl-incf total (length (org-remark-koreader-lua-array annotations))))))
    (should (= total 97))))

;;;; The placement

(ert-deftest org-remark-koreader-corpus/nothing-lands-on-the-wrong-text ()
  "No annotation is placed anywhere other than where the scenario put it.

This is the rule the package is built around, and here it is measured
against an outside truth: the source bounds from `expected.json'.  A
`wrong' means a mark colours text the reader never pointed at; a `lost'
means a mark that could not be placed.  The second is allowed by the
design, the first is not -- so the count of both is pinned down."
  (let ((tally nil))
    (dolist (dir (org-remark-koreader-corpus-tests--fixtures))
      (dolist (cell (alist-get 'tally (org-remark-koreader-fixtures--fixture dir)))
        (cl-incf (alist-get (car cell) tally 0) (cdr cell))))
    (should (= (alist-get 'right tally 0) 47))
    (should (= (alist-get 'wrong tally 0) 0))
    (should (= (alist-get 'lost tally 0) 0))
    (should (= (alist-get 'unknown tally 0) 0))
    ;; A bookmark has no range to compare, so it gets a verdict of its own.
    (should (= (alist-get 'bookmark tally 0) 9))
    (should (= (alist-get 'bookmark-lost tally 0) 0))))

(ert-deftest org-remark-koreader-corpus/the-ladder-reaches-every-annotation ()
  "The distribution over the rungs of the ladder.

Not every annotation takes the same route, and the route is part of the
outcome: an estimated position must never be handed over as an exact
one.  A shift between the rungs is therefore a change worth seeing, even
when everything still ends up in the right place."
  (let ((tally (list (cons 'total 0) (cons 'same-node 0) (cons 'cross-node 0))))
    (pcase-dolist (`(,source . ,sidecar) (org-remark-koreader-corpus-tests--cases))
      (dolist (mark (org-remark-koreader-corpus-tests--resolve source sidecar))
        (cl-incf (alist-get 'total tally))
        (cl-incf (alist-get (if (org-remark-koreader-same-node-p mark)
                                'same-node 'cross-node)
                            tally))
        (cl-incf (alist-get (org-remark-koreader-mark-confidence mark) tally 0))))
    (should (= (alist-get 'total tally) 56))
    (should (= (alist-get 'same-node tally) 42))
    (should (= (alist-get 'cross-node tally) 14))
    ;; 36 unambiguous by searching for the text, 3 ambiguous but narrowed to
    ;; one, 17 by way of the XPointer projection -- among them the marks
    ;; whose stored text is the rendered text and therefore is not in the
    ;; source word for word, even inside a single text node.
    (should (= (alist-get 'exact tally 0) 36))
    (should (= (alist-get 'disambiguated tally 0) 3))
    (should (= (alist-get 'projected tally 0) 17))
    (should (= (alist-get 'unresolved tally 0) 0))))

(ert-deftest org-remark-koreader-corpus/document-order-is-monotone ()
  "KOReader writes annotations in document order.

The narrowing with the bounds of a neighbouring mark rests on this.
Were the assumption to be wrong, that narrowing would be invalid -- so
it stands here as a test and not as a remark."
  (pcase-dolist (`(,source . ,sidecar) (org-remark-koreader-corpus-tests--cases))
    (should (org-remark-koreader-match-document-order-monotone-p
             (org-remark-koreader-corpus-tests--resolve source sidecar)))))

(ert-deftest org-remark-koreader-corpus/every-bookmark-says-what-page-means ()
  "A bookmark is placed, and it says where that position comes from.

`page' is the first character of the rendered page, not the place the
reader pointed at.  Every bookmark therefore carries that note, so the
report cannot present the position as more precise than it is."
  (let ((bookmarks 0))
    (pcase-dolist (`(,source . ,sidecar) (org-remark-koreader-corpus-tests--cases))
      (dolist (mark (org-remark-koreader-corpus-tests--resolve source sidecar))
        (when (eq (org-remark-koreader-mark-kind mark) 'bookmark)
          (cl-incf bookmarks)
          (should (org-remark-koreader-mark-beg mark))
          (should (= (org-remark-koreader-mark-beg mark)
                     (org-remark-koreader-mark-end mark)))
          (should (seq-find (lambda (note) (string-match-p "rendered page" note))
                            (org-remark-koreader-mark-anomalies mark))))))
    (should (= bookmarks 9))))

(provide 'org-remark-koreader-corpus-tests)
;;; org-remark-koreader-corpus-tests.el ends here
