;;; org-remark-koreader-dom-tests.el --- Tests for the reconstructed DOM  -*- lexical-binding: t; -*-

;; Running them:
;;
;;     emacs --batch -Q -L . -l ert -l test/org-remark-koreader-dom-tests.el \
;;           -f ert-run-tests-batch-and-exit 2>&1 | grep -E '^Ran |FAILED'

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-remark-koreader-dom)
(require 'org-remark-koreader-model)
(require 'org-remark-koreader-match)

(defmacro org-remark-koreader-dom-tests--with (text &rest body)
  "Build the DOM of TEXT and run BODY with `dom' bound."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (let ((dom (org-remark-koreader-dom-parse)))
       (ignore dom)
       ,@body)))

(defmacro org-remark-koreader-dom-tests--with-plain (text &rest body)
  "Build the plain-text tree of TEXT and run BODY with `dom' bound."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,text)
     (let ((dom (org-remark-koreader-dom-parse-plain)))
       (ignore dom)
       ,@body)))

(defun org-remark-koreader-dom-tests--at (dom path offset)
  "Return the character at PATH and OFFSET in DOM."
  (let ((position (org-remark-koreader-dom-resolve dom path offset)))
    (and position (buffer-substring-no-properties position (1+ position)))))

;;;; Blocks and numbering

(ert-deftest org-remark-koreader-dom/paragraphs-are-numbered ()
  "Paragraphs get an index under body, headings an element name of their own."
  (org-remark-koreader-dom-tests--with
      "# Kop\n\nEerste alinea.\n\nTweede alinea.\n"
    (should (member "/html/body/h1/text()" (org-remark-koreader-dom-paths dom)))
    (should (member "/html/body/p[1]/text()" (org-remark-koreader-dom-paths dom)))
    (should (member "/html/body/p[2]/text()" (org-remark-koreader-dom-paths dom)))))

(ert-deftest org-remark-koreader-dom/index-absent-for-a-unique-element ()
  "An element unique among its siblings gets no index.
That is the form the stored paths use; with an index in it not one path
would be found."
  (org-remark-koreader-dom-tests--with "Only paragraph.\n"
    (should (member "/html/body/p/text()" (org-remark-koreader-dom-paths dom)))
    (should-not (member "/html/body/p[1]/text()"
                        (org-remark-koreader-dom-paths dom)))))

(ert-deftest org-remark-koreader-dom/lists-are-numbered ()
  "Lists are numbered across the whole document."
  (org-remark-koreader-dom-tests--with
      "* een\n* twee\n\nTussentekst.\n\n* drie\n"
    (should (member "/html/body/ul[1]/li[1]/text()"
                    (org-remark-koreader-dom-paths dom)))
    (should (member "/html/body/ul[1]/li[2]/text()"
                    (org-remark-koreader-dom-paths dom)))
    (should (member "/html/body/ul[2]/li/text()"
                    (org-remark-koreader-dom-paths dom)))))

(ert-deftest org-remark-koreader-dom/loose-list-gets-a-paragraph-in-its-item ()
  "A list with blank lines between its items gets a `p' inside every `li'.
The difference appears literally in the paths and decides whether a
path is found."
  (org-remark-koreader-dom-tests--with "* one\n\n* two\n"
    (should (member "/html/body/ul/li[1]/p/text()"
                    (org-remark-koreader-dom-paths dom))))
  (org-remark-koreader-dom-tests--with "* one\n* two\n"
    (should (member "/html/body/ul/li[1]/text()"
                    (org-remark-koreader-dom-paths dom)))))

;;;; Inline

(ert-deftest org-remark-koreader-dom/inline-splits-text-nodes ()
  "Markup inside a paragraph yields numbered text nodes."
  (org-remark-koreader-dom-tests--with "voor **vet** na\n"
    (should (member "/html/body/p/text()[1]" (org-remark-koreader-dom-paths dom)))
    (should (member "/html/body/p/strong/text()"
                    (org-remark-koreader-dom-paths dom)))
    (should (member "/html/body/p/text()[2]"
                    (org-remark-koreader-dom-paths dom)))))

