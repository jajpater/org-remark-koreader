;;; org-remark-koreader-model.el --- Normalised annotation model  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 jajpater

;; Author: jajpater
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Turns a parsed sidecar into marks of a fixed shape.
;;
;; The kind of an annotation is decided here once and never derived again
;; elsewhere.  KOReader has no kind field: the distinction follows from which
;; fields are present.
;;
;; This layer knows nothing about org-remark and nothing about Markdown.  It
;; knows only KOReader's data and the identity that follows from it.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'org-remark-koreader-lua)

;;;; Model

(cl-defstruct (org-remark-koreader-mark
               (:constructor org-remark-koreader-mark-create)
               (:copier nil))
  "One KOReader annotation in normalised form.

KIND is `bookmark', `highlight' or `annotation'.

CONFIDENCE records how the buffer position was determined: `exact',
`disambiguated', `projected', `joined', `approximate', `elsewhere' or
`unresolved'.  An estimated position must never be presented as an
exact one.

RAW keeps the original table, so that fields this model does not know
about remain inspectable without parsing again."
  id kind text note page pos0 pos1
  chapter pageno datetime datetime-updated drawer color
  confidence beg end candidates anomalies tuple raw)

(cl-defstruct (org-remark-koreader-document
               (:constructor org-remark-koreader-document-create)
               (:copier nil))
  "One document with its annotations.

IDENTITY is the key under which annotations of this document are
recognised; see `org-remark-koreader-source-identity'.

REJECTIONS holds annotations that are structurally unusable, as a list
of (INDEX . REASON).  They are reported, not silently dropped: an
import that shrinks without saying so is worse than one that says what
went wrong."
  identity source-path sidecar-path
  cre-dom-version partial-md5 title
  marks rejections)

(defconst org-remark-koreader-kind-types
  '((highlight . koreader-highlight)
    (annotation . koreader-annotation)
    (bookmark . koreader-bookmark))
  "Mapping from kind to `org-remark-type'.")

(defun org-remark-koreader-mark-org-remark-type (mark)
  "Return the `org-remark-type' belonging to MARK."
  (alist-get (org-remark-koreader-mark-kind mark)
             org-remark-koreader-kind-types))

;;;; XPointer

(cl-defstruct (org-remark-koreader-xpointer
               (:constructor org-remark-koreader-xpointer-create)
               (:copier nil))
  "A CRengine XPointer, split into block path and character offset.
RAW is the untouched value; it stays authoritative when storing."
  path offset raw)

(defun org-remark-koreader-parse-xpointer (string)
  "Split STRING into block path and offset.
An XPointer such as \"/html/body/p[2]/text().221\" points at character
221 in that block's text node.  When the offset suffix is missing,
OFFSET stays nil rather than 0: unknown is not the same as the
beginning."
  (when (and string (stringp string) (not (string-empty-p string)))
    (if (string-match "\\`\\(.*\\)\\.\\([0-9]+\\)\\'" string)
        (org-remark-koreader-xpointer-create
         :path (match-string 1 string)
         :offset (string-to-number (match-string 2 string))
         :raw string)
      (org-remark-koreader-xpointer-create :path string :raw string))))

(defun org-remark-koreader-same-node-p (mark)
  "Return non-nil when both XPointers of MARK lie in the same text node.

This is the cheap prediction: if the answer is yes, the stored text
appears verbatim in the source; if it is no, it never does.  It costs
two string comparisons and needs no reconstruction of the DOM."
  (let ((pos0 (org-remark-koreader-parse-xpointer
               (org-remark-koreader-mark-pos0 mark)))
        (pos1 (org-remark-koreader-parse-xpointer
               (org-remark-koreader-mark-pos1 mark))))
    (and pos0 pos1
         (equal (org-remark-koreader-xpointer-path pos0)
                (org-remark-koreader-xpointer-path pos1)))))

(defun org-remark-koreader-offset-span (mark)
  "Return the number of characters between MARK's offsets, or nil.
Only meaningful when both XPointers lie in the same text node."
  (let ((from (org-remark-koreader-parse-xpointer
               (org-remark-koreader-mark-pos0 mark)))
        (to (org-remark-koreader-parse-xpointer
             (org-remark-koreader-mark-pos1 mark))))
    (when (and from to
               (org-remark-koreader-xpointer-offset from)
               (org-remark-koreader-xpointer-offset to))
      (- (org-remark-koreader-xpointer-offset to)
         (org-remark-koreader-xpointer-offset from)))))

