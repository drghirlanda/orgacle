;;; epresent-test.el --- Tests for epresent  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with `make test'.  Everything here must work in batch mode on a
;; machine with no window system, so nothing may create a frame, wait on
;; redisplay, or start a subprocess.

;;; Code:

(require 'ert)
(require 'org)
(require 'epresent)

(defconst epresent-test-fixture-directory
  (expand-file-name "fixtures"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Directory holding the Org fixtures these tests run against.")

(defmacro epresent-test-with-fixture (name &rest body)
  "Visit fixture NAME in a temporary Org buffer and evaluate BODY there."
  (declare (indent 1) (debug (form body)))
  `(with-temp-buffer
     (insert-file-contents
      (expand-file-name ,name epresent-test-fixture-directory))
     (let ((org-mode-hook nil))
       (org-mode))
     ,@body))

(ert-deftest epresent-test-harness-works ()
  "The fixture directory exists and `epresent' is loadable."
  (should (file-directory-p epresent-test-fixture-directory))
  (should (featurep 'epresent)))

(provide 'epresent-test)
;;; epresent-test.el ends here