(ert-deftest org-remark-koreader-dom/emphasis-and-strong-differ ()
  "One asterisk is emphasis, two is strong."
  (org-remark-koreader-dom-tests--with "een *nadruk* en **sterk** hier\n"
    (should (member "/html/body/p/em/text()" (org-remark-koreader-dom-paths dom)))
    (should (member "/html/body/p/strong/text()"
                    (org-remark-koreader-dom-paths dom)))))

(ert-deftest org-remark-koreader-dom/several-emphases-are-numbered ()
  "Two emphases in the same paragraph get em[1] and em[2]."
  (org-remark-koreader-dom-tests--with "*een* tussen *twee*\n"
    (should (member "/html/body/p/em[1]/text()"
                    (org-remark-koreader-dom-paths dom)))
    (should (member "/html/body/p/em[2]/text()"
                    (org-remark-koreader-dom-paths dom)))))

(ert-deftest org-remark-koreader-dom/a-link-yields-an-a ()
  "The text of a link sits under `a'; the address does not count."
  (org-remark-koreader-dom-tests--with "Lees [de passage](https://x) goed\n"
    (should (member "/html/body/p/a/text()" (org-remark-koreader-dom-paths dom)))
    (should (equal (org-remark-koreader-dom-tests--at dom "/html/body/p/a/text()" 0)
                   "d"))))

;;;; Whitespace

(ert-deftest org-remark-koreader-dom/whitespace-is-collapsed ()
  "A run of whitespace counts as one character.

The offsets in the sidecar count in the rendered text, in which HTML
turns every run of spaces, tabs and newlines into a single space.
Without this every position after such a run would shift by a
character."
  (org-remark-koreader-dom-tests--with "aaa   bbb\n"
    (let ((node (gethash "/html/body/p/text()"
                         (org-remark-koreader-dom-nodes dom))))
      (should (equal (org-remark-koreader-dom-node-text node) "aaa bbb"))))
  ;; A newline inside a paragraph counts as one space.
  (org-remark-koreader-dom-tests--with "regel een\nregel twee\n"
    (let ((node (gethash "/html/body/p/text()"
                         (org-remark-koreader-dom-nodes dom))))
      (should (equal (org-remark-koreader-dom-node-text node)
                     "regel een regel twee"))))
  ;; Een spatie vóór het regeleinde is samen met dat regeleinde één spatie.
  ;; Dit is het gemeten geval waarin bron en gerenderde tekst uiteenlopen.
  (org-remark-koreader-dom-tests--with "regel een \nregel twee\n"
    (let ((node (gethash "/html/body/p/text()"
                         (org-remark-koreader-dom-nodes dom))))
      (should (equal (org-remark-koreader-dom-node-text node)
                     "regel een regel twee")))))

