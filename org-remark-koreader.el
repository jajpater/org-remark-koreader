;;; org-remark-koreader.el --- KOReader annotations through org-remark  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 jajpater

;; Author: jajpater
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org-remark "1.3.0"))
;; Keywords: annotate, writing, note-taking, marginal-notes
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Makes KOReader annotations visible and editable as org-remark marks.
;; Works on Markdown, plain text and EPUB.
;;
;; The KOReader sidecar is only ever read.  The source file and the sidecar
;; stay byte for byte identical after every operation.
;;
;; Usage: open the file that also sits on the e-reader and call
;; `org-remark-koreader-import'.  Annotations that cannot be placed reliably
;; get no overlay but appear in a report; a wrongly placed mark is worse than
;; an unresolved one.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'org)
(require 'org-remark)
(require 'org-remark-koreader-lua)
(require 'org-remark-koreader-model)
(require 'org-remark-koreader-match)
;; Registers itself as a document family.  It does not require nov.el in
;; order to load; only in order to run, and that happens only for an EPUB.
(require 'org-remark-koreader-epub)

;; nov.el is a soft dependency: the package loads and works without it, and
;; uses this function only in a `nov-mode' buffer.
(declare-function nov-goto-document "nov" (index))
(defvar nov-documents)
(defvar nov-documents-index)

;;;; Instellingen

(defcustom org-remark-koreader-sidecar-resolver nil
  "Function that finds the sidecar path for a source file.

Called with the path of the source file, returning the path to
`metadata.<extension>.lua', or nil.  Without this function only the
adjacent `.sdr' directory is examined.

KOReader also knows other metadata locations — a central directory, a
hash-based layout — which differ per installation.  Those are not
guessed at; whoever uses them points them out here."
  :group 'org-remark-koreader
  :type '(choice (const :tag "Only the adjacent directory" nil)
                 function))

;; `eval-and-compile' is needed because the pen macro reads this list during
;; macro expansion; when byte compiling the value would otherwise not yet
;; exist.
(eval-and-compile
  (defconst org-remark-koreader-colors
    '("yellow" "green" "blue" "red" "orange" "purple" "cyan" "olive" "gray")
    "Colours for which a pen of its own exists.

These are the nine colours the generated corpus has produced in
sidecars."))

(defcustom org-remark-koreader-color-faces
  '(("yellow" . org-remark-koreader-yellow)
    ("green" . org-remark-koreader-green)
    ("blue" . org-remark-koreader-blue)
    ("red" . org-remark-koreader-red)
    ("orange" . org-remark-koreader-orange)
    ("purple" . org-remark-koreader-purple)
    ("cyan" . org-remark-koreader-cyan)
    ("olive" . org-remark-koreader-olive)
    ("gray" . org-remark-koreader-gray))
  "Mapping from KOReader colour to face.

Kind and colour are independent: `org-remark-type' governs the
behaviour of a highlight, annotation or bookmark, this alist governs
how it looks."
  :group 'org-remark-koreader
  :type '(alist :key-type string :value-type face))

(defcustom org-remark-koreader-unknown-color-face 'org-remark-koreader-unknown
  "Face for a colour absent from `org-remark-koreader-color-faces'.

An unknown colour never quietly gets the face of a known one: the mark
would then claim something other than what KOReader says.  The original
colour name is kept either way."
  :group 'org-remark-koreader
  :type 'face)

;;;; Faces

(defface org-remark-koreader-yellow
  '((((background light)) :background "#f7e59a")
    (t :background "#5b5326"))
  "Face for a yellow KOReader mark.")

(defface org-remark-koreader-green
  '((((background light)) :background "#b8e0b0")
    (t :background "#2f4f34"))
  "Face for a green KOReader mark.")

(defface org-remark-koreader-blue
  '((((background light)) :background "#b3d4f0")
    (t :background "#26415b"))
  "Face for a blue KOReader mark.")

(defface org-remark-koreader-red
  '((((background light)) :background "#f0b8b8")
    (t :background "#5b2626"))
  "Face for a red KOReader mark.")

(defface org-remark-koreader-orange
  '((((background light)) :background "#f5cd9e")
    (t :background "#5b3f26"))
  "Face for an orange KOReader mark.")

(defface org-remark-koreader-purple
  '((((background light)) :background "#dcc2ea")
    (t :background "#452650"))
  "Face for a purple KOReader mark.")

(defface org-remark-koreader-cyan
  '((((background light)) :background "#aee2e6")
    (t :background "#1f4a4f"))
  "Face for a cyan KOReader mark.")

(defface org-remark-koreader-olive
  '((((background light)) :background "#d5dfa2")
    (t :background "#464f26"))
  "Face for an olive KOReader mark.")

(defface org-remark-koreader-gray
  '((((background light)) :background "#dcdcdc")
    (t :background "#3f3f3f"))
  "Face for a grey KOReader mark.")

(defface org-remark-koreader-unknown
  '((t :underline (:style wave)))
  "Face for a KOReader colour this package does not know.")

(defface org-remark-koreader-bookmark
  '((t :inherit org-remark-highlighter))
  "Face for a KOReader bookmark.")

