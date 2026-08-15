;;; org-remark-koreader-epub-tests.el --- Tests for the EPUB family  -*- lexical-binding: t; -*-

;; Running them:
;;
;;     emacs --batch -Q -L . -l ert -l test/org-remark-koreader-epub-tests.el \
;;           -f ert-run-tests-batch-and-exit 2>&1 | grep -E '^Ran |FAILED'

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-remark-koreader-epub)

(defun org-remark-koreader-epub-tests--mark (&rest args)
  "Make a mark for the tests out of ARGS."
  (apply #'org-remark-koreader-mark-create args))

;;;; Recognising the family

(ert-deftest org-remark-koreader-epub/recognises-its-own-root ()
  "An EPUB XPointer begins with `/body/DocFragment'."
  (should (org-remark-koreader-epub-marks-p
           (list (org-remark-koreader-epub-tests--mark
                  :pos0 "/body/DocFragment[3]/body/p[1]/text().0"))))
  ;; A bookmark has no `pos0'; then `page' counts.
  (should (org-remark-koreader-epub-marks-p
           (list (org-remark-koreader-epub-tests--mark
                  :page "/body/DocFragment/body/p[3]/text().0"))))
  (should-not (org-remark-koreader-epub-marks-p
               (list (org-remark-koreader-epub-tests--mark
                      :pos0 "/html/body/p[2]/text().4"))))
  (should-not (org-remark-koreader-epub-marks-p
               (list (org-remark-koreader-epub-tests--mark
                      :pos0 "/FictionBook/body/pre[2]/text().0")))))

;;;; The spine number

(ert-deftest org-remark-koreader-epub/reads-the-spine-number ()
  "Without an index the number is one, not zero.

A book with a single content document yields a bare `DocFragment'; that
is the first spine item, and the spine counts from one."
  (should (= 1 (org-remark-koreader-epub-fragment
                "/body/DocFragment/body/p[1]/text().0")))
  (should (= 3 (org-remark-koreader-epub-fragment
                "/body/DocFragment[3]/body/p[1]/text().0")))
  (should (= 12 (org-remark-koreader-epub-fragment
                 "/body/DocFragment[12]/body/p[9]/text()[2].41")))
  (should-not (org-remark-koreader-epub-fragment "/html/body/p[1]/text().0"))
  (should-not (org-remark-koreader-epub-fragment nil)))

;;;; The path inside the document

(ert-deftest org-remark-koreader-epub/cuts-out-the-document-path ()
  "An EPUB XPointer carries two paths one after the other.

The first belongs to CRengine's book-wide tree, the second to the XHTML
file.  The text node and the offset belong to neither."
  (should (equal (org-remark-koreader-epub--steps
                  "/body/DocFragment[7]/body/p[3]/text().0")
                 '("body" "p[3]")))
  (should (equal (org-remark-koreader-epub--steps
                  "/body/DocFragment/body/p[2]/text()[1].14")
                 '("body" "p[2]")))
  ;; Without a text node the path stays as it is.
  (should (equal (org-remark-koreader-epub--steps
                  "/body/DocFragment/body/blockquote/p")
                 '("body" "blockquote" "p")))
  (should-not (org-remark-koreader-epub--steps "/html/body/p[1]/text().0")))

(ert-deftest org-remark-koreader-epub/follows-the-path-in-the-tree ()
  "A step without an index is the first of its kind, not the zeroth."
  (let ((dom (with-temp-buffer
               (insert "<html><body><p>one</p><p>two</p>"
                       "<blockquote><p>three</p></blockquote></body></html>")
               (libxml-parse-html-region (point-min) (point-max)))))
    (should (equal (org-remark-koreader-epub--collapse
                    (dom-texts (org-remark-koreader-epub--follow
                                dom '("body" "p[2]"))))
                   "two"))
    (should (equal (org-remark-koreader-epub--collapse
                    (dom-texts (org-remark-koreader-epub--follow
                                dom '("body" "blockquote" "p"))))
                   "three"))
    ;; A path that does not exist yields nil, not the nearest node.
    (should-not (org-remark-koreader-epub--follow dom '("body" "p[9]")))
    (should-not (org-remark-koreader-epub--follow dom '("body" "table")))))

(ert-deftest org-remark-koreader-epub/reads-the-offset ()
  "The offset sits behind the text node."
  (should (= 0 (org-remark-koreader-epub--offset
                "/body/DocFragment/body/p[3]/text().0")))
  (should (= 26 (org-remark-koreader-epub--offset
                 "/body/DocFragment/body/p[1]/text().26")))
  (should-not (org-remark-koreader-epub--offset
               "/body/DocFragment/body/p[1]/text()")))

;;;; Alike blocks and text nodes

(ert-deftest org-remark-koreader-epub/counts-alike-predecessors ()
  "Two paragraphs alike word for word can be told apart only by their order."
  (let* ((dom (with-temp-buffer
                (insert "<html><body><p>first</p><p>same</p>"
                        "<p>between</p><p>same</p></body></html>")
                (libxml-parse-html-region (point-min) (point-max))))
         (second (org-remark-koreader-epub--follow dom '("body" "p[2]")))
         (fourth (org-remark-koreader-epub--follow dom '("body" "p[4]"))))
    (should (= 0 (org-remark-koreader-epub--earlier-alike dom second "same")))
    (should (= 1 (org-remark-koreader-epub--earlier-alike dom fourth "same")))))

(ert-deftest org-remark-koreader-epub/measures-the-prefix-of-a-text-node ()
  "The offset of `text()[2]' counts inside that node, not inside the paragraph.

To map that onto the buffer it must first be known how much rendered
text precedes it, including that of the inline elements in between."
  (let* ((dom (with-temp-buffer
                (insert "<html><body><p>begin <em>italic</em> end</p></body></html>")
                (libxml-parse-html-region (point-min) (point-max))))
         (paragraph (org-remark-koreader-epub--follow dom '("body" "p"))))
    (should (= 0 (org-remark-koreader-epub--text-node-prefix paragraph 1)))
    ;; "begin " plus "italic" is twelve characters; the space counts too.
    (should (= 12 (org-remark-koreader-epub--text-node-prefix paragraph 2)))
    (should-not (org-remark-koreader-epub--text-node-prefix paragraph 3))))

(ert-deftest org-remark-koreader-epub/reads-the-text-node-number ()
  "Without a number it is the first text node."
  (should (= 1 (org-remark-koreader-epub--text-node-index
                "/body/DocFragment/body/p[1]/text().26")))
  (should (= 2 (org-remark-koreader-epub--text-node-index
                "/body/DocFragment/body/p[2]/text()[2].2314"))))

(ert-deftest org-remark-koreader-epub/counts-whitespace-as-one-character ()
  "A run of whitespace counts as one character.

That is how it sits in the text KOReader bases its offsets on; that the
rendering turns it into a newline does not change the count."
  (with-temp-buffer
    (insert "one   two\nthree")
    (let ((begin (point-min)))
      (should (= (org-remark-koreader-epub--forward begin 0) begin))
      ;; "one" is three characters, then one for the whole run of
      ;; whitespace.
      (should (equal (buffer-substring-no-properties
                      (org-remark-koreader-epub--forward begin 4) (point-max))
                     "two\nthree"))
      (should (equal (buffer-substring-no-properties
                      (org-remark-koreader-epub--forward begin 8) (point-max))
                     "three")))))

;;;; Finding the element in the buffer

(defmacro org-remark-koreader-epub-tests--with-document (xhtml rendered &rest body)
  "Pretend XHTML is the document on screen and RENDERED the rendering.
Run BODY in a buffer holding RENDERED."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'org-remark-koreader-epub--document-dom)
              (lambda ()
                (with-temp-buffer
                  (insert ,xhtml)
                  (libxml-parse-html-region (point-min) (point-max))))))
     (with-temp-buffer
       (insert ,rendered)
       ,@body)))

(ert-deftest org-remark-koreader-epub/points-at-the-right-one-of-three-alike-paragraphs ()
  "Three alike paragraphs; the path says which one is meant.

This is the case that searching for the text alone cannot settle, and to
which the XPointer gives an independent answer."
  (org-remark-koreader-epub-tests--with-document
      "<html><body><p>head</p><p>same line</p><p>same line</p><p>same line</p></body></html>"
      "head\n\nsame line\n\nsame line\n\nsame line\n"
    (let ((first (org-remark-koreader-epub-element-region
                  "/body/DocFragment/body/p[2]/text().0"))
          (third (org-remark-koreader-epub-element-region
                  "/body/DocFragment/body/p[4]/text().0")))
      (should (equal (buffer-substring-no-properties (car first) (cdr first))
                     "same line"))
      (should (equal (buffer-substring-no-properties (car third) (cdr third))
                     "same line"))
      ;; Not the same place: `p[2]' is the first occurrence and `p[4]' the
      ;; last.
      (should (< (car first) (car third)))
      (should (= (car first)
                 (save-excursion (goto-char (point-min))
                                 (search-forward "same line")
                                 (match-beginning 0))))
      (should (= (car third)
                 (save-excursion (goto-char (point-max))
                                 (search-backward "same line")
                                 (point)))))))

(ert-deftest org-remark-koreader-epub/yields-nil-for-a-path-that-does-not-exist ()
  "A path that is not there yields nil, not the nearest place."
  (org-remark-koreader-epub-tests--with-document
      "<html><body><p>only paragraph</p></body></html>"
      "only paragraph\n"
    (should-not (org-remark-koreader-epub-element-region
                 "/body/DocFragment/body/p[7]/text().0"))))

;;;; Bounds of the offset

(ert-deftest org-remark-koreader-epub/refuses-an-offset-outside-the-element ()
  "An offset reaching beyond the element describes no place inside it.

Without that bound the count simply runs on into the next paragraph and
produces a position that means nothing — and that says nothing about
itself either."
  (org-remark-koreader-epub-tests--with-document
      "<html><body><p>short piece of text</p></body></html>"
      "short piece of text\n\nplenty more text after this\n"
    (let ((path "/body/DocFragment/body/p/text().%d"))
      ;; Inside the element, and the bound itself, are valid.
      (should (= 1 (org-remark-koreader-epub--block-position (format path 0))))
      (should (= 6 (org-remark-koreader-epub--block-position (format path 5))))
      (should (org-remark-koreader-epub--block-position (format path 19)))
      ;; One character further falls outside the element.
      (should-not (org-remark-koreader-epub--block-position (format path 20)))
      (should-not (org-remark-koreader-epub--block-position (format path 999))))))

(ert-deftest org-remark-koreader-epub/an-enclosing-element-is-no-predecessor ()
  "A chapter of one paragraph: `body' carries the same text as that paragraph.

Had that counted as an alike predecessor, the paragraph would be skipped
and nothing would be found."
  (org-remark-koreader-epub-tests--with-document
      "<html><body><p>the only paragraph</p></body></html>"
      "the only paragraph\n"
    (should (equal (org-remark-koreader-epub-element-region
                    "/body/DocFragment/body/p/text().0")
                   (cons 1 19)))))

;;;; Scripts without word spaces

(ert-deftest org-remark-koreader-epub/recognises-script-breaking-without-a-space ()
  "Only Chinese, Japanese and Korean need the last resort."
  (should (org-remark-koreader-epub--breakable-p "これは日本語です"))
  (should (org-remark-koreader-epub--breakable-p "中文句子"))
  (should-not (org-remark-koreader-epub--breakable-p "ordinary English"))
  (should-not (org-remark-koreader-epub--breakable-p "Ελληνικά and café")))

(ert-deftest org-remark-koreader-epub/finds-text-with-a-break-inside-it ()
  "Shr breaks Japanese between the characters; free whitespace is no help.

The ordinary routes search between words, and between these characters
there never was a space."
  (with-temp-buffer
    (insert "before\nこれは日本語の文\n章です。here\n")
    (let ((text "これは日本語の文章です。"))
      (should-not (save-excursion (goto-char (point-min))
                                  (search-forward text nil t)))
      (should-not (save-excursion
                    (goto-char (point-min))
                    (re-search-forward
                     (org-remark-koreader-epub--loose-regexp text) nil t)))
      (should (save-excursion
                (goto-char (point-min))
                (re-search-forward
                 (org-remark-koreader-epub--broken-regexp text) nil t))))))

;;;; Selections across a block boundary

(ert-deftest org-remark-koreader-epub/splits-on-newlines ()
  "KOReader puts a newline in the text at a block transition."
  (should (equal (org-remark-koreader-epub--parts "one part")
                 '("one part")))
  (should (equal (org-remark-koreader-epub--parts "first part\nsecond part")
                 '("first part" "second part")))
  ;; Empty pieces and whitespace at the edges do not count.
  (should (equal (org-remark-koreader-epub--parts "first\n\n  second  ")
                 '("first" "second"))))

(ert-deftest org-remark-koreader-epub/joins-the-parts ()
  "The parts are searched separately and the range runs from first to last.

What the rendering puts between them — shr numbers list items — need not
be recognised; it simply falls inside the range."
  (with-temp-buffer
    (insert "1 First list crossing begins with amber rope\n"
            "2 Second list crossing ends with a blue knot.\n")
    (let ((span (org-remark-koreader-epub--span
                 '("First list crossing begins with amber rope"
                   "Second list crossing ends with a blue knot"))))
      (should span)
      (should (equal (buffer-substring-no-properties (car span) (cdr span))
                     (concat "First list crossing begins with amber rope\n"
                             "2 Second list crossing ends with a blue knot"))))))

(ert-deftest org-remark-koreader-epub/refuses-parts-in-the-wrong-order ()
  "When the parts are out of order it is no selection."
  (with-temp-buffer
    (insert "second part sits here\n\nfirst part sits here\n")
    (should-not (org-remark-koreader-epub--span
                 '("first part" "second part")))))

(ert-deftest org-remark-koreader-epub/refuses-an-ambiguous-part ()
  "When a part occurs more than once there is nothing to join."
  (with-temp-buffer
    (insert "repeated part\nrepeated part\nend\n")
    (should-not (org-remark-koreader-epub--span '("repeated part" "end")))))

;;;; Registering with the resolver

(ert-deftest org-remark-koreader-epub/registers-itself-as-a-family ()
  "The EPUB family registers itself; `-match.el' does not know it."
  (should (seq-find (lambda (family)
                      (eq (car family) #'org-remark-koreader-epub-marks-p))
                    org-remark-koreader-match-families)))

;;;; The full cycle on a real EPUB
;;
;; Needs nov.el and the generated corpus.  If either is missing these tests
;; skip themselves: the corpus comes along with the package, but a checkout
;; without it should still be able to run the rest.

(defconst org-remark-koreader-epub-tests--fixture
  (expand-file-name
   "corpus/epub/006-multichapter-spine"
   (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "Directory holding the EPUB that exercises the full cycle.")

(defun org-remark-koreader-epub-tests--available-p ()
  "Return non-nil when nov.el and the fixture EPUB are both there."
  (and (require 'nov nil :noerror)
       ;; org-remark itself has to be loaded, not just `org-remark-nov'.
       ;; That hangs `org-remark-highlights-load' in a hook and only declares
       ;; it; normally the autoload settles that, but the suite runs with
       ;; `emacs -Q' and therefore without the package manager's autoloads.
       (require 'org-remark-koreader nil :noerror)
       (require 'org-remark-nov nil :noerror)
       (file-readable-p (expand-file-name
                         "source.epub"
                         org-remark-koreader-epub-tests--fixture))))

(defmacro org-remark-koreader-epub-tests--with-book (var &rest body)
  "Copy the fixture EPUB to a temporary directory and bind VAR to the path.

An import writes a notes file beside the source; that must never end up
in the fixture directory, which is measuring equipment and not a
workspace."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "org-remark-koreader-epub" :directory))
          (,var (expand-file-name "source.epub" dir))
          (nov-text-width t)
          (nov-variable-pitch nil))
     (unwind-protect
         (progn
           (copy-file (expand-file-name
                       "source.epub" org-remark-koreader-epub-tests--fixture)
                      ,var)
           (copy-directory (expand-file-name
                            "source.sdr"
                            org-remark-koreader-epub-tests--fixture)
                           (expand-file-name "source.sdr" dir))
           ,@body)
       (dolist (buffer (buffer-list))
         (when (and (buffer-file-name buffer)
                    (string-prefix-p dir (buffer-file-name buffer)))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory dir :recursive))))

(defun org-remark-koreader-epub-tests--count (file regexp)
  "Count the lines in FILE matching REGEXP."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (cl-loop while (re-search-forward regexp nil t) count t)))

(ert-deftest org-remark-koreader-epub/imports-the-whole-book ()
  "One import places the annotations of every chapter.

`nov-mode' shows one chapter at a time, so the import visits them all
and returns to where the reader was."
  (skip-unless (org-remark-koreader-epub-tests--available-p))
  (org-remark-koreader-epub-tests--with-book epub
    (org-remark-nov-mode +1)
    (with-current-buffer (find-file-noselect epub)
      (nov-mode)
      (nov-goto-document 2)
      (org-remark-koreader-import)
      (org-remark-save)
      (should (= (symbol-value 'nov-documents-index) 2))
      (let ((notes (expand-file-name "marginalia.org"
                                     (file-name-directory epub))))
        (should (file-exists-p notes))
        ;; Six annotations, spread over three chapters.
        (should (= 6 (org-remark-koreader-epub-tests--count
                      notes "^:org-remark-id:")))
        (should (= 3 (org-remark-koreader-epub-tests--count
                      notes "^:org-remark-file:")))))))

(ert-deftest org-remark-koreader-epub/second-import-makes-no-duplicates ()
  "Importing the book again does not change the notes file."
  (skip-unless (org-remark-koreader-epub-tests--available-p))
  (org-remark-koreader-epub-tests--with-book epub
    (org-remark-nov-mode +1)
    (with-current-buffer (find-file-noselect epub)
      (nov-mode)
      (nov-goto-document 2)
      (org-remark-koreader-import)
      (org-remark-save)
      (org-remark-koreader-import)
      (org-remark-save)
      (let ((notes (expand-file-name "marginalia.org"
                                     (file-name-directory epub))))
        (should (= 6 (org-remark-koreader-epub-tests--count
                      notes "^:org-remark-id:")))
        (should (= 3 (org-remark-koreader-epub-tests--count
                      notes "^:org-remark-file:")))))))

(ert-deftest org-remark-koreader-epub/leaves-no-remnants-behind ()
  "Turning the page leaves no collapsed overlays behind.

`nov-mode' erases the buffer for the next chapter, but overlays survive
that: they collapse onto position one.  Without clearing, every chapter
would drag the marks of the previous one along."
  (skip-unless (org-remark-koreader-epub-tests--available-p))
  (org-remark-koreader-epub-tests--with-book epub
    (org-remark-nov-mode +1)
    (with-current-buffer (find-file-noselect epub)
      (nov-mode)
      (nov-goto-document 2)
      (org-remark-koreader-import)
      (should-not (seq-find (lambda (ov)
                              (and (overlay-get ov 'org-remark-id)
                                   (= (overlay-start ov) (overlay-end ov))
                                   (= (overlay-start ov) (point-min))))
                            (overlays-in (point-min) (point-max)))))))

(provide 'org-remark-koreader-epub-tests)
;;; org-remark-koreader-epub-tests.el ends here
