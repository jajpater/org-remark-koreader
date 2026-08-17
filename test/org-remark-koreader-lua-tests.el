;;; org-remark-koreader-lua-tests.el --- Tests for the Lua reader  -*- lexical-binding: t; -*-

;; Running them:
;;
;;     emacs --batch -Q -L . -l ert -l test/org-remark-koreader-lua-tests.el \
;;           -f ert-run-tests-batch-and-exit 2>&1 | grep -E '^Ran |FAILED'

;;; Code:

(require 'ert)
(require 'org-remark-koreader-lua)

(defun org-remark-koreader-lua-tests--read (text)
  "Parse TEXT as sidecar content."
  (org-remark-koreader-lua-read-string text "test"))

(defun org-remark-koreader-lua-tests--value (text)
  "Parse `return { [\"x\"] = TEXT }' and return the value of x."
  (org-remark-koreader-lua-get
   (org-remark-koreader-lua-tests--read (format "return {\n  [\"x\"] = %s,\n}" text))
   "x"))

(defun org-remark-koreader-lua-tests--error (text)
  "Parse TEXT and return the error message, or nil on success."
  (condition-case err
      (progn (org-remark-koreader-lua-tests--read text) nil)
    (org-remark-koreader-lua-error (cadr err))))

(defmacro org-remark-koreader-lua-tests--should-reject (text)
  "Expect TEXT to be refused with a non-empty message."
  `(let ((message (org-remark-koreader-lua-tests--error ,text)))
     (should (stringp message))
     (should (string-match-p "expected" message))))

;;;; The shape KOReader writes

(ert-deftest org-remark-koreader-lua/reads-the-fixture ()
  "The controlled fixture parses into four annotations in written order."
  (let* ((file (expand-file-name
                "test/fixtures/koreader-v2026.07-basic/source.sdr/metadata.md.lua"
                (locate-dominating-file default-directory "org-remark-koreader-lua.el")))
         (root (org-remark-koreader-lua-read-file file))
         (annotations (org-remark-koreader-lua-array
                       (org-remark-koreader-lua-get root "annotations"))))
    (should (= (length annotations) 4))
    (should (equal (mapcar (lambda (a) (org-remark-koreader-lua-get a "text"))
                           annotations)
                   '("in KOReader v2026.07-annotatiefixture"
                     "unieke ankerlicht"
                     "donkere horizon"
                     "kalme noorderwind")))))

(ert-deftest org-remark-koreader-lua/a-bookmark-lacks-drawer ()
  "The distinction between bookmark and text range is field presence."
  (let* ((file (expand-file-name
                "test/fixtures/koreader-v2026.07-basic/source.sdr/metadata.md.lua"
                (locate-dominating-file default-directory "org-remark-koreader-lua.el")))
         (annotations (org-remark-koreader-lua-array
                       (org-remark-koreader-lua-get
                        (org-remark-koreader-lua-read-file file) "annotations"))))
    (should-not (org-remark-koreader-lua-has-key-p (nth 0 annotations) "drawer"))
    (should (org-remark-koreader-lua-has-key-p (nth 1 annotations) "drawer"))
    (should-not (org-remark-koreader-lua-has-key-p (nth 1 annotations) "note"))
    (should (org-remark-koreader-lua-has-key-p (nth 3 annotations) "note"))))

(ert-deftest org-remark-koreader-lua/a-multiline-note-stays-whole ()
  "A backslash followed by a real newline is one newline.
This is the shape a reader with a line-bound pattern misses in silence."
  (should (equal (org-remark-koreader-lua-tests--value "\"one\\\ntwo\\\nthree\"")
                 "one\ntwo\nthree")))

(ert-deftest org-remark-koreader-lua/escapes ()
  "The escapes the serializer produces."
  (should (equal (org-remark-koreader-lua-tests--value "\"said \\\"hi\\\"\"")
                 "said \"hi\""))
  (should (equal (org-remark-koreader-lua-tests--value "\"path\\\\to\"")
                 "path\\to"))
  (should (equal (org-remark-koreader-lua-tests--value "\"tab\\9here\"")
                 "tab\there"))
  (should (equal (org-remark-koreader-lua-tests--value "\"cr\\13here\"")
                 "cr\rhere"))
  (should (equal (org-remark-koreader-lua-tests--value "\"nul\\000here\"")
                 "nul\0here")))

(ert-deftest org-remark-koreader-lua/value-types ()
  "Strings, numbers, booleans, nil and tables."
  (should (equal (org-remark-koreader-lua-tests--value "\"text\"") "text"))
  (should (equal (org-remark-koreader-lua-tests--value "42") 42))
  (should (equal (org-remark-koreader-lua-tests--value "-7") -7))
  (should (equal (org-remark-koreader-lua-tests--value "0.23076923076923")
                 0.23076923076923))
  (should (equal (org-remark-koreader-lua-tests--value "1e+20") 1e+20))
  (should (eq (org-remark-koreader-lua-tests--value "true") t))
  (should (eq (org-remark-koreader-lua-tests--value "false") :false))
  (should (eq (org-remark-koreader-lua-tests--value "nil") :nil))
  (should (org-remark-koreader-lua-table-p
           (org-remark-koreader-lua-tests--value "{}"))))

(ert-deftest org-remark-koreader-lua/false-is-not-absent ()
  "A key whose value is `false' is present.
Were `false' to map onto nil, a field that is present would count as
missing — and the kind of an annotation rests on exactly that presence."
  (let ((table (org-remark-koreader-lua-tests--read
                "return { [\"flag\"] = false, }")))
    (should (org-remark-koreader-lua-has-key-p table "flag"))
    (should (eq (org-remark-koreader-lua-get table "flag") :false))
    (should-not (org-remark-koreader-lua-has-key-p table "absent"))))

(ert-deftest org-remark-koreader-lua/order-is-preserved ()
  "The order in which the fields were written is kept."
  (should (equal (org-remark-koreader-lua-keys
                  (org-remark-koreader-lua-tests--read
                   "return { [\"c\"] = 1, [\"a\"] = 2, [\"b\"] = 3, }"))
                 '("c" "a" "b"))))

(ert-deftest org-remark-koreader-lua/comments-and-whitespace ()
  "A leading comment line is part of the format."
  (should (equal (org-remark-koreader-lua-get
                  (org-remark-koreader-lua-tests--read
                   "-- /path/to/metadata.md.lua\nreturn {\n [\"a\"] = 1,\n}")
                  "a")
                 1)))

;;;; What gets refused

(ert-deftest org-remark-koreader-lua/refuses-executable-constructs ()
  "Anything that is not purely data is refused."
  (org-remark-koreader-lua-tests--should-reject
   "return { [\"a\"] = os.time(), }")
  (org-remark-koreader-lua-tests--should-reject
   "return { [\"a\"] = function() end, }")
  (org-remark-koreader-lua-tests--should-reject
   "return { [\"a\"] = require(\"x\"), }")
  (org-remark-koreader-lua-tests--should-reject
   "return { [\"a\"] = 1, } os.remove(\"/\")"))

(ert-deftest org-remark-koreader-lua/refuses-non-finite-numbers ()
  "inf and nan are not serialisable data."
  (org-remark-koreader-lua-tests--should-reject "return { [\"a\"] = inf, }")
  (org-remark-koreader-lua-tests--should-reject "return { [\"a\"] = nan, }")
  (org-remark-koreader-lua-tests--should-reject "return { [\"a\"] = -inf, }"))

(ert-deftest org-remark-koreader-lua/refuses-a-block-comment ()
  "A block comment marks data the serializer could not write."
  (org-remark-koreader-lua-tests--should-reject
   "return { [\"a\"] = nil --[[cycle]], }"))

(ert-deftest org-remark-koreader-lua/refuses-broken-structure ()
  "Unterminated forms and missing punctuation fail loudly."
  (org-remark-koreader-lua-tests--should-reject "return { [\"a\"] = \"unfinished")
  (org-remark-koreader-lua-tests--should-reject "return { [\"a\"] = 1,")
  (org-remark-koreader-lua-tests--should-reject "return { [\"a\"] 1, }")
  (org-remark-koreader-lua-tests--should-reject "return { a = 1, }")
  (org-remark-koreader-lua-tests--should-reject "{ [\"a\"] = 1, }")
  (org-remark-koreader-lua-tests--should-reject "return \"not a table\""))

(ert-deftest org-remark-koreader-lua/refuses-a-duplicate-key ()
  "The same key twice means one value gets lost."
  (org-remark-koreader-lua-tests--should-reject
   "return { [\"a\"] = 1, [\"a\"] = 2, }"))

(ert-deftest org-remark-koreader-lua/refuses-an-unknown-escape ()
  "An unknown escape is not let through silently."
  (org-remark-koreader-lua-tests--should-reject
   "return { [\"a\"] = \"path\\qto\", }"))

(ert-deftest org-remark-koreader-lua/limits-are-enforced ()
  "Depth, field count and string length are bounded."
  (let ((org-remark-koreader-lua-max-depth 2))
    (org-remark-koreader-lua-tests--should-reject
     "return { [\"a\"] = { [\"b\"] = { [\"c\"] = { [\"d\"] = 1, }, }, }, }"))
  (let ((org-remark-koreader-lua-max-entries 2))
    (org-remark-koreader-lua-tests--should-reject
     "return { [\"a\"] = 1, [\"b\"] = 2, [\"c\"] = 3, }"))
  (let ((org-remark-koreader-lua-max-string-length 4))
    (org-remark-koreader-lua-tests--should-reject
     "return { [\"a\"] = \"far too long\", }")))

(ert-deftest org-remark-koreader-lua/a-list-with-a-gap-fails ()
  "A missing element must not pass as a shorter list."
  (let ((table (org-remark-koreader-lua-tests--read
                "return { [1] = \"a\", [3] = \"c\", }")))
    (should-error (org-remark-koreader-lua-array table)
                  :type 'org-remark-koreader-lua-error)))

(ert-deftest org-remark-koreader-lua/an-error-names-place-and-version ()
  "A message has to be traceable: origin, line and target version."
  (let ((message (org-remark-koreader-lua-tests--error
                  "return {\n  [\"a\"] = 1,\n  [\"b\"] = os.time(),\n}")))
    (should (string-match-p "\\`test: " message))
    (should (string-match-p "line 3" message))
    (should (string-match-p "v2026\\.07" message))))

(provide 'org-remark-koreader-lua-tests)
;;; org-remark-koreader-lua-tests.el ends here
