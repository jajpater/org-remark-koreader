;;; org-remark-koreader-epub.el --- EPUB annotations in a nov buffer  -*- lexical-binding: t; -*-

;;; Commentary:

;; The EPUB family works differently from the other two, and more simply.
;;
;; For Markdown and plain text, KOReader and Emacs read the same file, and
;; CRengine's tree has to be reconstructed in order to translate an XPointer
;; into a source position.  For EPUB they both read the same XHTML, but Emacs
;; does not show that source: `nov-mode' shows what shr made of it.
;;
;; Reconstructing a tree makes no sense there — we would have to predict
;; another program's rendering.  What can be done follows from measurement:
;; the stored text appears verbatim in the nov buffer.  The XPointer is
;; therefore not the route to the position but the indication of which chapter
;; it is, and the text does the rest.
;;
;; That the chapter is fixed is a gain, not a limitation.  KOReader sees the
;; whole book as one DOM, so a sentence occurring twice yields two candidates
;; there.  In `nov-mode' one chapter sits in the buffer, and within it that
;; same sentence is often unambiguous.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'dom)
(require 'org-remark-koreader-model)
(require 'org-remark-koreader-match)

(declare-function nov-slurp "nov" (filename &optional parse-xml-p))
(declare-function nov-content-spine "nov" (content))
(defvar nov-documents)
(defvar nov-documents-index)
(defvar nov-content-file)

;;;; Recognising the family

(defconst org-remark-koreader-epub--root "/body/DocFragment"
  "Root of the tree KOReader builds for an EPUB.")

(defun org-remark-koreader-epub-marks-p (marks)
  "Return non-nil when MARKS come from an EPUB."
  (seq-some
   (lambda (mark)
     (seq-some (lambda (pointer)
                 (and pointer
                      (string-prefix-p org-remark-koreader-epub--root pointer)))
               (list (org-remark-koreader-mark-pos0 mark)
                     (org-remark-koreader-mark-page mark))))
   marks))

;;;; The spine document of a mark

(defun org-remark-koreader-epub-fragment (pointer)
  "Return the spine number from POINTER, one-based, or nil.

A book with a single content document yields `DocFragment' without an
index; that is number one, not number zero."
  (when (and pointer
             (string-match "DocFragment\\(?:\\[\\([0-9]+\\)\\]\\)?" pointer))
    (if (match-string 1 pointer)
        (string-to-number (match-string 1 pointer))
      1)))

(defun org-remark-koreader-epub--mark-fragment (mark)
  "Return the spine number of MARK, or nil."
  (org-remark-koreader-epub-fragment
   (or (org-remark-koreader-mark-pos0 mark)
       (org-remark-koreader-mark-page mark))))

(defun org-remark-koreader-epub--spine ()
  "Return the spine of the current book as a list of manifest ids."
  (when (and (boundp 'nov-content-file) nov-content-file)
    (org-remark-koreader-epub--spine-of
     (nov-slurp nov-content-file :parse-xml))))

(defun org-remark-koreader-epub--spine-of (content)
  "Return the spine from CONTENT."
  (nov-content-spine content))

(defun org-remark-koreader-epub-current-fragment ()
  "Return the spine number of the document now on screen, or nil.

Not derivable from `nov-documents-index' by arithmetic.  nov removes the
navigation document from the spine and prepends it again, so its order
can differ from the spine's — and with a navigation document halfway
through the spine it is a permutation.  What both sides do share is the
manifest id."
  (when-let* ((spine (org-remark-koreader-epub--spine))
              (document (and (boundp 'nov-documents)
                             (boundp 'nov-documents-index)
                             (ignore-errors (aref nov-documents nov-documents-index))))
              (position (seq-position spine (car document))))
    (1+ position)))

;;;; The path inside the document

;; A bookmark has no text to search for; its only anchor is `page', and that
;; names an element in the XHTML.  Without a reconstructed tree that path
;; cannot be translated into a buffer position directly.
;;
;; But the XHTML itself is right there: nov unpacks it and keeps the path.
;; From it one can read which text sits at that spot, and that text can then
;; be found in the rendered buffer — the same route the highlights already
;; take.  The XHTML says what is there, the buffer says where.

(defun org-remark-koreader-epub--document-dom ()
  "Parse the XHTML of the document now on screen, or return nil."
  (when-let* ((entry (and (boundp 'nov-documents)
                          (boundp 'nov-documents-index)
                          (ignore-errors
                            (aref nov-documents nov-documents-index))))
              (file (cdr entry))
              (readable (file-readable-p file)))
    (let ((parsed (with-temp-buffer
                    (insert-file-contents file)
                    (libxml-parse-html-region (point-min) (point-max)))))
      ;; The parser yields a wrapper holding comments and the `html' element;
      ;; the paths from the sidecar start inside that element.
      (if (eq (dom-tag parsed) 'html)
          parsed
        (dom-child-by-tag parsed 'html)))))

(defun org-remark-koreader-epub--steps (pointer)
  "Return the steps inside the document from POINTER.

An EPUB XPointer carries two paths one after the other: CRengine's
book-wide one (`/body/DocFragment[N]') and the one inside the XHTML
document (`/body/p[3]').  Only the second belongs to the file nov
unpacked."
  (when (and pointer (string-match "DocFragment\\(?:\\[[0-9]+\\]\\)?\\(/.*\\)"
                                   pointer))
    (let ((path (match-string 1 pointer)))
      ;; The text node itself is not an element; the path stops at its
      ;; parent.  The offset sits behind the node and is no part of it either.
      (setq path (replace-regexp-in-string
                  "/text()\\(\\[[0-9]+\\]\\)?\\(\\.[0-9]+\\)?\\'" "" path))
      (seq-remove #'string-empty-p (split-string path "/")))))

(defun org-remark-koreader-epub--follow (node steps)
  "Follow STEPS from NODE and return the node, or nil."
  (let ((current node))
    (dolist (step steps)
      (when current
        (let* ((tag (intern (if (string-match "\\`\\([^[]+\\)" step)
                                (match-string 1 step)
                              step)))
               (index (if (string-match "\\[\\([0-9]+\\)\\]" step)
                          (string-to-number (match-string 1 step))
                        1))
               (siblings (seq-filter
                          (lambda (child)
                            (and (consp child) (eq (dom-tag child) tag)))
                          (dom-children current))))
          (setq current (nth (1- index) siblings)))))
    current))

(defun org-remark-koreader-epub--collapse (text)
  "Collapse the whitespace in TEXT, the way an HTML renderer does."
  (string-trim (replace-regexp-in-string "[ \t\n\r\f]+" " " (or text ""))))

(defun org-remark-koreader-epub--loose-regexp (text)
  "Return a pattern that finds TEXT with whitespace free to vary."
  (mapconcat #'regexp-quote (split-string text "[ \t\n\r]+" t) "[ \t\n\r]+"))

(defun org-remark-koreader-epub--elements (node)
  "Return every element under NODE in document order."
  (let ((out nil))
    (dolist (child (dom-children node))
      (when (and (consp child) (symbolp (dom-tag child)))
        (push child out)
        (setq out (append (nreverse (org-remark-koreader-epub--elements child))
                          out))))
    (nreverse out)))

(defun org-remark-koreader-epub--earlier-alike (root node text)
  "Count the elements before NODE under ROOT with the same rendered TEXT.

Two paragraphs can be word for word the same.  Which of the two an
XPointer points at is in the path — `p[4]' is a different one from
`p[2]' — and that difference is no longer visible in the rendered text.
What does survive is the order: if this is the second alike one in the
document, it is also the second in the buffer.

Only elements of the same kind count.  An enclosing element carries the
same text as soon as it contains nothing else — in a chapter consisting
of one paragraph, `body' carries word for word what that paragraph
carries — and that is not a predecessor but a wrapper."
  (let ((tag (dom-tag node))
        (count 0)
        (seen nil))
    (dolist (element (org-remark-koreader-epub--elements root))
      (cond
       (seen nil)
       ((eq element node) (setq seen t))
       ((and (eq (dom-tag element) tag)
             (equal text (org-remark-koreader-epub--collapse
                          (dom-texts element))))
        (cl-incf count))))
    (and seen count)))

(defun org-remark-koreader-epub--text-node-prefix (element index)
  "Return the rendered text of ELEMENT before its INDEX-th text node.

A paragraph with inline markup has several direct text nodes; the
XPointer numbers them with `text()[N]', and the offset counts inside
that one node.  To map that onto the buffer, it must first be known how
much text precedes it — including the text of the inline elements in
between, because that simply appears in the rendering too.

Text nodes holding whitespace only do not count in the numbering; those
arose from the file's formatting and not from its content."
  (let ((count 0)
        (prefix "")
        (found nil))
    (dolist (child (dom-children element))
      (unless found
        (if (stringp child)
            (unless (string-empty-p (org-remark-koreader-epub--collapse child))
              (cl-incf count)
              (if (= count index)
                  (setq found t)
                (setq prefix (concat prefix child))))
          (setq prefix (concat prefix (dom-texts child))))))
    ;; Trim at the front only.  A space behind the prefix belongs to the
    ;; transition into the next text node and counts in the paragraph as
    ;; usual; trimming it would make the count one character short.
    (and found
         (length (replace-regexp-in-string
                  "[ \t\n\r\f]+" " " (string-trim-left prefix))))))

(defun org-remark-koreader-epub--text-node-index (pointer)
  "Return the text node number from POINTER; without a number that is one."
  (if (and pointer (string-match "/text()\\[\\([0-9]+\\)\\]" pointer))
      (string-to-number (match-string 1 pointer))
    1))

(defun org-remark-koreader-epub--forward (begin count)
  "Return the position COUNT rendered characters after BEGIN.

A run of whitespace counts as one character, because that is how it
sits in the text KOReader bases its offsets on.  The rendering may have
turned it into a newline; that does not change the count."
  (save-excursion
    (goto-char begin)
    (let ((seen 0))
      (while (and (< seen count) (not (eobp)))
        (if (looking-at "[ \t\n\r\f]+")
            (goto-char (match-end 0))
          (forward-char 1))
        (cl-incf seen))
      (point))))

(defun org-remark-koreader-epub-element-region (pointer)
  "Return the buffer range of the element POINTER names, or nil.

The XHTML says which element it is and what text sits in it; the buffer
says where that text is.  Alike predecessors are skipped, so that
`p[4]' does not land on `p[2]'."
  (when-let* ((dom (org-remark-koreader-epub--document-dom))
              (steps (org-remark-koreader-epub--steps pointer))
              (node (org-remark-koreader-epub--follow dom steps))
              (text (org-remark-koreader-epub--collapse (dom-texts node)))
              (usable (not (string-empty-p text)))
              (skip (org-remark-koreader-epub--earlier-alike dom node text)))
    (save-excursion
      (goto-char (point-min))
      (let ((pattern (org-remark-koreader-epub--loose-regexp text))
            (found nil))
        (dotimes (_ (1+ skip))
          (setq found (re-search-forward pattern nil :noerror))
          ;; One character back, so a further round does not take the same
          ;; hit again.  The match data stays that of the last search.
          (when found (goto-char (1+ (match-beginning 0)))))
        (when found (cons (match-beginning 0) (match-end 0)))))))

(defconst org-remark-koreader-epub--breakable-rx
  (concat "[" "　-〿"      ; CJK punctuation
          "぀-ゟ"          ; hiragana
          "゠-ヿ"          ; katakana
          "一-鿿"          ; Han
          "가-힯"          ; hangul
          "]")
  "Characters that may break a line without a space being present.

Chinese, Japanese and Korean are written without word spaces, so a line
break there falls in the middle of what KOReader stores as one
continuous string.

Spelled out as ranges rather than as a character category: in Emacs
`\\cc' and `\\cj' turn out to match Greek and `café' as well, and then
this last resort would apply to ordinary text.")

(defun org-remark-koreader-epub--breakable-p (text)
  "Return non-nil when TEXT holds characters that may break without a space."
  (and text (string-match-p org-remark-koreader-epub--breakable-rx text)))

(defun org-remark-koreader-epub--broken-regexp (text)
  "Return a pattern that finds TEXT with a newline between every character.

A last resort, and only for scripts without word spaces.  The ordinary
route lets whitespace between words vary; there is nothing to gain by
that here, because between these characters there never was a space."
  (let ((parts nil))
    (dolist (char (string-to-list text))
      (push (if (memq char '(?\s ?\t ?\n ?\r ?\f))
                "[ \t\n\r\f]+"
              (regexp-quote (char-to-string char)))
            parts))
    (mapconcat #'identity (nreverse parts) "\n?")))

(defun org-remark-koreader-epub--block-position (pointer)
  "Return the buffer position POINTER points at, or nil.

Three things must not get lost on the way: which of two alike
paragraphs it is, which text node inside the paragraph, and how many
characters further along."
  (when-let* ((dom (org-remark-koreader-epub--document-dom))
              (steps (org-remark-koreader-epub--steps pointer))
              (node (org-remark-koreader-epub--follow dom steps))
              (prefix (org-remark-koreader-epub--text-node-prefix
                       node (org-remark-koreader-epub--text-node-index pointer)))
              (region (org-remark-koreader-epub-element-region pointer))
              (position (org-remark-koreader-epub--forward
                         (car region)
                         (+ prefix
                            (or (org-remark-koreader-epub--offset pointer) 0)))))
    ;; An offset reaching beyond the element describes no place inside it.
    ;; Without this bound the count runs on into the next paragraph and
    ;; produces a position that means nothing — and that says nothing about
    ;; itself either.
    (and (<= position (cdr region)) position)))

(defun org-remark-koreader-epub--offset (pointer)
  "Return the character offset from POINTER, or nil."
  (when (and pointer (string-match "\\.\\([0-9]+\\)\\'" pointer))
    (string-to-number (match-string 1 pointer))))

;;;; The ladder

(defun org-remark-koreader-epub--parts (text)
  "Split TEXT on newlines.

KOReader writes a selection across block boundaries with a newline at
the transition.  The rendering puts something else there — shr numbers
list items, and that digit is not in the stored text — so the parts can
be found separately where the whole cannot."
  (seq-remove #'string-empty-p
              (mapcar #'string-trim (split-string (or text "") "\n"))))

(defun org-remark-koreader-epub--span (parts)
  "Return the range PARTS together span, or nil.

Every part must occur exactly once and they must be in order.
Otherwise it is not one contiguous selection but a chance collection of
hits."
  (let ((begin nil)
        (end nil)
        (ok t))
    (dolist (part parts)
      (when ok
        (let ((hits (org-remark-koreader-match--occurrences part)))
          (if (/= (length hits) 1)
              (setq ok nil)
            (let ((hit (car hits)))
              (if (and end (< (car hit) end))
                  (setq ok nil)
                (unless begin (setq begin (car hit)))
                (setq end (cdr hit))))))))
    (and ok begin end (cons begin end))))

(defun org-remark-koreader-epub--place-in-document (marks)
  "Place the MARKS that sit in the document now on screen."
  ;; Round 1 — text unambiguous within this chapter.
  (dolist (mark marks)
    (when (eq (org-remark-koreader-mark-confidence mark) 'unresolved)
      (let ((hits (org-remark-koreader-match--occurrences
                   (org-remark-koreader-mark-text mark))))
        (setf (org-remark-koreader-mark-candidates mark) hits)
        (when (= (length hits) 1)
          (org-remark-koreader-match--place mark (car hits) 'exact)))))
  ;; Round 2 — narrow the ambiguous cases with the neighbours that are fixed.
  (let ((index -1))
    (dolist (mark marks)
      (cl-incf index)
      (when (and (eq (org-remark-koreader-mark-confidence mark) 'unresolved)
                 (> (length (org-remark-koreader-mark-candidates mark)) 1))
        (let* ((bounds (org-remark-koreader-match--bounds marks index))
               ;; The element from the XPointer is an independent signal: it
               ;; comes from the path and not from the text.  If the same
               ;; sentence sits three times in the chapter, `p[4]' says which
               ;; of the three is meant.
               (region (org-remark-koreader-epub-element-region
                        (org-remark-koreader-mark-pos0 mark)))
               (remaining
                (seq-filter (lambda (candidate)
                              (and (org-remark-koreader-match--within
                                    candidate (car bounds) (cdr bounds))
                                   (or (null region)
                                       (and (<= (car region) (car candidate))
                                            (<= (cdr candidate) (cdr region))))))
                            (org-remark-koreader-mark-candidates mark))))
          (if (= (length remaining) 1)
              (org-remark-koreader-match--place mark (car remaining)
                                                'disambiguated)
            (org-remark-koreader-match--note-anomaly
             mark "%d candidates left after narrowing from %d"
             (length remaining)
             (length (org-remark-koreader-mark-candidates mark))))))))
  ;; Round 3 — the selection crossed a block boundary; find the parts apart.
  (dolist (mark marks)
    (when (eq (org-remark-koreader-mark-confidence mark) 'unresolved)
      (let ((parts (org-remark-koreader-epub--parts
                    (org-remark-koreader-mark-text mark))))
        (when (> (length parts) 1)
          (when-let* ((span (org-remark-koreader-epub--span parts)))
            (org-remark-koreader-match--place mark span 'joined)
            (org-remark-koreader-match--note-anomaly
             mark "joined from %d parts across a block boundary"
             (length parts)))))))
  ;; Round 4 — scripts without word spaces, where the rendering may have
  ;; broken in the middle of a word.
  (dolist (mark marks)
    (when (eq (org-remark-koreader-mark-confidence mark) 'unresolved)
      (let ((text (org-remark-koreader-mark-text mark)))
        (when (org-remark-koreader-epub--breakable-p text)
          (save-excursion
            (goto-char (point-min))
            (when (re-search-forward
                   (org-remark-koreader-epub--broken-regexp text) nil :noerror)
              (org-remark-koreader-match--place
               mark (cons (match-beginning 0) (match-end 0)) 'approximate)
              (org-remark-koreader-match--note-anomaly
               mark "found with a line break inside the script")))))))
  marks)

(defun org-remark-koreader-epub--place-bookmark (mark)
  "Put MARK as a point marker at the place its `page' points to.

As with the other families that place means \"this page\" and not \"this
sentence\": `page' is the start of the rendered page on which the
bookmark was set, as KOReader broke it.  There is nothing to verify — a
bookmark has no stored text to compare the found spot against."
  (let ((position (org-remark-koreader-epub--block-position
                   (org-remark-koreader-mark-page mark))))
    (if position
        (progn
          (org-remark-koreader-match--place mark (cons position position)
                                            'projected)
          (org-remark-koreader-match--note-anomaly
           mark "bookmark at the start of the rendered page"))
      (org-remark-koreader-match--note-anomaly
       mark "`page' points at no text present in this rendering"))))

(defun org-remark-koreader-epub-resolve (marks)
  "Determine the position of MARKS in the nov buffer now on screen.

Marks from another chapter get confidence `elsewhere'.  That is not a
failure but a finding: that chapter is not in the buffer right now, and
nov uses one buffer for the whole book."
  (let ((current (org-remark-koreader-epub-current-fragment)))
    (dolist (mark marks)
      (setf (org-remark-koreader-mark-confidence mark) 'unresolved
            (org-remark-koreader-mark-beg mark) nil
            (org-remark-koreader-mark-end mark) nil
            (org-remark-koreader-mark-candidates mark) nil))
    (if (null current)
        (dolist (mark marks)
          (org-remark-koreader-match--note-anomaly
           mark "no EPUB document on screen"))
      (let ((here nil))
        (dolist (mark marks)
          (let ((fragment (org-remark-koreader-epub--mark-fragment mark)))
            (cond
             ((null fragment)
              (org-remark-koreader-match--note-anomaly
               mark "the XPointer names no DocFragment"))
             ((/= fragment current)
              (setf (org-remark-koreader-mark-confidence mark) 'elsewhere)
              (org-remark-koreader-match--note-anomaly
               mark "belongs to spine document %d" fragment))
             ((eq (org-remark-koreader-mark-kind mark) 'bookmark)
              (org-remark-koreader-epub--place-bookmark mark))
             ((null (org-remark-koreader-mark-text mark))
              (org-remark-koreader-match--note-anomaly
               mark "no text to search for"))
             (t (push mark here)))))
        (org-remark-koreader-epub--place-in-document (nreverse here))))
    marks))

;;;; Registering

(add-to-list 'org-remark-koreader-match-families
             (cons #'org-remark-koreader-epub-marks-p
                   #'org-remark-koreader-epub-resolve))

(provide 'org-remark-koreader-epub)
;;; org-remark-koreader-epub.el ends here