;;;; Canonicalisation and baseline
;;
;; Canonicalising may only undo what the Org storage itself does.  Any
;; transformation beyond that makes a genuine user edit invisible; any
;; transformation too few makes a note count as locally changed while in
;; fact only the storage threw something away.

(defun org-remark-koreader--canonicalize-note (note)
  "Canonicalisation v1 of NOTE.
Normalises line endings to LF and removes trailing whitespace.  Leading
and interior whitespace are left alone: those survive the Org storage
and may therefore be a genuine user edit."
  (string-trim-right
   (replace-regexp-in-string "\r\n?\\|\r" "\n" (or note ""))))

(defun org-remark-koreader--note-baseline-hash (canonical-note)
  "Baseline hash of CANONICAL-NOTE.
The encoding is explicit: `secure-hash' documents no particular
encoding for multibyte strings, even though it behaves like UTF-8 in
practice.  The domain prefix keeps hashes for different purposes apart;
the version number makes a later change to the canonicalisation
recognisable rather than silent."
  (secure-hash
   'sha256
   (encode-coding-string
    (concat "org-remark-koreader:note-baseline:v1\0" canonical-note)
    'utf-8-unix)))

;;;; Identity

(defun org-remark-koreader-source-identity (source-path)
  "Return the document identity for SOURCE-PATH.

The name deliberately differs from the slot accessor
`org-remark-koreader-document-identity': that is the stored value, this
is how it is computed.

It is the file name without its directory.  That choice is driven by
what has to stay stable: the same annotation must remain recognisable
when the document sits at another path — on the e-reader, on the
computer, in a different directory — and also when its contents are
updated.

`partial_md5_checksum' does not qualify: it changes as soon as the
document changes, after which every annotation would get a new identity
and show up as a duplicate on the next import.  It is kept anyway, as
diagnostic data.  `doc_path' does not qualify either: that is the path
on the reading device.

Two documents with the same file name therefore share an identity.
That is harmless: org-remark already separates annotations per source
file, so a collision can at worst produce two identical IDs inside
different collections, never a mix-up within one document."
  (file-name-nondirectory source-path))

(defun org-remark-koreader--identity-tuple (identity kind pos0 pos1 datetime)
  "Build the identity tuple from IDENTITY, KIND, POS0, POS1 and DATETIME.
The tuple holds only fields that do not change through editing: `note',
`datetime_updated' and `text' are deliberately left out, because
KOReader lets all three change without it becoming a different
annotation."
  (mapconcat (lambda (part) (or part ""))
             (list identity (symbol-name kind) pos0 pos1 datetime)
             "\0"))

(defun org-remark-koreader-tuple-readable (tuple)
  "Return TUPLE in readable form.

The tuple uses NUL as its separator, because that character cannot
occur in any field and the hash is therefore unambiguous.  It must not
be written down as such: a single NUL makes Emacs and other tools treat
the whole file as binary, after which not one letter reads correctly.
What gets stored is this rendering, meant for people; the hash stays
computed over the form above."
  (and tuple (string-join (split-string tuple "\0") " | ")))

