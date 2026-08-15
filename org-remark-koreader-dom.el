;;; org-remark-koreader-dom.el --- The source as a CRengine DOM  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 jajpater

;; Author: jajpater
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Reconstructs, from the source file, the document structure KOReader sees,
;; and uses it to resolve an XPointer to a buffer position.
;;
;; KOReader renders Markdown to HTML and addresses annotations with paths such
;; as `/html/body/p[2]/text()[3].151' — the third text node in the second
;; paragraph, character 151.  Translating such a path back to a place in the
;; source file means rebuilding the same tree here, inline elements included:
;; those split a paragraph into several text nodes.
;;
;; Two properties were established empirically and drive the design.
;;
;; Text nodes carry *collapsed* whitespace.  HTML turns every run of spaces,
;; tabs and newlines into a single space, and the offsets count in that
;; collapsed text.  Two source characters can therefore be one counted
;; character.  Each text node consequently keeps a mapping from counted
;; character to source position, rather than computing with a fixed shift.
;;
;; An index is absent from the path when the element is unique among its
;; siblings: `/html/body/ol/li[2]' with one list, `ol[2]' with more.
;;
;; What this reader does not model, it reports.  A construct it does not know
;; makes the whole document suspect, because it shifts the numbering of
;; everything after it; a path that no longer fits would otherwise silently
;; point at the wrong place.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(cl-defstruct (org-remark-koreader-dom-node
               (:constructor org-remark-koreader-dom-node-create)
               (:copier nil))
  "A node in the reconstructed DOM.

TAG is the HTML element name as a symbol, or `text' for a text node.
BEG and END are the source range.

For text nodes: TEXT is the collapsed content as the renderer counts
it, and MAP is a vector mapping every index in TEXT to a source
position.  MAP has one element more than TEXT is long, so that the
position after the last character is known too.

VERBATIM says that this node's offsets count the source untouched
rather than the collapsed text.  That holds inside a `pre'.

RANGES is the list of source ranges the text was built from.  Usually
there is one, and then it says no more than BEG and END do.  In a block
quote there is one per line: the text runs on across the line break,
but the quote marker at the start of each following line is not part of
it."
  tag children beg end text map block ranges verbatim)

(cl-defstruct (org-remark-koreader-dom
               (:constructor org-remark-koreader-dom--create)
               (:copier nil))
  "A reconstructed document.

NODES is a hash table from path to text node.  ORDERED is the same
collection as a list of (PATH . NODE) in document order.  UNSUPPORTED
holds the constructs that are not modelled, as (LINE . DESCRIPTION)."
  root nodes ordered unsupported)

