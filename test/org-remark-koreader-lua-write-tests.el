;;; org-remark-koreader-lua-write-tests.el --- Tests for the sidecar writer  -*- lexical-binding: t; -*-

;; The writer has one job that matters more than the rest: give a sidecar
;; back unchanged.  A sidecar holds reading state this package does not
;; understand and keys it has never seen, and the only way to be sure none of
;; it is lost is to compare bytes.
;;
;; `nothing-changes-in-a-round-trip' is therefore the test to look at first.
;; It reads every sidecar in the repository -- the generated corpus and the
;; one a real KOReader wrote -- writes it back and compares character for
;; character.  The remaining tests pin down the cases the corpus happens not
;; to contain.
;;
;; Running them:
;;
;;     emacs --batch -Q -L . -l ert -l test/org-remark-koreader-lua-write-tests.el \
;;           -f ert-run-tests-batch-and-exit 2>&1 | grep -E '^Ran |FAILED'

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org-remark-koreader-lua)
(require 'org-remark-koreader-lua-write)

(defconst org-remark-koreader-lua-write-tests--root
  (expand-file-name
   ".." (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "The repository root.")

(defun org-remark-koreader-lua-write-tests--sidecars ()
  "Return every sidecar in the repository, corpus and fixtures alike."
  (sort (append
         (file-expand-wildcards
          (expand-file-name "test/corpus/*/*/source.sdr/*.lua"
                            org-remark-koreader-lua-write-tests--root))
         (file-expand-wildcards
          (expand-file-name "test/fixtures/*/source.sdr/*.lua"
                            org-remark-koreader-lua-write-tests--root)))
        #'string<))

(defun org-remark-koreader-lua-write-tests--slurp (path)
  "Return the contents of PATH exactly as the reader sees them."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents path))
    (buffer-string)))

(defun org-remark-koreader-lua-write-tests--roundtrip (text origin)
  "Parse TEXT and write it back.  ORIGIN names it in errors."
  (let ((table (org-remark-koreader-lua-read-string text origin)))
    (org-remark-koreader-lua-write-string
     table (org-remark-koreader-lua-preamble text))))

(defun org-remark-koreader-lua-write-tests--value (text)
  "Write TEXT as the only value in a sidecar and return the whole file."
  (org-remark-koreader-lua-write-string
   (org-remark-koreader-lua--table-create :entries (list (cons "x" text)))))

;;;; The proof

(ert-deftest org-remark-koreader-lua-write/nothing-changes-in-a-round-trip ()
  "Every sidecar in the repository survives reading and writing unchanged."
  (let ((sidecars (org-remark-koreader-lua-write-tests--sidecars))
        (differing nil))
    ;; A count, so that an empty glob cannot pass for a clean run.
    (should (<= 20 (length sidecars)))
    (dolist (path sidecars)
      (let* ((original (org-remark-koreader-lua-write-tests--slurp path))
             (written (org-remark-koreader-lua-write-tests--roundtrip original path)))
        (unless (equal original written)
          (push (file-name-nondirectory path) differing))))
    (should (equal differing nil))))

(ert-deftest org-remark-koreader-lua-write/the-preamble-is-carried-over ()
  "The comment line KOReader opens with is part of the file, so it stays."
  (let ((text "-- /mnt/onboard/book.sdr/metadata.md.lua\nreturn {\n    [\"a\"] = 1,\n}\n"))
    (should (equal (org-remark-koreader-lua-preamble text)
                   "-- /mnt/onboard/book.sdr/metadata.md.lua\n"))
    (should (equal (org-remark-koreader-lua-write-tests--roundtrip text "test") text)))
  ;; And a file without one gets none invented for it.
  (let ((text "return {\n    [\"a\"] = 1,\n}\n"))
    (should (equal (org-remark-koreader-lua-preamble text) ""))
    (should (equal (org-remark-koreader-lua-write-tests--roundtrip text "test") text))))

;;;; Strings

(ert-deftest org-remark-koreader-lua-write/quotes-and-backslashes-are-escaped ()
  (should (equal (org-remark-koreader-lua-write-tests--value "a \"b\" c")
                 "return {\n    [\"x\"] = \"a \\\"b\\\" c\",\n}\n"))
  (should (equal (org-remark-koreader-lua-write-tests--value "a \\ b")
                 "return {\n    [\"x\"] = \"a \\\\ b\",\n}\n")))

(ert-deftest org-remark-koreader-lua-write/a-newline-becomes-a-line-continuation ()
  "KOReader writes a backslash and a real newline, which keeps a note readable.
Writing `\\n' instead would be valid Lua and a different file."
  (should (equal (org-remark-koreader-lua-write-tests--value "one\ntwo")
                 "return {\n    [\"x\"] = \"one\\\ntwo\",\n}\n")))