(defun org-remark-koreader--identity-hash (tuple)
  "Return the ID belonging to TUPLE.
Sixteen hex digits is ample to tell marks apart within one document,
and stays readable in a property drawer."
  (substring
   (secure-hash 'sha256
                (encode-coding-string
                 (concat "org-remark-koreader:mark-id:v1\0" tuple)
                 'utf-8-unix))
   0 16))

;;;; Normalisation

(defconst org-remark-koreader--required-fields
  '("datetime" "page" "pageno")
  "Fields every annotation has, whatever its kind.")

(defconst org-remark-koreader--required-range-fields
  '("chapter" "color" "drawer" "pos0" "pos1" "text")
  "Fields only an annotation with a text range has.

`chapter' and `text' are listed here because a bookmark can lack both:
a document without a table of contents has no chapter, and a bookmark's
text is a caption KOReader generates, which need not be there either.
An annotation with a text range always has them — although `chapter' is
then sometimes the empty string.")

(defun org-remark-koreader--annotation-kind (table)
  "Determine the kind of TABLE.
An absent `drawer' means bookmark; that is KOReader's own rule.  A
present `note' then distinguishes an annotation from a bare highlight."
  (cond
   ((not (org-remark-koreader-lua-has-key-p table "drawer")) 'bookmark)
   ((org-remark-koreader-lua-has-key-p table "note") 'annotation)
   (t 'highlight)))

(defun org-remark-koreader--string-field (table key)
  "Return the string value of KEY in TABLE, or nil."
  (let ((value (org-remark-koreader-lua-get table key)))
    (and (stringp value) value)))

(defun org-remark-koreader--missing-fields (table kind)
  "Return the expected fields missing from TABLE for kind KIND."
  (seq-remove (lambda (field) (org-remark-koreader-lua-has-key-p table field))
              (append org-remark-koreader--required-fields
                      (unless (eq kind 'bookmark)
                        org-remark-koreader--required-range-fields))))

(defun org-remark-koreader--normalize-annotation (table identity)
  "Turn the parsed TABLE into a mark inside document IDENTITY.
Signals an ordinary error when expected fields are missing; the caller
catches it and reports the annotation as rejected."
  (unless (org-remark-koreader-lua-table-p table)
    (error "Annotation is not a table"))
  (let* ((kind (org-remark-koreader--annotation-kind table))
         (missing (org-remark-koreader--missing-fields table kind)))
    (when missing
      (error "Expected fields missing for kind %s: %s"
             kind (string-join missing ", ")))
    (let* ((pos0 (org-remark-koreader--string-field table "pos0"))
           (pos1 (org-remark-koreader--string-field table "pos1"))
           (datetime (org-remark-koreader--string-field table "datetime"))
           (tuple (org-remark-koreader--identity-tuple
                   identity kind pos0 pos1 datetime)))
      (org-remark-koreader-mark-create
       :id (org-remark-koreader--identity-hash tuple)
       :tuple tuple
       :kind kind
       :text (org-remark-koreader--string-field table "text")
       :note (org-remark-koreader--string-field table "note")
       :page (org-remark-koreader--string-field table "page")
       :pos0 pos0
       :pos1 pos1
       :chapter (org-remark-koreader--string-field table "chapter")
       :pageno (org-remark-koreader-lua-get table "pageno")
       :datetime datetime
       :datetime-updated (org-remark-koreader--string-field
                          table "datetime_updated")
       :drawer (org-remark-koreader--string-field table "drawer")
       :color (org-remark-koreader--string-field table "color")
       :confidence 'unresolved
       :raw table))))

(defun org-remark-koreader-document-from-sidecar (sidecar-path source-path)
  "Read SIDECAR-PATH and return the document for SOURCE-PATH.

A missing `annotations' key, an empty list and a structurally invalid
list are three different things; only the last is an error."
  (let* ((data (org-remark-koreader-lua-read-file sidecar-path))
         (identity (org-remark-koreader-source-identity source-path))
         (annotations (org-remark-koreader-lua-get data "annotations"))
         (doc-props (org-remark-koreader-lua-get data "doc_props"))
         (marks nil)
         (rejections nil)
         (index 0))
    (when (and annotations (not (org-remark-koreader-lua-table-p annotations)))
      (signal 'org-remark-koreader-lua-error
              (list (format "%s: `annotations' is not a table" sidecar-path))))
    (dolist (entry (and annotations (org-remark-koreader-lua-array annotations)))
      (cl-incf index)
      (condition-case err
          (push (org-remark-koreader--normalize-annotation entry identity) marks)
        (error (push (cons index (error-message-string err)) rejections))))
    (org-remark-koreader-document-create
     :identity identity
     :source-path source-path
     :sidecar-path sidecar-path
     :cre-dom-version (org-remark-koreader-lua-get data "cre_dom_version")
     :partial-md5 (org-remark-koreader--string-field data "partial_md5_checksum")
     :title (and (org-remark-koreader-lua-table-p doc-props)
                 (org-remark-koreader--string-field doc-props "title"))
     :marks (nreverse marks)
     :rejections (nreverse rejections))))

(provide 'org-remark-koreader-model)
;;; org-remark-koreader-model.el ends here
