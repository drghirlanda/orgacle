;;; init.el --- Batch bootstrap for the epresent test suite  -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded with -l before every batch target in the Makefile.  Provisions the
;; packages needed to lint and test epresent into ./.deps, so that `make'
;; needs nothing on the machine but Emacs itself, and puts the project root
;; on `load-path'.

;;; Code:

(require 'package)
(require 'seq)

(defconst epresent-dev-dependencies '(package-lint org-superstar)
  "Packages needed to lint and test epresent, but not to use it.
`org-superstar' is here only until it is made optional; see Task 11.")

(setq package-user-dir (expand-file-name ".deps" default-directory)
      package-archives '(("gnu"   . "https://elpa.gnu.org/packages/")
                         ("melpa" . "https://melpa.org/packages/")))

(package-initialize)

(let ((missing (seq-remove #'package-installed-p epresent-dev-dependencies)))
  (when missing
    (package-refresh-contents)
    (mapc #'package-install missing)))

(add-to-list 'load-path default-directory)

(provide 'init)
;;; init.el ends here