;;;; Pennen
;;
;; Every kind-colour combination gets a pen of its own.  That is not
;; decoration: on reload org-remark looks the pen up by the stored label
;; (`org-remark-highlight-load').  If that pen does not exist it falls back to
;; `org-remark-mark' and `org-remark-type' disappears — with which the generic
;; methods below no longer apply either.

(defmacro org-remark-koreader--define-pens ()
  "Define a pen per kind and colour, plus one for bookmarks."
  (let ((forms nil))
    (dolist (kind '(("highlight" . koreader-highlight)
                    ("annotation" . koreader-annotation)))
      (dolist (color (append org-remark-koreader-colors '("unknown")))
        (push `(org-remark-create
                ,(format "koreader-%s-%s" (car kind) color)
                ',(if (string= color "unknown")
                      'org-remark-koreader-unknown
                    (intern (format "org-remark-koreader-%s" color)))
                '(org-remark-type ,(cdr kind)))
              forms)))
    (push `(org-remark-create
            "koreader-bookmark"
            'org-remark-koreader-bookmark
            '(org-remark-type koreader-bookmark))
          forms)
    `(progn ,@(nreverse forms))))

(org-remark-koreader--define-pens)

(defun org-remark-koreader--pen-label (mark)
  "Return the pen label for MARK."
  (let ((kind (org-remark-koreader-mark-kind mark))
        (color (org-remark-koreader-mark-color mark)))
    (if (eq kind 'bookmark)
        "koreader-bookmark"
      (format "koreader-%s-%s" kind
              (if (assoc color org-remark-koreader-color-faces)
                  color
                "unknown")))))

(defun org-remark-koreader--face (mark)
  "Return the face for MARK."
  (if (eq (org-remark-koreader-mark-kind mark) 'bookmark)
      'org-remark-koreader-bookmark
    (or (alist-get (org-remark-koreader-mark-color mark)
                   org-remark-koreader-color-faces nil nil #'equal)
        org-remark-koreader-unknown-color-face)))

;;;; Type-specific behaviour

(defconst org-remark-koreader-types
  '(koreader-highlight koreader-annotation koreader-bookmark)
  "The `org-remark-type' values this package manages.")

(defun org-remark-koreader--own-type-p (type)
  "Return non-nil when TYPE is managed by this package."
  (and (memq type org-remark-koreader-types) t))

;; `org-remark-highlight-make-overlay' is mandatory, not optional.  The
;; generic default does nothing and returns nil; only the nil type has a
;; method that really makes an overlay.  A type of one's own without this
;; method therefore silently yields no overlay at all — the mark does get
;; stored, but is nowhere to be seen.

(defun org-remark-koreader--make-overlay (beg end face)
  "Make an overlay from BEG to END with FACE."
  (let ((ov (make-overlay beg end nil :front-advance)))
    (overlay-put ov 'face (or face 'org-remark-highlighter))
    ov))

(cl-defmethod org-remark-highlight-make-overlay
  (beg end face (_org-remark-type (eql 'koreader-highlight)))
  "Make a text-range overlay from BEG to END with FACE."
  (org-remark-koreader--make-overlay beg end face))

(cl-defmethod org-remark-highlight-make-overlay
  (beg end face (_org-remark-type (eql 'koreader-annotation)))
  "Make a text-range overlay from BEG to END with FACE."
  (org-remark-koreader--make-overlay beg end face))

(cl-defmethod org-remark-highlight-make-overlay
  (beg end face (_org-remark-type (eql 'koreader-bookmark)))
  "Make a point marker at BEG with FACE.
END is ignored: a bookmark has no text range, only a place."
  (ignore end)
  (org-remark-koreader--make-overlay beg beg face))

;; `org-remark-highlight-headline-text' is the second mandatory method.  The
;; generic has no default — only methods for the nil type and for line
;; highlights — so a type of one's own yields `cl-no-applicable-method' when
;; saving.

(defun org-remark-koreader--headline-text (ov)
  "Return the title text for the headline of OV.
Newlines become spaces: an Org headline is one line."
  (replace-regexp-in-string
   "\n" " "
   (buffer-substring-no-properties (overlay-start ov) (overlay-end ov))))

(cl-defmethod org-remark-highlight-headline-text
  (ov (_org-remark-type (eql 'koreader-highlight)))
  "Return the marked text of OV as headline text."
  (org-remark-koreader--headline-text ov))

(cl-defmethod org-remark-highlight-headline-text
  (ov (_org-remark-type (eql 'koreader-annotation)))
  "Return the marked text of OV as headline text."
  (org-remark-koreader--headline-text ov))

(cl-defmethod org-remark-highlight-headline-text
  (ov (_org-remark-type (eql 'koreader-bookmark)))
  "Return headline text for the point marker OV.
A bookmark has no text range, so there is nothing to quote; the line it
sits on is the only meaningful thing to go by."
  (let ((line (save-excursion
                (goto-char (overlay-start ov))
                (string-trim (buffer-substring-no-properties
                              (line-beginning-position)
                              (line-end-position))))))
    (if (string-empty-p line)
        "KOReader bookmark"
      (format "Bookmark: %s"
              (if (< 60 (length line)) (concat (substring line 0 60) "…") line)))))

;; On load org-remark restores positions by searching for the stored text as
;; a regular expression.  That mechanism must not run here: it would add a
;; second, contradictory positioning next to our own resolver, and it moves
;; text containing regexp metacharacters silently.
(cl-defmethod org-remark-highlights-adjust-positions-p
  ((_org-remark-type (eql 'koreader-highlight)))
  nil)

(cl-defmethod org-remark-highlights-adjust-positions-p
  ((_org-remark-type (eql 'koreader-annotation)))
  nil)

(cl-defmethod org-remark-highlights-adjust-positions-p
  ((_org-remark-type (eql 'koreader-bookmark)))
  nil)

;; A bookmark is a point marker and therefore zero length by definition.
;; Without this method the housekeeping cleans it away and the note loses its
;; link.
(cl-defmethod org-remark-highlights-housekeep-delete-p
  (_ov (_org-remark-type (eql 'koreader-bookmark)))
  nil)

;;;; Finding the sidecar

(defun org-remark-koreader-sidecar-file (source-path)
  "Return the path to the sidecar of SOURCE-PATH, or nil.

Mind the naming: the extension drops out of the directory name and
stays in the file name.  So `book.md' goes with
`book.sdr/metadata.md.lua'."
  (or (and org-remark-koreader-sidecar-resolver
           (funcall org-remark-koreader-sidecar-resolver source-path))
      (let* ((dir (file-name-directory source-path))
             (sdr (expand-file-name
                   (concat (file-name-base source-path) ".sdr") dir))
             (extension (file-name-extension source-path))
             (file (and extension
                        (expand-file-name
                         (format "metadata.%s.lua" extension) sdr))))
        (and file (file-readable-p file) file))))

(defun org-remark-koreader-export-file (source-path)
  "Return the annotation export file beside the sidecar of SOURCE-PATH, or nil.

This is the optional transport file KOReader writes when \"Export
annotations on book closing\" is on.  It is reported but never quietly
merged: it is not a second authoritative sidecar.

Its absence here proves nothing.  KOReader has a configurable export
directory, so the file may sit elsewhere."
  (let ((sidecar (org-remark-koreader-sidecar-file source-path)))
    (when sidecar
      (let ((file (expand-file-name
                   (concat (file-name-nondirectory source-path)
                           ".annotations.lua")
                   (file-name-directory sidecar))))
        (and (file-readable-p file) file)))))

;;;; Properties

(defun org-remark-koreader--property-value (value)
  "Make VALUE fit to be a value in an Org property drawer.

A property is one line of text.  A control character in it breaks that
line — and a NUL does more than that: Emacs treats a file containing a
NUL as binary, after which the whole notes file opens as raw bytes and
not one accented character reads correctly.  The sidecar is user input,
so no field may reach the drawer unfiltered."
  (when value
    (let ((text (string-trim
                 (replace-regexp-in-string "[\0-\10\13-\37\177]+" " "
                                           (format "%s" value)))))
      (unless (string-empty-p text) text))))

(defun org-remark-koreader--properties (mark document)
  "Build the overlay properties for MARK from DOCUMENT.

Names prefixed `org-remark-' end up in the property drawer; names with
`*' stay on the overlay only.  The note baseline is deliberately not
among them: it may exist only once the note text does."
  (let ((props (list 'org-remark-type
                     (org-remark-koreader-mark-org-remark-type mark)))
        (dom-version (org-remark-koreader-document-cre-dom-version document)))
    (dolist (pair
             (list
              (cons 'org-remark-koreader-kind
                    (symbol-name (org-remark-koreader-mark-kind mark)))
              (cons 'org-remark-koreader-page
                    (org-remark-koreader-mark-page mark))
              (cons 'org-remark-koreader-pos0
                    (org-remark-koreader-mark-pos0 mark))
              (cons 'org-remark-koreader-pos1
                    (org-remark-koreader-mark-pos1 mark))
              (cons 'org-remark-koreader-datetime
                    (org-remark-koreader-mark-datetime mark))
              (cons 'org-remark-koreader-chapter
                    (org-remark-koreader-mark-chapter mark))
              (cons 'org-remark-koreader-color
                    (org-remark-koreader-mark-color mark))
              (cons 'org-remark-koreader-drawer
                    (org-remark-koreader-mark-drawer mark))
              (cons 'org-remark-koreader-identity
                    (org-remark-koreader-document-identity document))
              (cons 'org-remark-koreader-tuple
                    (org-remark-koreader-tuple-readable
                     (org-remark-koreader-mark-tuple mark)))
              ;; XPointers hold within one DOM version; without this datum
              ;; there is no telling later what they were valid against.
              (cons 'org-remark-koreader-cre-dom-version
                    (and dom-version (format "%s" dom-version)))
              (cons '*org-remark-koreader-confidence
                    (symbol-name (org-remark-koreader-mark-confidence mark)))))
      ;; A nil value would end up in the drawer as the string "nil".
      (when-let* ((value (org-remark-koreader--property-value (cdr pair))))
        (setq props (append props (list (car pair) value)))))
    props))

;;;; Writing the note text
;;
;; org-remark has no setter for the body: in its design that is purely text
;; typed by the user.  Inserting a KOReader note is therefore a step of our
;; own.

(defconst org-remark-koreader-note-hash-property "org-remark-koreader-note-hash"
  "Property holding the hash of the most recently imported note.

A property, not a drawer and not a child headline: `org-end-of-meta-data'
skips only logbook drawers, so a drawer of our own would land in the
body, and a child headline would make the user's note vanish from the
body as read.")

(defun org-remark-koreader--headline-body ()
  "Return the complete body of the headline at point, or nil.

Deliberately not `org-remark-notes-get-body': that truncates at 200
characters.  Enough for a preview, but anyone comparing against it sees
every long note as changed."
  (save-excursion
    (org-end-of-meta-data :full)
    (unless (or (looking-at org-heading-regexp) (eobp))
      (buffer-substring-no-properties (point) (org-end-of-subtree)))))

(defun org-remark-koreader--note-breaks-structure-p (note)
  "Return non-nil when NOTE as a body would break the Org structure.

A line beginning with asterisks and whitespace is a heading in Org.
Were one to sit in a note, the body would split the surrounding
highlight and the annotations after it would lose their link.  This does
not occur in the measured corpus; it is reported rather than written
silently, because damaging silently is the worst of the three possible
outcomes."
  (and note
       (seq-some (lambda (line) (string-match-p "\\`\\*+[ \t]" line))
                 (split-string note "\n"))))

(defun org-remark-koreader--note-action (baseline current incoming)
  "Decide what should happen to the body.

BASELINE is the stored hash or nil, CURRENT the canonicalised body in
the file, INCOMING the canonicalised KOReader note.

The deciding signal is not whether the body is empty, but whether an
import baseline exists.  An empty body after an earlier import may be a
deliberate deletion, and must then not be filled again.

When a baseline does exist this is a three-way comparison: the baseline
is the last imported value, CURRENT the local one and INCOMING the
current KOReader one.  Which of the two sides changed something follows
from that, and the distinction matters — changed locally only is simply
work that must be kept, changed on both sides is a conflict the user
has to see."
  (if (null baseline)
      (if (string-empty-p current) 'write 'keep-existing)
    (let ((local-changed
           (not (equal baseline
                       (org-remark-koreader--note-baseline-hash current))))
          (koreader-changed
           (not (equal baseline
                       (org-remark-koreader--note-baseline-hash incoming)))))
      (cond
       ((and (not local-changed) (not koreader-changed)) 'unchanged)
       ((not local-changed) 'write)
       ((not koreader-changed) 'keep-local)
       (t 'conflict)))))

(defun org-remark-koreader--write-note (notes-buf id note)
  "Write NOTE as the body of the headline with ID in NOTES-BUF.

Returns what was done: `write', `unchanged', `keep-existing',
`keep-local' or `no-headline'.

Body and baseline are changed in the same buffer operation and saved in
one go.  Were the baseline to exist before the body, an interruption
would leave an empty body with an existing baseline — and that
combination means precisely that the user erased the note."
  (with-current-buffer notes-buf
    (org-with-wide-buffer
     (let ((headline (org-find-property org-remark-prop-id id)))
       (if (not headline)
           'no-headline
         (goto-char headline)
         (let* ((baseline (org-entry-get nil org-remark-koreader-note-hash-property))
                (current (org-remark-koreader--canonicalize-note
                          (org-remark-koreader--headline-body)))
                (incoming (org-remark-koreader--canonicalize-note note))
                (action (if (org-remark-koreader--note-breaks-structure-p incoming)
                            'unsafe
                          (org-remark-koreader--note-action
                           baseline current incoming))))
           (when (eq action 'write)
             (goto-char headline)
             (org-end-of-meta-data :full)
             (let ((beg (point))
                   (end (save-excursion (org-end-of-subtree))))
               (unless (or (looking-at org-heading-regexp) (eobp))
                 (delete-region beg end))
               (unless (string-empty-p incoming)
                 (insert incoming "\n")))
             (goto-char headline)
             (org-entry-put nil org-remark-koreader-note-hash-property
                            (org-remark-koreader--note-baseline-hash incoming))
             (save-buffer))
           action))))))

(defun org-remark-koreader--update-note-overlay (id note)
  "Update the display cache of the overlay with ID to NOTE.
`*org-remark-note-body' is what org-remark shows itself; authoritative
are the body in the Org file and the baseline."
  (dolist (ov org-remark-highlights)
    (when (equal (overlay-get ov 'org-remark-id) id)
      (overlay-put ov '*org-remark-note-body
                   (if (< 200 (length note)) (substring note 0 200) note)))))

;;;; Reconciliation
;;
;; Importing again is not an add operation but a comparison of two sides.
;; Looking only at what the sidecar holds leaves the most interesting state
;; invisible: an annotation deleted in KOReader then stays behind as a dead
;; headline in the Org file, without overlay and without notice, and that
;; piles up with every use.

(cl-defstruct (org-remark-koreader-reconciliation
               (:constructor org-remark-koreader-reconciliation-create)
               (:copier nil))
  "The outcome of comparing sidecar and notes file.

NEW are marks that have no Org headline yet.  KNOWN are marks that do.
CHANGED holds (MARK . FIELDS) for marks KOReader changed something
about.  DISAPPEARED holds the stored annotations that no longer occur
in the sidecar.  UNRESOLVABLE holds marks that are there but can no
longer be placed."
  new known changed disappeared unresolvable)

(defun org-remark-koreader--existing-entries (notes-buf source-name)
  "Return the stored KOReader annotations for SOURCE-NAME from NOTES-BUF.

Returns an alist from ID to plist.  Only headlines with an
`org-remark-koreader-kind' count: an ordinary org-remark highlight the
user made themselves does not belong in this comparison."
  (with-current-buffer notes-buf
    (org-with-wide-buffer
     (let ((entries nil)
           (heading (org-find-property org-remark-prop-source-file source-name)))
       (when heading
         (goto-char heading)
         (org-narrow-to-subtree)
         (while (org-at-heading-p (org-next-visible-heading 1))
           (let ((id (org-entry-get (point) org-remark-prop-id))
                 (kind (org-entry-get (point) "org-remark-koreader-kind")))
             (when (and id kind)
               (push (cons id
                           (list :kind kind
                                 :title (org-get-heading :no-tags :no-todo)
                                 :color (org-entry-get
                                         (point) "org-remark-koreader-color")
                                 :text (org-entry-get
                                        (point) "org-remark-original-text")))
                     entries)))))
       (nreverse entries)))))

(defconst org-remark-koreader-tracked-fields
  '((:color . "colour") (:text . "text"))
  "Fields KOReader itself may change after an import.

KOReader lets the colour of a mark be changed and the stored text be
edited.  Neither is reason to treat the annotation as new — the
identity does not depend on them — but both are worth reporting, so
that a silent change becomes visible.")

(defun org-remark-koreader--changed-fields (mark entry)
  "Return the fields in which MARK differs from the stored ENTRY.

For a bookmark `text' is left out.  The stored text of a text range is
the source text itself and therefore comparable with what KOReader
keeps; for a bookmark the headline is one we made from the line it sits
on, and KOReader's `text' is a caption of its own.  Those two are never
equal, so any comparison would report a change on every import."
  (let ((bookmark (eq (org-remark-koreader-mark-kind mark) 'bookmark)))
    (delq nil
          (mapcar
           (lambda (field)
             (let ((was (plist-get entry (car field)))
                   (now (pcase (car field)
                          (:color (org-remark-koreader-mark-color mark))
                          (:text (unless bookmark
                                   (org-remark-koreader-mark-text mark))))))
               (and was now (not (equal was now)) (cdr field))))
           org-remark-koreader-tracked-fields))))

(defun org-remark-koreader--reconcile (marks existing)
  "Compare MARKS from the sidecar with the EXISTING annotations."
  (let ((new nil) (known nil) (changed nil) (unresolvable nil)
        (seen (make-hash-table :test 'equal)))
    (dolist (mark marks)
      (let* ((id (org-remark-koreader-mark-id mark))
             (entry (alist-get id existing nil nil #'equal)))
        (puthash id t seen)
        (cond
         (entry
          (push mark known)
          (let ((fields (org-remark-koreader--changed-fields mark entry)))
            (when fields (push (cons mark fields) changed)))
          ;; Placed before, not any more: the source has changed.
          (unless (org-remark-koreader-mark-beg mark)
            (push mark unresolvable)))
         ;; A mark without a position gets no headline, so it is not "new"
         ;; but "not placed" — and that is stated elsewhere already.  Were it
         ;; to count here, every import would report it as new again.
         ((org-remark-koreader-mark-beg mark)
          (push mark new)))))
    (org-remark-koreader-reconciliation-create
     :new (nreverse new)
     :known (nreverse known)
     :changed (nreverse changed)
     :unresolvable (nreverse unresolvable)
     :disappeared (seq-remove (lambda (cell) (gethash (car cell) seen))
                              existing))))

;;;; Importing

(defvar-local org-remark-koreader--last-document nil
  "The most recently imported document in this buffer.")

(defvar-local org-remark-koreader--last-marks nil
  "The marks of the last import in this buffer.")

(defun org-remark-koreader--mark-one (mark document)
  "Make the org-remark mark for MARK from DOCUMENT.
Returns the overlay, or nil."
  (org-remark-highlight-mark
   (org-remark-koreader-mark-beg mark)
   (org-remark-koreader-mark-end mark)
   (org-remark-koreader-mark-id mark)
   nil                                  ; MODE nil saves; :load does not
   (org-remark-koreader--pen-label mark)
   (org-remark-koreader--face mark)
   (org-remark-koreader--properties mark document)))

(defun org-remark-koreader--nov-buffer-p ()
  "Return non-nil when this buffer shows an EPUB in `nov-mode'."
  (and (derived-mode-p 'nov-mode)
       (boundp 'nov-documents)
       (vectorp (symbol-value 'nov-documents))))

;;;###autoload
(defun org-remark-koreader-import ()
  "Import the KOReader annotations belonging to the current file.

Reads the sidecar, determines each annotation's position in this buffer
and makes org-remark marks for whatever can be placed reliably.  What
cannot gets no mark and appears in the report.

In an EPUB that goes chapter by chapter.  `nov-mode' shows one at a
time in the same buffer, so the other chapters are visited and then the
reader is returned to where they were.  See
`org-remark-koreader--import-book'.

The sidecar and the source file are not modified."
  (interactive)
  (if (org-remark-koreader--nov-buffer-p)
      (org-remark-koreader--import-book)
    (plist-get (org-remark-koreader--import-here) :marks)))

(defun org-remark-koreader--import-book ()
  "Import every chapter of the EPUB in this buffer.

Each chapter gets a headline of its own in the notes file — that is
`org-remark-nov's doing — and a reconciliation of its own, because the
annotations of another chapter do not belong to it.  The marks of a
chapter that goes off screen have been saved by then; on return
org-remark loads them again.

Returns the marks of the chapter you were on."
  (let ((start (symbol-value 'nov-documents-index))
        (total (length (symbol-value 'nov-documents)))
        (names (org-remark-koreader--chapter-names))
        (per-chapter nil)
        (marks nil))
    (unwind-protect
        (dotimes (index total)
          ;; Clear first, then turn the page.  `nov-mode' erases the buffer
          ;; for the next chapter, but overlays survive that: they collapse
          ;; onto position one and stay there.  What goes here has been saved
          ;; already; org-remark loads it back as soon as the chapter comes
          ;; into view again.
          (org-remark-highlights-clear)
          (nov-goto-document index)
          (let ((result (org-remark-koreader--import-here :quiet)))
            (when result
              (push (cons index result) per-chapter))))
      (org-remark-highlights-clear)
      (nov-goto-document start))
    (setq marks (plist-get (alist-get start per-chapter) :marks))
    (org-remark-koreader--report-book (nreverse per-chapter) start names)
    marks))

(defun org-remark-koreader--import-here (&optional quiet)
  "Import the annotations for the document now on screen.
Without QUIET the report is shown straight away."
  (let* ((source (or (buffer-file-name)
                     (user-error "This buffer does not belong to a file")))
         (sidecar (or (org-remark-koreader-sidecar-file source)
                      (user-error "No KOReader sidecar found next to %s"
                                  (file-name-nondirectory source))))
         (document (org-remark-koreader-document-from-sidecar sidecar source))
         (marks (org-remark-koreader-match-resolve
                 (org-remark-koreader-document-marks document)))
         (placed 0)
         (notes nil)
         ;; Record what was already there before placing: afterwards every
         ;; annotation is known and there is no telling what was new.
         (notes-file (org-remark-notes-get-file-name))
         (source-name (org-remark-source-get-file-name
                       (org-remark-source-find-file-name)))
         (existing (and (file-exists-p notes-file)
                        (org-remark-koreader--existing-entries
                         (find-file-noselect notes-file) source-name)))
         (state (org-remark-koreader--reconcile marks existing)))
    (dolist (mark marks)
      (when (org-remark-koreader-mark-beg mark)
        (when (org-remark-koreader--mark-one mark document)
          (cl-incf placed))))
    ;; The notes only after making every mark: by then
    ;; `org-remark-highlight-mark' has created and saved the headline.
    (let ((notes-buf (find-file-noselect (org-remark-notes-get-file-name))))
      (dolist (mark marks)
        (when (and (org-remark-koreader-mark-beg mark)
                   (org-remark-koreader-mark-note mark))
          (let* ((action (org-remark-koreader--write-note
                          notes-buf
                          (org-remark-koreader-mark-id mark)
                          (org-remark-koreader-mark-note mark)))
                 (cell (assq action notes)))
            (if cell (cl-incf (cdr cell)) (push (cons action 1) notes))
            (when (eq action 'write)
              (org-remark-koreader--update-note-overlay
               (org-remark-koreader-mark-id mark)
               (org-remark-koreader-mark-note mark)))))))
    (setq org-remark-koreader--last-document document
          org-remark-koreader--last-marks marks)
    (unless quiet
      (org-remark-koreader--report document marks placed notes state))
    (list :document document :marks marks :placed placed
          :notes notes :state state)))

;;;; Resolver after loading

(defun org-remark-koreader--relocate (ov text)
  "Try to place OV on TEXT again.
Returns t on an unambiguous hit.  In case of doubt nothing happens: the
overlay stays where it was and is flagged."
  (let ((hits (org-remark-koreader-match--occurrences text)))
    (cond
     ((= (length hits) 1)
      (move-overlay ov (car (car hits)) (cdr (car hits)))
      (overlay-put ov '*org-remark-koreader-confidence "exact")
      (overlay-put ov '*org-remark-koreader-stale nil)
      t)
     (t
      (overlay-put ov '*org-remark-koreader-stale
                   (format "%d candidates" (length hits)))
      nil))))

(defun org-remark-koreader--bookmark-overlay-p (ov)
  "Return non-nil when OV is a bookmark."
  (eq (overlay-get ov 'org-remark-type) 'koreader-bookmark))

(defun org-remark-koreader--notes-entry (notes-buf id function)
  "Call FUNCTION on the headline of ID in NOTES-BUF, or return nil.

FUNCTION runs with point on the headline, in a widened buffer.

On load org-remark returns only id, position, label, original text and
body; the remaining properties stay in the notes file and never reach
the overlay.  Anyone wanting to know more has to fetch it there."
  (when (and notes-buf (buffer-live-p notes-buf) id)
    (with-current-buffer notes-buf
      (org-with-wide-buffer
       (when-let* ((position (org-find-property org-remark-prop-id id)))
         (goto-char position)
         (funcall function))))))

(defun org-remark-koreader--notes-property (notes-buf id property)
  "Return PROPERTY of ID from NOTES-BUF, or nil."
  (org-remark-koreader--notes-entry
   notes-buf id (lambda () (org-entry-get (point) property))))

(defun org-remark-koreader--notes-page (notes-buf id)
  "Return the stored `page' XPointer of ID from NOTES-BUF, or nil.
For a bookmark `page' is the only anchor."
  (org-remark-koreader--notes-property
   notes-buf id "org-remark-koreader-page"))

(defun org-remark-koreader--relocate-bookmarks (bookmarks notes-buf)
  "Put the point markers in BOOKMARKS back on their `page' XPointer.

For a bookmark this is the most reliable route, not the weakest.  After
a change to the source a highlight has to be found again by its text; a
bookmark has no such text, but its XPointer names a block and an offset
inside it.  As long as the document has the same blocks, that path
still points at the same place, even when text has been added
elsewhere.

Returns the number of bookmarks that no longer have a place."
  (let* ((stale 0)
         (pages (mapcar (lambda (ov)
                          (org-remark-koreader--notes-page
                           notes-buf (overlay-get ov 'org-remark-id)))
                        bookmarks))
         (dom (org-remark-koreader-match-build-dom-for-pointers pages)))
    (cl-loop for ov in bookmarks
             for page in pages
             do
      (let ((position (and page
                           (org-remark-koreader-match-page-position page dom))))
        (if position
            (progn
              (move-overlay ov position position)
              (overlay-put ov '*org-remark-koreader-stale nil))
          (cl-incf stale)
          (overlay-put ov '*org-remark-koreader-stale
                       "`page' points outside the reconstructed tree"))))
    stale))

(defun org-remark-koreader--resolve-after-load (overlays notes-buf)
  "Check the KOReader marks in OVERLAYS after loading.

org-remark's own position correction is off for these types, so this is
the only place where positions are still put right after reopening.  An
overlay whose text no longer matches is moved only when that text can
be found again unambiguously.

Bookmarks take another route: see
`org-remark-koreader--relocate-bookmarks'."
  (let ((stale 0)
        (bookmarks nil))
    (dolist (ov overlays)
      (when (org-remark-koreader--own-type-p (overlay-get ov 'org-remark-type))
        (if (org-remark-koreader--bookmark-overlay-p ov)
            (push ov bookmarks)
          (let ((text (overlay-get ov '*org-remark-original-text)))
            (when (and text (not (string-empty-p text))
                       (not (equal text (buffer-substring-no-properties
                                         (overlay-start ov) (overlay-end ov)))))
              (unless (org-remark-koreader--relocate ov text)
                (cl-incf stale)))))))
    (when bookmarks
      (cl-incf stale (org-remark-koreader--relocate-bookmarks
                      (nreverse bookmarks) notes-buf)))
    (when (> stale 0)
      (message "org-remark-koreader: %d mark(s) could not be found unambiguously"
               stale))
    stale))

(add-hook 'org-remark-highlights-after-load-functions
          #'org-remark-koreader--resolve-after-load)

;;;; Report

(defconst org-remark-koreader-report-buffer "*org-remark-koreader*"
  "Name of the report buffer.")

(defun org-remark-koreader--report-reconciliation (state)
  "Write the reconciliation STATE into the current buffer."
  (when state
    (let ((new (org-remark-koreader-reconciliation-new state))
          (known (org-remark-koreader-reconciliation-known state))
          (changed (org-remark-koreader-reconciliation-changed state))
          (gone (org-remark-koreader-reconciliation-disappeared state))
          (lost (org-remark-koreader-reconciliation-unresolvable state)))
      (when known
        (insert (format "\nreconciliation: %d new, %d already known\n"
                        (length new) (length known))))
      (when changed
        (insert (format "\nChanged in KOReader (%d):\n" (length changed)))
        (pcase-dolist (`(,mark . ,fields) changed)
          (insert (format "  %s — %s\n"
                          (string-join fields " and ")
                          (org-remark-koreader--excerpt
                           (org-remark-koreader-mark-text mark))))))
      (when lost
        (insert (format "\nNo longer placeable (%d):\n" (length lost)))
        (insert "These annotations were already there, but can no longer be\n"
                "found in this source.  The mark is gone; the note is not.\n")
        (dolist (mark lost)
          (insert (format "  %s\n"
                          (org-remark-koreader--excerpt
                           (org-remark-koreader-mark-text mark))))))
      (when gone
        (insert (format "\nGone from KOReader (%d):\n" (length gone)))
        (insert "These annotations are still in the notes file but no longer\n"
                "in the sidecar.  They are not removed automatically: a note\n"
                "you wrote alongside would disappear with them.\n")
        (pcase-dolist (`(,id . ,entry) gone)
          (insert (format "  %s  %s\n" id
                          (org-remark-koreader--excerpt
                           (or (plist-get entry :title)
                               (plist-get entry :text))))))))))

(defun org-remark-koreader--excerpt (text)
  "Return a short rendering of TEXT for the report."
  (let ((text (or text "")))
    (if (< 66 (length text))
        (concat (substring text 0 66) "…")
      text)))

(defconst org-remark-koreader-note-actions
  '((write . "written")
    (unchanged . "unchanged, the baseline already matched")
    (keep-local . "edited locally, not overwritten")
    (keep-existing . "existing note, not overwritten")
    (conflict . "changed on both sides — local text kept")
    (unsafe . "skipped: would be read as an Org heading")
    (no-headline . "no headline found"))
  "What the outcomes of writing a note mean.

Reporting a bare count would mislead: zero notes written can mean there
was nothing to do or that something went wrong, and that difference
ought to be visible.")

(defun org-remark-koreader--report (document marks placed notes state)
  "Show what the import of DOCUMENT with MARKS produced.
PLACED is the number of marks placed, NOTES an alist from outcome to
count for the notes, STATE the reconciliation."
  (let ((summary (org-remark-koreader-match-summary marks))
        (export (org-remark-koreader-export-file
                 (org-remark-koreader-document-source-path document)))
        (rejections (org-remark-koreader-document-rejections document)))
    (with-current-buffer (get-buffer-create org-remark-koreader-report-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert (format "KOReader import: %s\n"
                        (org-remark-koreader-document-identity document))
                (format "sidecar: %s\n"
                        (org-remark-koreader-document-sidecar-path document))
                (format "annotations: %d, placed: %d\n"
                        (length marks) placed))
        (dolist (cell summary)
          (insert (format "  %-14s %d\n" (car cell) (cdr cell))))
        (when notes
          (insert "\nnotes:\n")
          (dolist (cell notes)
            (insert (format "  %2d  %s\n" (cdr cell)
                            (or (alist-get (car cell)
                                           org-remark-koreader-note-actions)
                                (symbol-name (car cell)))))))
        (org-remark-koreader--report-reconciliation state)
        (when export
          (insert "\nThere is an annotation export beside the sidecar:\n"
                  (format "  %s\n" export)
                  "It is not read along; it is a transport file, not a\n"
                  "second authoritative sidecar.\n"))
        (when rejections
          (insert "\nRejected annotations:\n")
          (pcase-dolist (`(,index . ,reason) rejections)
            (insert (format "  [%d] %s\n" index reason))))
        (let ((unresolved
               (seq-filter (lambda (mark)
                             (eq (org-remark-koreader-mark-confidence mark)
                                 'unresolved))
                           marks)))
          (when unresolved
            (insert (format "\nNot placed (%d):\n" (length unresolved)))
            (dolist (mark unresolved)
              (insert (format "  %s | %s | %s\n"
                              (org-remark-koreader-mark-kind mark)
                              (or (org-remark-koreader-mark-pos0 mark)
                                  (org-remark-koreader-mark-page mark))
                              (string-join
                               (org-remark-koreader-mark-anomalies mark) "; ")))
              (when-let* ((text (org-remark-koreader-mark-text mark)))
                (insert (format "      %S\n"
                                (if (< 70 (length text))
                                    (concat (substring text 0 70) "…")
                                  text)))))))
        (goto-char (point-min))))
    (display-buffer org-remark-koreader-report-buffer)))

(defun org-remark-koreader--chapter-names ()
  "Return the names of the spine documents in this buffer.

To be fetched before the report is built: `nov-documents' is
buffer-local, and in the report buffer it does not exist."
  (when (boundp 'nov-documents)
    (mapcar (lambda (entry) (format "%s" (car entry)))
            (append (symbol-value 'nov-documents) nil))))

(defun org-remark-koreader--report-book (per-chapter here names)
  "Show what the import produced per chapter.
PER-CHAPTER is an alist from document index to outcome, HERE the index
of the chapter the reader was on, NAMES the document names."
  (let ((document (plist-get (cdr (car per-chapter)) :document))
        (placed 0)
        (annotations 0))
    (with-current-buffer (get-buffer-create org-remark-koreader-report-buffer)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (special-mode)
        (insert (format "KOReader-import: %s\n"
                        (org-remark-koreader-document-identity document))
                (format "sidecar: %s\n"
                        (org-remark-koreader-document-sidecar-path document))
                "\nPer chapter.  An annotation belongs to one chapter; in the other\n"
                "chapters it counts as `elsewhere'.\n\n")
        (pcase-dolist (`(,index . ,result) per-chapter)
          (let ((count (seq-count
                        (lambda (mark)
                          (and (org-remark-koreader-mark-beg mark)
                               (not (eq (org-remark-koreader-mark-confidence mark)
                                        'elsewhere))))
                        (plist-get result :marks))))
            (ignore count)
            (cl-incf placed (plist-get result :placed))
            (setq annotations (length (plist-get result :marks)))
            (insert (format "  %-14s %2d placed%s\n"
                            (or (nth index names) (format "document %d" index))
                            (plist-get result :placed)
                            (if (= index here) "   ← you were here" "")))))
        (insert (format "\nannotaties: %d, geplaatst: %d\n" annotations placed))
        (when (< placed annotations)
          (insert (format "%d not placed; open `%s' in the chapter\n"
                          (- annotations placed)
                          "org-remark-koreader-report")
                  "they belong to for the reason.\n"))
        (goto-char (point-min))))
    (display-buffer org-remark-koreader-report-buffer)))

;;;###autoload
(defun org-remark-koreader-report ()
  "Show the report of the last import in this buffer."
  (interactive)
  (if (get-buffer org-remark-koreader-report-buffer)
      (display-buffer org-remark-koreader-report-buffer)
    (user-error "No import done in this buffer yet")))

;;;; Reading in again

;;;###autoload
(defun org-remark-koreader-reload ()
  "Build the KOReader marks in this buffer again.

Differs from `org-remark-koreader-import' in what happens beforehand.
Import lays its outcome beside what is already there; reload first
throws every mark away and reads them back from the notes file.  That
removes marks left behind in the buffer with no headline to go with
them — after an import on a source that has since changed, for
instance.

The notes file leads here and is not touched: what sits there comes
back, and only then is the sidecar laid alongside again."
  (interactive)
  (unless (buffer-file-name)
    (user-error "This buffer does not belong to a file"))
  (org-remark-highlights-clear)
  (org-remark-highlights-load)
  (org-remark-koreader-import))

;;;; Inspecting one mark

(defconst org-remark-koreader--inspect-fields
  '(("kind" . "org-remark-koreader-kind")
    ("chapter" . "org-remark-koreader-chapter")
    ("colour" . "org-remark-koreader-color")
    ("style" . "org-remark-koreader-drawer")
    ("page" . "org-remark-koreader-page")
    ("pos0" . "org-remark-koreader-pos0")
    ("pos1" . "org-remark-koreader-pos1")
    ("date" . "org-remark-koreader-datetime")
    ("DOM version" . "org-remark-koreader-cre-dom-version")
    ("identity" . "org-remark-koreader-identity")
    ("tuple" . "org-remark-koreader-tuple"))
  "Fields `org-remark-koreader-inspect-mark' shows, in order.")

(defconst org-remark-koreader-inspect-buffer "*org-remark-koreader-mark*"
  "Name of the buffer in which one mark is shown.")

(defun org-remark-koreader--mark-at-point ()
  "Return the KOReader overlay at point, or nil.

Looks one character back as well, because a bookmark is zero length: it
sits between two characters and `overlays-at' does not find it."
  (let ((overlays (overlays-in (max (point-min) (1- (point)))
                               (min (point-max) (1+ (point))))))
    (seq-find (lambda (ov)
                (and (org-remark-koreader--own-type-p
                      (overlay-get ov 'org-remark-type))
                     (<= (overlay-start ov) (point))
                     (<= (point) (overlay-end ov))))
              overlays)))

(defun org-remark-koreader--inspect-value (ov notes-buf property)
  "Return PROPERTY of OV, from NOTES-BUF or else from the overlay itself.

The notes file takes precedence: that is what has been stored.  The
overlay carries these fields only while this session's import is still
fresh."
  (or (org-remark-koreader--notes-property
       notes-buf (overlay-get ov 'org-remark-id) property)
      (overlay-get ov (intern property))))

;;;###autoload
(defun org-remark-koreader-inspect-mark ()
  "Show what sits behind the KOReader mark at point.

Shows which annotation it is, where KOReader had it, where it ended up
here and how that place was determined.  Without this a mark is a
coloured piece of text about which nothing more can be said."
  (interactive)
  (let ((ov (or (org-remark-koreader--mark-at-point)
                (user-error "No KOReader mark at point"))))
    (let* ((id (overlay-get ov 'org-remark-id))
           (notes-file (org-remark-notes-get-file-name))
           (notes-buf (and notes-file (file-exists-p notes-file)
                           (find-file-noselect notes-file)))
           (note (org-remark-koreader--notes-entry
                  notes-buf id #'org-remark-koreader--headline-body))
           (text (overlay-get ov '*org-remark-original-text))
           (confidence (overlay-get ov '*org-remark-koreader-confidence))
           (stale (overlay-get ov '*org-remark-koreader-stale)))
      (with-current-buffer (get-buffer-create org-remark-koreader-inspect-buffer)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (special-mode)
          (insert (format "%-12s %s\n" "id" id))
          (dolist (field org-remark-koreader--inspect-fields)
            (when-let* ((value (org-remark-koreader--inspect-value
                                ov notes-buf (cdr field))))
              (insert (format "%-12s %s\n" (car field) value))))
          (insert (format "%-12s %d–%d\n" "in this buffer"
                          (overlay-start ov) (overlay-end ov)))
          (insert (format "%-12s %s\n" "determined as"
                          (or confidence "unknown — not from this session")))
          (when stale
            (insert (format "%-12s %s\n" "note" stale)))
          (when (and text (not (string-empty-p text)))
            (insert (format "\nmarked text:\n%s\n" text)))
          (when (and note (not (string-empty-p note)))
            (insert (format "\nnote:\n%s" note)))
          (goto-char (point-min))))
      (display-buffer org-remark-koreader-inspect-buffer))))

;;;; Minor mode

;;;###autoload
(define-minor-mode org-remark-koreader-mode
  "Show KOReader annotations for this file as org-remark marks."
  :lighter " KOR"
  (when org-remark-koreader-mode
    (unless org-remark-mode (org-remark-mode +1))
    ;; In an EPUB `org-remark-nov' decides where the notes file goes, what
    ;; "source file" means, and the reloading when a chapter is turned.
    ;; Without that mode everything lands under one headline.
    (when (and (derived-mode-p 'nov-mode)
               (fboundp 'org-remark-nov-mode)
               (not (bound-and-true-p org-remark-nov-mode)))
      (org-remark-nov-mode +1))))

(provide 'org-remark-koreader)
;;; org-remark-koreader.el ends here