(ert-deftest org-remark-koreader-dom/offset-points-at-the-right-source-position ()
  "After collapsed whitespace the mapping to the source still holds."
  (org-remark-koreader-dom-tests--with "aaa   bbb\n"
    ;; Gerenderd "aaa bbb": index 4 is de `b'.
    (should (equal (org-remark-koreader-dom-tests--at dom "/html/body/p/text()" 4)
                   "b"))
    ;; Index 3 is de spatie; die beeldt af op het eerste witruimteteken.
    (should (equal (org-remark-koreader-dom-tests--at dom "/html/body/p/text()" 3)
                   " "))))

;;;; Ranges across nodes

(ert-deftest org-remark-koreader-dom/range-within-a-block-runs-on ()
  "Text running across inline markup is joined seamlessly."
  (org-remark-koreader-dom-tests--with "voor **vet** na\n"
    (should (equal (org-remark-koreader-dom-range-text
                    dom "/html/body/p/text()[1]" 0 "/html/body/p/text()[2]" 3)
                   "voor vet na"))))

(ert-deftest org-remark-koreader-dom/range-across-a-block-gets-a-newline ()
  "Across a block boundary comes a newline, and the whitespace before it goes."
  (org-remark-koreader-dom-tests--with "* een \n* twee\n"
    (should (equal (org-remark-koreader-dom-range-text
                    dom "/html/body/ul/li[1]/text()" 0
                    "/html/body/ul/li[2]/text()" 4)
                   "een\ntwee"))))

(ert-deftest org-remark-koreader-dom/range-yields-source-positions ()
  "A range yields a start and end position in the source."
  (org-remark-koreader-dom-tests--with "voor **vet** na\n"
    (let ((range (org-remark-koreader-dom-resolve-range
                  dom "/html/body/p/text()[1]" 0 "/html/body/p/text()[2]" 3)))
      (should range)
      (should (equal (buffer-substring-no-properties (car range) (cdr range))
                     "voor **vet** na")))))

;;;; What is not there is not guessed at

(ert-deftest org-remark-koreader-dom/unknown-path-yields-nil ()
  "A path that does not exist yields nil, not the nearest place.
A path that does not fit means the tree differs from what the renderer
saw; every position is a guess then."
  (org-remark-koreader-dom-tests--with "Only paragraph.\n"
    (should-not (org-remark-koreader-dom-resolve dom "/html/body/p[9]/text()" 0))
    (should-not (org-remark-koreader-dom-resolve dom "/html/body/p/text()" 999))))

(ert-deftest org-remark-koreader-dom/states-its-own-limitation ()
  "A construct that is not modelled is recorded, not passed over.
A blank quoted line starts a second paragraph inside the same block
quote; that tree is deeper than what is reconstructed here."
  (org-remark-koreader-dom-tests--with "> first paragraph\n>\n> second paragraph\n"
    (should (org-remark-koreader-dom-unsupported dom))))

(ert-deftest org-remark-koreader-dom/quote-across-two-lines-is-one-text-node ()
  "Two quoted lines form one text node, without the quote markers.

That is how it sits in the sidecar too: one path with an offset range
running across both lines."
  (org-remark-koreader-dom-tests--with "> first line\n> second line\n"
    (should-not (org-remark-koreader-dom-unsupported dom))
    (let ((node (gethash "/html/body/blockquote/p/text()"
                         (org-remark-koreader-dom-nodes dom))))
      (should node)
      (should (equal (org-remark-koreader-dom-node-text node)
                     "first line second line"))
      ;; The character after the space is the `s' of "second" — the `> '
      ;; between them does not count.
      (should (equal (char-after (org-remark-koreader-dom-resolve
                                  dom "/html/body/blockquote/p/text()" 11))
                     ?s)))))

(ert-deftest org-remark-koreader-dom/inline-code-is-an-element-of-its-own ()
  "Backticks yield one `code' element, and the markup inside does not count.

Underscores in a name like `resolve_text_range' are not italics."
  (org-remark-koreader-dom-tests--with
      "The function `resolve_text_range` works here.\n"
    (should (equal (org-remark-koreader-dom-paths dom)
                   '("/html/body/p/code/text()"
                     "/html/body/p/text()[1]"
                     "/html/body/p/text()[2]")))
    (should (equal (org-remark-koreader-dom-node-text
                    (gethash "/html/body/p/code/text()"
                             (org-remark-koreader-dom-nodes dom)))
                   "resolve_text_range"))))

;;;; Plain text

(ert-deftest org-remark-koreader-dom/plain-text-numbers-non-blank-lines ()
  "Every non-blank line is a `pre'; blank lines do not count.

Without that every blank line would shift the numbering and not one
path after the first would still fit."
  (org-remark-koreader-dom-tests--with-plain
      "first line\n\n\n\nsecond line\n\nthird line\n"
    (should (equal (org-remark-koreader-dom-paths dom)
                   '("/FictionBook/body/pre[1]/text()"
                     "/FictionBook/body/pre[2]/text()"
                     "/FictionBook/body/pre[3]/text()")))
    (should (equal (org-remark-koreader-dom-node-text
                    (gethash "/FictionBook/body/pre[2]/text()"
                             (org-remark-koreader-dom-nodes dom)))
                   "second line"))))

