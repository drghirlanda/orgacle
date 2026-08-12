;;; checkdoc-batch.el --- Fail the build on checkdoc complaints  -*- lexical-binding: t; -*-

;;; Commentary:

;; `checkdoc-file' prints its complaints but never changes the exit status,
;; so a Makefile or a CI job cannot tell a clean run from a dirty one.  This
;; wrapper counts complaints through `checkdoc-create-error-function' and
;; exits non-zero when there are any.
;;
;; Usage: emacs -Q --batch -l test/checkdoc-batch.el FILE...

;;; Code:

(require 'checkdoc)

(defvar epresent-checkdoc-count 0
  "Number of complaints seen during this batch run.")

(setq checkdoc-create-error-function
      (lambda (text start _end &optional _unfixable)
        (setq epresent-checkdoc-count (1+ epresent-checkdoc-count))
        (message "%s:%d: %s"
                 (file-name-nondirectory (or (buffer-file-name) "?"))
                 (line-number-at-pos (or start (point)))
                 text)
        nil))

(let ((files (or command-line-args-left '("epresent.el"))))
  (dolist (file files)
    (checkdoc-file file))
  (if (zerop epresent-checkdoc-count)
      (message "checkdoc: clean (%d file(s))" (length files))
    (message "checkdoc: %d complaint(s)" epresent-checkdoc-count)
    (kill-emacs 1)))

(provide 'checkdoc-batch)
;;; checkdoc-batch.el ends here
