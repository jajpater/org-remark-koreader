;;; canonicalize-note-tests.el --- Contract for the note baseline  -*- lexical-binding: t; -*-

;; Records canonicalisation v1 and the baseline hash as an executable
;; contract.
;;
;; At its heart is the equivalence requirement: canonicalisation must
;; reproduce exactly what the Org storage does to a note.  Do less, and a note
;; looks locally changed while only the storage threw something away.  Do
;; more, and a genuine user edit becomes invisible.
;;
;; The file holds a reference implementation, but does not test that itself:
;; as soon as the package is loaded, every test calls the production functions
;;
;;     org-remark-koreader--canonicalize-note
;;     org-remark-koreader--note-baseline-hash
;;
;; and the reference falls back to its only other role, namely recording what
;; the contract is.  Without that inversion the reference would stay green
;; while the real implementation drifted.
;;
;; Running it — with the project directory on the load path, so the package is
;; found as soon as it exists:
;;
;;     emacs --batch -Q -L . -l ert -l test/canonicalize-note-tests.el \
;;           -f ert-run-tests-batch-and-exit 2>&1 | grep -E '^Ran |skipped|FAILED'
;;
;; The loading happens below in this file itself.  `-L .' only adds the
;; directory to `load-path' and loads nothing; without the `require' below the
;; contract tests would stay skipped even though the implementation exists.

;;; Code:

(require 'ert)
(require 'org)
(require 'subr-x)

;; Load the package if it can be found.  As long as it does not exist this is
;; a no-op and the suite runs against the reference implementation; the two
;; contract tests then report themselves visibly as `skipped'.
(require 'org-remark-koreader nil :noerror)

;;;; Reference implementation
;;
;; This is the normative description of canonicalisation v1.  Change nothing
;; here without raising the version number in the hash domain prefix and
;; renewing every existing baseline.

(defun canonicalize-note-tests--reference-canonicalize (note)
  "Canonicalisation v1 of NOTE.
Normalises line endings to LF and removes trailing whitespace.  Leading
and interior whitespace are left alone: those survive the Org storage
and may therefore be a genuine user edit."
  (string-trim-right
   (replace-regexp-in-string "\r\n?\\|\r" "\n" (or note ""))))

(defun canonicalize-note-tests--reference-hash (canonical-note)
  "Baseline hash of CANONICAL-NOTE.
The encoding is explicit: `secure-hash' documents no particular encoding
for multibyte strings, even though it behaves like UTF-8 in practice."
  (secure-hash
   'sha256
   (encode-coding-string
    (concat "org-remark-koreader:note-baseline:v1\0" canonical-note)
    'utf-8-unix)))

;;;; Dispatch: the production function as soon as it exists

(defun canonicalize-note-tests--package-loaded-p ()
  "Return non-nil when both production functions are available."
  (and (fboundp 'org-remark-koreader--canonicalize-note)
       (fboundp 'org-remark-koreader--note-baseline-hash)))

(defun canonicalize-note-tests--canonicalize (note)
  "Canonicalise NOTE with the production function when there is one."
  (if (fboundp 'org-remark-koreader--canonicalize-note)
      (org-remark-koreader--canonicalize-note note)
    (canonicalize-note-tests--reference-canonicalize note)))

(defun canonicalize-note-tests--hash (canonical-note)
  "Hash CANONICAL-NOTE with the production function when there is one."
  (if (fboundp 'org-remark-koreader--note-baseline-hash)
      (org-remark-koreader--note-baseline-hash canonical-note)
    (canonicalize-note-tests--reference-hash canonical-note)))

;;;; What the Org storage does to a note

(defun canonicalize-note-tests--roundtrip (note)
  "Write NOTE as a body under a headline and read it back.
Mimics what the adapter does and what `org-remark-notes-get-body' reads."
  (with-temp-buffer
    (org-mode)
    (insert "* Heading\n:PROPERTIES:\n:org-remark-id: abc\n:END:\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (org-end-of-meta-data :full)
    (insert note "\n")
    (goto-char (point-min))
    (org-next-visible-heading 1)
    (save-excursion
      (org-end-of-meta-data :full)
      (if (or (looking-at org-heading-regexp) (eobp))
          nil
        (buffer-substring-no-properties (point) (org-end-of-subtree))))))

(defconst canonicalize-note-tests--vectors
  '("hello"
    "text with a trailing space  "
    "text with a trailing tab\t"
    "text\n"
    "text\n\n\n"
    "text  \n  "
    "line one\nline two"
    "  leading space"
    "\ttab in front"
    "text\r\nwith crlf"
    "text\rwith a lone cr"
    ""
    "café naïve Ελληνικά 🧠"
    "line one\n\nblank line between\nline three")
  "Test vectors for canonicalisation v1.")

;;;; The central requirement

(ert-deftest canonicalize-note/matches-the-org-roundtrip ()
  "Canonicalisation reproduces exactly what the Org storage does to the text.
For every vector: canonicalising the result read back yields the same as
canonicalising the input."
  (dolist (note canonicalize-note-tests--vectors)
    (let ((from-storage (canonicalize-note-tests--canonicalize
                         (canonicalize-note-tests--roundtrip note)))
          (from-input (canonicalize-note-tests--canonicalize note)))
      (should (equal from-storage from-input)))))

;;;; What is and is not thrown away

(ert-deftest canonicalize-note/trailing-whitespace-goes ()
  "Spaces, tabs and newlines at the end go."
  (dolist (case '(("text  "        . "text")
                  ("text\t"        . "text")
                  ("text\n"        . "text")
                  ("text\n\n\n"    . "text")
                  ("text  \n  "    . "text")))
    (should (equal (canonicalize-note-tests--canonicalize (car case))
                   (cdr case)))))

(ert-deftest canonicalize-note/leading-and-interior-whitespace-stays ()
  "Everything but trailing whitespace is left alone.
A user who adds a space or a blank line has to stay visible."
  (dolist (note '("  leading space"
                  "\ttab in front"
                  "line one\n\nblank line between"
                  "two  spaces  inside"))
    (should (equal (canonicalize-note-tests--canonicalize note) note))))

(ert-deftest canonicalize-note/line-endings-normalised ()
  "CRLF and a lone CR become LF."
  (should (equal (canonicalize-note-tests--canonicalize "a\r\nb") "a\nb"))
  (should (equal (canonicalize-note-tests--canonicalize "a\rb") "a\nb"))
  (should (equal (canonicalize-note-tests--canonicalize "a\r\n\r\nb") "a\n\nb")))

(ert-deftest canonicalize-note/empty-and-nil-are-equal ()
  "An empty body comes back from Org as nil; that coincides with \"\"."
  (should (equal (canonicalize-note-tests--canonicalize nil) ""))
  (should (equal (canonicalize-note-tests--canonicalize "") ""))
  (should (equal (canonicalize-note-tests--canonicalize "   \n  ") "")))

(ert-deftest canonicalize-note/unicode-stays-intact ()
  "No normalisation happens; the text stays byte for byte the same."
  (dolist (note '("café naïve" "Ελληνικά" "“a quotation”" "emoji 🧠"))
    (should (equal (canonicalize-note-tests--canonicalize note) note))))

;;;; The hash

(ert-deftest canonicalize-note/hash-is-deterministic-and-sha256 ()
  "The hash is stable and has the length of SHA-256 in hex."
  (let ((h (canonicalize-note-tests--hash "a note")))
    (should (equal h (canonicalize-note-tests--hash "a note")))
    (should (= (length h) 64))
    (should (string-match-p "\\`[0-9a-f]+\\'" h))))

(ert-deftest canonicalize-note/hash-tells-different-notes-apart ()
  "Different content yields a different hash."
  (should-not (equal (canonicalize-note-tests--hash "note a")
                     (canonicalize-note-tests--hash "note b"))))

(ert-deftest canonicalize-note/hash-ignores-trailing-whitespace-only ()
  "What canonicalisation removes does not change the hash; the rest does."
  (should (equal (canonicalize-note-tests--hash
                  (canonicalize-note-tests--canonicalize "note\n\n"))
                 (canonicalize-note-tests--hash
                  (canonicalize-note-tests--canonicalize "note"))))
  (should-not (equal (canonicalize-note-tests--hash
                      (canonicalize-note-tests--canonicalize " note"))
                     (canonicalize-note-tests--hash
                      (canonicalize-note-tests--canonicalize "note")))))

(ert-deftest canonicalize-note/hash-is-encoding-independent ()
  "The explicit UTF-8 encoding makes the hash independent of buffer
locale settings."
  (let* ((note "café Ελληνικά 🧠")
         (h1 (let ((coding-system-for-write 'latin-1))
               (canonicalize-note-tests--hash note)))
         (h2 (let ((coding-system-for-write 'utf-8))
               (canonicalize-note-tests--hash note))))
    (should (equal h1 h2))))

;;;; The implementation must not drift from the contract
;;
;; These two tests skip visibly as long as the package is not loaded.  If a
;; `skipped' appears in the output, the suite ran against the reference; if it
;; does not, the real implementation was tested.

(ert-deftest canonicalize-note/implementation-follows-the-contract ()
  "The production function yields exactly what the reference does."
  (skip-unless (canonicalize-note-tests--package-loaded-p))
  (dolist (note (cons nil canonicalize-note-tests--vectors))
    (should (equal (org-remark-koreader--canonicalize-note note)
                   (canonicalize-note-tests--reference-canonicalize note)))))

(ert-deftest canonicalize-note/hash-implementation-follows-the-contract ()
  "The production hash yields exactly what the reference does."
  (skip-unless (canonicalize-note-tests--package-loaded-p))
  (dolist (note canonicalize-note-tests--vectors)
    (let ((canonical (canonicalize-note-tests--reference-canonicalize note)))
      (should (equal (org-remark-koreader--note-baseline-hash canonical)
                     (canonicalize-note-tests--reference-hash canonical))))))

(provide 'canonicalize-note-tests)
;;; canonicalize-note-tests.el ends here
