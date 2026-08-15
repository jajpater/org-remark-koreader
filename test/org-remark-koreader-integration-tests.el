;;; org-remark-koreader-integration-tests.el --- The full cycle  -*- lexical-binding: t; -*-

;; The decisive test: import → Org headline with a complete body → save →
;; kill buffer → reopen → overlay plus editable note, without duplicates.
;;
;; Here the assumptions come together that only running can check: that
;; `org-remark-highlight-mark' with every property in one call yields a fully
;; stored annotation, that our own body-insertion function is idempotent, and
;; that the resolver really runs after reopening.
;;
;; Running them (org-remark has to be on the load path):
;;
;;     emacs --batch -Q -L . -L <pad-naar-org-remark> -l ert \
;;           -l test/org-remark-koreader-integration-tests.el \
;;           -f ert-run-tests-batch-and-exit 2>&1 | grep -E '^Ran |FAILED'

;;; Code:

(require 'ert)
(require 'cl-lib)

(defvar org-remark-koreader-integration-tests--available
  (require 'org-remark-koreader nil :noerror)
  "Non-nil when the package and org-remark could be loaded.")

(defvar org-remark-koreader-integration-tests--root
  (locate-dominating-file
   (or load-file-name buffer-file-name default-directory)
   "org-remark-koreader.el")
  "Root of the package.")

(defvar org-remark-koreader-integration-tests--dir nil
  "Temporary working directory of the running test.")

(defun org-remark-koreader-integration-tests--fixture-dir ()
  "Return the directory of the controlled fixture."
  (expand-file-name "test/fixtures/koreader-v2026.07-basic"
                    org-remark-koreader-integration-tests--root))

(defun org-remark-koreader-integration-tests--setup ()
  "Copy the fixture to a temporary directory and return the source path.

The work happens on a copy: the test has to be able to show that source
and sidecar stay untouched, and that can only be checked if they could
have been changed."
  (let* ((dir (make-temp-file "org-remark-koreader-" :directory))
         (source (expand-file-name "source.md" dir))
         (sdr (expand-file-name "source.sdr" dir))
         (fixture (org-remark-koreader-integration-tests--fixture-dir)))
    (setq org-remark-koreader-integration-tests--dir dir)
    (copy-file (expand-file-name "source.md" fixture) source)
    (make-directory sdr)
    (copy-file (expand-file-name "source.sdr/metadata.md.lua" fixture)
               (expand-file-name "metadata.md.lua" sdr))
    source))

(defun org-remark-koreader-integration-tests--teardown ()
  "Clean up the temporary directory and every buffer belonging to it."
  (when org-remark-koreader-integration-tests--dir
    (dolist (buffer (buffer-list))
      (when-let* ((file (buffer-file-name buffer)))
        (when (string-prefix-p org-remark-koreader-integration-tests--dir file)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))
    (delete-directory org-remark-koreader-integration-tests--dir :recursive)
    (setq org-remark-koreader-integration-tests--dir nil)))

(defun org-remark-koreader-integration-tests--visit (source)
  "Open SOURCE in a buffer org-remark considers visible.

`org-remark-highlights-load' postpones itself as long as there is no
window.  In batch that window does exist, but it does not show the
buffer; without this step the loading would never happen and the test
would pass by doing nothing."
  (let ((buffer (find-file-noselect source)))
    (set-window-buffer (selected-window) buffer)
    (with-current-buffer buffer
      ;; In ordinary use `org-remark-global-tracking-mode' does this through
      ;; `find-file-hook'.  That path postpones loading until there is a
      ;; window and hangs on `post-command-hook' for it — and that does not
      ;; run in batch.  So the mode is switched on directly here, with a
      ;; window, so that the loading really happens.
      (if org-remark-mode
          (org-remark-highlights-load)
        (org-remark-mode +1)))
    buffer))

(defmacro org-remark-koreader-integration-tests--with-fixture (var &rest body)
  "Run BODY with VAR bound to the source path of a fresh fixture."
  (declare (indent 1))
  `(progn
     (skip-unless org-remark-koreader-integration-tests--available)
     (let ((,var (org-remark-koreader-integration-tests--setup))
           (org-remark-notes-file-name "marginalia.org"))
       (unwind-protect (progn ,@body)
         (org-remark-koreader-integration-tests--teardown)))))

(defun org-remark-koreader-integration-tests--koreader-overlays ()
  "Return the KOReader overlays in the current buffer, ordered by position."
  (sort (seq-filter (lambda (ov)
                      (org-remark-koreader--own-type-p
                       (overlay-get ov 'org-remark-type)))
                    (overlays-in (point-min) (point-max)))
        (lambda (a b) (< (overlay-start a) (overlay-start b)))))

(defun org-remark-koreader-integration-tests--range-overlays ()
  "Return the KOReader overlays with a text range, ordered by position."
  (seq-remove #'org-remark-koreader--bookmark-overlay-p
              (org-remark-koreader-integration-tests--koreader-overlays)))

(defun org-remark-koreader-integration-tests--bookmark-overlays ()
  "Return the KOReader point markers, ordered by position."
  (seq-filter #'org-remark-koreader--bookmark-overlay-p
              (org-remark-koreader-integration-tests--koreader-overlays)))

(defun org-remark-koreader-integration-tests--texts (overlays)
  "Return the buffer text under each of OVERLAYS."
  (mapcar (lambda (ov)
            (buffer-substring-no-properties
             (overlay-start ov) (overlay-end ov)))
          overlays))

(defconst org-remark-koreader-integration-tests--fixture-texts
  '("unieke ankerlicht" "donkere horizon" "kalme noorderwind")
  "The three text ranges from the fixture, in document order.")

(defun org-remark-koreader-integration-tests--notes-file (source)
  "Return the path to the notes file belonging to SOURCE."
  (expand-file-name "marginalia.org" (file-name-directory source)))

(defun org-remark-koreader-integration-tests--body (source id)
  "Return the complete body of the headline with ID belonging to SOURCE."
  (with-current-buffer (find-file-noselect
                        (org-remark-koreader-integration-tests--notes-file source))
    (org-with-wide-buffer
     (let ((headline (org-find-property org-remark-prop-id id)))
       (when headline
         (goto-char headline)
         (org-remark-koreader--headline-body))))))

(defun org-remark-koreader-integration-tests--note-mark (marks)
  "Return the mark that has a note from MARKS."
  (seq-find #'org-remark-koreader-mark-note marks))

;;;; The full cycle

(ert-deftest org-remark-koreader-integration/import-places-and-writes ()
  "Import yields overlays and a complete note in the Org file."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (let* ((marks (org-remark-koreader-import))
             (overlays (org-remark-koreader-integration-tests--koreader-overlays))
             (note-mark (org-remark-koreader-integration-tests--note-mark marks)))
        ;; Three text ranges and one point marker for the bookmark.
        (should (= (length marks) 4))
        (should (= (length overlays) 4))
        (should (equal (org-remark-koreader-integration-tests--texts
                        (org-remark-koreader-integration-tests--range-overlays))
                       org-remark-koreader-integration-tests--fixture-texts))
        ;; The body read back carries no trailing newline: the Org storage
        ;; throws that away.  That is precisely why canonicalisation exists.
        (should (equal (org-remark-koreader-integration-tests--body
                        source (org-remark-koreader-mark-id note-mark))
                       (org-remark-koreader-mark-note note-mark)))))))

(ert-deftest org-remark-koreader-integration/survives-save-kill-reopen ()
  "After saving, closing and reopening, mark and note are still there.
This is the test the rest of the design rests on."
  (org-remark-koreader-integration-tests--with-fixture source
    (let (id note)
      (with-current-buffer (org-remark-koreader-integration-tests--visit source)
        (let* ((marks (org-remark-koreader-import))
               (mark (org-remark-koreader-integration-tests--note-mark marks)))
          (setq id (org-remark-koreader-mark-id mark)
                note (org-remark-koreader-mark-note mark)))
        (org-remark-save)
        (set-buffer-modified-p nil)
        (kill-buffer))
      ;; Reopen.
      (with-current-buffer (org-remark-koreader-integration-tests--visit source)
        (let ((overlays (org-remark-koreader-integration-tests--koreader-overlays)))
          (should (= (length overlays) 4))
          ;; The type survives, and with it the generic methods still apply.
          (should (seq-every-p (lambda (ov)
                                 (org-remark-koreader--own-type-p
                                  (overlay-get ov 'org-remark-type)))
                               overlays))
          (should (equal (org-remark-koreader-integration-tests--texts
                          (org-remark-koreader-integration-tests--range-overlays))
                         org-remark-koreader-integration-tests--fixture-texts))
          ;; The point marker is zero length; without our own
          ;; `housekeep-delete-p' method the housekeeping would have removed
          ;; it.
          (let ((bookmarks (org-remark-koreader-integration-tests--bookmark-overlays)))
            (should (= (length bookmarks) 1))
            (should (= (overlay-start (car bookmarks))
                       (overlay-end (car bookmarks))))))
        ;; The note is still there in full — not the display value truncated
        ;; at 200 characters that org-remark returns itself.
        (should (equal (org-remark-koreader-integration-tests--body source id)
                       note))))))

(ert-deftest org-remark-koreader-integration/second-import-makes-no-duplicates ()
  "Importing again yields the same marks, no more."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (org-remark-save)
      (let ((na-een (length (org-remark-koreader-integration-tests--koreader-overlays))))
        (org-remark-koreader-import)
        (org-remark-save)
        (should (= (length (org-remark-koreader-integration-tests--koreader-overlays))
                   na-een))
        ;; Nothing may have been added in the Org file either.
        (with-current-buffer (find-file-noselect
                              (org-remark-koreader-integration-tests--notes-file source))
          (org-with-wide-buffer
           (goto-char (point-min))
           (should (= (cl-loop while (re-search-forward "^:org-remark-id:" nil t)
                               count t)
                      4))))))))

;;;; The notes file stays text

(ert-deftest org-remark-koreader-integration/the-notes-file-has-no-control-characters ()
  "The notes file written contains no control characters.

One NUL is enough to make Emacs open the whole file as raw bytes: every
accented character then appears as an octal escape and `file' reports
it as `data'.  The sidecar is user input, so no field may reach the
property drawer unfiltered."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (org-remark-save))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally
       (org-remark-koreader-integration-tests--notes-file source))
      (goto-char (point-min))
      (should-not (re-search-forward "[\0-\10\13-\37\177]" nil :noerror)))))

(ert-deftest org-remark-koreader-integration/the-notes-file-is-valid-utf-8 ()
  "The notes file written can be read as UTF-8."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (org-remark-save))
    (let* ((file (org-remark-koreader-integration-tests--notes-file source))
           (raw (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally file)
                  (buffer-string))))
      (should (equal (decode-coding-string raw 'utf-8 :nocopy)
                     (decode-coding-string raw 'utf-8))))))

(ert-deftest org-remark-koreader-integration/the-tuple-stays-readable ()
  "The identity tuple is stored readably, not with NUL separators.
The hash stays computed over the NUL form; only the stored rendering
differs."
  (skip-unless org-remark-koreader-integration-tests--available)
  (let ((tuple (org-remark-koreader--identity-tuple
                "book.md" 'highlight "/html/body/p/text().1"
                "/html/body/p/text().9" "2026-08-14 12:00:00")))
    (should (string-match-p "\0" tuple))
    (should-not (string-match-p "\0" (org-remark-koreader-tuple-readable tuple)))
    (should (equal (org-remark-koreader-tuple-readable tuple)
                   (concat "book.md | highlight | /html/body/p/text().1"
                           " | /html/body/p/text().9 | 2026-08-14 12:00:00")))
    ;; De weergave gaat door de property-filter heen zonder te veranderen.
    (should (equal (org-remark-koreader--property-value
                    (org-remark-koreader-tuple-readable tuple))
                   (org-remark-koreader-tuple-readable tuple)))))

(ert-deftest org-remark-koreader-integration/a-note-with-a-heading-line-is-refused ()
  "A note that would become an Org heading is reported, not written.
Writing it silently would split the highlight and make every annotation
after it lose its link."
  (skip-unless org-remark-koreader-integration-tests--available)
  (should (org-remark-koreader--note-breaks-structure-p "line\n* heading\nline"))
  (should (org-remark-koreader--note-breaks-structure-p "** begin"))
  (should-not (org-remark-koreader--note-breaks-structure-p "some *emphasis* here"))
  (should-not (org-remark-koreader--note-breaks-structure-p "3 * 4 = 12")))

;;;; Behoud van lokale bewerkingen

(ert-deftest org-remark-koreader-integration/a-local-edit-is-kept ()
  "A note the user has edited is not overwritten.
The difference is exactly the evidence that nothing may be written."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (let* ((marks (org-remark-koreader-import))
             (id (org-remark-koreader-mark-id
                  (org-remark-koreader-integration-tests--note-mark marks)))
             (notes (find-file-noselect
                     (org-remark-koreader-integration-tests--notes-file source))))
        (with-current-buffer notes
          (org-with-wide-buffer
           (goto-char (org-find-property org-remark-prop-id id))
           (org-end-of-meta-data :full)
           (insert "The reader's own addition.\n"))
          (save-buffer))
        (org-remark-koreader-import)
        (should (string-match-p
                 "The reader's own addition"
                 (org-remark-koreader-integration-tests--body source id)))))))

(ert-deftest org-remark-koreader-integration/an-emptied-note-stays-empty ()
  "A note the user has erased is not filled again.
There is a baseline, so the empty body is a deliberate deletion and not
a missing import."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (let* ((marks (org-remark-koreader-import))
             (id (org-remark-koreader-mark-id
                  (org-remark-koreader-integration-tests--note-mark marks)))
             (notes (find-file-noselect
                     (org-remark-koreader-integration-tests--notes-file source))))
        (with-current-buffer notes
          (org-with-wide-buffer
           (goto-char (org-find-property org-remark-prop-id id))
           (org-end-of-meta-data :full)
           (delete-region (point) (save-excursion (org-end-of-subtree))))
          (save-buffer))
        (org-remark-koreader-import)
        (should-not (org-remark-koreader-integration-tests--body source id))))))

;;;; Reconciliatie

(defun org-remark-koreader-integration-tests--sidecar (source)
  "Return the sidecar path belonging to SOURCE."
  (expand-file-name "source.sdr/metadata.md.lua" (file-name-directory source)))

(defun org-remark-koreader-integration-tests--drop-annotation (source text)
  "Remove the annotation with TEXT from the sidecar belonging to SOURCE.
Mimics what KOReader does when you erase a mark."
  (let ((sidecar (org-remark-koreader-integration-tests--sidecar source)))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8-unix))
        (insert-file-contents sidecar))
      (goto-char (point-min))
      (should (search-forward (format "\"%s\"" text) nil :noerror))
      ;; Terug naar het begin van het blok en het hele blok weghalen.
      (should (re-search-backward "^        \\[[0-9]+\\] = {" nil :noerror))
      (let ((beg (match-beginning 0)))
        (should (re-search-forward "^        },\n" nil :noerror))
        (delete-region beg (point)))
      ;; De overgebleven blokken hernummeren.  KOReader schrijft een
      ;; aaneengesloten lijst, en de lezer weigert terecht een gat: dat zou
      ;; betekenen dat er een annotatie ontbreekt.
      (goto-char (point-min))
      (let ((index 0))
        (while (re-search-forward "^        \\[\\([0-9]+\\)\\] = {" nil :noerror)
          (replace-match (number-to-string (cl-incf index)) nil :literal nil 1)))
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region (point-min) (point-max) sidecar nil :silent)))))

(ert-deftest org-remark-koreader-integration/a-vanished-annotation-is-reported ()
  "An annotation gone from KOReader is reported, not removed.

Throwing it away silently would take the note the user wrote alongside
with it.  Leaving it silently is as bad: dead headlines then pile up
without anyone noticing."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (org-remark-save))
    (org-remark-koreader-integration-tests--drop-annotation
     source "donkere horizon")
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (let ((report (with-current-buffer org-remark-koreader-report-buffer
                      (buffer-string))))
        (should (string-match-p "Gone from KOReader (1)" report))
        (should (string-match-p "donkere horizon" report)))
      ;; The headline is still there: not silently removed.
      (with-current-buffer (find-file-noselect
                            (org-remark-koreader-integration-tests--notes-file
                             source))
        (org-with-wide-buffer
         (goto-char (point-min))
         (should (search-forward "donkere horizon" nil :noerror)))))))

(ert-deftest org-remark-koreader-integration/new-and-known-are-told-apart ()
  "The second import reports nothing as new."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (org-remark-save)
      (org-remark-koreader-import)
      (let ((report (with-current-buffer org-remark-koreader-report-buffer
                      (buffer-string))))
        (should (string-match-p "0 new, 4 already known" report))))))

(ert-deftest org-remark-koreader-integration/a-colour-change-in-koreader-is-reported ()
  "When the colour changes in KOReader, that is visible."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (org-remark-save))
    ;; Green becomes blue in the sidecar.
    (let ((sidecar (org-remark-koreader-integration-tests--sidecar source)))
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8-unix))
          (insert-file-contents sidecar))
        (goto-char (point-min))
        (should (search-forward "\"green\"" nil :noerror))
        (replace-match "\"blue\"")
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region (point-min) (point-max) sidecar nil :silent))))
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (let ((report (with-current-buffer org-remark-koreader-report-buffer
                      (buffer-string))))
        (should (string-match-p "Changed in KOReader (1)" report))
        (should (string-match-p "colour — donkere horizon" report))))))

(ert-deftest org-remark-koreader-integration/conflict-is-told-from-a-local-change ()
  "Changed locally only is something other than changed on both sides.

Either way the local text is kept, but only the second case is a
conflict the user has to see."
  (skip-unless org-remark-koreader-integration-tests--available)
  (let* ((baseline (org-remark-koreader--note-baseline-hash "origineel")))
    ;; Alleen lokaal: KOReader stuurt nog steeds de oorspronkelijke tekst.
    (should (eq (org-remark-koreader--note-action
                 baseline "lokaal bewerkt" "origineel")
                'keep-local))
    ;; Beide kanten: KOReader stuurt iets nieuws én lokaal is bewerkt.
    (should (eq (org-remark-koreader--note-action
                 baseline "lokaal bewerkt" "nieuw uit KOReader")
                'conflict))
    ;; Alleen KOReader: lokaal onaangeroerd, dus verversen mag.
    (should (eq (org-remark-koreader--note-action
                 baseline "origineel" "nieuw uit KOReader")
                'write))))

(ert-deftest org-remark-koreader-integration/your-own-highlights-do-not-count ()
  "An ordinary org-remark highlight does not count as a vanished KOReader mark.
Without this distinction every mark made by hand would show up in the
report as something gone from KOReader."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (org-remark-save)
      ;; Een eigen markering, buiten KOReader om.
      (org-remark-mark (point-min) (+ (point-min) 8))
      (org-remark-save)
      (org-remark-koreader-import)
      (let ((report (with-current-buffer org-remark-koreader-report-buffer
                      (buffer-string))))
        (should-not (string-match-p "Gone from KOReader" report))))))

;;;; De vier toestanden los

(ert-deftest org-remark-koreader-integration/four-states ()
  "The decision to write depends on the baseline, not on emptiness."
  (skip-unless org-remark-koreader-integration-tests--available)
  (let* ((note "de notitie")
         (hash (org-remark-koreader--note-baseline-hash note)))
    (should (eq (org-remark-koreader--note-action nil "" note) 'write))
    (should (eq (org-remark-koreader--note-action nil "iets anders" note)
                'keep-existing))
    (should (eq (org-remark-koreader--note-action hash note note) 'unchanged))
    (should (eq (org-remark-koreader--note-action hash note "nieuwe tekst")
                'write))
    (should (eq (org-remark-koreader--note-action hash "aangepast" note)
                'keep-local))
    ;; Een lege body mét baseline is een verwijdering, geen ontbrekende import.
    (should (eq (org-remark-koreader--note-action hash "" note) 'keep-local))))

;;;; Bookmarks

(ert-deftest org-remark-koreader-integration/zero-length-overlay-survives-housekeeping ()
  "A point marker is not cleaned away.

This checks the representation, not the placement: the overlay is made
synthetically here.  Whether a lone `page' XPointer can be translated
reliably into a buffer position is another question."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-mode +1)
      (let ((ov (org-remark-highlight-mark
                 (point-min) (point-min) "punt0000" :load
                 "koreader-bookmark" 'org-remark-koreader-bookmark
                 '(org-remark-type koreader-bookmark))))
        (should ov)
        (should (= (overlay-start ov) (overlay-end ov)))
        (org-remark-highlights-housekeep)
        (should (overlay-buffer ov))
        (should (= (overlay-start ov) (overlay-end ov)))))))

(ert-deftest org-remark-koreader-integration/an-ordinary-zero-length-overlay-is-cleaned-up ()
  "Without a type of its own the housekeeping does clean a zero-length overlay.
That makes it visible that the test above demonstrates something."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-mode +1)
      (let ((ov (org-remark-highlight-mark
                 (point-min) (point-min) "punt0001" :load nil nil nil)))
        (should ov)
        (org-remark-highlights-housekeep)
        (should-not (overlay-buffer ov))))))

;;;; Untouched

(ert-deftest org-remark-koreader-integration/source-and-sidecar-stay-identical ()
  "After an import the source file and sidecar are byte-identical to the original."
  (org-remark-koreader-integration-tests--with-fixture source
    (let* ((fixture (org-remark-koreader-integration-tests--fixture-dir))
           (sidecar (expand-file-name
                     "source.sdr/metadata.md.lua"
                     org-remark-koreader-integration-tests--dir)))
      (with-current-buffer (org-remark-koreader-integration-tests--visit source)
        (org-remark-koreader-import)
        (org-remark-save))
      (dolist (pair (list (cons source (expand-file-name "source.md" fixture))
                          (cons sidecar
                                (expand-file-name "source.sdr/metadata.md.lua"
                                                  fixture))))
        (should (equal (with-temp-buffer
                         (set-buffer-multibyte nil)
                         (insert-file-contents-literally (car pair))
                         (buffer-string))
                       (with-temp-buffer
                         (set-buffer-multibyte nil)
                         (insert-file-contents-literally (cdr pair))
                         (buffer-string))))))))

;;;; The resolver runs

(ert-deftest org-remark-koreader-integration/the-resolver-moves-after-a-source-change ()
  "After a change to the source our own resolver moves the overlay.

org-remark's own position correction is off for these types, so if the
overlay moves along, that came from the resolver on
`org-remark-highlights-after-load-functions'."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (org-remark-save)
      (set-buffer-modified-p nil)
      (kill-buffer))
    ;; Add text at the front, so that every stored position shifts.
    (with-temp-buffer
      (insert-file-contents source)
      (goto-char (point-min))
      (insert "An inserted paragraph up front.\n\n")
      (write-region (point-min) (point-max) source nil :silent))
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (let ((overlays (org-remark-koreader-integration-tests--koreader-overlays)))
        (should (= (length overlays) 4))
        (should (equal (org-remark-koreader-integration-tests--texts
                        (org-remark-koreader-integration-tests--range-overlays))
                       org-remark-koreader-integration-tests--fixture-texts))))))

(ert-deftest org-remark-koreader-integration/bookmark-follows-the-inserted-paragraph ()
  "After a change to the source a bookmark returns to its own block.

It has no text to search for; its XPointer names a block and an offset.
If the document shifts, the bookmark shifts with it — with nothing to
search for at all."
  (org-remark-koreader-integration-tests--with-fixture source
    (let (before)
      (with-current-buffer (org-remark-koreader-integration-tests--visit source)
        (org-remark-koreader-import)
        (setq before (overlay-start
                    (car (org-remark-koreader-integration-tests--bookmark-overlays))))
        (org-remark-save)
        (set-buffer-modified-p nil)
        (kill-buffer))
      (let ((addition "An inserted paragraph up front.\n\n"))
        (with-temp-buffer
          (insert-file-contents source)
          (goto-char (point-min))
          (insert addition)
          (write-region (point-min) (point-max) source nil :silent))
        (with-current-buffer (org-remark-koreader-integration-tests--visit source)
          (let ((bookmarks (org-remark-koreader-integration-tests--bookmark-overlays)))
            (should (= (length bookmarks) 1))
            (should (= (overlay-start (car bookmarks))
                       (+ before (length addition))))))))))

;;;; Reading in again

(ert-deftest org-remark-koreader-integration/reload-clears-a-mark-without-a-headline ()
  "Reload throws away what no longer belongs.

A mark left behind in the buffer without a headline in the notes file
survives an import — which lays its outcome beside it — but not a
reload, which clears first and then reads back."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (org-remark-save)
      ;; A mark without a headline, of the kind left behind when the source
      ;; has changed since the previous import.
      (let ((ov (make-overlay (point-min) (+ (point-min) 4))))
        (overlay-put ov 'org-remark-id "orphaned")
        (overlay-put ov 'org-remark-type 'koreader-highlight))
      (should (= (length (org-remark-koreader-integration-tests--koreader-overlays))
                 5))
      (org-remark-koreader-reload)
      (should (= (length (org-remark-koreader-integration-tests--koreader-overlays))
                 4))
      (should (equal (org-remark-koreader-integration-tests--texts
                      (org-remark-koreader-integration-tests--range-overlays))
                     org-remark-koreader-integration-tests--fixture-texts)))))

(ert-deftest org-remark-koreader-integration/reload-makes-no-duplicates ()
  "Reloading again changes neither buffer nor notes file."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (org-remark-save)
      (org-remark-koreader-reload)
      (org-remark-save)
      (should (= (length (org-remark-koreader-integration-tests--koreader-overlays))
                 4))
      (with-current-buffer (find-file-noselect
                            (org-remark-koreader-integration-tests--notes-file source))
        (org-with-wide-buffer
         (goto-char (point-min))
         (should (= (cl-loop while (re-search-forward "^:org-remark-id:" nil t)
                             count t)
                    4)))))))

;;;; Inspecting one mark

(ert-deftest org-remark-koreader-integration/inspect-shows-origin-and-note ()
  "Inspect shows where the mark comes from and what belongs to it."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (let* ((marks (org-remark-koreader-import))
             (mark (org-remark-koreader-integration-tests--note-mark marks)))
        (goto-char (org-remark-koreader-mark-beg mark))
        (org-remark-koreader-inspect-mark)
        (let ((shown (with-current-buffer org-remark-koreader-inspect-buffer
                       (buffer-string))))
          (should (string-match-p "kind *annotation" shown))
          (should (string-match-p
                   (regexp-quote (org-remark-koreader-mark-pos0 mark)) shown))
          (should (string-match-p
                   (regexp-quote (org-remark-koreader-mark-id mark)) shown))
          ;; The note comes from the notes file, not from the sidecar: this
          ;; shows what sits in Emacs.
          (should (string-match-p "noorderwind" shown)))))))

(ert-deftest org-remark-koreader-integration/inspect-finds-the-bookmark ()
  "A point marker is zero length; inspect finds it anyway."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (let ((bookmark (car (org-remark-koreader-integration-tests--bookmark-overlays))))
        (goto-char (overlay-start bookmark))
        (org-remark-koreader-inspect-mark)
        (let ((shown (with-current-buffer org-remark-koreader-inspect-buffer
                       (buffer-string))))
          (should (string-match-p "kind *bookmark" shown))
          (should (string-match-p "page" shown)))))))

(ert-deftest org-remark-koreader-integration/inspect-without-a-mark-says-so ()
  "Outside a mark nothing happens silently."
  (org-remark-koreader-integration-tests--with-fixture source
    (with-current-buffer (org-remark-koreader-integration-tests--visit source)
      (org-remark-koreader-import)
      (goto-char (point-max))
      (should-error (org-remark-koreader-inspect-mark) :type 'user-error))))

(provide 'org-remark-koreader-integration-tests)
;;; org-remark-koreader-integration-tests.el ends here
