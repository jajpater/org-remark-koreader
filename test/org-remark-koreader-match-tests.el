;;; org-remark-koreader-match-tests.el --- Tests for locating annotations  -*- lexical-binding: t; -*-

;; Running them:
;;
;;     emacs --batch -Q -L . -l ert -l test/org-remark-koreader-match-tests.el \
;;           -f ert-run-tests-batch-and-exit 2>&1 | grep -E '^Ran |FAILED'

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-remark-koreader-model)
(require 'org-remark-koreader-match)
(require 'org-remark-koreader-dom)

;;;; The ladder in miniature

(defmacro org-remark-koreader-match-tests--with-buffer (text &rest body)
  "Run BODY in a buffer holding TEXT."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (goto-char (point-min))
     ,@body))

(defun org-remark-koreader-match-tests--mark (&rest args)
  "Make a mark from ARGS; within one text node by default."
  (apply #'org-remark-koreader-mark-create
         (append args (list :kind 'highlight
                            :pos0 "/html/body/p[1]/text().0"
                            :pos1 "/html/body/p[1]/text().5"))))

(ert-deftest org-remark-koreader-match/unambiguous-text-is-exact ()
  "One verbatim hit yields an exact position."
  (org-remark-koreader-match-tests--with-buffer "before unique text after"
    (let ((mark (org-remark-koreader-match-tests--mark :text "unique text")))
      (org-remark-koreader-match-resolve (list mark))
      (should (eq (org-remark-koreader-mark-confidence mark) 'exact))
      (should (equal (buffer-substring-no-properties
                      (org-remark-koreader-mark-beg mark)
                      (org-remark-koreader-mark-end mark))
                     "unique text")))))

(ert-deftest org-remark-koreader-match/ambiguous-text-without-a-bound-stays-unresolved ()
  "Without a hard bound no choice is made."
  (org-remark-koreader-match-tests--with-buffer "repeated and repeated"
    (let ((mark (org-remark-koreader-match-tests--mark :text "repeated")))
      (org-remark-koreader-match-resolve (list mark))
      (should (eq (org-remark-koreader-mark-confidence mark) 'unresolved))
      (should (= (length (org-remark-koreader-mark-candidates mark)) 2))
      (should (seq-find (lambda (note) (string-match-p "candidates" note))
                        (org-remark-koreader-mark-anomalies mark))))))

(ert-deftest org-remark-koreader-match/a-neighbour-narrows-to-one ()
  "A neighbour resolved as exact rules out the other candidate."
  (org-remark-koreader-match-tests--with-buffer "repeated ANCHOR repeated"
    (let* ((first (org-remark-koreader-match-tests--mark :text "ANCHOR"))
           (second (org-remark-koreader-match-tests--mark :text "repeated"))
           (marks (list first second)))
      (org-remark-koreader-match-resolve marks)
      (should (eq (org-remark-koreader-mark-confidence first) 'exact))
      (should (eq (org-remark-koreader-mark-confidence second) 'disambiguated))
      ;; The second occurrence, because that is the only one after the anchor.
      (should (> (org-remark-koreader-mark-beg second)
                 (org-remark-koreader-mark-end first))))))

(ert-deftest org-remark-koreader-match/a-disambiguated-mark-is-no-bound ()
  "A narrowing rests only on neighbours resolved as exact.
Otherwise an earlier choice carries on as though it were a fact."
  (org-remark-koreader-match-tests--with-buffer "aa bb aa bb"
    (let* ((one (org-remark-koreader-match-tests--mark :text "aa"))
           (two (org-remark-koreader-match-tests--mark :text "bb"))
           (marks (list one two)))
      (org-remark-koreader-match-resolve marks)
      (should (eq (org-remark-koreader-mark-confidence one) 'unresolved))
      (should (eq (org-remark-koreader-mark-confidence two) 'unresolved)))))

(ert-deftest org-remark-koreader-match/the-chapter-narrows ()
  "An unambiguous heading rules out candidates outside that section."
  (org-remark-koreader-match-tests--with-buffer
      "# First\n\nrepeated here\n\n# Second\n\nrepeated there\n"
    (let ((mark (org-remark-koreader-match-tests--mark
                 :text "repeated" :chapter "Second")))
      (org-remark-koreader-match-resolve (list mark))
      (should (eq (org-remark-koreader-mark-confidence mark) 'disambiguated))
      (should (string-match-p
               "there"
               (buffer-substring-no-properties
                (org-remark-koreader-mark-beg mark) (point-max)))))))

(ert-deftest org-remark-koreader-match/a-duplicate-heading-does-not-narrow ()
  "A heading occurring twice points at no section."
  (org-remark-koreader-match-tests--with-buffer
      "# Same\n\nrepeated here\n\n# Same\n\nrepeated there\n"
    (let ((mark (org-remark-koreader-match-tests--mark
                 :text "repeated" :chapter "Same")))
      (org-remark-koreader-match-resolve (list mark))
      (should (eq (org-remark-koreader-mark-confidence mark) 'unresolved)))))

(ert-deftest org-remark-koreader-match/text-is-not-a-pattern ()
  "Regexp metacharacters in the stored text are searched for literally."
  (org-remark-koreader-match-tests--with-buffer
      "the storm and later storms? indeed"
    (let ((mark (org-remark-koreader-match-tests--mark :text "storms?")))
      (org-remark-koreader-match-resolve (list mark))
      (should (eq (org-remark-koreader-mark-confidence mark) 'exact))
      (should (equal (buffer-substring-no-properties
                      (org-remark-koreader-mark-beg mark)
                      (org-remark-koreader-mark-end mark))
                     "storms?")))))

(ert-deftest org-remark-koreader-match/overlapping-occurrences-count ()
  "Two overlapping occurrences are two candidates, not one."
  (org-remark-koreader-match-tests--with-buffer "aaaa"
    (should (= (length (org-remark-koreader-match--occurrences "aa")) 3))))

(provide 'org-remark-koreader-match-tests)
;;; org-remark-koreader-match-tests.el ends here