(ert-deftest org-remark-koreader-dom/plain-text-counts-offsets-untouched ()
  "In a `pre' the offsets count the source, not the collapsed text.

Measured against the fixture: a line with three spaces in a row has an
offset range that counts all three, while the stored text keeps one."
  (org-remark-koreader-dom-tests--with-plain "Multiple   spaces stay visible.\n"
    (let ((path "/FictionBook/body/pre/text()"))
      ;; 31 characters in the source, and offset 31 is the place after the
      ;; last one.
      (should (org-remark-koreader-dom-resolve dom path 31))
      (should-not (org-remark-koreader-dom-resolve dom path 32))
      ;; The rendered text of that range is collapsed: that is what sits in
      ;; the sidecar.
      (should (equal (org-remark-koreader-dom-range-text dom path 0 path 31)
                     "Multiple spaces stay visible.")))))

(ert-deftest org-remark-koreader-dom/plain-text-joins-lines-without-indentation ()
  "Across a line boundary comes a newline, without the indentation.

Two indented code lines yield one text in the sidecar with a newline
between them and no spaces around it."
  (org-remark-koreader-dom-tests--with-plain
      "    four space code\n    second code line\n"
    (should (equal (org-remark-koreader-dom-range-text
                    dom "/FictionBook/body/pre[1]/text()" 4
                    "/FictionBook/body/pre[2]/text()" 20)
                   "four space code\nsecond code line"))))

(ert-deftest org-remark-koreader-dom/plain-text-reads-no-markup ()
  "A `#' or `*' in plain text is a character, not markup."
  (org-remark-koreader-dom-tests--with-plain "# no heading with *no* emphasis\n"
    (should (equal (org-remark-koreader-dom-paths dom)
                   '("/FictionBook/body/pre/text()")))
    (should (equal (org-remark-koreader-dom-node-text
                    (gethash "/FictionBook/body/pre/text()"
                             (org-remark-koreader-dom-nodes dom)))
                   "# no heading with *no* emphasis"))))

(ert-deftest org-remark-koreader-dom/tree-choice-follows-the-xpointer ()
  "The sidecar says itself which tree KOReader built."
  (with-temp-buffer
    (insert "one line\n")
    (should (equal (org-remark-koreader-dom-paths
                    (org-remark-koreader-match-build-dom-for-pointers
                     '("/FictionBook/body/pre/text().0")))
                   '("/FictionBook/body/pre/text()")))
    (should (equal (org-remark-koreader-dom-paths
                    (org-remark-koreader-match-build-dom-for-pointers
                     '("/html/body/p/text().0")))
                   '("/html/body/p/text()")))
    ;; Without an indication it stays the Markdown tree: that is the family
    ;; this package was measured against.
    (should (equal (org-remark-koreader-dom-paths
                    (org-remark-koreader-match-build-dom-for-pointers '(nil)))
                   '("/html/body/p/text()")))))

;;;; Aligning the range with the stored text

(ert-deftest org-remark-koreader-dom/alignment-recognises-trimmed-edges ()
  "KOReader trims the stored text but not the offsets.
A selection that began on a space therefore yields a range one
character longer than the text."
  (should (equal (org-remark-koreader-match--align "text" "text") '(0 . 0)))
  (should (equal (org-remark-koreader-match--align " text" "text") '(1 . 0)))
  (should (equal (org-remark-koreader-match--align "text " "text") '(0 . 1)))
  (should-not (org-remark-koreader-match--align "other text" "text")))

(provide 'org-remark-koreader-dom-tests)
;;; org-remark-koreader-dom-tests.el ends here