(ert-deftest org-remark-koreader-lua-write/control-characters-become-decimal-escapes ()
  (should (equal (org-remark-koreader-lua-write-tests--value "a\tb")
                 "return {\n    [\"x\"] = \"a\\9b\",\n}\n"))
  (should (equal (org-remark-koreader-lua-write-tests--value "a\rb")
                 "return {\n    [\"x\"] = \"a\\13b\",\n}\n")))

(ert-deftest org-remark-koreader-lua-write/an-escape-before-a-digit-is-padded ()
  "Lua reads up to three digits, so `\\1' followed by `23' would be one escape.
No fixture contains this; the padding is what keeps it from happening."
  (let ((written (org-remark-koreader-lua-write-tests--value "\C-a23")))
    (should (equal written "return {\n    [\"x\"] = \"\\00123\",\n}\n"))
    ;; And it reads back as the character it was, not as \123.
    (should (equal (org-remark-koreader-lua-get
                    (org-remark-koreader-lua-read-string written "test") "x")
                   "\C-a23"))))

(ert-deftest org-remark-koreader-lua-write/text-outside-ascii-stays-as-it-is ()
  (should (equal (org-remark-koreader-lua-write-tests--value "日本語 café")
                 "return {\n    [\"x\"] = \"日本語 café\",\n}\n")))

;;;; Values and shape

(ert-deftest org-remark-koreader-lua-write/every-kind-of-value-comes-back ()
  (let* ((text (concat "return {\n"
                       "    [\"yes\"] = true,\n"
                       "    [\"no\"] = false,\n"
                       "    [\"none\"] = nil,\n"
                       "    [\"whole\"] = 42,\n"
                       "    [\"half\"] = 0.5,\n"
                       "    [\"negative\"] = -7,\n"
                       "    [\"empty\"] = {},\n"
                       "    [\"nested\"] = {\n"
                       "        [1] = \"first\",\n"
                       "    },\n"
                       "}\n")))
    (should (equal (org-remark-koreader-lua-write-tests--roundtrip text "test") text))))

(ert-deftest org-remark-koreader-lua-write/the-order-of-the-keys-is-kept ()
  "The writer reproduces the order it read, and does not impose one.

Every sidecar in the corpus is already in sorted order, so the round trip
cannot tell the two rules apart; only a list of ten or more entries can,
because sorting keys as text puts 10 before 2."
  (let ((text (concat "return {\n"
                      "    [\"zebra\"] = 1,\n"
                      "    [\"aardvark\"] = 2,\n"
                      "}\n")))
    (should (equal (org-remark-koreader-lua-write-tests--roundtrip text "test") text)))
  (let ((text (concat "return {\n"
                      (mapconcat (lambda (n) (format "    [%d] = %d,\n" n n))
                                 (number-sequence 1 12) "")
                      "}\n")))
    (should (equal (org-remark-koreader-lua-write-tests--roundtrip text "test") text))))

(ert-deftest org-remark-koreader-lua-write/what-is-written-can-be-read-again ()
  "A changed table still yields a file the reader accepts and agrees with."
  (let* ((path (car (org-remark-koreader-lua-write-tests--sidecars)))
         (table (org-remark-koreader-lua-read-string
                 (org-remark-koreader-lua-write-tests--slurp path) path)))
    ;; Add a key the package knows nothing about, as a stand-in for the
    ;; reading state a future KOReader might store.
    (setf (org-remark-koreader-lua-table-entries table)
          (append (org-remark-koreader-lua-table-entries table)
                  (list (cons "a_field_from_the_future" "keep me"))))
    (let* ((written (org-remark-koreader-lua-write-string table))
           (again (org-remark-koreader-lua-read-string written "written")))
      (should (equal (org-remark-koreader-lua-get again "a_field_from_the_future")
                     "keep me"))
      (should (equal (org-remark-koreader-lua-keys again)
                     (org-remark-koreader-lua-keys table)))
      (should (equal (org-remark-koreader-lua-write-string again) written)))))

(provide 'org-remark-koreader-lua-write-tests)
;;; org-remark-koreader-lua-write-tests.el ends here