(defconst org-remark-koreader-dom-block-tags
  '(p h1 h2 h3 h4 h5 h6 li blockquote pre hr)
  "Elements that form a block of their own.

The distinction matters when joining text across several nodes: inside
one block the text runs on seamlessly, across a block boundary a
newline appears between them.")

;;;; Witruimte

(defconst org-remark-koreader-dom--space-chars '(?\s ?\t ?\n ?\r ?\f)
  "Characters the renderer counts as whitespace.")

(defun org-remark-koreader-dom--collapse-ranges (ranges)
  "Return the collapsed text of RANGES, a list of (BEGIN . END).

Returns a cons (TEXT . MAP).  Every run of whitespace becomes a single
space, mapped to the position of the first whitespace character; every
other character maps to itself.  This is what the HTML renderer does to
the text, and it is why offsets cannot be traced back to the source
with a fixed shift.

The transition from one range to the next counts as whitespace itself,
at the position where the previous range ends.  Whatever sits between
those two ranges in the source is not part of the text."
  (let ((chars nil)
        (positions nil)
        (space nil)                     ; open whitespace run: position or nil
        (last nil))
    (dolist (range ranges)
      (let ((point (car range))
            (end (cdr range)))
        (when (and last (not space)) (setq space last))
        (while (< point end)
          (let ((char (char-after point)))
            (if (memq char org-remark-koreader-dom--space-chars)
                (unless space (setq space point))
              (when space
                (push ?\s chars)
                (push space positions)
                (setq space nil))
              (push char chars)
              (push point positions)))
          (setq point (1+ point)))
        (setq last end)))
    ;; Trailing whitespace does belong: the renderer collapses it, it does
    ;; not make it disappear.
    (when space
      (push ?\s chars)
      (push space positions))
    (push (or last (car (car ranges))) positions)
    (cons (concat (nreverse chars))
          (vconcat (nreverse positions)))))

(defun org-remark-koreader-dom--collapse (beg end)
  "Return the collapsed text of the source range BEG to END."
  (org-remark-koreader-dom--collapse-ranges (list (cons beg end))))

(defun org-remark-koreader-dom--collapse-string (string)
  "Collapse every run of whitespace in STRING to a single space.

For text out of a `pre': there the offsets count the source untouched
while the stored text has been collapsed.  A no-break space (U+00A0)
does not take part — it survives in the stored text."
  (replace-regexp-in-string "[ \t\n\r\f]+" " " string))

;;;; Blokken

(defconst org-remark-koreader-dom--heading-rx
  "^\\(#\\{1,6\\}\\)[ \t]+\\(.*?\\)[ \t]*$"
  "An ATX heading.")

(defconst org-remark-koreader-dom--thematic-rx
  "^[ \t]*\\(\\*[ \t]*\\*[ \t]*\\*[ \t*]*\\|-[ \t]*-[ \t]*-[ \t-]*\\|_[ \t]*_[ \t]*_[ \t_]*\\)$"
  "A thematic break.")

(defconst org-remark-koreader-dom--bullet-rx
  "^\\([ \t]*\\)\\([*+-]\\)[ \t]+"
  "The bullet of an unordered list.")

(defconst org-remark-koreader-dom--ordered-rx
  "^\\([ \t]*\\)\\([0-9]+\\)[.)][ \t]+"
  "The number of an ordered list.")

(defconst org-remark-koreader-dom--fence-rx
  "^[ \t]*\\(```\\|~~~\\)"
  "The start or end of a fenced code block.")

(defun org-remark-koreader-dom--blank-line-p ()
  "Return non-nil when the current line is blank."
  (looking-at-p "^[ \t]*$"))

(defun org-remark-koreader-dom--block-start-p ()
  "Return non-nil when a new block starts on this line."
  (or (org-remark-koreader-dom--blank-line-p)
      (looking-at-p org-remark-koreader-dom--heading-rx)
      (looking-at-p org-remark-koreader-dom--thematic-rx)
      (looking-at-p org-remark-koreader-dom--bullet-rx)
      (looking-at-p org-remark-koreader-dom--ordered-rx)
      (looking-at-p org-remark-koreader-dom--fence-rx)
      (looking-at-p "^[ \t]*>")))

(defvar org-remark-koreader-dom--unsupported nil
  "Constructs collected during parsing that are not modelled.")

(defun org-remark-koreader-dom--unsupported (description)
  "Record that DESCRIPTION on this line is not modelled."
  (push (cons (line-number-at-pos) description)
        org-remark-koreader-dom--unsupported))

