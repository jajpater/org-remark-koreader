;;; spike-notes-backend.el --- Can the sidecar be the notes store?  -*- lexical-binding: t; -*-

;; org-remark keeps its annotations in a second file: an Org file beside the
;; document.  This package therefore writes everything twice -- once in
;; KOReader's sidecar, once in the marginalia file.  The question this
;; experiment answers is whether that second copy is unavoidable.
;;
;; It is not.  org-remark never reads the notes file itself: it asks
;; `org-remark-notes-get-file-name' for a name and hands that to
;; `find-file-noselect'.  Everything after that happens in a buffer.  So a
;; file-name handler -- the mechanism TRAMP uses to make a remote path behave
;; like a local one -- can serve a buffer whose Org text is made from the
;; sidecar the moment org-remark asks for it, with no file on disk and no
;; change to org-remark.
;;
;; This script builds exactly that and measures it against the corpus.  It is
;; an experiment, not part of the package: nothing here is loaded by
;; `org-remark-koreader.el', and it writes nothing anywhere.  Its `write-region'
;; captures the text org-remark wanted to save and drops it, because proving
;; that the funnel exists is a different thing from writing to a sidecar.
;;
;; Usage:
;;
;;     emacs --batch -Q -L . -L <org-remark> -l test/spike-notes-backend.el \
;;           -f org-remark-koreader-spike-main [path-to-corpus]

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'org)
(require 'org-remark)
(require 'org-remark-koreader)

(defconst org-remark-koreader-spike-prefix "/korsdr:"
  "Prefix that marks a path as served by the spike's handler.

Any string works as long as it cannot occur as a real path.  The name
after it is the source document, plus `.org' so that `auto-mode-alist'
puts the notes buffer in `org-mode' -- org-remark reads it with
`org-entry-get' and friends, which need a real Org buffer.")

(defvar org-remark-koreader-spike-unknown nil
  "Handler operations the spike does not implement.
Kept so the experiment can say what it got away with not knowing.")

(defvar org-remark-koreader-spike-written nil
  "The text org-remark last wanted to save.  Nothing is written to disk.")

;;;; The virtual notes file

(defun org-remark-koreader-spike-name (source)
  "Return the virtual notes file name for SOURCE."
  (concat org-remark-koreader-spike-prefix source ".org"))

(defun org-remark-koreader-spike--source (name)
  "Return the source document behind virtual file NAME."
  (file-name-sans-extension
   (substring name (length org-remark-koreader-spike-prefix))))

(defun org-remark-koreader-spike--notes-text (source)
  "Build the Org text org-remark expects for SOURCE, out of its sidecar.

Only marks with a resolved, non-empty range are emitted.  A bookmark is
a point without extent; org-remark's housekeeping deletes a zero-length
overlay unless a type says otherwise, and this experiment deliberately
runs with no types of its own -- the question here is the store, not the
pens."
  (let* ((sidecar (org-remark-koreader-sidecar-file source))
         (document (org-remark-koreader-document-from-sidecar sidecar source))
         (marks (with-temp-buffer
                  (insert-file-contents source)
                  (org-remark-koreader-match-resolve
                   (org-remark-koreader-document-marks document)))))
    (with-temp-buffer
      (insert (format "* %s\n:PROPERTIES:\n:%s: %s\n:END:\n"
                      (file-name-nondirectory source)
                      org-remark-prop-source-file
                      (file-name-nondirectory source)))
      (dolist (mark marks)
        (let ((beg (org-remark-koreader-mark-beg mark))
              (end (org-remark-koreader-mark-end mark))
              (text (or (org-remark-koreader-mark-text mark) ""))
              (note (org-remark-koreader-mark-note mark)))
          (when (and beg end (< beg end))
            (let ((line (replace-regexp-in-string "\n" " " text)))
              (insert (format "** %s\n:PROPERTIES:\n:%s: %s\n:%s: %d\n:%s: %d\n"
                              line
                              org-remark-prop-id (org-remark-koreader-mark-id mark)
                              org-remark-prop-source-beg beg
                              org-remark-prop-source-end end))
              (insert (format ":org-remark-original-text: %s\n:END:\n" line))
              (when note (insert note "\n"))))))
      (buffer-string))))

;;;; The handler

(defun org-remark-koreader-spike-handler (operation &rest args)
  "Serve OPERATION with ARGS for a virtual notes file.

The set below is what `find-file-noselect', `org-mode' and
`org-remark-save' turned out to need; anything else is recorded and
answered with nil.  Two of these must return a string even when the
answer is uninteresting: give `directory-file-name' or
`file-name-as-directory' a nil and Emacs reports \"Invalid handler in
`file-name-handler-alist'\", which says nothing about the cause."
  (let ((name (or (car args) "")))
    (cl-flet ((bare (n) (substring n (length org-remark-koreader-spike-prefix))))
      (pcase operation
        ('expand-file-name name)
        ('file-truename name)
        ('abbreviate-file-name name)
        ('file-name-sans-versions name)
        ;; These recurse into the handler if called on the virtual name.
        ('file-name-nondirectory (file-name-nondirectory (bare name)))
        ('file-name-directory
         (concat org-remark-koreader-spike-prefix (file-name-directory (bare name))))
        ('directory-file-name
         (concat org-remark-koreader-spike-prefix (directory-file-name (bare name))))
        ('file-name-as-directory
         (concat org-remark-koreader-spike-prefix (file-name-as-directory (bare name))))
        ('unhandled-file-name-directory (file-name-directory (bare name)))
        ('file-exists-p (file-exists-p (org-remark-koreader-spike--source name)))
        ('file-readable-p (file-readable-p (org-remark-koreader-spike--source name)))
        ('file-writable-p t)
        ('file-regular-p t)
        ('file-directory-p (string-suffix-p "/" name))
        ('file-symlink-p nil)
        ('file-remote-p nil)
        ('file-newer-than-file-p nil)
        ('vc-registered nil)
        ('file-locked-p nil) ('lock-file nil) ('unlock-file nil)
        ('make-auto-save-file-name nil) ('find-backup-file-name nil)
        ('verify-visited-file-modtime t) ('set-visited-file-modtime nil)
        ('file-modes (file-modes (org-remark-koreader-spike--source name)))
        ;; A borrowed inode would make Emacs think this is the source file
        ;; itself and reuse its buffer, leaving the notes in fundamental-mode.
        ('file-attributes
         (let ((real (file-attributes (org-remark-koreader-spike--source name))))
           (list nil 1 (user-uid) (group-gid)
                 (nth 4 real) (nth 5 real) (nth 6 real)
                 (length (org-remark-koreader-spike--notes-text
                          (org-remark-koreader-spike--source name)))
                 "-r--r--r--" nil
                 (mod (abs (sxhash name)) 100000) 999999)))
        ('get-file-buffer
         (seq-find (lambda (b) (equal (buffer-file-name b) name)) (buffer-list)))
        ('insert-file-contents
         (let ((text (org-remark-koreader-spike--notes-text
                      (org-remark-koreader-spike--source name))))
           (when (nth 1 args) (setq buffer-file-name name))
           (insert text)
           (when (nth 1 args) (set-buffer-modified-p nil))
           (list name (length text))))
        ('write-region
         (let ((start (nth 0 args)) (end (nth 1 args)))
           (setq org-remark-koreader-spike-written
                 (if (stringp start) start
                   (buffer-substring-no-properties (or start (point-min))
                                                   (or end (point-max)))))
           (set-visited-file-modtime '(0 0))
           nil))
        (_ (cl-pushnew operation org-remark-koreader-spike-unknown) nil)))))

(defun org-remark-koreader-spike-install ()
  "Put the handler in place and point org-remark at it."
  (add-to-list 'file-name-handler-alist
               (cons (concat "\\`" (regexp-quote org-remark-koreader-spike-prefix))
                     #'org-remark-koreader-spike-handler))
  ;; org-remark records the source under a name relative to the notes file's
  ;; own directory.  That directory is virtual here, so the relative name
  ;; would come out as a row of `..' that matches nothing.
  (setq org-remark-source-file-name #'file-name-nondirectory)
  (setq org-remark-notes-file-name
        (lambda () (org-remark-koreader-spike-name (buffer-file-name)))))

;;;; Measuring

(defun org-remark-koreader-spike--fold (text)
  "Return TEXT with every run of whitespace as one space."
  (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or text ""))))

(defun org-remark-koreader-spike--case (directory)
  "Run the whole org-remark cycle over the corpus case in DIRECTORY.

Returns a plist with the counts.  `:moved' is the one that matters: it
counts overlays that ended up somewhere other than where the store said,
which is what would happen if org-remark quietly re-searched the text."
  (let* ((source (car (directory-files directory :full
                                       "\\`source\\.\\(md\\|txt\\)\\'")))
         (buffer (find-file-noselect source))
         (stored (with-current-buffer buffer
                   (org-remark-highlights-get
                    (find-file-noselect
                     (org-remark-koreader-spike-name source))))))
    (with-current-buffer buffer
      ;; org-remark defers loading until the buffer has a window.
      (set-window-buffer (selected-window) buffer)
      (org-remark-mode +1)
      (org-remark-highlights-load)
      (let ((overlays (seq-filter (lambda (ov) (overlay-get ov 'org-remark-id))
                                  (overlays-in (point-min) (point-max))))
            (verbatim 0) (spanning 0) (moved 0))
        (dolist (ov overlays)
          (let* ((id (overlay-get ov 'org-remark-id))
                 (shown (buffer-substring-no-properties
                         (overlay-start ov) (overlay-end ov)))
                 (kept (overlay-get ov '*org-remark-original-text))
                 (entry (seq-find (lambda (h) (equal (plist-get h :id) id)) stored))
                 (location (and entry (plist-get entry :location))))
            (if (equal (org-remark-koreader-spike--fold shown)
                       (org-remark-koreader-spike--fold kept))
                (setq verbatim (1+ verbatim))
              ;; KOReader stores rendered text, so a mark across `**bold**' or
              ;; a `> ' quote marker covers more source than it stored.  That
              ;; is the range being right, not wrong.
              (setq spanning (1+ spanning)))
            (when (and location
                       (not (and (= (overlay-start ov) (car location))
                                 (= (overlay-end ov) (cdr location)))))
              (setq moved (1+ moved)))))
        (list :name (file-name-nondirectory (directory-file-name directory))
              :overlays (length overlays)
              :verbatim verbatim :spanning spanning :moved moved)))))

(defun org-remark-koreader-spike-report (&optional corpus)
  "Run the experiment over CORPUS and report what org-remark did with it."
  (org-remark-koreader-spike-install)
  (let* ((corpus (or corpus "test/corpus/md-txt"))
         (cases (seq-filter #'file-directory-p
                            (directory-files corpus :full "\\`[^.]")))
         (overlays 0) (verbatim 0) (spanning 0) (moved 0) (broken 0))
    (dolist (directory (sort cases #'string<))
      (condition-case err
          (let ((result (org-remark-koreader-spike--case directory)))
            (setq overlays (+ overlays (plist-get result :overlays))
                  verbatim (+ verbatim (plist-get result :verbatim))
                  spanning (+ spanning (plist-get result :spanning))
                  moved (+ moved (plist-get result :moved)))
            (princ (format "%-24s %2d overlays  %2d verbatim  %2d spanning  %2d moved\n"
                           (plist-get result :name)
                           (plist-get result :overlays)
                           (plist-get result :verbatim)
                           (plist-get result :spanning)
                           (plist-get result :moved))))
        (error (setq broken (1+ broken))
               (princ (format "%-24s BROKE: %S\n"
                              (file-name-nondirectory
                               (directory-file-name directory))
                              err)))))
    (princ (format "\ntotal: %d overlays  %d verbatim  %d spanning  %d moved  %d cases broke\n"
                   overlays verbatim spanning moved broken))
    (princ (format "handler operations not implemented: %S\n"
                   org-remark-koreader-spike-unknown))))

(defun org-remark-koreader-spike-show-save (source)
  "Mark something by hand in SOURCE and show what a save funnels out.

The point is the shape of what arrives: one Org text, in one call, for
the whole store.  A backend would have one place to translate, and one
place where an unknown field could be lost."
  (let ((buffer (find-file-noselect source)))
    (with-current-buffer buffer
      (set-window-buffer (selected-window) buffer)
      (org-remark-mode +1)
      (org-remark-highlights-load)
      (goto-char (point-min))
      (search-forward " ")
      (org-remark-mark (point-min) (point))
      (setq org-remark-koreader-spike-written nil)
      (org-remark-save)
      (princ (format "\nsave funnelled %d characters through one write-region:\n\n%s"
                     (length (or org-remark-koreader-spike-written ""))
                     (or org-remark-koreader-spike-written "(nothing)"))))))

(defun org-remark-koreader-spike-main ()
  "Entry point for batch use."
  (org-remark-koreader-spike-report (car command-line-args-left)))

(provide 'spike-notes-backend)
;;; spike-notes-backend.el ends here