(defun org-remark-koreader-dom--parse-blocks (end)
  "Parse blocks from point up to END and return them as a list."
  (let ((blocks nil))
    (while (< (point) end)
      (cond
       ((org-remark-koreader-dom--blank-line-p)
        (forward-line 1))
       ((looking-at org-remark-koreader-dom--heading-rx)
        (let ((level (length (match-string 1)))
              (beg (match-beginning 2))
              (stop (match-end 2)))
          (forward-line 1)
          (push (org-remark-koreader-dom-node-create
                 :tag (intern (format "h%d" level))
                 :beg beg :end stop
                 :children (org-remark-koreader-dom--parse-inline beg stop))
                blocks)))
       ((looking-at-p org-remark-koreader-dom--thematic-rx)
        (push (org-remark-koreader-dom-node-create
               :tag 'hr :beg (point) :end (line-end-position))
              blocks)
        (forward-line 1))
       ((looking-at-p org-remark-koreader-dom--fence-rx)
        (push (org-remark-koreader-dom--parse-fence end) blocks))
       ((looking-at-p "^[ \t]*>")
        (push (org-remark-koreader-dom--parse-blockquote end) blocks))
       ((or (looking-at-p org-remark-koreader-dom--bullet-rx)
            (looking-at-p org-remark-koreader-dom--ordered-rx))
        (push (org-remark-koreader-dom--parse-list end) blocks))
       (t
        (push (org-remark-koreader-dom--parse-paragraph end) blocks))))
    (nreverse blocks)))

(defun org-remark-koreader-dom--parse-paragraph (end)
  "Parse a paragraph from point, at most up to END."
  (let ((beg (point)))
    (forward-line 1)
    (while (and (< (point) end)
                (not (org-remark-koreader-dom--block-start-p)))
      (forward-line 1))
    (let ((stop (save-excursion
                  (goto-char (point))
                  (skip-chars-backward " \t\n")
                  (point))))
      (org-remark-koreader-dom-node-create
       :tag 'p :beg beg :end stop
       :children (org-remark-koreader-dom--parse-inline beg stop)))))

(defun org-remark-koreader-dom--parse-fence (end)
  "Parse a fenced code block from point, at most up to END."
  (let ((beg (point)))
    (forward-line 1)
    (while (and (< (point) end)
                (not (looking-at-p org-remark-koreader-dom--fence-rx)))
      (forward-line 1))
    (when (< (point) end) (forward-line 1))
    ;; The contents of a fenced block are one text node under `pre'.  What
    ;; CRengine does with whitespace there has not been measured, so the
    ;; contents are not offered as addressable.
    (org-remark-koreader-dom-node-create :tag 'pre :beg beg :end (point))))

(defun org-remark-koreader-dom--parse-blockquote (end)
  "Parse a block quote from point, at most up to END."
  (let ((beg (point))
        (lines nil))
    (while (and (< (point) end) (looking-at "^[ \t]*>[ \t]?"))
      (push (cons (match-end 0) (line-end-position)) lines)
      (forward-line 1))
    ;; The lines of the quote together form one paragraph: the text runs on
    ;; across the line break, and the quote marker is not part of it.  Each
    ;; line is therefore parsed separately and joined afterwards, so that the
    ;; quote markers fall outside the text nodes.
    ;;
    ;; A blank quoted line starts a second paragraph inside the same block
    ;; quote.  That yields a deeper tree than is reconstructed here.
    (let ((lines (nreverse lines)))
      (when (seq-some (lambda (line) (= (car line) (cdr line))) lines)
        (org-remark-koreader-dom--unsupported
         "block quote with several paragraphs modelled as one paragraph"))
      (let ((content-beg (car (car lines)))
            (content-end (cdr (car (last lines)))))
        (org-remark-koreader-dom-node-create
         :tag 'blockquote :beg beg :end (point)
         :children
         (list (org-remark-koreader-dom-node-create
                :tag 'p :beg content-beg :end content-end
                :children
                (org-remark-koreader-dom--merge-text
                 (mapcan (lambda (line)
                           (org-remark-koreader-dom--parse-inline
                            (car line) (cdr line)))
                         lines)))))))))

;;;; Lijsten

(defun org-remark-koreader-dom--list-marker ()
  "Return (KIND . INDENT) for the list marker on this line, or nil."
  (cond
   ((looking-at org-remark-koreader-dom--bullet-rx)
    (cons 'ul (length (match-string 1))))
   ((looking-at org-remark-koreader-dom--ordered-rx)
    (cons 'ol (length (match-string 1))))))

(defun org-remark-koreader-dom--parse-list (end)
  "Parse a list from point, at most up to END."
  (let* ((marker (org-remark-koreader-dom--list-marker))
         (kind (car marker))
         (indent (cdr marker))
         (beg (point))
         (items nil)
         (loose nil)
         (done nil))
    (while (and (not done) (< (point) end))
      (cond
       ((org-remark-koreader-dom--blank-line-p)
        ;; A blank line inside the list makes it loose; after the list it is
        ;; just a separator.  Which of the two shows from what follows.
        (let ((restart (save-excursion
                         (forward-line 1)
                         (while (and (< (point) end)
                                     (org-remark-koreader-dom--blank-line-p))
                           (forward-line 1))
                         (and (< (point) end)
                              (equal (org-remark-koreader-dom--list-marker)
                                     marker)
                              (point)))))
          (if restart
              (progn (setq loose t) (goto-char restart))
            (setq done t))))
       ((equal (org-remark-koreader-dom--list-marker) marker)
        (push (org-remark-koreader-dom--parse-list-item end indent) items))
       ((let ((here (org-remark-koreader-dom--list-marker)))
          (and here (> (cdr here) indent)))
        ;; A more deeply indented list belongs to the previous item, which
        ;; already absorbed it.  If one turns up here anyway, the nesting does
        ;; not match what the item consumed.
        (org-remark-koreader-dom--unsupported
         "nested list in an unexpected place")
        (setq done t))
       (t (setq done t))))
    (org-remark-koreader-dom-node-create
     :tag kind :beg beg :end (point)
     :children (org-remark-koreader-dom--finish-items (nreverse items) loose))))

(defun org-remark-koreader-dom--finish-items (items loose)
  "Return ITEMS, wrapped in a paragraph when LOOSE.

In HTML a list with blank lines between its items gets a `p' inside
every `li'; a tight list does not.  That difference appears literally in
the paths — `li[2]/p/text()' against `li[2]/text()' — and therefore
decides whether a path is found at all."
  (mapcar
   (lambda (item)
     (if (not loose)
         item
       (let* ((children (org-remark-koreader-dom-node-children item))
              (inline (seq-take-while
                       (lambda (node)
                         (memq (org-remark-koreader-dom-node-tag node)
                               '(text em strong code a)))
                       children))
              (rest (seq-drop children (length inline))))
         (setf (org-remark-koreader-dom-node-children item)
               (cons (org-remark-koreader-dom-node-create
                      :tag 'p
                      :beg (org-remark-koreader-dom-node-beg item)
                      :end (org-remark-koreader-dom-node-end item)
                      :children inline)
                     rest))
         item)))
   items))

(defun org-remark-koreader-dom--parse-list-item (end indent)
  "Parse one list item from point, at most up to END.
INDENT is the indentation of the list marker."
  (looking-at (if (eq (car (org-remark-koreader-dom--list-marker)) 'ul)
                  org-remark-koreader-dom--bullet-rx
                org-remark-koreader-dom--ordered-rx))
  (let ((beg (match-end 0))
        (item-start (point))
        (nested nil))
    (forward-line 1)
    ;; Continuation lines belong to this item as long as they do not start a
    ;; new block.  A more deeply indented marker starts a nested list.
    (let ((content-end (line-end-position 0))
          (stop nil))
      (while (and (not stop) (< (point) end))
        (let ((marker (org-remark-koreader-dom--list-marker)))
          (cond
           ((org-remark-koreader-dom--blank-line-p) (setq stop t))
           ((and marker (> (cdr marker) indent))
            (setq nested (org-remark-koreader-dom--parse-list end))
            (setq stop t))
           ((or marker (org-remark-koreader-dom--block-start-p)) (setq stop t))
           (t (setq content-end (line-end-position))
              (forward-line 1)))))
      (org-remark-koreader-dom-node-create
       :tag 'li :beg item-start :end (point)
       :children (append (org-remark-koreader-dom--parse-inline beg content-end)
                         (when nested (list nested)))))))

;;;; Inline

(defconst org-remark-koreader-dom--inline-rx
  (concat "\\(\\*\\*\\|__\\)"                       ; 1: strong
          "\\|\\(\\*\\|_\\)"                        ; 2: emphasis
          "\\|\\(`+\\)"                             ; 3: code
          "\\|\\(\\[\\)")                           ; 4: link
  "Where an inline element may begin.")

(defun org-remark-koreader-dom--parse-inline (beg end)
  "Parse the inline range BEG to END and return the nodes."
  (let ((nodes nil)
        (point beg))
    (save-excursion
      (while (< point end)
        (goto-char point)
        (if (not (re-search-forward org-remark-koreader-dom--inline-rx end :noerror))
            (progn (push (org-remark-koreader-dom--text-node point end) nodes)
                   (setq point end))
          (let* ((start (match-beginning 0))
                 (node (org-remark-koreader-dom--parse-inline-element start end)))
            (cond
             (node
              (when (> start point)
                (push (org-remark-koreader-dom--text-node point start) nodes))
              (push node nodes)
              (setq point (org-remark-koreader-dom-node-end node)))
             (t
              ;; Not a valid element: the character is ordinary text.  Step
              ;; one character on so the search makes progress.
              (setq point (max (1+ start) point))
              (when (>= point end)
                (push (org-remark-koreader-dom--text-node
                       (min start end) end)
                      nodes))))))))
    ;; Merge adjacent text: two text nodes side by side do not exist in the
    ;; DOM, and would spoil the numbering of `text()[N]'.
    (org-remark-koreader-dom--merge-text (nreverse nodes))))

(defun org-remark-koreader-dom--merge-text (nodes)
  "Merge consecutive text nodes in NODES.

Two text nodes side by side do not exist in the DOM — there is always
an element between them — so consecutive text ought to be one node.
That holds even when the two are not adjacent in the source: in a block
quote there is a quote marker between them that does not count."
  (let ((out nil))
    (dolist (node nodes)
      (let ((previous (car out)))
        (if (and previous
                 (eq (org-remark-koreader-dom-node-tag previous) 'text)
                 (eq (org-remark-koreader-dom-node-tag node) 'text))
            (setcar out (org-remark-koreader-dom--text-node-from-ranges
                         (append (org-remark-koreader-dom-node-ranges previous)
                                 (org-remark-koreader-dom-node-ranges node))))
          (push node out))))
    (nreverse out)))

(defun org-remark-koreader-dom--text-node (beg end)
  "Make a text node for the source range BEG to END."
  (org-remark-koreader-dom--text-node-from-ranges (list (cons beg end))))

(defun org-remark-koreader-dom--verbatim-text-node (beg end)
  "Make a text node that reproduces the source untouched.

Inside a `pre' the offsets from the sidecar count the characters as
they stand in the source, including runs of several spaces.  The
mapping from offset to source position is therefore the identity.  That
the stored text has been collapsed is settled when comparing, not here:
the offsets are the anchor, the text is the check."
  (org-remark-koreader-dom-node-create
   :tag 'text :beg beg :end end
   :ranges (list (cons beg end))
   :verbatim t
   :text (buffer-substring-no-properties beg end)
   :map (vconcat (number-sequence beg end))))

(defun org-remark-koreader-dom--text-node-from-ranges (ranges)
  "Make one text node out of RANGES, a list of (BEGIN . END)."
  (let ((collapsed (org-remark-koreader-dom--collapse-ranges ranges)))
    (org-remark-koreader-dom-node-create
     :tag 'text
     :beg (car (car ranges))
     :end (cdr (car (last ranges)))
     :ranges ranges
     :text (car collapsed) :map (cdr collapsed))))

(defun org-remark-koreader-dom--parse-inline-element (start limit)
  "Try to read an inline element at START, not beyond LIMIT."
  (save-excursion
    (goto-char start)
    (cond
     ;; Code takes precedence: inside backticks no other markup counts.
     ((looking-at "\\(`+\\)")
      (let* ((fence (match-string 1))
             (inner (match-end 0)))
        ;; Search from after the opening fence.  `looking-at' does not move
        ;; point, so without this the search finds that same fence again.
        (goto-char inner)
        (when (search-forward fence limit :noerror)
          (org-remark-koreader-dom-node-create
           :tag 'code :beg start :end (point)
           :children (list (org-remark-koreader-dom--text-node
                            inner (match-beginning 0)))))))
     ((looking-at "\\(\\*\\*\\|__\\)")
      (org-remark-koreader-dom--parse-delimited start limit (match-string 1) 'strong))
     ((looking-at "\\([*_]\\)")
      (org-remark-koreader-dom--parse-delimited start limit (match-string 1) 'em))
     ((eq (char-after start) ?\[)
      (org-remark-koreader-dom--parse-link start limit)))))

(defun org-remark-koreader-dom--parse-delimited (start limit delimiter tag)
  "Read an element with TAG between DELIMITER from START, not beyond LIMIT."
  (save-excursion
    (let ((inner (+ start (length delimiter))))
      (goto-char inner)
      ;; An opening marker followed straight away by whitespace is not
      ;; markup.
      (unless (or (>= inner limit)
                  (memq (char-after inner) '(?\s ?\t ?\n)))
        (when (search-forward delimiter limit :noerror)
          (let ((close (match-beginning 0)))
            (when (> close inner)
              (org-remark-koreader-dom-node-create
               :tag tag :beg start :end (point)
               :children (org-remark-koreader-dom--parse-inline inner close)))))))))

(defun org-remark-koreader-dom--parse-link (start limit)
  "Read a link from START, not beyond LIMIT."
  (save-excursion
    (goto-char start)
    (when (looking-at "\\[\\([^]\n]*\\)\\](\\([^)\n]*\\))")
      (let ((end (match-end 0)))
        (when (<= end limit)
          (org-remark-koreader-dom-node-create
           :tag 'a :beg start :end end
           :children (org-remark-koreader-dom--parse-inline
                      (match-beginning 1) (match-end 1))))))))

;;;; Paden

(defun org-remark-koreader-dom--child-path (parent-path children)
  "Return a list of (PATH . NODE) for CHILDREN under PARENT-PATH.

An index is absent when the element is unique among its siblings — that
is the form the stored paths use."
  (let ((counts (make-hash-table :test 'eq))
        (seen (make-hash-table :test 'eq))
        (out nil))
    (dolist (node children)
      (let ((tag (org-remark-koreader-dom-node-tag node)))
        (puthash tag (1+ (gethash tag counts 0)) counts)))
    (dolist (node children)
      (let* ((tag (org-remark-koreader-dom-node-tag node))
             (index (puthash tag (1+ (gethash tag seen 0)) seen))
             (name (if (eq tag 'text) "text()" (symbol-name tag)))
             (path (if (= (gethash tag counts) 1)
                       (format "%s/%s" parent-path name)
                     (format "%s/%s[%d]" parent-path name index))))
        (push (cons path node) out)))
    (nreverse out)))

(defun org-remark-koreader-dom--collect (parent-path children table block)
  "Collect text nodes under CHILDREN into TABLE, below PARENT-PATH.
BLOCK is the path of the enclosing block element."
  (pcase-dolist (`(,path . ,node) (org-remark-koreader-dom--child-path
                                   parent-path children))
    (if (eq (org-remark-koreader-dom-node-tag node) 'text)
        (progn (setf (org-remark-koreader-dom-node-block node) block)
               (puthash path node table))
      (org-remark-koreader-dom--collect
       path (org-remark-koreader-dom-node-children node) table
       (if (memq (org-remark-koreader-dom-node-tag node)
                 org-remark-koreader-dom-block-tags)
           path
         block)))))

;;;; Publieke ingang

(defun org-remark-koreader-dom--assemble (blocks root)
  "Make the document object from BLOCKS under path ROOT."
  (let ((table (make-hash-table :test 'equal))
        (ordered nil))
    (org-remark-koreader-dom--collect root blocks table nil)
    (maphash (lambda (path node) (push (cons path node) ordered)) table)
    (org-remark-koreader-dom--create
     :root blocks
     :nodes table
     :ordered (sort ordered
                    (lambda (a b)
                      (< (org-remark-koreader-dom-node-beg (cdr a))
                         (org-remark-koreader-dom-node-beg (cdr b)))))
     :unsupported (nreverse org-remark-koreader-dom--unsupported))))

(defun org-remark-koreader-dom-parse (&optional beg end)
  "Build the DOM of the current buffer, or of the range BEG to END.

This is the tree KOReader builds for a Markdown source; for plain text
that is `org-remark-koreader-dom-parse-plain'."
  (let ((beg (or beg (point-min)))
        (end (or end (point-max)))
        (org-remark-koreader-dom--unsupported nil))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char beg)
        (org-remark-koreader-dom--assemble
         (org-remark-koreader-dom--parse-blocks end) "/html/body")))))

(defun org-remark-koreader-dom-parse-plain (&optional beg end)
  "Build the tree of a plain-text source, or of the range BEG to END.

In KOReader a `.txt' does not take the HTML route but the FictionBook
route: every non-blank line becomes a `pre' element of its own,
numbered from one.  Blank lines get no element and therefore do not
count in that numbering.

Nothing on the line is interpreted.  A `#' is not a heading here and a
`*' is not emphasis: KOReader reads this file as text, and the tree
ought to do the same."
  (let ((beg (or beg (point-min)))
        (end (or end (point-max)))
        (org-remark-koreader-dom--unsupported nil))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char beg)
        (let ((blocks nil))
          (while (< (point) end)
            (let ((from (line-beginning-position))
                  (to (min end (line-end-position))))
              (unless (save-excursion
                        (goto-char from)
                        (looking-at-p "[ \t]*$"))
                (push (org-remark-koreader-dom-node-create
                       :tag 'pre :beg from :end to
                       :children
                       (list (org-remark-koreader-dom--verbatim-text-node
                              from to)))
                      blocks)))
            (forward-line 1))
          (org-remark-koreader-dom--assemble
           (nreverse blocks) "/FictionBook/body"))))))

(defun org-remark-koreader-dom-resolve (dom path offset)
  "Return the source position for PATH and OFFSET in DOM, or nil.

Nil means the path does not exist in the reconstructed tree, or the
offset falls outside it.  That is a more honest answer than the nearest
place: a path that does not fit means the tree differs from what the
renderer saw, and then every position is a guess."
  (when-let* ((node (gethash path (org-remark-koreader-dom-nodes dom)))
              (map (org-remark-koreader-dom-node-map node)))
    (when (and (>= offset 0) (< offset (length map)))
      (aref map offset))))

(defun org-remark-koreader-dom--node-index (dom path)
  "Return the place of PATH in DOM's document order, or nil."
  (seq-position (org-remark-koreader-dom-ordered dom) path
                (lambda (cell wanted) (equal (car cell) wanted))))

(defun org-remark-koreader-dom-range-text (dom path0 offset0 path1 offset1)
  "Return the rendered text between two XPointers in DOM, or nil.

The joining rule was measured, not chosen.  Text nodes within the same
block run on seamlessly — only inline markup stood between them, and
that takes up no room.  Across a block boundary comes a newline, and
the whitespace on either side of that boundary disappears: it belonged
to the source markup, not to the text.

Out of a `pre' the text comes untouched; there it is collapsed here
after all, because that is how it sits in the sidecar."
  (let ((from (org-remark-koreader-dom--node-index dom path0))
        (to (org-remark-koreader-dom--node-index dom path1)))
    (when (and from to (<= from to))
      (let ((pieces nil)
            (previous-block nil))
        (cl-loop
         for index from from to to
         for cell = (nth index (org-remark-koreader-dom-ordered dom))
         for node = (cdr cell)
         for text = (org-remark-koreader-dom-node-text node)
         for start = (if (= index from) (min offset0 (length text)) 0)
         for stop = (if (= index to) (min offset1 (length text)) (length text))
         do (let ((piece (let ((raw (substring text start stop)))
                           (if (org-remark-koreader-dom-node-verbatim node)
                               (org-remark-koreader-dom--collapse-string raw)
                             raw)))
                  (block (org-remark-koreader-dom-node-block node)))
              (when (and previous-block (not (equal block previous-block)))
                (push (string-trim-right (or (pop pieces) "")) pieces)
                (push "\n" pieces)
                (setq piece (string-trim-left piece)))
              (push piece pieces)
              (setq previous-block block)))
        (apply #'concat (nreverse pieces))))))

(defun org-remark-koreader-dom-resolve-range (dom path0 offset0 path1 offset1)
  "Return the source range (BEGIN . END) between two XPointers in DOM, or nil."
  (let ((beg (org-remark-koreader-dom-resolve dom path0 offset0))
        (end (org-remark-koreader-dom-resolve dom path1 offset1)))
    (when (and beg end (<= beg end))
      (cons beg end))))

(defun org-remark-koreader-dom-paths (dom)
  "Return every text-node path in DOM."
  (let ((paths nil))
    (maphash (lambda (path _node) (push path paths))
             (org-remark-koreader-dom-nodes dom))
    (sort paths #'string<)))

(provide 'org-remark-koreader-dom)
;;; org-remark-koreader-dom.el ends here
